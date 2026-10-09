/* =====================================================================================
   CONTINUOUS PUSH CAMPAIGN — PRODUCTION SCORING (MMM_v3: P(delivered) x P(click | delivered))
   -------------------------------------------------------------------------------------
   NO PYTHON NEEDED TO RUN THIS. MMM_v3 is two logistic GLMs:
     deliver model  P(the WhatsApp is delivered)          weights: model_version = 'MMM_v3_deliver'
     click model    P(tracked-link click | delivered)     weights: model_version = 'MMM_v3_click'
   Each is "add one weight per feature level, then 1/(1+exp(-z))"; the ranking score is
   p_click = p_deliver x p_click_if_delivered (expected clicks per message sent).
   WhatsApp history is counted per MESSAGE (Twilio SID), not per status-event row.

   PART 1  One-time setup: weights table + ledger table              (run once)
   PART 2  Daily build: continuous_push_campaign_audience            (daily, ~10:30)
   PART 3  Daily pick: continuous_push_campaign_send_today + controls (daily, after 2)
   PART 4  After Tania's process has sent: write sent rows to ledger (daily, after send)
   PART 5  Checks

   ELIGIBILITY = your September build (phase2_q2s_all_scored_sep2026 + L2S Sept build),
   re-run as of today, with four deliberate changes:
     1. Discount rule: Q2S offer = GREATEST(7, CEIL(prior)+3, CEIL(PSM rmd) if rmd > prior,
        CEIL(alpha locked DUT) if alpha active); EXCLUDED (not capped) if > 17.
        L2S stays at a flat 10.
     2. Call history uses all three sales campaigns (adds Motor Leads - Inactive).
     3. Phone-first rule: no message if a Callback Scheduled outcome in the last 1 day, or a
        new lead in the last 1 day. The floor is still working them.
     4. Selection cooldown: no one selected (either arm) in the last 7 days.
     5. 7-day spam guard (view CONTINUOUS_PUSH_CAMPAIGN_DO_NOT_MESSAGE_7D): nobody who received
        a discount WhatsApp, or was picked/sent by this process, in the last 7 days. Applied
        when picking (Part 2) AND again when building Tania's send table (Part 3).
   Holdout: arm = hash(phone) -> 50% treated / 50% control, fixed for life. Each day the
   top 2N by score are selected; treated go to Tania, control go straight to the ledger.
   ===================================================================================== */

USE ROLE ACCOUNTADMIN;

SET daily_n        = 100;     -- treated sends per day (control adds roughly the same again)
SET cooldown_days  = 7;      -- selection cooldown in days (same as the 7-day spam guard)
-- model_version is read from CPC_MODEL_REGISTRY at the start of Part 2 (the current champion)


/* =====================================================================================
   PART 1 — ONE-TIME SETUP
   ===================================================================================== */

CREATE TABLE IF NOT EXISTS PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CPC_MODEL_WEIGHTS (
    model_version  VARCHAR,
    feature        VARCHAR,
    feature_level  VARCHAR,
    coef           FLOAT,
    loaded_at      TIMESTAMP_NTZ DEFAULT SYSDATE()
);

-- append-only ledger: one row per person per selection (treated AND control)
CREATE TABLE IF NOT EXISTS PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_HISTORY (
    phone_number                   VARCHAR,
    phone9                         VARCHAR,
    audience                       VARCHAR,     -- Q2S_LT45 / Q2S_GT45 / L2S
    arm                            VARCHAR,     -- treated / control
    was_sent                       BOOLEAN,
    selected_date                  DATE,
    rank_on_day                    NUMBER,
    model_version                  VARCHAR,
    p_click                        FLOAT,
    prior_discount_percentage      FLOAT,
    psm_rmd                        FLOAT,
    offered_discount_percentage    NUMBER,
    premium_without_any_discounts  FLOAT,
    last_quoted_premium            FLOAT,
    new_premium_offered            FLOAT,
    logged_at                      TIMESTAMP_NTZ DEFAULT SYSDATE()
);

-- model registry: which weight version is live. MMM_auto_retrain.py appends a row per retrain and
-- promotes a new champion only if it passes the gate; Part 2 always scores with the current champion.
CREATE TABLE IF NOT EXISTS PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CPC_MODEL_REGISTRY (
    model_version       VARCHAR,
    status              VARCHAR,          -- champion / retired / rejected
    created_at          TIMESTAMP_NTZ,
    promoted_at         TIMESTAMP_NTZ,
    trained_through     DATE,             -- last send date in its training data
    train_rows          NUMBER,
    train_clicks        NUMBER,
    test_batch          VARCHAR,
    test_rows           NUMBER,
    test_clicks         NUMBER,
    test_auc            FLOAT,
    test_top10_capture  FLOAT,
    champion_version    VARCHAR,
    champion_test_auc   FLOAT,
    notes               VARCHAR
);

INSERT INTO PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CPC_MODEL_REGISTRY
    (model_version, status, created_at, promoted_at, trained_through, train_rows, train_clicks,
     test_batch, test_rows, test_clicks, test_auc, test_top10_capture, notes)
SELECT 'MMM_v3', 'champion', SYSDATE(), SYSDATE(), '2026-09-16', 52238, 307, 'SEP', 20723, 116, 0.756, 0.379,
       'initial manual release (trained in chat, Oct 2026)'
WHERE NOT EXISTS (SELECT 1 FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CPC_MODEL_REGISTRY);

