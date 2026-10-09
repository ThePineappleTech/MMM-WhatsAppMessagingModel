"""
MMM (Moving Messaging Model) — automated retraining. No CSV downloads: everything goes through Snowflake.

    python MMM_auto_retrain.py              # full run: rebuild frame, train, compare, publish if it passes
    python MMM_auto_retrain.py --dry-run    # everything except writing weights / registry rows
    python MMM_auto_retrain.py --skip-build # reuse the existing training frame (faster while testing)
    python MMM_auto_retrain.py --force      # promote even if the gate says no (use deliberately)

What one run does
  1. Connects with the same RSA-key-from-S3 pattern as your Streamlit apps (user PROGRAM).
  2. Rebuilds sandbox.pineapp_will.cpc_training_frame by running MMM_build_training_frame.sql
     (Aug + Sep campaigns + every pick in CONTINUOUS_PUSH_CAMPAIGN_HISTORY).
  3. Pulls the frame into pandas (phone numbers are never pulled).
  4. Trains the challenger with MMM_train.py: fit on everything except the latest batch, test on
     the latest batch; then refit on everything for the production weights.
  5. Scores the same test batch with the current champion's weights (exactly as the SQL does).
  6. GATE — the challenger is promoted only if:
       * the test batch has at least MIN_TEST_CLICKS clicks, and
       * challenger test AUC >= MIN_AUC, and
       * challenger test AUC >= champion test AUC - TOLERANCE (when the comparison is fair, i.e.
         the champion never saw the test batch).
  7. Loads the weights into CPC_MODEL_WEIGHTS as <version>_deliver / <version>_click and records the
     run in CPC_MODEL_REGISTRY. If promoted, it becomes status 'champion' and the daily production
     SQL picks it up automatically on its next run. Rejected runs are recorded as 'rejected'.
  8. Writes a JSON run report to ./mmm_runs/.

Schedule it monthly (Windows Task Scheduler, cron, or n8n). Retraining more often than monthly adds
little: a month of 100 sends/day is roughly 3,000 sends and ~20-40 clicks.

Requirements:  pip install -r requirements.txt
Environment:   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY  (same as your Streamlit apps), either set in the
               terminal or in a .env file in this folder. They are used ONLY to download the Snowflake
               private key (rsa_key.p8) from S3, nothing else touches AWS.
"""
import argparse
import json
import os
import sys
from datetime import datetime

import boto3
import pandas as pd
import snowflake.connector
from cryptography.hazmat.primitives import serialization
from snowflake.connector.pandas_tools import write_pandas

import MMM_train as mmm   # the training module (same folder)

# Load AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY from a .env file next to this script, if present
# (same keys your Streamlit apps use). Variables already set in the terminal take priority.
try:
    from dotenv import load_dotenv
    load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), '.env'))
except ImportError:
    pass

# ----------------------------------------------------------------------------------- settings
HERE = os.path.dirname(os.path.abspath(__file__))
BUILD_SQL = os.path.join(HERE, 'MMM_build_training_frame.sql')
FRAME_TABLE = 'sandbox.pineapp_will.cpc_training_frame'
WEIGHTS_TABLE = 'PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CPC_MODEL_WEIGHTS'
REGISTRY_TABLE = 'PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CPC_MODEL_REGISTRY'
ROLE = None              # e.g. 'ACCOUNTADMIN' if PROGRAM's default role lacks access; None = default role

MIN_AUC = 0.65           # absolute floor for the challenger on the test batch
TOLERANCE = 0.01         # challenger may be this much below the champion and still be promoted
MIN_TEST_CLICKS = 30     # below this the test is too noisy to judge -> keep the champion


def log(*a):
    print(f'[{datetime.now():%H:%M:%S}]', *a, flush=True)


# ----------------------------------------------------------------------------------- snowflake
def get_snowflake_conn():
    """Same pattern as the Streamlit apps, minus st.cache_resource. Errors are allowed to raise."""
    s3 = boto3.client('s3', aws_access_key_id=os.getenv('AWS_ACCESS_KEY_ID'),
                      aws_secret_access_key=os.getenv('AWS_SECRET_ACCESS_KEY'))
    obj = s3.get_object(Bucket='sftp.data.upload', Key='n8n_lambda_snowflake/rsa_key.p8')
    p_key = serialization.load_pem_private_key(obj['Body'].read(), password=None)
    pkb = p_key.private_bytes(encoding=serialization.Encoding.DER,
                              format=serialization.PrivateFormat.PKCS8,
                              encryption_algorithm=serialization.NoEncryption())
    kwargs = dict(user='PROGRAM', account='QFB99976.us-west-2', private_key=pkb,
                  warehouse='compute_wh', database='SANDBOX', schema='PINEAPP_WILL')  # default only, every query is fully qualified
    if ROLE:
        kwargs['role'] = ROLE
    return snowflake.connector.connect(**kwargs)


def query_df(conn, sql, params=None) -> pd.DataFrame:
    cur = conn.cursor()
    try:
        cur.execute(sql, params)
        return cur.fetch_pandas_all()
    finally:
        cur.close()


