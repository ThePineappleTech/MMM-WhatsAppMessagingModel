"""MMM (Moving Messaging Model) — delivery model x click model (two logistic GLMs).

Use it two ways:
  1) By hand:     python MMM_train.py            (reads cpc_training_frame.csv, writes MMM_weights.csv)
  2) Automated:   imported by MMM_auto_retrain.py, which pulls the frame straight from Snowflake.

  p_click (per message sent) = P(delivered) x P(click | delivered)
  * deliver model: all campaign sends,      target = delivered or read
  * click   model: delivered sends only,    target = tracked-link click within 7 days

Validation: train on everything except the latest batch, test on the latest batch (the batch is
the campaign for AUG/SEP, and the calendar month for the continuous process 'CPC_YYYYMMDD').
Production: refit on everything, intercepts recalibrated to the latest batch.
"""
import os
import warnings

import numpy as np
import pandas as pd
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_auc_score
from sklearn.model_selection import StratifiedKFold, cross_val_score
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import OneHotEncoder

warnings.filterwarnings('ignore')

# ----------------------------------------------------------------------------------- settings
# Campaign WhatsApp templates whose sends count as training examples. MMM_auto_retrain.py replaces this
# with the contents of PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CPC_DISCOUNT_TEMPLATES before training,
# so the Snowflake table is the one place to register new templates. This default is for manual CSV runs.
TEMPLATES = {'00158', '00159', '00164', '00165'}
MIN_DAYS_OBSERVED = 7            # a send needs 7 full days before its click label is final
MIN_TEST_CLICKS = 40             # the test batch is widened backwards until it has this many clicks
C_GRID = [0.03, 0.1, 0.3]        # L2 strengths tried by 5-fold CV
INCLUDE_DISCOUNT_FEATURES = False  # tested Oct 2026: no gain (AUC 0.756 without vs 0.754 with)


# ----------------------------------------------------------------------------------- data prep
def prepare(frame: pd.DataFrame) -> pd.DataFrame:
    """Keep real, matured, treated campaign sends; apply the phone-first rule."""
    d = frame.copy()
    d.columns = [c.upper() for c in d.columns]
    d['TEMPLATE_ID'] = d.TEMPLATE_ID.astype(str).str.strip().str.replace(r'\.0$', '', regex=True).str.zfill(5)
    keep = (d.TEMPLATE_ID.isin(TEMPLATES)
            & (d.SOLD_BEFORE_ANCHOR == 0)
            & ~d.SEGMENT.str.endswith('_CTRL')
            & (d.DAYS_OBSERVED >= MIN_DAYS_OBSERVED))
    d = d[keep].copy()
    phone_first = (d.DAYS_SINCE_LAST_CALLBACK <= 1) | (d.DAYS_SINCE_LAST_LEAD <= 1)
    d = d[~phone_first].copy()
    d['DELIVERED'] = d.SEND_STATUS.isin(['read', 'delivered']).astype(int)
    # batch = campaign for the old bulk sends, calendar month for the continuous process
    d['BATCH'] = np.where(d.CAMPAIGN.str.startswith('CPC_'), 'CPC_' + d.CAMPAIGN.str[4:10], d.CAMPAIGN)
    d['BATCH_START'] = pd.to_datetime(d.ANCHOR_TS).groupby(d.BATCH).transform('min')
    return d


def _cut(s, bins, labels):
    return pd.cut(s, bins, labels=labels, right=True).cat.add_categories('none').fillna('none').astype(str)