-- load MMM_v3 weights, both models (delete first so re-running doesn't duplicate)
DELETE FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CPC_MODEL_WEIGHTS WHERE model_version IN ('MMM_v3_deliver', 'MMM_v3_click');
INSERT INTO PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CPC_MODEL_WEIGHTS (model_version, feature, feature_level, coef) VALUES
    ('MMM_v3_deliver', 'segment', 'L2S', -0.0935),
    ('MMM_v3_deliver', 'segment', 'Q2S_GT45', 0.2811),
    ('MMM_v3_deliver', 'segment', 'Q2S_LT45', 0.0552),
    ('MMM_v3_deliver', 'lead_age', '0-3d', 0.8579),
    ('MMM_v3_deliver', 'lead_age', '16-30d', -0.5413),
    ('MMM_v3_deliver', 'lead_age', '181-365d', -0.1547),
    ('MMM_v3_deliver', 'lead_age', '31-90d', -0.1033),
    ('MMM_v3_deliver', 'lead_age', '365d+', -0.2975),
    ('MMM_v3_deliver', 'lead_age', '4-7d', 0.8518),
    ('MMM_v3_deliver', 'lead_age', '8-15d', -0.2253),
    ('MMM_v3_deliver', 'lead_age', '91-180d', -0.1448),
    ('MMM_v3_deliver', 'quote_age', '0-14d', 0.089),
    ('MMM_v3_deliver', 'quote_age', '15-45d', -0.2122),
    ('MMM_v3_deliver', 'quote_age', '181-365d', 0.1305),
    ('MMM_v3_deliver', 'quote_age', '365d+', 1.7061),
    ('MMM_v3_deliver', 'quote_age', '46-90d', -0.7281),
    ('MMM_v3_deliver', 'quote_age', '91-180d', -0.698),
    ('MMM_v3_deliver', 'quote_age', 'none', -0.0446),
    ('MMM_v3_deliver', 'call_age', '0-2d', -0.123),
    ('MMM_v3_deliver', 'call_age', '180d+', 0.0128),
    ('MMM_v3_deliver', 'call_age', '3-7d', 0.1058),
    ('MMM_v3_deliver', 'call_age', '31-90d', -0.0176),
    ('MMM_v3_deliver', 'call_age', '8-30d', 0.1788),
    ('MMM_v3_deliver', 'call_age', '91-180d', -0.2113),
    ('MMM_v3_deliver', 'call_age', 'none', 0.2973),
    ('MMM_v3_deliver', 'callback_age', '0-7d', 0.5445),
    ('MMM_v3_deliver', 'callback_age', '31-90d', -0.0702),
    ('MMM_v3_deliver', 'callback_age', '8-30d', 0.1046),
    ('MMM_v3_deliver', 'callback_age', '90d+', -0.0217),
    ('MMM_v3_deliver', 'callback_age', 'none', -0.3145),
    ('MMM_v3_deliver', 'last_outcome', 'auto_disconnected', -0.4003),
    ('MMM_v3_deliver', 'last_outcome', 'callback_scheduled', 0.1451),
    ('MMM_v3_deliver', 'last_outcome', 'never_connected', 0.1496),
    ('MMM_v3_deliver', 'last_outcome', 'no_prior_call', 0.2973),
    ('MMM_v3_deliver', 'last_outcome', 'other_connected', 0.0511),
    ('MMM_v3_deliver', 'calls_30d', '0', 0.0684),
    ('MMM_v3_deliver', 'calls_30d', '1-2', 0.1446),
    ('MMM_v3_deliver', 'calls_30d', '3-5', 0.0288),
    ('MMM_v3_deliver', 'calls_30d', '6+', 0.0009),
    ('MMM_v3_deliver', 'lead_type', 'first_time', -0.2265),
    ('MMM_v3_deliver', 'lead_type', 'reengaged', 0.4693),
    ('MMM_v3_deliver', 'leads_30d', '0', -0.5893),
    ('MMM_v3_deliver', 'leads_30d', '1', 0.6312),
    ('MMM_v3_deliver', 'leads_30d', '2+', 0.2009),
    ('MMM_v3_deliver', 'last_source', 'aggregator', 0.2746),
    ('MMM_v3_deliver', 'last_source', 'digital', 0.2546),
    ('MMM_v3_deliver', 'last_source', 'lead_provider', 0.1507),
    ('MMM_v3_deliver', 'last_source', 'organic', -0.1755),
    ('MMM_v3_deliver', 'last_source', 'unknown_sources', -0.2615),
    ('MMM_v3_deliver', 'first_source', 'aggregator', 0.1998),
    ('MMM_v3_deliver', 'first_source', 'digital', -0.0997),
    ('MMM_v3_deliver', 'first_source', 'lead_provider', -0.0747),
    ('MMM_v3_deliver', 'first_source', 'organic', -0.0989),
    ('MMM_v3_deliver', 'first_source', 'unknown_sources', 0.3162),
    ('MMM_v3_deliver', 'first_all', 'appunknown', 0.1479),
    ('MMM_v3_deliver', 'first_all', 'bingpaid', 0.0378),
    ('MMM_v3_deliver', 'first_all', 'dealership', -0.0725),
    ('MMM_v3_deliver', 'first_all', 'directtraffic', -0.3509),
    ('MMM_v3_deliver', 'first_all', 'facebookads', 0.223),
    ('MMM_v3_deliver', 'first_all', 'googleorganic', 0.1386),
    ('MMM_v3_deliver', 'first_all', 'googlepaid', 0.0688),
    ('MMM_v3_deliver', 'first_all', 'other', 0.0129),
    ('MMM_v3_deliver', 'first_all', 'partnership', 0.0171),
    ('MMM_v3_deliver', 'first_all', 'provider', 0.0186),
    ('MMM_v3_deliver', 'first_all', 'tiktokads', 0.1399),
    ('MMM_v3_deliver', 'first_all', 'web', -0.0232),
    ('MMM_v3_deliver', 'first_all', 'webunknown', -0.1152),
    ('MMM_v3_deliver', 'premium', '1000-1500', 0.0848),
    ('MMM_v3_deliver', 'premium', '1500-2000', 0.1232),
    ('MMM_v3_deliver', 'premium', '2000-3000', 0.0974),
    ('MMM_v3_deliver', 'premium', '3000+', 0.0002),
    ('MMM_v3_deliver', 'premium', '<1000', 0.0308),
    ('MMM_v3_deliver', 'premium', 'none', -0.0935),
    ('MMM_v3_deliver', 'dialer_ch', '0.6-0.9', 0.2244),
    ('MMM_v3_deliver', 'dialer_ch', '0.9-1.1', -0.1241),
    ('MMM_v3_deliver', 'dialer_ch', '1.1-1.4', 0.0391),
    ('MMM_v3_deliver', 'dialer_ch', '1.4+', 0.0464),
    ('MMM_v3_deliver', 'dialer_ch', '<0.6', 0.0039),
    ('MMM_v3_deliver', 'dialer_ch', 'none', 0.0531),
    ('MMM_v3_deliver', 'prior_click', 'no', 0.0951),
    ('MMM_v3_deliver', 'prior_click', 'yes', 0.1476),
    ('MMM_v3_deliver', 'wa_delivered', '0', -1.2707),
    ('MMM_v3_deliver', 'wa_delivered', '1-2', -0.2256),
    ('MMM_v3_deliver', 'wa_delivered', '3-5', 0.2775),
    ('MMM_v3_deliver', 'wa_delivered', '6+', 1.4615),
    ('MMM_v3_deliver', 'wa_failed', '0', 0.9996),
    ('MMM_v3_deliver', 'wa_failed', '1', 0.0131),
    ('MMM_v3_deliver', 'wa_failed', '2+', -0.77),
    ('MMM_v3_deliver', 'wa_read_rate', '0', 0.4457),
    ('MMM_v3_deliver', 'wa_read_rate', '1-49%', 0.1713),
    ('MMM_v3_deliver', 'wa_read_rate', '100%', 0.5044),
    ('MMM_v3_deliver', 'wa_read_rate', '50-99%', 0.392),
    ('MMM_v3_deliver', 'wa_read_rate', 'none', -1.2707),
    ('MMM_v3_deliver', 'wa_replied', 'no', 0.2443),
    ('MMM_v3_deliver', 'wa_replied', 'yes', -0.0016),
    ('MMM_v3_deliver', 'intercept', '', 0.3303),
    ('MMM_v3_click', 'segment', 'L2S', -0.7982),
    ('MMM_v3_click', 'segment', 'Q2S_GT45', -0.1941),
    ('MMM_v3_click', 'segment', 'Q2S_LT45', 0.5197),
    ('MMM_v3_click', 'lead_age', '0-3d', 0.052),
    ('MMM_v3_click', 'lead_age', '16-30d', 0.0521),
    ('MMM_v3_click', 'lead_age', '181-365d', -0.1795),
    ('MMM_v3_click', 'lead_age', '31-90d', 0.0529),
    ('MMM_v3_click', 'lead_age', '365d+', -0.375),
    ('MMM_v3_click', 'lead_age', '4-7d', -0.0487),
    ('MMM_v3_click', 'lead_age', '8-15d', 0.0849),
    ('MMM_v3_click', 'lead_age', '91-180d', -0.1114),
    ('MMM_v3_click', 'quote_age', '0-14d', -0.8136),
    ('MMM_v3_click', 'quote_age', '15-45d', -0.6846),
    ('MMM_v3_click', 'quote_age', '181-365d', -0.1231),
    ('MMM_v3_click', 'quote_age', '365d+', -0.1089),
    ('MMM_v3_click', 'quote_age', '46-90d', -0.1052),
    ('MMM_v3_click', 'quote_age', '91-180d', 0.276),
    ('MMM_v3_click', 'quote_age', 'none', 1.0869),
    ('MMM_v3_click', 'call_age', '0-2d', -0.1974),
    ('MMM_v3_click', 'call_age', '180d+', -0.3438),
    ('MMM_v3_click', 'call_age', '3-7d', 0.0418),
    ('MMM_v3_click', 'call_age', '31-90d', 0.1615),
    ('MMM_v3_click', 'call_age', '8-30d', -0.0609),
    ('MMM_v3_click', 'call_age', '91-180d', -0.1784),
    ('MMM_v3_click', 'call_age', 'none', 0.1047),
    ('MMM_v3_click', 'callback_age', '0-7d', -0.0033),
    ('MMM_v3_click', 'callback_age', '31-90d', -0.1411),
    ('MMM_v3_click', 'callback_age', '8-30d', -0.1972),
    ('MMM_v3_click', 'callback_age', '90d+', -0.026),
    ('MMM_v3_click', 'callback_age', 'none', -0.105),
    ('MMM_v3_click', 'last_outcome', 'auto_disconnected', -0.1639),
    ('MMM_v3_click', 'last_outcome', 'callback_scheduled', 0.2104),
    ('MMM_v3_click', 'last_outcome', 'never_connected', -0.1145),
    ('MMM_v3_click', 'last_outcome', 'no_prior_call', 0.1047),
    ('MMM_v3_click', 'last_outcome', 'other_connected', -0.5093),
    ('MMM_v3_click', 'calls_30d', '0', -0.2605),
    ('MMM_v3_click', 'calls_30d', '1-2', -0.1157),
    ('MMM_v3_click', 'calls_30d', '3-5', -0.0935),
    ('MMM_v3_click', 'calls_30d', '6+', -0.003),
    ('MMM_v3_click', 'lead_type', 'first_time', -0.5894),
    ('MMM_v3_click', 'lead_type', 'reengaged', 0.1168),
    ('MMM_v3_click', 'leads_30d', '0', -0.4718),
    ('MMM_v3_click', 'leads_30d', '1', -0.0011),
    ('MMM_v3_click', 'leads_30d', '2+', 0.0003),
    ('MMM_v3_click', 'last_source', 'aggregator', 0.255),
    ('MMM_v3_click', 'last_source', 'digital', 0.0861),
    ('MMM_v3_click', 'last_source', 'lead_provider', -0.5601),
    ('MMM_v3_click', 'last_source', 'organic', 0.0902),
    ('MMM_v3_click', 'last_source', 'unknown_sources', -0.3438),
    ('MMM_v3_click', 'first_source', 'aggregator', -0.1336),
    ('MMM_v3_click', 'first_source', 'digital', 0.0565),
    ('MMM_v3_click', 'first_source', 'lead_provider', -0.3039),
    ('MMM_v3_click', 'first_source', 'organic', -0.2527),
    ('MMM_v3_click', 'first_source', 'unknown_sources', 0.1612),
    ('MMM_v3_click', 'first_all', 'appunknown', -0.0906),
    ('MMM_v3_click', 'first_all', 'bingpaid', -0.1908),
    ('MMM_v3_click', 'first_all', 'dealership', -0.0445),
    ('MMM_v3_click', 'first_all', 'directtraffic', -0.3786),
    ('MMM_v3_click', 'first_all', 'facebookads', -0.2205),
    ('MMM_v3_click', 'first_all', 'googleorganic', 0.2512),
    ('MMM_v3_click', 'first_all', 'googlepaid', -0.0233),
    ('MMM_v3_click', 'first_all', 'other', -0.0668),
    ('MMM_v3_click', 'first_all', 'partnership', -0.1455),
    ('MMM_v3_click', 'first_all', 'provider', 0.2275),
    ('MMM_v3_click', 'first_all', 'tiktokads', 0.1274),
    ('MMM_v3_click', 'first_all', 'web', 0.0236),
    ('MMM_v3_click', 'first_all', 'webunknown', 0.0584),
    ('MMM_v3_click', 'premium', '1000-1500', -0.0733),
    ('MMM_v3_click', 'premium', '1500-2000', 0.0435),
    ('MMM_v3_click', 'premium', '2000-3000', 0.1613),
    ('MMM_v3_click', 'premium', '3000+', 0.386),
    ('MMM_v3_click', 'premium', '<1000', -0.192),
    ('MMM_v3_click', 'premium', 'none', -0.7982),
    ('MMM_v3_click', 'dialer_ch', '0.6-0.9', -0.3816),
    ('MMM_v3_click', 'dialer_ch', '0.9-1.1', -0.0221),
    ('MMM_v3_click', 'dialer_ch', '1.1-1.4', -0.3048),
    ('MMM_v3_click', 'dialer_ch', '1.4+', -0.0601),
    ('MMM_v3_click', 'dialer_ch', '<0.6', 0.114),
    ('MMM_v3_click', 'dialer_ch', 'none', 0.182),
    ('MMM_v3_click', 'prior_click', 'no', -0.8038),
    ('MMM_v3_click', 'prior_click', 'yes', 0.3312),
    ('MMM_v3_click', 'wa_delivered', '0', 0.138),
    ('MMM_v3_click', 'wa_delivered', '1-2', -0.1352),
    ('MMM_v3_click', 'wa_delivered', '3-5', -0.1145),
    ('MMM_v3_click', 'wa_delivered', '6+', -0.3609),
    ('MMM_v3_click', 'wa_failed', '0', -0.2468),
    ('MMM_v3_click', 'wa_failed', '1', -0.3605),
    ('MMM_v3_click', 'wa_failed', '2+', 0.1347),
    ('MMM_v3_click', 'wa_read_rate', '0', -0.1672),
    ('MMM_v3_click', 'wa_read_rate', '1-49%', -0.3367),
    ('MMM_v3_click', 'wa_read_rate', '100%', 0.0051),
    ('MMM_v3_click', 'wa_read_rate', '50-99%', -0.1118),
    ('MMM_v3_click', 'wa_read_rate', 'none', 0.138),
    ('MMM_v3_click', 'wa_replied', 'no', -0.3745),
    ('MMM_v3_click', 'wa_replied', 'yes', -0.0981),
    ('MMM_v3_click', 'intercept', '', -1.4202);

-- Discount WhatsApp templates: the ONE place to register a template id. Used by the spam guard,
-- the repeat-messaging model features, and the retrain (which only learns from these templates).
-- When Make's continuous-campaign template id is known, add it with:
--   INSERT INTO PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CPC_DISCOUNT_TEMPLATES (template_id, description) VALUES ('<id>', 'continuous campaign');
CREATE TABLE IF NOT EXISTS PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CPC_DISCOUNT_TEMPLATES (
    template_id  VARCHAR,
    description  VARCHAR,
    added_at     TIMESTAMP_NTZ DEFAULT SYSDATE()
);

INSERT INTO PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CPC_DISCOUNT_TEMPLATES (template_id, description)
SELECT v.template_id, v.description
FROM (VALUES ('00158', 'Aug 2026 L2S'), ('00159', 'Aug 2026 Q2S'),
             ('00164', 'Sep 2026 L2S'), ('00165', 'Sep 2026 Q2S')) v(template_id, description)
WHERE v.template_id NOT IN (SELECT template_id FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CPC_DISCOUNT_TEMPLATES);

-- 7-day spam guard. Anyone in here must not receive another discount message today.
CREATE OR REPLACE VIEW PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_DO_NOT_MESSAGE_7D AS
SELECT RIGHT(REGEXP_REPLACE(SPLIT_PART(w.NUMBER::STRING, '.', 1), '[^0-9]', ''), 9) AS phone9,
       'twilio_discount_template_sent' AS reason
FROM TWILIO_DATABASE.DATA.WHATSAPPTEMPLATEDATA w
JOIN TWILIO_DATABASE.DATA.MESSAGES m ON m.SID = w.MESSAGE_SID
WHERE m.STATUS <> 'received'
  AND m.DATE_SENT >= DATEADD('day', -7, SYSDATE())
  AND TRIM(w.TEMPLATE_ID) IN (SELECT template_id FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CPC_DISCOUNT_TEMPLATES)
UNION
SELECT phone9, 'ledger_confirmed_sent'
FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_HISTORY
WHERE was_sent = TRUE AND selected_date >= DATEADD('day', -7, CURRENT_DATE)
UNION
SELECT phone9, 'ledger_picked_for_sending_earlier'
FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_HISTORY
WHERE arm = 'treated' AND selected_date >= DATEADD('day', -7, CURRENT_DATE) AND selected_date < CURRENT_DATE;


/* =====================================================================================
   PART 2 — DAILY BUILD: every eligible person, scored
   ===================================================================================== */

-- score with the current champion from the registry (MMM_v3 until a retrain promotes a new one)
SET model_version = (SELECT model_version FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CPC_MODEL_REGISTRY
                     WHERE status = 'champion' ORDER BY promoted_at DESC LIMIT 1);

CREATE OR REPLACE TABLE PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_AUDIENCE AS
WITH
/* ---------- Q2S: September build, unchanged except where marked ---------- */
base_quotes AS (
    SELECT g.USER_ID, g.FORMATTED_PHONE, g.DISCOUNT_ACTIVITY_ID, TO_VARCHAR(g.QUOTE_NO) AS quote_no,   -- quote_no added (PSM join)
           COALESCE(g.QUOTED_AT, g.QUOTE_JOURNEY_START_AT, CAST(g.QUOTE_DATE AS TIMESTAMP)) AS quote_ts,
           RIGHT(REGEXP_REPLACE(COALESCE(g.FORMATTED_PHONE,''), '[^0-9]', ''), 9) AS phone9
    FROM ACTUARIAL_DATABASE.SANDBOX.GOLDEN_QUOTE_JOURNEY_DATASET g
    WHERE g.SOLD_AT IS NULL AND g.FORMATTED_PHONE IS NOT NULL
      AND (g.QUOTE_NO IS NOT NULL OR g.QUOTED_AT IS NOT NULL)
      AND COALESCE(g.QUOTED_AT, g.QUOTE_JOURNEY_START_AT, CAST(g.QUOTE_DATE AS TIMESTAMP)) IS NOT NULL
),
daily_quotes AS (
    SELECT * FROM (
        SELECT b.*, ROW_NUMBER() OVER (PARTITION BY b.USER_ID, CAST(b.quote_ts AS DATE) ORDER BY b.quote_ts DESC) AS rn_in_day
        FROM base_quotes b
    ) WHERE rn_in_day = 1
),
gapped_quotes AS (
    SELECT d.*, DATEDIFF('day', LAG(d.quote_ts) OVER (PARTITION BY d.USER_ID ORDER BY d.quote_ts), d.quote_ts) AS days_since_prev_quote
    FROM daily_quotes d
),
episoded_quotes AS (
    SELECT g.*, SUM(CASE WHEN g.days_since_prev_quote IS NULL OR g.days_since_prev_quote > 45 THEN 1 ELSE 0 END)
               OVER (PARTITION BY g.USER_ID ORDER BY g.quote_ts ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS episode_id
    FROM gapped_quotes g
),
episode_governing_quote AS (
    SELECT * FROM (
        SELECT e.*, ROW_NUMBER() OVER (PARTITION BY e.USER_ID, e.episode_id ORDER BY e.quote_ts ASC) AS rn_in_episode,
               MAX(e.episode_id) OVER (PARTITION BY e.USER_ID) AS latest_episode_id
        FROM episoded_quotes e
    ) WHERE rn_in_episode = 1 AND episode_id = latest_episode_id
),
quoters AS (
    SELECT USER_ID, DISCOUNT_ACTIVITY_ID, quote_no, quote_ts AS quote_anchor_ts, phone9
    FROM episode_governing_quote WHERE LENGTH(phone9) = 9
),
da_premium AS (
    SELECT discount_activity_id, pre_disc_quote_premium, post_disc_quote_premium, discount_zar, vehicle_reg_norm, line_no
    FROM (
        SELECT ID AS discount_activity_id,
            (COALESCE(TRY_TO_NUMBER(PREMIUM_BREAKDOWN_COMPREHENSIVE_PREMIUM),0) + COALESCE(TRY_TO_NUMBER(PREMIUM_BREAKDOWN_CAR_HIRE_PREMIUM),0)
           + COALESCE(TRY_TO_NUMBER(PREMIUM_BREAKDOWN_CREDIT_SHORTFALL_PREMIUM),0) + COALESCE(TRY_TO_NUMBER(DISCOUNT_ZAR),0)) AS pre_disc_quote_premium,
            (COALESCE(TRY_TO_NUMBER(PREMIUM_BREAKDOWN_COMPREHENSIVE_PREMIUM),0) + COALESCE(TRY_TO_NUMBER(PREMIUM_BREAKDOWN_CAR_HIRE_PREMIUM),0)
           + COALESCE(TRY_TO_NUMBER(PREMIUM_BREAKDOWN_CREDIT_SHORTFALL_PREMIUM),0)) AS post_disc_quote_premium,
            COALESCE(TRY_TO_NUMBER(DISCOUNT_ZAR),0) AS discount_zar,
            UPPER(REGEXP_REPLACE(VEHICLE_REGISTRATION, '[^A-Za-z0-9]', '')) AS vehicle_reg_norm,
            TRY_TO_NUMBER(POLICY_LINE_NO::STRING) AS line_no,
            ROW_NUMBER() OVER (PARTITION BY ID ORDER BY TRY_TO_TIMESTAMP_NTZ(UPDATEDAT) DESC NULLS LAST,
                                                        TRY_TO_TIMESTAMP_NTZ(CREATEDAT) DESC NULLS LAST) AS rn
        FROM pineapple_database.pineapple_mongo.DISCOUNTS_ACTIVITY
    ) WHERE rn = 1
),
stmtr_by_line AS (
    SELECT AGR_LINE_NO, MAKE, MODEL FROM ACTUARIAL_DATABASE.SANDBOX.OBJECT_STMTR
    WHERE AGR_LINE_NO IS NOT NULL AND MAKE IS NOT NULL AND TRIM(MAKE) <> ''
    QUALIFY ROW_NUMBER() OVER (PARTITION BY AGR_LINE_NO ORDER BY SEQ_NO DESC) = 1
),
/* ---------- shared exclusion sets (September logic) ---------- */
active_phones AS (
    SELECT DISTINCT RIGHT(REGEXP_REPLACE(SPLIT_PART("cus_mobile_phone_no"::STRING,'.',1),'[^0-9]',''),9) AS phone
    FROM sftp_latest_reports.data."pa_active"
    WHERE "cus_mobile_phone_no" IS NOT NULL AND LENGTH(REGEXP_REPLACE(SPLIT_PART("cus_mobile_phone_no"::STRING,'.',1),'[^0-9]','')) >= 9
),
policy_holders AS (
    SELECT DISTINCT RIGHT(REGEXP_REPLACE(SPLIT_PART(vehicle_ownerperson_cellphonenumber::STRING,'.',1),'[^0-9]',''),9) AS phone
    FROM pineapple_database.pineapple_mongo.mtr_policy_requests_full
    WHERE type IN ('createPolicy','additionalVehiclePolicy') AND TRY_CAST(response_status AS INTEGER) = 200
      AND LENGTH(REGEXP_REPLACE(SPLIT_PART(vehicle_ownerperson_cellphonenumber::STRING,'.',1),'[^0-9]','')) >= 9
),
outcome_calls AS (     -- full outbound history, any campaign (September FIX A / FIX B scope)
    SELECT RIGHT(REGEXP_REPLACE(COALESCE(oc.subject,''), '[^0-9]', ''), 9) AS phone, oc.start_time, o.name
    FROM connex_db.data.cxm_interactions oc
    JOIN connex_db.data.cxm_outcomes o ON o.id = oc.outcome_id
    WHERE oc.direction = 'outbound' AND LENGTH(REGEXP_REPLACE(COALESCE(oc.subject,''), '[^0-9]', '')) >= 9
),
dnc_flag AS (SELECT DISTINCT phone FROM outcome_calls WHERE name = 'Do Not Call'),
existing_or_sale_phones AS (SELECT DISTINCT phone FROM outcome_calls WHERE name ILIKE '%existing%policyholder%' OR name ILIKE '%sale made%'),
permanent_disqualified_phones AS (
    SELECT DISTINCT phone FROM outcome_calls
    WHERE name ILIKE 'no insurable risk%' OR name IN ('Incorrect Number','Incorrect Contact Number','Wrong Number','Disconnected')
),
l2s_disqualified_phones AS (     -- September L2S list adds 'Still shopping for a car' + existing/sale
    SELECT DISTINCT phone FROM outcome_calls
    WHERE name ILIKE 'no insurable risk%' OR name = 'Still shopping for a car'
       OR name ILIKE '%existing%policyholder%' OR name ILIKE '%sale made%'
       OR name IN ('Incorrect Number','Incorrect Contact Number','Wrong Number','Disconnected')
),
recent_temp_disconnected_phones AS (
    SELECT DISTINCT phone FROM outcome_calls
    WHERE name = 'Temporary Disconnected Number' AND start_time >= DATEADD('day', -90, CURRENT_DATE)
),
opt_out_phones AS (
    SELECT DISTINCT RIGHT(REGEXP_REPLACE(CLIENT_NUMEBR,'[^0-9]',''),9) AS phone
    FROM LOGGING_DB.PDP_LOGGING.OPT_OUT_WHATSAPP_LOGGING
    WHERE CLIENT_NUMEBR IS NOT NULL AND LENGTH(REGEXP_REPLACE(CLIENT_NUMEBR,'[^0-9]','')) >= 9
),
leads_all AS (
    SELECT RIGHT(REGEXP_REPLACE(COALESCE(contact_number,''),'[^0-9]',''),9) AS phone9,
           TRY_TO_TIMESTAMP(usercreatedat) AS lead_ts, user_id, first_name, last_name,
           LOWER(COALESCE(final_attributed_source_fixed,'unknown')) AS attr_source,
           LOWER(COALESCE(all_sources,'unknown')) AS all_src,
           CASE WHEN final_attributed_source_fixed = 'lead_provider' THEN sub_sources ELSE all_sources END AS channel_key,
           COALESCE(lead_source_reference_UCID, '') AS ucid
    FROM pineapple_database.pineapple_mongo.lead_channel_labels
    WHERE LENGTH(REGEXP_REPLACE(COALESCE(contact_number,''),'[^0-9]','')) >= 9
      AND TRY_TO_TIMESTAMP(usercreatedat) IS NOT NULL
),
recent_dealership AS (SELECT DISTINCT phone9 FROM leads_all WHERE all_src = 'dealership' AND lead_ts >= DATEADD('day',-2,CURRENT_DATE)),
names AS (SELECT phone9, first_name, last_name FROM leads_all QUALIFY ROW_NUMBER() OVER (PARTITION BY phone9 ORDER BY lead_ts DESC) = 1),
lead_recency AS (SELECT phone9, MAX(lead_ts) AS max_lead_ts FROM leads_all GROUP BY phone9),
psm AS (
    SELECT TO_VARCHAR(MOTOR_QUOTE_NO) AS quote_no,
           TRY_TO_DOUBLE(RECOMMENDED_DISCOUNT_PERCENTAGE)                  AS psm_rmd,
           COALESCE(TRY_TO_BOOLEAN(ALPHA_GROUP_IS_ACTIVE), FALSE)          AS alpha_active,
           TRY_TO_DOUBLE(ALPHA_GROUP_LOCKED_DUT)                           AS alpha_locked_dut
    FROM PINEAPPLE_DATABASE.PINEAPPLE_MONGO.MTR_USER_PRICE_SENSITIVITY_DISCOUNTS
    WHERE MOTOR_QUOTE_NO IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY MOTOR_QUOTE_NO ORDER BY TRY_TO_TIMESTAMP_NTZ(UPDATEDAT) DESC NULLS LAST) = 1
),
q2s_eligible AS (
    SELECT q.phone9, q.quote_no,
           DATEDIFF('day', q.quote_anchor_ts, CURRENT_DATE) AS days_since_quote,
           nm.first_name, nm.last_name,
           dp.pre_disc_quote_premium AS pre_prem, dp.post_disc_quote_premium AS last_prem,
           CASE WHEN dp.pre_disc_quote_premium > 0
                THEN LEAST(GREATEST(100.0 * dp.discount_zar / dp.pre_disc_quote_premium, 0), 100) END AS prior_disc,
           COALESCE(sl.MAKE,  vm.make)  AS vehicle_make,
           COALESCE(sl.MODEL, vm.model) AS vehicle_model,
           ps.psm_rmd, ps.alpha_active, ps.alpha_locked_dut
    FROM quoters q
    LEFT JOIN active_phones ap ON ap.phone = q.phone9
    LEFT JOIN policy_holders ph ON ph.phone = q.phone9
    LEFT JOIN dnc_flag dn ON dn.phone = q.phone9
    LEFT JOIN existing_or_sale_phones es ON es.phone = q.phone9
    LEFT JOIN permanent_disqualified_phones pd ON pd.phone = q.phone9
    LEFT JOIN recent_temp_disconnected_phones rtd ON rtd.phone = q.phone9
    LEFT JOIN opt_out_phones oo ON oo.phone = q.phone9
    LEFT JOIN recent_dealership rd ON rd.phone9 = q.phone9
    LEFT JOIN names nm ON nm.phone9 = q.phone9
    LEFT JOIN da_premium dp ON dp.discount_activity_id = q.DISCOUNT_ACTIVITY_ID
    LEFT JOIN stmtr_by_line sl ON sl.AGR_LINE_NO = dp.line_no
    LEFT JOIN sandbox.pineapp_will.vehicle_model_lookup vm ON vm.reg_norm = dp.vehicle_reg_norm
    LEFT JOIN psm ps ON ps.quote_no = q.quote_no
    WHERE ap.phone IS NULL AND ph.phone IS NULL AND dn.phone IS NULL AND es.phone IS NULL AND oo.phone IS NULL
      AND pd.phone IS NULL AND rtd.phone IS NULL AND rd.phone9 IS NULL
      AND DATEDIFF('day', q.quote_anchor_ts, CURRENT_DATE) <= 365
),
q2s_priced AS (
    SELECT e.*,
           -- CHANGE 1: 7-17% rule, kept low; exclude (not cap) anything above 17
           GREATEST(7,
                    CEIL(e.prior_disc + 3.0),
                    IFF(e.psm_rmd > e.prior_disc, CEIL(e.psm_rmd), 0),
                    IFF(e.alpha_active, CEIL(COALESCE(e.alpha_locked_dut, 0)), 0)) AS offer_pct
    FROM q2s_eligible e
    WHERE e.prior_disc IS NOT NULL
),
q2s_final AS (
    SELECT phone9, IFF(days_since_quote <= 45, 'Q2S_LT45', 'Q2S_GT45') AS audience,
           first_name, last_name, vehicle_make, vehicle_model,
           pre_prem, last_prem, prior_disc, psm_rmd, offer_pct,
           ROUND(pre_prem * (1 - offer_pct / 100.0), 2) AS new_premium_offered
    FROM q2s_priced
    WHERE offer_pct <= 17
      AND vehicle_make IS NOT NULL AND vehicle_model IS NOT NULL
      AND pre_prem > 0 AND last_prem IS NOT NULL
      AND ROUND(pre_prem * (1 - offer_pct / 100.0), 2) <= last_prem * 0.97
    QUALIFY ROW_NUMBER() OVER (PARTITION BY phone9 ORDER BY days_since_quote ASC, quote_no) = 1
),
/* ---------- L2S: September build (<= 15 days), unchanged ---------- */
quoted_users AS (
    SELECT DISTINCT USER_ID AS user_id FROM ACTUARIAL_DATABASE.SANDBOX.GOLDEN_QUOTE_JOURNEY_DATASET WHERE USER_ID IS NOT NULL
    UNION
    SELECT DISTINCT "key_entity_details/user_id" FROM MONGO_DATA_BASE.DATA.EVENT_LOGS
    WHERE ACTION = 'quoted' AND "key_entity_details/user_id" IS NOT NULL
),
quoted_phones AS (
    SELECT DISTINCT RIGHT(REGEXP_REPLACE(COALESCE(FORMATTED_PHONE,''),'[^0-9]',''),9) AS phone9
    FROM ACTUARIAL_DATABASE.SANDBOX.GOLDEN_QUOTE_JOURNEY_DATASET
    WHERE FORMATTED_PHONE IS NOT NULL AND LENGTH(REGEXP_REPLACE(COALESCE(FORMATTED_PHONE,''),'[^0-9]','')) >= 9
),
sold_users AS (
    SELECT DISTINCT "key_entity_details/user_id" AS user_id FROM MONGO_DATA_BASE.DATA.EVENT_LOGS
    WHERE ACTION = 'insured' AND "key_entity_details/user_id" IS NOT NULL
),
lead_latest AS (
    SELECT phone9, user_id, first_name, last_name FROM leads_all
    QUALIFY ROW_NUMBER() OVER (PARTITION BY phone9 ORDER BY lead_ts DESC) = 1
),
l2s_final AS (
    SELECT ll.phone9, 'L2S' AS audience, ll.first_name, ll.last_name,
           NULL::VARCHAR AS vehicle_make, NULL::VARCHAR AS vehicle_model,
           NULL::FLOAT AS pre_prem, NULL::FLOAT AS last_prem, 0::FLOAT AS prior_disc, NULL::FLOAT AS psm_rmd,
           10 AS offer_pct, NULL::FLOAT AS new_premium_offered
    FROM lead_latest ll
    JOIN lead_recency lr ON lr.phone9 = ll.phone9
    LEFT JOIN active_phones ap ON ap.phone = ll.phone9
    LEFT JOIN policy_holders ph ON ph.phone = ll.phone9
    LEFT JOIN dnc_flag dn ON dn.phone = ll.phone9
    LEFT JOIN quoted_phones qp ON qp.phone9 = ll.phone9
    LEFT JOIN quoted_users qu ON qu.user_id = ll.user_id
    LEFT JOIN sold_users su ON su.user_id = ll.user_id
    LEFT JOIN l2s_disqualified_phones dq ON dq.phone = ll.phone9
    LEFT JOIN recent_temp_disconnected_phones rtd ON rtd.phone = ll.phone9
    LEFT JOIN opt_out_phones oo ON oo.phone = ll.phone9
    LEFT JOIN recent_dealership rd ON rd.phone9 = ll.phone9
    WHERE ap.phone IS NULL AND ph.phone IS NULL AND dn.phone IS NULL AND oo.phone IS NULL
      AND qp.phone9 IS NULL AND qu.user_id IS NULL AND su.user_id IS NULL
      AND dq.phone IS NULL AND rtd.phone IS NULL AND rd.phone9 IS NULL
      AND DATEDIFF('day', lr.max_lead_ts, CURRENT_DATE) <= 15
),
pool AS (
    SELECT * FROM q2s_final
    UNION ALL
    SELECT * FROM l2s_final
),
pool_clean AS (    -- September name / test-account gates, applied to both audiences
    SELECT p.* FROM pool p
    WHERE p.first_name IS NOT NULL AND TRIM(p.first_name) <> '' AND p.last_name IS NOT NULL AND TRIM(p.last_name) <> ''
      AND LOWER(TRIM(p.first_name)) <> 'nofirstname' AND LOWER(TRIM(p.last_name)) <> 'nolastname'
      AND UPPER(TRIM(p.first_name) || ' ' || TRIM(p.last_name)) NOT IN ('PINE APPLE','PABLO ESCOBAR')
      AND '+27' || p.phone9 NOT IN ('+27815557799','+27815559988','+27832750122','+27832570211',
                                    '+27890204585','+27887580624','+27896325334','+27935191849','+27781111000')
),
/* ---------- model features, AS OF NOW (same definitions as the training frame) ---------- */
lf AS (
    SELECT p.phone9,
           COUNT(l.lead_ts)                                                         AS n_leads_before,
           COUNT_IF(l.lead_ts >= DATEADD('day', -30, SYSDATE()))                     AS n_leads_30d,
           COUNT_IF(l.ucid ILIKE 'PINCARDISC%')                                      AS n_prior_campaign_clicks,
           DATEDIFF('day', MAX(l.lead_ts), SYSDATE())                               AS days_since_last_lead
    FROM pool_clean p LEFT JOIN leads_all l ON l.phone9 = p.phone9 AND l.lead_ts < SYSDATE()
    GROUP BY p.phone9
),
lead_first AS (
    SELECT p.phone9, l.attr_source AS first_attr_source, l.all_src AS first_all_src
    FROM pool_clean p JOIN leads_all l ON l.phone9 = p.phone9
    QUALIFY ROW_NUMBER() OVER (PARTITION BY p.phone9 ORDER BY l.lead_ts ASC) = 1
),
lead_last AS (
    SELECT p.phone9, l.attr_source AS last_attr_source, l.channel_key AS last_channel_key
    FROM pool_clean p JOIN leads_all l ON l.phone9 = p.phone9
    QUALIFY ROW_NUMBER() OVER (PARTITION BY p.phone9 ORDER BY l.lead_ts DESC) = 1
),
calls3 AS (        -- CHANGE 2: all three sales campaigns; Connex is SAST, shift to UTC
    SELECT RIGHT(REGEXP_REPLACE(COALESCE(i.subject,''),'[^0-9]',''),9) AS phone9,
           DATEADD('hour', -2, i.start_time) AS call_ts, COALESCE(o.name, '') AS outcome
    FROM connex_db.data.cxm_interactions i
    LEFT JOIN connex_db.data.cxm_outcomes o ON o.id = i.outcome_id
    WHERE i.direction = 'outbound' AND i.start_time IS NOT NULL
      AND i.campaign_id IN ('568752c7-ffbc-4edb-9665-0a6792c1f7e7','6c7bc2df-17f5-4c06-8b4f-c7274bfde6ca',
                            '90ae6979-ab80-48fc-b7e1-29e2ef46c6d6')
),
cf AS (
    SELECT p.phone9,
           COUNT_IF(c.call_ts >= DATEADD('day', -30, SYSDATE()))                                   AS n_calls_30d,
           DATEDIFF('hour', MAX(c.call_ts), SYSDATE()) / 24.0                                      AS days_since_last_call,
           DATEDIFF('hour', MAX(IFF(c.outcome ILIKE 'Callback Scheduled%', c.call_ts, NULL)), SYSDATE()) / 24.0 AS days_since_last_callback
    FROM pool_clean p LEFT JOIN calls3 c ON c.phone9 = p.phone9 AND c.call_ts < SYSDATE()
    GROUP BY p.phone9
),
last_out AS (
    SELECT p.phone9, c.outcome AS last_outcome
    FROM pool_clean p JOIN calls3 c ON c.phone9 = p.phone9 AND c.call_ts < SYSDATE()
    QUALIFY ROW_NUMBER() OVER (PARTITION BY p.phone9 ORDER BY c.call_ts DESC) = 1
),
qf AS (
    SELECT p.phone9,
           DATEDIFF('day', MAX(COALESCE(g.QUOTED_AT, g.QUOTE_JOURNEY_START_AT, CAST(g.QUOTE_DATE AS TIMESTAMP))::TIMESTAMP_NTZ), SYSDATE()) AS days_since_last_quote
    FROM pool_clean p
    LEFT JOIN ACTUARIAL_DATABASE.SANDBOX.GOLDEN_QUOTE_JOURNEY_DATASET g
           ON RIGHT(REGEXP_REPLACE(COALESCE(g.FORMATTED_PHONE,''),'[^0-9]',''),9) = p.phone9
    GROUP BY p.phone9
),
wa_msgs AS (       -- ONE ROW PER MESSAGE: Twilio keeps a row per status event, collapse onto the SID
    SELECT p.phone9, w.MESSAGE_SID AS sid,
           MIN(m.DATE_SENT)                                      AS sent_ts,
           MAX(IFF(m.STATUS IN ('delivered', 'read'), 1, 0))     AS was_delivered,
           MAX(IFF(m.STATUS = 'read', 1, 0))                     AS was_read,
           MAX(IFF(m.STATUS IN ('undelivered', 'failed'), 1, 0)) AS was_failed,
           MAX(IFF(dt.template_id IS NOT NULL, 1, 0))            AS is_disc_template
    FROM pool_clean p
    JOIN TWILIO_DATABASE.DATA.WHATSAPPTEMPLATEDATA w
      ON RIGHT(REGEXP_REPLACE(SPLIT_PART(w.NUMBER::STRING,'.',1),'[^0-9]',''),9) = p.phone9
    JOIN TWILIO_DATABASE.DATA.MESSAGES m
      ON m.SID = w.MESSAGE_SID AND m.STATUS <> 'received'
     AND m.DATE_SENT >= DATEADD('day', -181, SYSDATE())
    LEFT JOIN PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CPC_DISCOUNT_TEMPLATES dt ON dt.template_id = TRIM(w.TEMPLATE_ID)
    GROUP BY p.phone9, w.MESSAGE_SID
),
disc AS (          -- repeat-messaging history: delivered DISCOUNT messages before now
    SELECT phone9,
           MAX(IFF(is_disc_template = 1 AND was_delivered = 1, sent_ts, NULL)) AS last_disc_ts,
           COUNT_IF(is_disc_template = 1 AND was_delivered = 1
                    AND sent_ts >= DATEADD('day', -28, SYSDATE()))              AS n_disc_28d
    FROM wa_msgs
    WHERE sent_ts < SYSDATE()
    GROUP BY phone9
),
wa AS (
    SELECT phone9,
           COUNT_IF(was_delivered = 1) AS n_wa_delivered_180d,
           COUNT_IF(was_read = 1)      AS n_wa_read_180d,
           COUNT_IF(was_failed = 1)    AS n_wa_failed_180d
    FROM wa_msgs
    WHERE sent_ts >= DATEADD('day', -180, SYSDATE()) AND sent_ts < DATEADD('day', -1, SYSDATE())
    GROUP BY phone9
),
rep AS (
    SELECT p.phone9, COUNT(DISTINCT m.SID) AS n_replies_180d
    FROM pool_clean p
    JOIN TWILIO_DATABASE.DATA.MESSAGES m
      ON RIGHT(REGEXP_REPLACE(COALESCE(m."from",''),'[^0-9]',''),9) = p.phone9
     AND m.STATUS = 'received'
     AND m.DATE_SENT >= DATEADD('day', -180, SYSDATE()) AND m.DATE_SENT < DATEADD('day', -1, SYSDATE())
    GROUP BY p.phone9
),
prev_msg AS (      -- messaged in any earlier campaign, or sent by this continuous process
    SELECT DISTINCT phone9 FROM (
        SELECT RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING,'[^0-9]',''),9) AS phone9, HAS_BEEN_MESSAGED AS hbm FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_20_PERCENT_DAY_1
        UNION ALL SELECT RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING,'[^0-9]',''),9), HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_20_DAY_1
        UNION ALL SELECT RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING,'[^0-9]',''),9), HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_10_DAY_1
        UNION ALL SELECT RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING,'[^0-9]',''),9), HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_20_Q2S_LESS_45DAYS_JUL2026
        UNION ALL SELECT RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING,'[^0-9]',''),9), HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_20_Q2S_OVER_45DAYS_JUL2026
        UNION ALL SELECT RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING,'[^0-9]',''),9), HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_15_L2S_JUL2026
        UNION ALL SELECT RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING,'[^0-9]',''),9), HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_Q2S_LESSTHAN45D_AUG2026
        UNION ALL SELECT RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING,'[^0-9]',''),9), HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_Q2S_MORETHAN45D_AUG2026
        UNION ALL SELECT RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING,'[^0-9]',''),9), HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_L2S_AUG2026
        UNION ALL SELECT RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING,'[^0-9]',''),9), HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_Q2S_LESSTHAN45D_SEP2026
        UNION ALL SELECT RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING,'[^0-9]',''),9), HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_Q2S_MORETHAN45D_SEP2026
        UNION ALL SELECT RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING,'[^0-9]',''),9), HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_L2S_SEP2026
        UNION ALL SELECT phone9, was_sent FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_HISTORY
    ) WHERE hbm = TRUE
),
cooldown AS (      -- CHANGE 4 + 5: selection cooldown, September send, 7-day spam guard
    SELECT DISTINCT phone9 FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_HISTORY
    WHERE selected_date >= DATEADD('day', -$cooldown_days, CURRENT_DATE)
    UNION
    SELECT RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING,'[^0-9]',''),9) FROM (
        SELECT PHONE_NUMBER, HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_Q2S_LESSTHAN45D_SEP2026
        UNION ALL SELECT PHONE_NUMBER, HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_Q2S_MORETHAN45D_SEP2026
        UNION ALL SELECT PHONE_NUMBER, HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_L2S_SEP2026
    ) WHERE HAS_BEEN_MESSAGED = TRUE AND DATEADD('day', $cooldown_days, '2026-09-16'::DATE) >= CURRENT_DATE
    UNION
    SELECT phone9 FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_DO_NOT_MESSAGE_7D
),
feat AS (
    SELECT p.*,
        lf.n_leads_before, lf.days_since_last_lead, cf.days_since_last_call, cf.days_since_last_callback,
        -- CHANGE 3: phone-first rule (callback scheduled or new lead within the last 1 day)
        (COALESCE(cf.days_since_last_callback, 999) <= 1
         OR COALESCE(lf.days_since_last_lead, 999) <= 1)                                        AS phone_first,
        (cd.phone9 IS NOT NULL)                                                                  AS in_cooldown,
        /* --- bins: identical edges to MMM_train.py (pd.cut, right-closed) --- */
        p.audience AS f_segment,
        CASE WHEN lf.days_since_last_lead IS NULL THEN 'none' WHEN lf.days_since_last_lead <= 3 THEN '0-3d'
             WHEN lf.days_since_last_lead <= 7 THEN '4-7d' WHEN lf.days_since_last_lead <= 15 THEN '8-15d'
             WHEN lf.days_since_last_lead <= 30 THEN '16-30d' WHEN lf.days_since_last_lead <= 90 THEN '31-90d'
             WHEN lf.days_since_last_lead <= 180 THEN '91-180d' WHEN lf.days_since_last_lead <= 365 THEN '181-365d'
             ELSE '365d+' END AS f_lead_age,
        CASE WHEN qf.days_since_last_quote IS NULL THEN 'none' WHEN qf.days_since_last_quote <= 14 THEN '0-14d'
             WHEN qf.days_since_last_quote <= 45 THEN '15-45d' WHEN qf.days_since_last_quote <= 90 THEN '46-90d'
             WHEN qf.days_since_last_quote <= 180 THEN '91-180d' WHEN qf.days_since_last_quote <= 365 THEN '181-365d'
             ELSE '365d+' END AS f_quote_age,
        CASE WHEN cf.days_since_last_call IS NULL THEN 'none' WHEN cf.days_since_last_call <= 2 THEN '0-2d'
             WHEN cf.days_since_last_call <= 7 THEN '3-7d' WHEN cf.days_since_last_call <= 30 THEN '8-30d'
             WHEN cf.days_since_last_call <= 90 THEN '31-90d' WHEN cf.days_since_last_call <= 180 THEN '91-180d'
             ELSE '180d+' END AS f_call_age,
        CASE WHEN cf.days_since_last_callback IS NULL THEN 'none' WHEN cf.days_since_last_callback <= 7 THEN '0-7d'
             WHEN cf.days_since_last_callback <= 30 THEN '8-30d' WHEN cf.days_since_last_callback <= 90 THEN '31-90d'
             ELSE '90d+' END AS f_callback_age,
        CASE WHEN lo.last_outcome IS NULL                          THEN 'no_prior_call'
             WHEN lo.last_outcome ILIKE 'Callback Scheduled%'      THEN 'callback_scheduled'
             WHEN lo.last_outcome ILIKE 'Do Not Call%' OR lo.last_outcome ILIKE 'Sale Made%'
               OR lo.last_outcome ILIKE '%Existing%Policyholder%' OR lo.last_outcome ILIKE '%No Insurable Risk%' THEN 'other_connected'
             WHEN lo.last_outcome ILIKE '%Disconnect%'             THEN 'auto_disconnected'
             WHEN lo.last_outcome IN ('Not Reached','No Answer Autodial','Auto Engaged','Voicemail') THEN 'never_connected'
             ELSE 'other_connected' END AS f_last_outcome,
        CASE WHEN COALESCE(cf.n_calls_30d, 0) = 0 THEN '0' WHEN cf.n_calls_30d <= 2 THEN '1-2'
             WHEN cf.n_calls_30d <= 5 THEN '3-5' ELSE '6+' END AS f_calls_30d,
        IFF(COALESCE(lf.n_leads_before, 0) >= 2, 'reengaged', 'first_time') AS f_lead_type,
        CASE WHEN COALESCE(lf.n_leads_30d, 0) = 0 THEN '0' WHEN lf.n_leads_30d = 1 THEN '1' ELSE '2+' END AS f_leads_30d,
        COALESCE(ll.last_attr_source, 'unknown')  AS f_last_source,
        COALESCE(fl.first_attr_source, 'unknown') AS f_first_source,
        IFF(fl.first_all_src IN ('provider','googlepaid','facebookads','tiktokads','googleorganic','partnership',
                                 'directtraffic','web','webunknown','dealership','bingpaid','appunknown'),
            fl.first_all_src, 'other') AS f_first_all,
        CASE WHEN COALESCE(wa.n_wa_delivered_180d, 0) = 0 THEN '0' WHEN wa.n_wa_delivered_180d <= 2 THEN '1-2'
             WHEN wa.n_wa_delivered_180d <= 5 THEN '3-5' ELSE '6+' END AS f_wa_delivered,
        CASE WHEN COALESCE(wa.n_wa_failed_180d, 0) = 0 THEN '0' WHEN wa.n_wa_failed_180d = 1 THEN '1' ELSE '2+' END AS f_wa_failed,
        CASE WHEN COALESCE(wa.n_wa_delivered_180d, 0) = 0 THEN 'none'
             WHEN wa.n_wa_read_180d / wa.n_wa_delivered_180d <= 0     THEN '0'
             WHEN wa.n_wa_read_180d / wa.n_wa_delivered_180d <= 0.499 THEN '1-49%'
             WHEN wa.n_wa_read_180d / wa.n_wa_delivered_180d <= 0.999 THEN '50-99%'
             ELSE '100%' END AS f_wa_read_rate,
        IFF(COALESCE(rp.n_replies_180d, 0) > 0, 'yes', 'no') AS f_wa_replied,
        CASE WHEN ds.last_disc_ts IS NULL THEN 'none'
             WHEN DATEDIFF('day', ds.last_disc_ts, SYSDATE()) <= 7  THEN '0-7d'
             WHEN DATEDIFF('day', ds.last_disc_ts, SYSDATE()) <= 14 THEN '8-14d'
             WHEN DATEDIFF('day', ds.last_disc_ts, SYSDATE()) <= 28 THEN '15-28d'
             WHEN DATEDIFF('day', ds.last_disc_ts, SYSDATE()) <= 60 THEN '29-60d'
             ELSE '61d+' END AS f_disc_msg_age,
        CASE WHEN COALESCE(ds.n_disc_28d, 0) = 0 THEN '0' WHEN ds.n_disc_28d = 1 THEN '1' ELSE '2+' END AS f_disc_msgs_28d,
        IFF(COALESCE(lf.n_prior_campaign_clicks, 0) > 0, 'yes', 'no') AS f_prior_click,
        IFF(pm.phone9 IS NOT NULL, 'yes', 'no') AS f_msg_before,
        CASE WHEN p.pre_prem IS NULL THEN 'none' WHEN p.pre_prem <= 1000 THEN '<1000' WHEN p.pre_prem <= 1500 THEN '1000-1500'
             WHEN p.pre_prem <= 2000 THEN '1500-2000' WHEN p.pre_prem <= 3000 THEN '2000-3000' ELSE '3000+' END AS f_premium,
        CASE WHEN dcf.channel_factor IS NULL OR dcf.channel_factor <= 0 THEN 'none'
             WHEN dcf.channel_factor <= 0.6 THEN '<0.6' WHEN dcf.channel_factor <= 0.9 THEN '0.6-0.9'
             WHEN dcf.channel_factor <= 1.1 THEN '0.9-1.1' WHEN dcf.channel_factor <= 1.4 THEN '1.1-1.4'
             ELSE '1.4+' END AS f_dialer_ch
    FROM pool_clean p
    LEFT JOIN lf ON lf.phone9 = p.phone9
    LEFT JOIN lead_first fl ON fl.phone9 = p.phone9
    LEFT JOIN lead_last ll ON ll.phone9 = p.phone9
    LEFT JOIN cf ON cf.phone9 = p.phone9
    LEFT JOIN last_out lo ON lo.phone9 = p.phone9
    LEFT JOIN qf ON qf.phone9 = p.phone9
    LEFT JOIN wa ON wa.phone9 = p.phone9
    LEFT JOIN rep rp ON rp.phone9 = p.phone9
    LEFT JOIN disc ds ON ds.phone9 = p.phone9
    LEFT JOIN prev_msg pm ON pm.phone9 = p.phone9
    LEFT JOIN cooldown cd ON cd.phone9 = p.phone9
    LEFT JOIN sandbox.william_connect_rates.postcutoff_channel_factor dcf ON dcf.channel_key = ll.last_channel_key
),
/* ---------- scoring: one weight per (feature, level), unseen levels score 0 ---------- */
long AS (
    SELECT f.phone9, k.key AS feature, k.value::VARCHAR AS feature_level
    FROM feat f,
         LATERAL FLATTEN(INPUT => OBJECT_CONSTRUCT(
            'segment', f.f_segment, 'lead_age', f.f_lead_age, 'quote_age', f.f_quote_age,
            'call_age', f.f_call_age, 'callback_age', f.f_callback_age, 'last_outcome', f.f_last_outcome,
            'calls_30d', f.f_calls_30d, 'lead_type', f.f_lead_type, 'leads_30d', f.f_leads_30d,
            'last_source', f.f_last_source, 'first_source', f.f_first_source, 'first_all', f.f_first_all,
            'wa_delivered', f.f_wa_delivered, 'wa_failed', f.f_wa_failed, 'wa_read_rate', f.f_wa_read_rate,
            'wa_replied', f.f_wa_replied, 'prior_click', f.f_prior_click,
            'disc_msg_age', f.f_disc_msg_age, 'disc_msgs_28d', f.f_disc_msgs_28d,
            'premium', f.f_premium, 'dialer_ch', f.f_dialer_ch)) k
),
z AS (
    SELECT l.phone9,
           SUM(IFF(w.model_version = $model_version || '_deliver', w.coef, 0)) AS z_deliver,
           SUM(IFF(w.model_version = $model_version || '_click',   w.coef, 0)) AS z_click
    FROM long l
    LEFT JOIN PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CPC_MODEL_WEIGHTS w
           ON w.model_version IN ($model_version || '_deliver', $model_version || '_click')
          AND w.feature = l.feature AND w.feature_level = l.feature_level
    GROUP BY l.phone9
),
icpt AS (
    SELECT MAX(IFF(model_version = $model_version || '_deliver', coef, NULL)) AS b_deliver,
           MAX(IFF(model_version = $model_version || '_click',   coef, NULL)) AS b_click
    FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CPC_MODEL_WEIGHTS
    WHERE feature = 'intercept' AND model_version IN ($model_version || '_deliver', $model_version || '_click')
)
SELECT
    f.first_name, f.last_name, '+27' || f.phone9 AS phone_number, f.phone9,
    f.audience,
    IFF(MOD(ABS(HASH(f.phone9, 'cpc_holdout_v1')), 2) = 0, 'treated', 'control') AS arm,
    ROUND(f.prior_disc, 2)            AS prior_discount_percentage,
    f.psm_rmd,
    f.offer_pct                       AS offered_discount_percentage,
    ROUND(f.pre_prem, 2)              AS premium_without_any_discounts,
    ROUND(f.last_prem, 2)             AS last_quoted_premium,
    f.new_premium_offered,
    f.vehicle_make, f.vehicle_model,
    $model_version                    AS model_version,
    ROUND(1 / (1 + EXP(-(i.b_deliver + z.z_deliver))), 5)                                     AS p_deliver,
    ROUND(1 / (1 + EXP(-(i.b_click + z.z_click))), 5)                                         AS p_click_if_delivered,
    ROUND(1 / (1 + EXP(-(i.b_deliver + z.z_deliver))) * 1 / (1 + EXP(-(i.b_click + z.z_click))), 6) AS p_click,
    f.phone_first, f.in_cooldown,
    (NOT f.phone_first AND NOT f.in_cooldown) AS selectable,
    f.f_segment, f.f_lead_age, f.f_quote_age, f.f_call_age, f.f_callback_age, f.f_last_outcome,
    f.f_calls_30d, f.f_lead_type, f.f_leads_30d, f.f_last_source, f.f_first_source, f.f_first_all,
    f.f_wa_delivered, f.f_wa_failed, f.f_wa_read_rate, f.f_wa_replied, f.f_prior_click, f.f_premium, f.f_dialer_ch,
    f.f_disc_msg_age, f.f_disc_msgs_28d,
    SYSDATE()                         AS scored_at_utc