def current_champion(conn):
    reg = query_df(conn, f"""SELECT model_version, trained_through FROM {REGISTRY_TABLE}
                             WHERE status = 'champion' ORDER BY promoted_at DESC LIMIT 1""")
    if reg.empty:
        return None, None, None
    version, through = reg.iloc[0, 0], reg.iloc[0, 1]
    w = query_df(conn, f"""SELECT model_version, feature, feature_level, coef FROM {WEIGHTS_TABLE}
                           WHERE model_version IN (%s, %s)""", (f'{version}_deliver', f'{version}_click'))
    w.columns = [c.lower() for c in w.columns]
    w['model'] = w.model_version.str.rsplit('_', n=1).str[-1]
    w = w.rename(columns={'feature_level': 'level'})[['model', 'feature', 'level', 'coef']]
    w['level'] = w.level.fillna('')
    return version, through, w


# ----------------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true', help='train and compare, but write nothing')
    ap.add_argument('--skip-build', action='store_true', help='reuse the existing training frame')
    ap.add_argument('--force', action='store_true', help='promote even if the gate fails')
    args = ap.parse_args()

    version = f'MMM_v{datetime.now():%Y%m%d}'
    report = {'version': version, 'started': datetime.now().isoformat(timespec='seconds'), 'args': vars(args)}
    conn = get_snowflake_conn()
    log('connected to Snowflake')
    try:
        if not args.skip_build:
            log('rebuilding the training frame (several minutes)...')
            for cur in conn.execute_string(open(BUILD_SQL).read()):
                cur.close()
        frame = query_df(conn, f'SELECT * EXCLUDE (phone9, audience_id) FROM {FRAME_TABLE}')
        log(f'pulled training frame: {len(frame):,} rows')

        tmpl = query_df(conn, 'SELECT template_id FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CPC_DISCOUNT_TEMPLATES')
        if len(tmpl):
            mmm.TEMPLATES = set(tmpl.iloc[:, 0].astype(str).str.strip())
        log(f'discount templates used for training: {sorted(mmm.TEMPLATES)}')

        champ_version, champ_through, champ_w = current_champion(conn)
        log(f'current champion: {champ_version} (trained through {champ_through})')

        out = mmm.run(frame, champion_weights=champ_w, champion_trained_through=champ_through, log=log)
        ch, cp = out['challenger'], out['champion']

        reasons = []
        if ch['clicks'] < MIN_TEST_CLICKS:
            reasons.append(f'test batch has only {ch["clicks"]} clicks (< {MIN_TEST_CLICKS})')
        if not ch['auc'] >= MIN_AUC:
            reasons.append(f'challenger AUC {ch["auc"]:.3f} < floor {MIN_AUC}')
        if cp is not None and ch['auc'] < cp['auc'] - TOLERANCE:
            reasons.append(f'challenger AUC {ch["auc"]:.3f} < champion {cp["auc"]:.3f} - {TOLERANCE}')
        promote = (not reasons) or args.force
        status = 'champion' if promote else 'rejected'
        log(f'GATE: {"PROMOTE" if promote else "KEEP CHAMPION"}' + (f' ({"; ".join(reasons)})' if reasons else '')
            + (' [--force]' if args.force and reasons else ''))

        report.update({'status': status, 'gate_reasons': reasons, 'challenger': ch, 'champion': cp,
                       'champion_version': champ_version, 'test_batches': out['test_batches'],
                       'train_rows': out['train_rows'], 'train_clicks': out['train_clicks'],
                       'trained_through': out['trained_through'],
                       'by_segment': out['by_segment']})

        if args.dry_run:
            log('dry run: nothing written to Snowflake')
        else:
            w = out['weights']
            up = pd.DataFrame({'MODEL_VERSION': version + '_' + w.model, 'FEATURE': w.feature,
                               'FEATURE_LEVEL': w.level.astype(str), 'COEF': w.coef.astype(float)})
            cur = conn.cursor()
            cur.execute(f'DELETE FROM {WEIGHTS_TABLE} WHERE model_version IN (%s, %s)',
                        (version + '_deliver', version + '_click'))
            ok, _, n, _ = write_pandas(conn, up, table_name='CPC_MODEL_WEIGHTS', database='PINEAPPLE_DATABASE',
                                       schema='MESSAGING_AUDIENCES', quote_identifiers=False)
            if not ok:
                raise RuntimeError('weights upload failed')
            if promote:
                cur.execute(f"UPDATE {REGISTRY_TABLE} SET status = 'retired' WHERE status = 'champion'")
            cur.execute(f"""INSERT INTO {REGISTRY_TABLE}
                (model_version, status, created_at, promoted_at, trained_through, train_rows, train_clicks,
                 test_batch, test_rows, test_clicks, test_auc, test_top10_capture, champion_version,
                 champion_test_auc, notes)
                VALUES (%s, %s, SYSDATE(), IFF(%s, SYSDATE(), NULL), %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)""",
                (version, status, promote, out['trained_through'], out['train_rows'], out['train_clicks'],
                 ','.join(out['test_batches']), ch['rows'], ch['clicks'], ch['auc'], ch['top10_capture'],
                 champ_version, None if cp is None else cp['auc'], '; '.join(reasons) or None))
            cur.close()
            log(f'loaded {n} weights as {version}_deliver/_click; registry status = {status}')
    finally:
        conn.close()
        os.makedirs(os.path.join(HERE, 'mmm_runs'), exist_ok=True)
        report['finished'] = datetime.now().isoformat(timespec='seconds')
        with open(os.path.join(HERE, 'mmm_runs', f'{version}.json'), 'w') as fh:
            json.dump(report, fh, indent=2, default=str)
    return 0 if report.get('status') == 'champion' or args.dry_run else 1


if __name__ == '__main__':
    sys.exit(main())