def build_features(d: pd.DataFrame) -> pd.DataFrame:
    """Binned features. Bin edges and labels must match the CASE statements in MMM_production_scoring.sql."""
    X = pd.DataFrame(index=d.index)
    X['segment'] = d.SEGMENT
    X['lead_age'] = _cut(d.DAYS_SINCE_LAST_LEAD, [-1, 3, 7, 15, 30, 90, 180, 365, 1e5],
                         ['0-3d', '4-7d', '8-15d', '16-30d', '31-90d', '91-180d', '181-365d', '365d+'])
    X['quote_age'] = _cut(d.DAYS_SINCE_LAST_QUOTE, [-1, 14, 45, 90, 180, 365, 1e5],
                          ['0-14d', '15-45d', '46-90d', '91-180d', '181-365d', '365d+'])
    X['call_age'] = _cut(d.DAYS_SINCE_LAST_CALL, [-1, 2, 7, 30, 90, 180, 1e5],
                         ['0-2d', '3-7d', '8-30d', '31-90d', '91-180d', '180d+'])
    X['callback_age'] = _cut(d.DAYS_SINCE_LAST_CALLBACK, [-1, 7, 30, 90, 1e5], ['0-7d', '8-30d', '31-90d', '90d+'])
    X['last_outcome'] = d.LAST_OUTCOME_GROUP.replace({'dnc': 'other_connected', 'existing_policyholder': 'other_connected',
                                                      'sale_made': 'other_connected', 'no_insurable_risk': 'other_connected'})
    X['calls_30d'] = _cut(d.N_CALLS_30D_BEFORE, [-1, 0, 2, 5, 1e5], ['0', '1-2', '3-5', '6+'])
    X['lead_type'] = d.LEAD_TYPE
    X['leads_30d'] = _cut(d.N_LEADS_30D_BEFORE, [-1, 0, 1, 1e5], ['0', '1', '2+'])
    X['last_source'] = d.LAST_ATTR_SOURCE.fillna('unknown')
    X['first_source'] = d.FIRST_ATTR_SOURCE.fillna('unknown')
    first_all = d.FIRST_ALL_SOURCE_TBL
    if 'FIRST_ALL_SRC' in d:                       # continuous rows have no campaign-table value
        first_all = first_all.fillna(d.FIRST_ALL_SRC)
    X['first_all'] = first_all.where(first_all.isin(['provider', 'googlepaid', 'facebookads', 'tiktokads', 'googleorganic',
                                                     'partnership', 'directtraffic', 'web', 'webunknown', 'dealership',
                                                     'bingpaid', 'appunknown']), 'other')
    X['premium'] = _cut(d.PRE_PREM, [-1, 1000, 1500, 2000, 3000, 1e7], ['<1000', '1000-1500', '1500-2000', '2000-3000', '3000+'])
    X['dialer_ch'] = _cut(d.DIALER_CHANNEL_FACTOR, [0, 0.6, 0.9, 1.1, 1.4, 10], ['<0.6', '0.6-0.9', '0.9-1.1', '1.1-1.4', '1.4+'])
    X['prior_click'] = np.where(d.N_PRIOR_CAMPAIGN_CLICKS > 0, 'yes', 'no')
    X['wa_delivered'] = _cut(d.N_WA_DELIVERED_180D, [-1, 0, 2, 5, 1e5], ['0', '1-2', '3-5', '6+'])
    X['wa_failed'] = _cut(d.N_WA_FAILED_180D, [-1, 0, 1, 1e5], ['0', '1', '2+'])
    rr = d.N_WA_READ_180D / d.N_WA_DELIVERED_180D.replace(0, np.nan)
    X['wa_read_rate'] = _cut(rr, [-0.01, 0, 0.499, 0.999, 1.01], ['0', '1-49%', '50-99%', '100%'])
    X['wa_replied'] = np.where(d.N_REPLIES_180D > 0, 'yes', 'no')
    # repeat-messaging history (added Oct 2026): how recently, and how often in the last 28 days, this
    # person received a delivered DISCOUNT WhatsApp. Little variation in the Aug/Sep data, so the weights
    # start near zero; they become informative once the continuous process has repeated people.
    if 'DAYS_SINCE_LAST_DISC_MSG' in d:
        X['disc_msg_age'] = _cut(d.DAYS_SINCE_LAST_DISC_MSG, [-1, 7, 14, 28, 60, 1e5],
                                 ['0-7d', '8-14d', '15-28d', '29-60d', '61d+'])
        X['disc_msgs_28d'] = _cut(d.N_DISC_DELIVERED_28D, [-1, 0, 1, 1e5], ['0', '1', '2+'])
    if INCLUDE_DISCOUNT_FEATURES:
        X['prior_quote_disc'] = _cut(d.PRIOR_DISC.where(d.SEGMENT != 'L2S'), [-0.01, 0, 4, 8, 100], ['0', '0-4', '4-8', '8+'])
        X['prev_disc_offer'] = _cut(d.PREV_DISC_OFFER_PCT, [0, 10, 14, 15, 17, 100], ['10', '11-14', '15', '17', '20'])
        X['prev_disc_status'] = d.PREV_DISC_MSG_STATUS.fillna('none')
        X['prev_disc_age'] = _cut(d.DAYS_SINCE_PREV_DISC_MSG, [-1, 21, 35, 1e5], ['0-21d', '22-35d', '36d+'])
    return X