FROM feat f
JOIN z ON z.phone9 = f.phone9
CROSS JOIN icpt i;


/* =====================================================================================
   PART 3 — DAILY PICK (the "neat" table Tania's process reads)
   - Picks the top 2 x daily_n selectable people by p_click.
   - Writes EVERY pick to the ledger immediately (control: was_sent = FALSE,
     treated: was_sent = NULL = picked, not yet confirmed). Because the pick is logged
     before anything is sent, tomorrow's Part 2 already sees these people as in cooldown.
   - Re-running Part 3 on the same day re-uses today's picks instead of picking 200 new
     people, so an accidental re-run can never double the day's volume.
   ===================================================================================== */

CREATE OR REPLACE TABLE PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_PICKED_TODAY AS
WITH already AS (
    SELECT DISTINCT phone9 FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_HISTORY
    WHERE selected_date = CURRENT_DATE
),
fresh AS (
    SELECT a.*, ROW_NUMBER() OVER (ORDER BY a.p_click DESC, a.phone9) AS rank_on_day
    FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_AUDIENCE a
    WHERE a.selectable
    QUALIFY ROW_NUMBER() OVER (ORDER BY a.p_click DESC, a.phone9) <= 2 * $daily_n
),
reused AS (
    SELECT a.*, ROW_NUMBER() OVER (ORDER BY a.p_click DESC, a.phone9) AS rank_on_day
    FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_AUDIENCE a
    WHERE a.phone9 IN (SELECT phone9 FROM already)
)
SELECT f.*, CURRENT_DATE AS selected_date FROM fresh f WHERE NOT EXISTS (SELECT 1 FROM already)
UNION ALL
SELECT r.*, CURRENT_DATE FROM reused r;