def split_latest(d: pd.DataFrame):
    """Test = the latest batch, widened backwards until it holds MIN_TEST_CLICKS clicks."""
    order = d.groupby('BATCH').BATCH_START.min().sort_values(ascending=False).index.tolist()
    test, clicks = [], 0
    for b in order[:-1]:                           # always leave at least one batch to train on
        test.append(b); clicks += int(d.loc[d.BATCH == b, 'CLICK_7D'].sum())
        if clicks >= MIN_TEST_CLICKS:
            break
    te = d.BATCH.isin(test).values
    return ~te, te, test


# ----------------------------------------------------------------------------------- modelling
def _pipe(C):
    return make_pipeline(OneHotEncoder(handle_unknown='ignore', min_frequency=100), LogisticRegression(C=C, max_iter=4000))


def fit(X, y, log=print, label=''):
    cv = StratifiedKFold(5, shuffle=True, random_state=1)
    scores = {C: cross_val_score(_pipe(C), X, y, cv=cv, scoring='roc_auc').mean() for C in C_GRID}
    C = max(scores, key=scores.get)
    log(f'  {label}: CV AUC ' + ', '.join(f'C={k}: {v:.3f}' for k, v in scores.items()) + f'  -> C={C}')
    return _pipe(C).fit(X, y)


def recalibrate(model, X, y):
    """Shift the intercept so the mean prediction on (X, y) equals y's actual rate."""
    lr = model.named_steps['logisticregression']
    z = lr.decision_function(model.named_steps['onehotencoder'].transform(X))
    lo, hi = -3.0, 3.0
    for _ in range(60):
        mid = (lo + hi) / 2
        if (1 / (1 + np.exp(-(z + mid)))).mean() > y.mean():
            hi = mid
        else:
            lo = mid
    shift = (lo + hi) / 2
    lr.intercept_ = lr.intercept_ + shift
    return shift


def weights_table(models: dict, features: list) -> pd.DataFrame:
    """One row per (model, feature, level). Infrequent levels carry the pooled weight; unseen levels score 0."""
    rows = []
    for name, model in models.items():
        oh, lr = model.named_steps['onehotencoder'], model.named_steps['logisticregression']
        coef = pd.Series(lr.coef_[0], index=oh.get_feature_names_out(features))
        for i, (f, cats) in enumerate(zip(features, oh.categories_)):
            inf = set(oh.infrequent_categories_[i] or [])
            for c in cats:
                key = f'{f}_infrequent_sklearn' if c in inf else f'{f}_{c}'
                rows.append({'model': name, 'feature': f, 'level': str(c), 'coef': round(float(coef.get(key, 0.0)), 4)})
        rows.append({'model': name, 'feature': 'intercept', 'level': '', 'coef': round(float(lr.intercept_[0]), 4)})
    return pd.DataFrame(rows)


def score_with_weights(X: pd.DataFrame, w: pd.DataFrame) -> pd.Series:
    """Score exactly the way the production SQL does: sum one weight per level, sigmoid, deliver x click."""
    out = {}
    for name in ('deliver', 'click'):
        ww = w[w.model == name]
        z = pd.Series(float(ww.loc[ww.feature == 'intercept', 'coef'].iloc[0]), index=X.index)
        for f in X.columns:
            lut = ww[ww.feature == f].set_index('level').coef
            z += X[f].map(lut).fillna(0.0)
        out[name] = 1 / (1 + np.exp(-z))
    return out['deliver'] * out['click']


def evaluate(t: pd.DataFrame, p, label='CLICK_7D') -> dict:
    s = t.assign(_p=np.asarray(p)).sort_values('_p', ascending=False)
    n, tot = len(s), s[label].sum()
    res = {'rows': int(n), 'clicks': int(tot), 'auc': float(roc_auc_score(s[label], s._p)) if 0 < tot < n else float('nan')}
    for k in (10, 30, 50):
        res[f'top{k}_capture'] = float(s[label].iloc[:int(n * k / 100)].sum() / tot) if tot else float('nan')
    return res


def run(frame: pd.DataFrame, champion_weights: pd.DataFrame | None = None,
        champion_trained_through=None, log=print) -> dict:
    """Full pipeline. Returns weights, validation metrics, and the champion's metrics on the same test batch."""
    d = prepare(frame)
    X = build_features(d)
    features = list(X.columns)
    y_del, y_clk = d.DELIVERED.values, d.CLICK_7D.values
    tr, te, test_batches = split_latest(d)
    log(f'training rows {tr.sum():,} (clicks {y_clk[tr].sum()}), test batch {test_batches} '
        f'rows {te.sum():,} (clicks {y_clk[te].sum()})')

    log('VALIDATION (fit on train, score test):')
    m_del = fit(X[tr], y_del[tr], log, 'deliver')
    dl = tr & (y_del == 1)
    m_clk = fit(X[dl], y_clk[dl], log, 'click|delivered')
    t = d[te].copy()
    p = m_del.predict_proba(X[te])[:, 1] * m_clk.predict_proba(X[te])[:, 1]
    challenger = evaluate(t, p)
    challenger['deliver_auc'] = float(roc_auc_score(t.DELIVERED, m_del.predict_proba(X[te])[:, 1]))
    log(f'  challenger: AUC {challenger["auc"]:.3f}  top10 {challenger["top10_capture"]:.0%}  '
        f'top30 {challenger["top30_capture"]:.0%}  deliver AUC {challenger["deliver_auc"]:.3f}')
    by_seg = {s: evaluate(g, p[(t.SEGMENT == s).values]) for s, g in t.groupby('SEGMENT')}
    for s, r in by_seg.items():
        log(f'    {s:9s} rows {r["rows"]:6,} clicks {r["clicks"]:3d}  AUC {r["auc"]:.3f}')

    champion = None
    test_start = pd.to_datetime(t.ANCHOR_TS).min()
    if champion_trained_through is not None and pd.Timestamp(champion_trained_through).date() >= test_start.date():
        log(f'  champion: not compared — it was trained on data up to {champion_trained_through}, '
            f'which overlaps the test batch (starts {test_start:%Y-%m-%d})')
        champion_weights = None
    if champion_weights is not None and len(champion_weights):
        pc = score_with_weights(X[te], champion_weights)
        champion = evaluate(t, pc.values)
        log(f'  champion:   AUC {champion["auc"]:.3f}  top10 {champion["top10_capture"]:.0%}  '
            f'top30 {champion["top30_capture"]:.0%}')

    log('PRODUCTION FIT (all rows, intercepts recalibrated to the test batch):')
    P_del = fit(X, y_del, log, 'deliver')
    P_clk = fit(X[y_del == 1], y_clk[y_del == 1], log, 'click|delivered')
    sh_d = recalibrate(P_del, X[te], y_del[te])
    sh_c = recalibrate(P_clk, X[te & (y_del == 1)], y_clk[te & (y_del == 1)])
    log(f'  intercept shifts: deliver {sh_d:+.3f}, click {sh_c:+.3f}')
    w = weights_table({'deliver': P_del, 'click': P_clk}, features)

    # self-check: lookup scoring (what the SQL does) must equal sklearn's own predictions
    chk = score_with_weights(X, w).values
    ref = P_del.predict_proba(X)[:, 1] * P_clk.predict_proba(X)[:, 1]
    if np.max(np.abs(chk - ref)) > 1e-3:
        raise RuntimeError('weights table does not reproduce the model — do not publish')

    return {'weights': w, 'challenger': challenger, 'champion': champion, 'by_segment': by_seg,
            'test_batches': test_batches, 'train_rows': int(tr.sum()), 'train_clicks': int(y_clk[tr].sum()),
            'trained_through': str(pd.to_datetime(d.ANCHOR_TS).max().date())}


if __name__ == '__main__':
    frame = pd.read_csv(os.environ.get('CPC_FRAME_CSV', 'cpc_training_frame.csv'), low_memory=False)
    out = run(frame)
    path = os.environ.get('CPC_WEIGHTS_CSV', 'MMM_weights.csv')
    out['weights'].to_csv(path, index=False)
    print(f'wrote {len(out["weights"])} weights to {path}')