-- log every pick now (guarded: one pick row per person per day)
INSERT INTO PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_HISTORY
    (phone_number, phone9, audience, arm, was_sent, selected_date, rank_on_day, model_version, p_click,
     prior_discount_percentage, psm_rmd, offered_discount_percentage, premium_without_any_discounts,
     last_quoted_premium, new_premium_offered)
SELECT p.phone_number, p.phone9, p.audience, p.arm, IFF(p.arm = 'control', FALSE, NULL), p.selected_date,
       p.rank_on_day, p.model_version, p.p_click,
       p.prior_discount_percentage, p.psm_rmd, p.offered_discount_percentage, p.premium_without_any_discounts,
       p.last_quoted_premium, p.new_premium_offered
FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_PICKED_TODAY p
WHERE NOT EXISTS (SELECT 1 FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_HISTORY h
                  WHERE h.phone9 = p.phone9 AND h.selected_date = p.selected_date);

-- Tania's table: treated picks, minus anyone the 7-day spam guard blocks (checked again here)
CREATE OR REPLACE TABLE PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_SEND_TODAY AS
SELECT p.first_name, p.last_name, p.phone_number,
       p.audience,                                    -- dictates which template Tania sends
       p.offered_discount_percentage,
       p.premium_without_any_discounts, p.last_quoted_premium, p.new_premium_offered,
       p.vehicle_make, p.vehicle_model,
       FALSE AS has_been_messaged,                    -- the send process flips this after sending
       CURRENT_DATE AS selected_date                  -- Make: only send if this is today's date
FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_PICKED_TODAY p
WHERE p.arm = 'treated'
  AND p.phone9 NOT IN (SELECT phone9 FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_DO_NOT_MESSAGE_7D)
ORDER BY p.rank_on_day;


/* =====================================================================================
   PART 4 — AFTER THE SEND: append a confirmation row (was_sent = TRUE) for each treated
   person Tania's process marked as messaged. The ledger stays append-only: a sent person
   has two rows that day (picked = NULL, confirmed = TRUE).
   Tania's process should ALSO check DO_NOT_MESSAGE_7D just before sending.
   ===================================================================================== */

INSERT INTO PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_HISTORY
    (phone_number, phone9, audience, arm, was_sent, selected_date, rank_on_day, model_version, p_click,
     prior_discount_percentage, psm_rmd, offered_discount_percentage, premium_without_any_discounts,
     last_quoted_premium, new_premium_offered)
SELECT p.phone_number, p.phone9, p.audience, 'treated', TRUE, p.selected_date, p.rank_on_day, p.model_version, p.p_click,
       p.prior_discount_percentage, p.psm_rmd, p.offered_discount_percentage, p.premium_without_any_discounts,
       p.last_quoted_premium, p.new_premium_offered
FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_PICKED_TODAY p
JOIN PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_SEND_TODAY s
  ON s.phone_number = p.phone_number AND s.has_been_messaged = TRUE
WHERE p.arm = 'treated'
  AND NOT EXISTS (SELECT 1 FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_HISTORY h
                  WHERE h.phone9 = p.phone9 AND h.selected_date = p.selected_date AND h.was_sent = TRUE);

-- then take the sent rows out of SEND_TODAY, so they can never be sent again from today's list.
-- Rows left behind = picked but NOT sent today (useful to inspect). Tomorrow's pick replaces the table.
DELETE FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_SEND_TODAY
WHERE has_been_messaged = TRUE;


/* =====================================================================================
   PART 5 — CHECKS (run after Part 2/3 the first few days)
   ===================================================================================== */

-- 5.1 Pool size, how many each rule removes, score and discount shape, by audience
SELECT audience,
       COUNT(*)                                        AS eligible,
       COUNT_IF(phone_first)                           AS held_for_phone,
       COUNT_IF(in_cooldown)                           AS in_cooldown,
       COUNT_IF(selectable)                            AS selectable,
       COUNT_IF(selectable AND arm = 'treated')        AS selectable_treated,
       ROUND(AVG(IFF(selectable, p_deliver, NULL)) * 100, 1) AS avg_p_deliver_pct,
       COUNT_IF(selectable AND p_deliver < 0.3)        AS selectable_likely_undeliverable,
       ROUND(AVG(IFF(selectable, p_click, NULL)) * 100, 3) AS avg_p_click_pct,
       ROUND(AVG(offered_discount_percentage), 2)      AS avg_offer,
       MIN(offered_discount_percentage)                AS min_offer,
       MAX(offered_discount_percentage)                AS max_offer
FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_AUDIENCE
GROUP BY audience ORDER BY audience;

-- 5.2 Today's pick: arm balance and audience mix (expect ~50/50)
SELECT arm, audience, COUNT(*) AS people, ROUND(AVG(p_click) * 100, 3) AS avg_p_click_pct,
       ROUND(AVG(offered_discount_percentage), 2) AS avg_offer
FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_PICKED_TODAY
GROUP BY 1, 2 ORDER BY 1, 2;

-- 5.3 Must be zero: duplicates or a person in both arms in the ledger
SELECT phone9, COUNT(DISTINCT arm) AS arms, COUNT(*) AS rows_
FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_HISTORY
GROUP BY phone9 HAVING COUNT(DISTINCT arm) > 1;

-- 5.4 Must be zero: anyone confirmed-sent twice within 7 days
SELECT a.phone9, a.selected_date AS first_send, b.selected_date AS second_send
FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_HISTORY a
JOIN PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_HISTORY b
  ON a.phone9 = b.phone9 AND a.was_sent = TRUE AND b.was_sent = TRUE
 AND b.selected_date > a.selected_date AND b.selected_date < DATEADD('day', 7, a.selected_date);