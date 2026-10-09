/* =====================================================================================
   MMM — RUN THE DAILY STEPS INSIDE SNOWFLAKE (stored procedures + scheduled Tasks)
   -------------------------------------------------------------------------------------
   Run this whole file ONCE in a Snowflake worksheet, step by step (see the numbered
   STEP headers). After that Snowflake runs the daily audience by itself:

     MMM_DAILY_PICK_TASK     10:30 Mon-Sat (SAST)  -> Parts 2+3: score everyone, pick today's
                                                       people, log picks, fill SEND_TODAY
     MMM_CONFIRM_SENDS_TASK  18:00 Mon-Sat (SAST)  -> Part 4: log the rows the send process
                                                       marked has_been_messaged = TRUE, then
                                                       delete those rows from SEND_TODAY

   The statements inside the procedures are copied unchanged from MMM_production_scoring.sql
   (Parts 2, 3 and 4). If you change those parts, re-run STEP 1 / STEP 2 of this file so the
   procedures pick the change up.

   Python is only used for the monthly retrain (MMM_auto_retrain.py). It writes new weights +
   a new champion into CPC_MODEL_REGISTRY, and the next 10:30 run scores with it automatically.
   ===================================================================================== */

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE SCHEMA PINEAPPLE_DATABASE.MESSAGING_AUDIENCES;


/* -------------------------------------------------------------------------------------
   STEP 1 — the daily pick procedure (Parts 2 + 3)
     P_DAILY_N        treated sends per day (control adds roughly the same again)
     P_COOLDOWN_DAYS  selection cooldown in days (7 = same as the spam guard)
     P_SCORE_ONLY     TRUE = only rebuild + score the audience (Part 2), pick nobody.
                      Use TRUE to test safely: nothing goes into the ledger.
   Session variables ($daily_n, $model_version ...) cannot be used inside a procedure, so each
   statement is run with EXECUTE IMMEDIATE and the values are written into the SQL text:
   the champion model from CPC_MODEL_REGISTRY, P_DAILY_N and P_COOLDOWN_DAYS. Apart from those
   three values, every statement is identical to MMM_production_scoring.sql.
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.MMM_DAILY_PICK(
    P_DAILY_N NUMBER DEFAULT 100,
    P_COOLDOWN_DAYS NUMBER DEFAULT 7,
    P_SCORE_ONLY BOOLEAN DEFAULT FALSE)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    stmt        VARCHAR;
    mv          VARCHAR;
    n_eligible  NUMBER;
    n_select    NUMBER;
    n_send      NUMBER;
BEGIN
    -- current champion model from the registry
    SELECT model_version INTO :mv FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CPC_MODEL_REGISTRY
    WHERE status = 'champion' ORDER BY promoted_at DESC LIMIT 1;
    IF (mv IS NULL) THEN
        RETURN 'FAILED: no champion in CPC_MODEL_REGISTRY';
    END IF;

    -- ===== PART 2: score everyone eligible =====
    -- part 2 statement 1: CREATE OR REPLACE TABLE PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINU...
    stmt := 'CREATE OR REPLACE TABLE PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_AUDIENCE AS
WITH
 
base_quotes AS (
    SELECT g.USER_ID, g.FORMATTED_PHONE, g.DISCOUNT_ACTIVITY_ID, TO_VARCHAR(g.QUOTE_NO) AS quote_no,   
           COALESCE(g.QUOTED_AT, g.QUOTE_JOURNEY_START_AT, CAST(g.QUOTE_DATE AS TIMESTAMP)) AS quote_ts,
           RIGHT(REGEXP_REPLACE(COALESCE(g.FORMATTED_PHONE,''''), ''[^0-9]'', ''''), 9) AS phone9
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
    SELECT d.*, DATEDIFF(''day'', LAG(d.quote_ts) OVER (PARTITION BY d.USER_ID ORDER BY d.quote_ts), d.quote_ts) AS days_since_prev_quote
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
            UPPER(REGEXP_REPLACE(VEHICLE_REGISTRATION, ''[^A-Za-z0-9]'', '''')) AS vehicle_reg_norm,
            TRY_TO_NUMBER(POLICY_LINE_NO::STRING) AS line_no,
            ROW_NUMBER() OVER (PARTITION BY ID ORDER BY TRY_TO_TIMESTAMP_NTZ(UPDATEDAT) DESC NULLS LAST,
                                                        TRY_TO_TIMESTAMP_NTZ(CREATEDAT) DESC NULLS LAST) AS rn
        FROM pineapple_database.pineapple_mongo.DISCOUNTS_ACTIVITY
    ) WHERE rn = 1
),
stmtr_by_line AS (
    SELECT AGR_LINE_NO, MAKE, MODEL FROM ACTUARIAL_DATABASE.SANDBOX.OBJECT_STMTR
    WHERE AGR_LINE_NO IS NOT NULL AND MAKE IS NOT NULL AND TRIM(MAKE) <> ''''
    QUALIFY ROW_NUMBER() OVER (PARTITION BY AGR_LINE_NO ORDER BY SEQ_NO DESC) = 1
),
 
active_phones AS (
    SELECT DISTINCT RIGHT(REGEXP_REPLACE(SPLIT_PART("cus_mobile_phone_no"::STRING,''.'',1),''[^0-9]'',''''),9) AS phone
    FROM sftp_latest_reports.data."pa_active"
    WHERE "cus_mobile_phone_no" IS NOT NULL AND LENGTH(REGEXP_REPLACE(SPLIT_PART("cus_mobile_phone_no"::STRING,''.'',1),''[^0-9]'','''')) >= 9
),
policy_holders AS (
    SELECT DISTINCT RIGHT(REGEXP_REPLACE(SPLIT_PART(vehicle_ownerperson_cellphonenumber::STRING,''.'',1),''[^0-9]'',''''),9) AS phone
    FROM pineapple_database.pineapple_mongo.mtr_policy_requests_full
    WHERE type IN (''createPolicy'',''additionalVehiclePolicy'') AND TRY_CAST(response_status AS INTEGER) = 200
      AND LENGTH(REGEXP_REPLACE(SPLIT_PART(vehicle_ownerperson_cellphonenumber::STRING,''.'',1),''[^0-9]'','''')) >= 9
),
outcome_calls AS (     
    SELECT RIGHT(REGEXP_REPLACE(COALESCE(oc.subject,''''), ''[^0-9]'', ''''), 9) AS phone, oc.start_time, o.name
    FROM connex_db.data.cxm_interactions oc
    JOIN connex_db.data.cxm_outcomes o ON o.id = oc.outcome_id
    WHERE oc.direction = ''outbound'' AND LENGTH(REGEXP_REPLACE(COALESCE(oc.subject,''''), ''[^0-9]'', '''')) >= 9
),
dnc_flag AS (SELECT DISTINCT phone FROM outcome_calls WHERE name = ''Do Not Call''),
existing_or_sale_phones AS (SELECT DISTINCT phone FROM outcome_calls WHERE name ILIKE ''%existing%policyholder%'' OR name ILIKE ''%sale made%''),
permanent_disqualified_phones AS (
    SELECT DISTINCT phone FROM outcome_calls
    WHERE name ILIKE ''no insurable risk%'' OR name IN (''Incorrect Number'',''Incorrect Contact Number'',''Wrong Number'',''Disconnected'')
),
l2s_disqualified_phones AS (     
    SELECT DISTINCT phone FROM outcome_calls
    WHERE name ILIKE ''no insurable risk%'' OR name = ''Still shopping for a car''
       OR name ILIKE ''%existing%policyholder%'' OR name ILIKE ''%sale made%''
       OR name IN (''Incorrect Number'',''Incorrect Contact Number'',''Wrong Number'',''Disconnected'')
),
recent_temp_disconnected_phones AS (
    SELECT DISTINCT phone FROM outcome_calls
    WHERE name = ''Temporary Disconnected Number'' AND start_time >= DATEADD(''day'', -90, CURRENT_DATE)
),
opt_out_phones AS (
    SELECT DISTINCT RIGHT(REGEXP_REPLACE(CLIENT_NUMEBR,''[^0-9]'',''''),9) AS phone
    FROM LOGGING_DB.PDP_LOGGING.OPT_OUT_WHATSAPP_LOGGING
    WHERE CLIENT_NUMEBR IS NOT NULL AND LENGTH(REGEXP_REPLACE(CLIENT_NUMEBR,''[^0-9]'','''')) >= 9
),
leads_all AS (
    SELECT RIGHT(REGEXP_REPLACE(COALESCE(contact_number,''''),''[^0-9]'',''''),9) AS phone9,
           TRY_TO_TIMESTAMP(usercreatedat) AS lead_ts, user_id, first_name, last_name,
           LOWER(COALESCE(final_attributed_source_fixed,''unknown'')) AS attr_source,
           LOWER(COALESCE(all_sources,''unknown'')) AS all_src,
           CASE WHEN final_attributed_source_fixed = ''lead_provider'' THEN sub_sources ELSE all_sources END AS channel_key,
           COALESCE(lead_source_reference_UCID, '''') AS ucid
    FROM pineapple_database.pineapple_mongo.lead_channel_labels
    WHERE LENGTH(REGEXP_REPLACE(COALESCE(contact_number,''''),''[^0-9]'','''')) >= 9
      AND TRY_TO_TIMESTAMP(usercreatedat) IS NOT NULL
),
recent_dealership AS (SELECT DISTINCT phone9 FROM leads_all WHERE all_src = ''dealership'' AND lead_ts >= DATEADD(''day'',-2,CURRENT_DATE)),
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
           DATEDIFF(''day'', q.quote_anchor_ts, CURRENT_DATE) AS days_since_quote,
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
      AND DATEDIFF(''day'', q.quote_anchor_ts, CURRENT_DATE) <= 365
),
q2s_priced AS (
    SELECT e.*,
           
           GREATEST(7,
                    CEIL(e.prior_disc + 3.0),
                    IFF(e.psm_rmd > e.prior_disc, CEIL(e.psm_rmd), 0),
                    IFF(e.alpha_active, CEIL(COALESCE(e.alpha_locked_dut, 0)), 0)) AS offer_pct
    FROM q2s_eligible e
    WHERE e.prior_disc IS NOT NULL
),
q2s_final AS (
    SELECT phone9, IFF(days_since_quote <= 45, ''Q2S_LT45'', ''Q2S_GT45'') AS audience,
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
 
quoted_users AS (
    SELECT DISTINCT USER_ID AS user_id FROM ACTUARIAL_DATABASE.SANDBOX.GOLDEN_QUOTE_JOURNEY_DATASET WHERE USER_ID IS NOT NULL
    UNION
    SELECT DISTINCT "key_entity_details/user_id" FROM MONGO_DATA_BASE.DATA.EVENT_LOGS
    WHERE ACTION = ''quoted'' AND "key_entity_details/user_id" IS NOT NULL
),
quoted_phones AS (
    SELECT DISTINCT RIGHT(REGEXP_REPLACE(COALESCE(FORMATTED_PHONE,''''),''[^0-9]'',''''),9) AS phone9
    FROM ACTUARIAL_DATABASE.SANDBOX.GOLDEN_QUOTE_JOURNEY_DATASET
    WHERE FORMATTED_PHONE IS NOT NULL AND LENGTH(REGEXP_REPLACE(COALESCE(FORMATTED_PHONE,''''),''[^0-9]'','''')) >= 9
),
sold_users AS (
    SELECT DISTINCT "key_entity_details/user_id" AS user_id FROM MONGO_DATA_BASE.DATA.EVENT_LOGS
    WHERE ACTION = ''insured'' AND "key_entity_details/user_id" IS NOT NULL
),
lead_latest AS (
    SELECT phone9, user_id, first_name, last_name FROM leads_all
    QUALIFY ROW_NUMBER() OVER (PARTITION BY phone9 ORDER BY lead_ts DESC) = 1
),
l2s_final AS (
    SELECT ll.phone9, ''L2S'' AS audience, ll.first_name, ll.last_name,
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
      AND DATEDIFF(''day'', lr.max_lead_ts, CURRENT_DATE) <= 15
),
pool AS (
    SELECT * FROM q2s_final
    UNION ALL
    SELECT * FROM l2s_final
),
pool_clean AS (    
    SELECT p.* FROM pool p
    WHERE p.first_name IS NOT NULL AND TRIM(p.first_name) <> '''' AND p.last_name IS NOT NULL AND TRIM(p.last_name) <> ''''
      AND LOWER(TRIM(p.first_name)) <> ''nofirstname'' AND LOWER(TRIM(p.last_name)) <> ''nolastname''
      AND UPPER(TRIM(p.first_name) || '' '' || TRIM(p.last_name)) NOT IN (''PINE APPLE'',''PABLO ESCOBAR'')
      AND ''+27'' || p.phone9 NOT IN (''+27815557799'',''+27815559988'',''+27832750122'',''+27832570211'',
                                    ''+27890204585'',''+27887580624'',''+27896325334'',''+27935191849'',''+27781111000'')
),
 
lf AS (
    SELECT p.phone9,
           COUNT(l.lead_ts)                                                         AS n_leads_before,
           COUNT_IF(l.lead_ts >= DATEADD(''day'', -30, SYSDATE()))                     AS n_leads_30d,
           COUNT_IF(l.ucid ILIKE ''PINCARDISC%'')                                      AS n_prior_campaign_clicks,
           DATEDIFF(''day'', MAX(l.lead_ts), SYSDATE())                               AS days_since_last_lead
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
calls3 AS (        
    SELECT RIGHT(REGEXP_REPLACE(COALESCE(i.subject,''''),''[^0-9]'',''''),9) AS phone9,
           DATEADD(''hour'', -2, i.start_time) AS call_ts, COALESCE(o.name, '''') AS outcome
    FROM connex_db.data.cxm_interactions i
    LEFT JOIN connex_db.data.cxm_outcomes o ON o.id = i.outcome_id
    WHERE i.direction = ''outbound'' AND i.start_time IS NOT NULL
      AND i.campaign_id IN (''568752c7-ffbc-4edb-9665-0a6792c1f7e7'',''6c7bc2df-17f5-4c06-8b4f-c7274bfde6ca'',
                            ''90ae6979-ab80-48fc-b7e1-29e2ef46c6d6'')
),
cf AS (
    SELECT p.phone9,
           COUNT_IF(c.call_ts >= DATEADD(''day'', -30, SYSDATE()))                                   AS n_calls_30d,
           DATEDIFF(''hour'', MAX(c.call_ts), SYSDATE()) / 24.0                                      AS days_since_last_call,
           DATEDIFF(''hour'', MAX(IFF(c.outcome ILIKE ''Callback Scheduled%'', c.call_ts, NULL)), SYSDATE()) / 24.0 AS days_since_last_callback
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
           DATEDIFF(''day'', MAX(COALESCE(g.QUOTED_AT, g.QUOTE_JOURNEY_START_AT, CAST(g.QUOTE_DATE AS TIMESTAMP))::TIMESTAMP_NTZ), SYSDATE()) AS days_since_last_quote
    FROM pool_clean p
    LEFT JOIN ACTUARIAL_DATABASE.SANDBOX.GOLDEN_QUOTE_JOURNEY_DATASET g
           ON RIGHT(REGEXP_REPLACE(COALESCE(g.FORMATTED_PHONE,''''),''[^0-9]'',''''),9) = p.phone9
    GROUP BY p.phone9
),
wa_msgs AS (       
    SELECT p.phone9, w.MESSAGE_SID AS sid,
           MIN(m.DATE_SENT)                                      AS sent_ts,
           MAX(IFF(m.STATUS IN (''delivered'', ''read''), 1, 0))     AS was_delivered,
           MAX(IFF(m.STATUS = ''read'', 1, 0))                     AS was_read,
           MAX(IFF(m.STATUS IN (''undelivered'', ''failed''), 1, 0)) AS was_failed,
           MAX(IFF(dt.template_id IS NOT NULL, 1, 0))            AS is_disc_template
    FROM pool_clean p
    JOIN TWILIO_DATABASE.DATA.WHATSAPPTEMPLATEDATA w
      ON RIGHT(REGEXP_REPLACE(SPLIT_PART(w.NUMBER::STRING,''.'',1),''[^0-9]'',''''),9) = p.phone9
    JOIN TWILIO_DATABASE.DATA.MESSAGES m
      ON m.SID = w.MESSAGE_SID AND m.STATUS <> ''received''
     AND m.DATE_SENT >= DATEADD(''day'', -181, SYSDATE())
    LEFT JOIN PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CPC_DISCOUNT_TEMPLATES dt ON dt.template_id = TRIM(w.TEMPLATE_ID)
    GROUP BY p.phone9, w.MESSAGE_SID
),
disc AS (          
    SELECT phone9,
           MAX(IFF(is_disc_template = 1 AND was_delivered = 1, sent_ts, NULL)) AS last_disc_ts,
           COUNT_IF(is_disc_template = 1 AND was_delivered = 1
                    AND sent_ts >= DATEADD(''day'', -28, SYSDATE()))              AS n_disc_28d
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
    WHERE sent_ts >= DATEADD(''day'', -180, SYSDATE()) AND sent_ts < DATEADD(''day'', -1, SYSDATE())
    GROUP BY phone9
),
rep AS (
    SELECT p.phone9, COUNT(DISTINCT m.SID) AS n_replies_180d
    FROM pool_clean p
    JOIN TWILIO_DATABASE.DATA.MESSAGES m
      ON RIGHT(REGEXP_REPLACE(COALESCE(m."from",''''),''[^0-9]'',''''),9) = p.phone9
     AND m.STATUS = ''received''
     AND m.DATE_SENT >= DATEADD(''day'', -180, SYSDATE()) AND m.DATE_SENT < DATEADD(''day'', -1, SYSDATE())
    GROUP BY p.phone9
),
prev_msg AS (      
    SELECT DISTINCT phone9 FROM (
        SELECT RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING,''[^0-9]'',''''),9) AS phone9, HAS_BEEN_MESSAGED AS hbm FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_20_PERCENT_DAY_1
        UNION ALL SELECT RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING,''[^0-9]'',''''),9), HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_20_DAY_1
        UNION ALL SELECT RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING,''[^0-9]'',''''),9), HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_10_DAY_1
        UNION ALL SELECT RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING,''[^0-9]'',''''),9), HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_20_Q2S_LESS_45DAYS_JUL2026
        UNION ALL SELECT RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING,''[^0-9]'',''''),9), HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_20_Q2S_OVER_45DAYS_JUL2026
        UNION ALL SELECT RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING,''[^0-9]'',''''),9), HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_15_L2S_JUL2026
        UNION ALL SELECT RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING,''[^0-9]'',''''),9), HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_Q2S_LESSTHAN45D_AUG2026
        UNION ALL SELECT RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING,''[^0-9]'',''''),9), HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_Q2S_MORETHAN45D_AUG2026
        UNION ALL SELECT RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING,''[^0-9]'',''''),9), HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_L2S_AUG2026
        UNION ALL SELECT RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING,''[^0-9]'',''''),9), HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_Q2S_LESSTHAN45D_SEP2026
        UNION ALL SELECT RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING,''[^0-9]'',''''),9), HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_Q2S_MORETHAN45D_SEP2026
        UNION ALL SELECT RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING,''[^0-9]'',''''),9), HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_L2S_SEP2026
        UNION ALL SELECT phone9, was_sent FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_HISTORY
    ) WHERE hbm = TRUE
),
cooldown AS (      
    SELECT DISTINCT phone9 FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_HISTORY
    WHERE selected_date >= DATEADD(''day'', -' || P_COOLDOWN_DAYS::VARCHAR || ', CURRENT_DATE)
    UNION
    SELECT RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING,''[^0-9]'',''''),9) FROM (
        SELECT PHONE_NUMBER, HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_Q2S_LESSTHAN45D_SEP2026
        UNION ALL SELECT PHONE_NUMBER, HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_Q2S_MORETHAN45D_SEP2026
        UNION ALL SELECT PHONE_NUMBER, HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_L2S_SEP2026
    ) WHERE HAS_BEEN_MESSAGED = TRUE AND DATEADD(''day'', ' || P_COOLDOWN_DAYS::VARCHAR || ', ''2026-09-16''::DATE) >= CURRENT_DATE
    UNION
    SELECT phone9 FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_DO_NOT_MESSAGE_7D
),
feat AS (
    SELECT p.*,
        lf.n_leads_before, lf.days_since_last_lead, cf.days_since_last_call, cf.days_since_last_callback,
        
        (COALESCE(cf.days_since_last_callback, 999) <= 1
         OR COALESCE(lf.days_since_last_lead, 999) <= 1)                                        AS phone_first,
        (cd.phone9 IS NOT NULL)                                                                  AS in_cooldown,
         
        p.audience AS f_segment,
        CASE WHEN lf.days_since_last_lead IS NULL THEN ''none'' WHEN lf.days_since_last_lead <= 3 THEN ''0-3d''
             WHEN lf.days_since_last_lead <= 7 THEN ''4-7d'' WHEN lf.days_since_last_lead <= 15 THEN ''8-15d''
             WHEN lf.days_since_last_lead <= 30 THEN ''16-30d'' WHEN lf.days_since_last_lead <= 90 THEN ''31-90d''
             WHEN lf.days_since_last_lead <= 180 THEN ''91-180d'' WHEN lf.days_since_last_lead <= 365 THEN ''181-365d''
             ELSE ''365d+'' END AS f_lead_age,
        CASE WHEN qf.days_since_last_quote IS NULL THEN ''none'' WHEN qf.days_since_last_quote <= 14 THEN ''0-14d''
             WHEN qf.days_since_last_quote <= 45 THEN ''15-45d'' WHEN qf.days_since_last_quote <= 90 THEN ''46-90d''
             WHEN qf.days_since_last_quote <= 180 THEN ''91-180d'' WHEN qf.days_since_last_quote <= 365 THEN ''181-365d''
             ELSE ''365d+'' END AS f_quote_age,
        CASE WHEN cf.days_since_last_call IS NULL THEN ''none'' WHEN cf.days_since_last_call <= 2 THEN ''0-2d''
             WHEN cf.days_since_last_call <= 7 THEN ''3-7d'' WHEN cf.days_since_last_call <= 30 THEN ''8-30d''
             WHEN cf.days_since_last_call <= 90 THEN ''31-90d'' WHEN cf.days_since_last_call <= 180 THEN ''91-180d''
             ELSE ''180d+'' END AS f_call_age,
        CASE WHEN cf.days_since_last_callback IS NULL THEN ''none'' WHEN cf.days_since_last_callback <= 7 THEN ''0-7d''
             WHEN cf.days_since_last_callback <= 30 THEN ''8-30d'' WHEN cf.days_since_last_callback <= 90 THEN ''31-90d''
             ELSE ''90d+'' END AS f_callback_age,
        CASE WHEN lo.last_outcome IS NULL                          THEN ''no_prior_call''
             WHEN lo.last_outcome ILIKE ''Callback Scheduled%''      THEN ''callback_scheduled''
             WHEN lo.last_outcome ILIKE ''Do Not Call%'' OR lo.last_outcome ILIKE ''Sale Made%''
               OR lo.last_outcome ILIKE ''%Existing%Policyholder%'' OR lo.last_outcome ILIKE ''%No Insurable Risk%'' THEN ''other_connected''
             WHEN lo.last_outcome ILIKE ''%Disconnect%''             THEN ''auto_disconnected''
             WHEN lo.last_outcome IN (''Not Reached'',''No Answer Autodial'',''Auto Engaged'',''Voicemail'') THEN ''never_connected''
             ELSE ''other_connected'' END AS f_last_outcome,
        CASE WHEN COALESCE(cf.n_calls_30d, 0) = 0 THEN ''0'' WHEN cf.n_calls_30d <= 2 THEN ''1-2''
             WHEN cf.n_calls_30d <= 5 THEN ''3-5'' ELSE ''6+'' END AS f_calls_30d,
        IFF(COALESCE(lf.n_leads_before, 0) >= 2, ''reengaged'', ''first_time'') AS f_lead_type,
        CASE WHEN COALESCE(lf.n_leads_30d, 0) = 0 THEN ''0'' WHEN lf.n_leads_30d = 1 THEN ''1'' ELSE ''2+'' END AS f_leads_30d,
        COALESCE(ll.last_attr_source, ''unknown'')  AS f_last_source,
        COALESCE(fl.first_attr_source, ''unknown'') AS f_first_source,
        IFF(fl.first_all_src IN (''provider'',''googlepaid'',''facebookads'',''tiktokads'',''googleorganic'',''partnership'',
                                 ''directtraffic'',''web'',''webunknown'',''dealership'',''bingpaid'',''appunknown''),
            fl.first_all_src, ''other'') AS f_first_all,
        CASE WHEN COALESCE(wa.n_wa_delivered_180d, 0) = 0 THEN ''0'' WHEN wa.n_wa_delivered_180d <= 2 THEN ''1-2''
             WHEN wa.n_wa_delivered_180d <= 5 THEN ''3-5'' ELSE ''6+'' END AS f_wa_delivered,
        CASE WHEN COALESCE(wa.n_wa_failed_180d, 0) = 0 THEN ''0'' WHEN wa.n_wa_failed_180d = 1 THEN ''1'' ELSE ''2+'' END AS f_wa_failed,
        CASE WHEN COALESCE(wa.n_wa_delivered_180d, 0) = 0 THEN ''none''
             WHEN wa.n_wa_read_180d / wa.n_wa_delivered_180d <= 0     THEN ''0''
             WHEN wa.n_wa_read_180d / wa.n_wa_delivered_180d <= 0.499 THEN ''1-49%''
             WHEN wa.n_wa_read_180d / wa.n_wa_delivered_180d <= 0.999 THEN ''50-99%''
             ELSE ''100%'' END AS f_wa_read_rate,
        IFF(COALESCE(rp.n_replies_180d, 0) > 0, ''yes'', ''no'') AS f_wa_replied,
        CASE WHEN ds.last_disc_ts IS NULL THEN ''none''
             WHEN DATEDIFF(''day'', ds.last_disc_ts, SYSDATE()) <= 7  THEN ''0-7d''
             WHEN DATEDIFF(''day'', ds.last_disc_ts, SYSDATE()) <= 14 THEN ''8-14d''
             WHEN DATEDIFF(''day'', ds.last_disc_ts, SYSDATE()) <= 28 THEN ''15-28d''
             WHEN DATEDIFF(''day'', ds.last_disc_ts, SYSDATE()) <= 60 THEN ''29-60d''
             ELSE ''61d+'' END AS f_disc_msg_age,
        CASE WHEN COALESCE(ds.n_disc_28d, 0) = 0 THEN ''0'' WHEN ds.n_disc_28d = 1 THEN ''1'' ELSE ''2+'' END AS f_disc_msgs_28d,
        IFF(COALESCE(lf.n_prior_campaign_clicks, 0) > 0, ''yes'', ''no'') AS f_prior_click,
        IFF(pm.phone9 IS NOT NULL, ''yes'', ''no'') AS f_msg_before,
        CASE WHEN p.pre_prem IS NULL THEN ''none'' WHEN p.pre_prem <= 1000 THEN ''<1000'' WHEN p.pre_prem <= 1500 THEN ''1000-1500''
             WHEN p.pre_prem <= 2000 THEN ''1500-2000'' WHEN p.pre_prem <= 3000 THEN ''2000-3000'' ELSE ''3000+'' END AS f_premium,
        CASE WHEN dcf.channel_factor IS NULL OR dcf.channel_factor <= 0 THEN ''none''
             WHEN dcf.channel_factor <= 0.6 THEN ''<0.6'' WHEN dcf.channel_factor <= 0.9 THEN ''0.6-0.9''
             WHEN dcf.channel_factor <= 1.1 THEN ''0.9-1.1'' WHEN dcf.channel_factor <= 1.4 THEN ''1.1-1.4''
             ELSE ''1.4+'' END AS f_dialer_ch
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
 
long AS (
    SELECT f.phone9, k.key AS feature, k.value::VARCHAR AS feature_level
    FROM feat f,
         LATERAL FLATTEN(INPUT => OBJECT_CONSTRUCT(
            ''segment'', f.f_segment, ''lead_age'', f.f_lead_age, ''quote_age'', f.f_quote_age,
            ''call_age'', f.f_call_age, ''callback_age'', f.f_callback_age, ''last_outcome'', f.f_last_outcome,
            ''calls_30d'', f.f_calls_30d, ''lead_type'', f.f_lead_type, ''leads_30d'', f.f_leads_30d,
            ''last_source'', f.f_last_source, ''first_source'', f.f_first_source, ''first_all'', f.f_first_all,
            ''wa_delivered'', f.f_wa_delivered, ''wa_failed'', f.f_wa_failed, ''wa_read_rate'', f.f_wa_read_rate,
            ''wa_replied'', f.f_wa_replied, ''prior_click'', f.f_prior_click,
            ''disc_msg_age'', f.f_disc_msg_age, ''disc_msgs_28d'', f.f_disc_msgs_28d,
            ''premium'', f.f_premium, ''dialer_ch'', f.f_dialer_ch)) k
),
z AS (
    SELECT l.phone9,
           SUM(IFF(w.model_version = ''' || mv || ''' || ''_deliver'', w.coef, 0)) AS z_deliver,
           SUM(IFF(w.model_version = ''' || mv || ''' || ''_click'',   w.coef, 0)) AS z_click
    FROM long l
    LEFT JOIN PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CPC_MODEL_WEIGHTS w
           ON w.model_version IN (''' || mv || ''' || ''_deliver'', ''' || mv || ''' || ''_click'')
          AND w.feature = l.feature AND w.feature_level = l.feature_level
    GROUP BY l.phone9
),
icpt AS (
    SELECT MAX(IFF(model_version = ''' || mv || ''' || ''_deliver'', coef, NULL)) AS b_deliver,
           MAX(IFF(model_version = ''' || mv || ''' || ''_click'',   coef, NULL)) AS b_click
    FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CPC_MODEL_WEIGHTS
    WHERE feature = ''intercept'' AND model_version IN (''' || mv || ''' || ''_deliver'', ''' || mv || ''' || ''_click'')
)
SELECT
    f.first_name, f.last_name, ''+27'' || f.phone9 AS phone_number, f.phone9,
    f.audience,
    IFF(MOD(ABS(HASH(f.phone9, ''cpc_holdout_v1'')), 2) = 0, ''treated'', ''control'') AS arm,
    ROUND(f.prior_disc, 2)            AS prior_discount_percentage,
    f.psm_rmd,
    f.offer_pct                       AS offered_discount_percentage,
    ROUND(f.pre_prem, 2)              AS premium_without_any_discounts,
    ROUND(f.last_prem, 2)             AS last_quoted_premium,
    f.new_premium_offered,
    f.vehicle_make, f.vehicle_model,
    ''' || mv || '''                    AS model_version,
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
CROSS JOIN icpt i';
    EXECUTE IMMEDIATE :stmt;

    SELECT COUNT(*), COUNT_IF(selectable) INTO :n_eligible, :n_select
    FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_AUDIENCE;

    IF (P_SCORE_ONLY) THEN
        RETURN 'SCORE ONLY (nobody picked): model ' || mv || ', eligible ' || n_eligible || ', selectable ' || n_select;
    END IF;

    -- ===== PART 3: pick today's people, log every pick, build SEND_TODAY =====
    -- part 3 statement 1: CREATE OR REPLACE TABLE PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINU...
    stmt := 'CREATE OR REPLACE TABLE PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_PICKED_TODAY AS
WITH already AS (
    SELECT DISTINCT phone9 FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_HISTORY
    WHERE selected_date = CURRENT_DATE
),
fresh AS (
    SELECT a.*, ROW_NUMBER() OVER (ORDER BY a.p_click DESC, a.phone9) AS rank_on_day
    FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_AUDIENCE a
    WHERE a.selectable
    QUALIFY ROW_NUMBER() OVER (ORDER BY a.p_click DESC, a.phone9) <= 2 * ' || P_DAILY_N::VARCHAR || '
),
reused AS (
    SELECT a.*, ROW_NUMBER() OVER (ORDER BY a.p_click DESC, a.phone9) AS rank_on_day
    FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_AUDIENCE a
    WHERE a.phone9 IN (SELECT phone9 FROM already)
)
SELECT f.*, CURRENT_DATE AS selected_date FROM fresh f WHERE NOT EXISTS (SELECT 1 FROM already)
UNION ALL
SELECT r.*, CURRENT_DATE FROM reused r';
    EXECUTE IMMEDIATE :stmt;

    -- part 3 statement 2: INSERT INTO PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAM...
    stmt := 'INSERT INTO PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_HISTORY
    (phone_number, phone9, audience, arm, was_sent, selected_date, rank_on_day, model_version, p_click,
     prior_discount_percentage, psm_rmd, offered_discount_percentage, premium_without_any_discounts,
     last_quoted_premium, new_premium_offered)
SELECT p.phone_number, p.phone9, p.audience, p.arm, IFF(p.arm = ''control'', FALSE, NULL), p.selected_date,
       p.rank_on_day, p.model_version, p.p_click,
       p.prior_discount_percentage, p.psm_rmd, p.offered_discount_percentage, p.premium_without_any_discounts,
       p.last_quoted_premium, p.new_premium_offered
FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_PICKED_TODAY p
WHERE NOT EXISTS (SELECT 1 FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_HISTORY h
                  WHERE h.phone9 = p.phone9 AND h.selected_date = p.selected_date)';
    EXECUTE IMMEDIATE :stmt;

    -- part 3 statement 3: CREATE OR REPLACE TABLE PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINU...
    stmt := 'CREATE OR REPLACE TABLE PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_SEND_TODAY AS
SELECT p.first_name, p.last_name, p.phone_number,
       p.audience,                                    
       p.offered_discount_percentage,
       p.premium_without_any_discounts, p.last_quoted_premium, p.new_premium_offered,
       p.vehicle_make, p.vehicle_model,
       FALSE AS has_been_messaged,                    
       CURRENT_DATE AS selected_date                  
FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_PICKED_TODAY p
WHERE p.arm = ''treated''
  AND p.phone9 NOT IN (SELECT phone9 FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_DO_NOT_MESSAGE_7D)
ORDER BY p.rank_on_day';
    EXECUTE IMMEDIATE :stmt;

    SELECT COUNT(*) INTO :n_send FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_SEND_TODAY;
    RETURN 'OK: model ' || mv || ', eligible ' || n_eligible || ', selectable ' || n_select
           || ', SEND_TODAY rows ' || n_send;
END;
$$;


/* -------------------------------------------------------------------------------------
   STEP 2 — the confirm procedure (Part 4)
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.MMM_CONFIRM_SENDS()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    stmt       VARCHAR;
    n_sent     NUMBER;
    n_unsent   NUMBER;
BEGIN
    -- part 4 statement 1: INSERT INTO PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAM...
    stmt := 'INSERT INTO PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_HISTORY
    (phone_number, phone9, audience, arm, was_sent, selected_date, rank_on_day, model_version, p_click,
     prior_discount_percentage, psm_rmd, offered_discount_percentage, premium_without_any_discounts,
     last_quoted_premium, new_premium_offered)
SELECT p.phone_number, p.phone9, p.audience, ''treated'', TRUE, p.selected_date, p.rank_on_day, p.model_version, p.p_click,
       p.prior_discount_percentage, p.psm_rmd, p.offered_discount_percentage, p.premium_without_any_discounts,
       p.last_quoted_premium, p.new_premium_offered
FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_PICKED_TODAY p
JOIN PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_SEND_TODAY s
  ON s.phone_number = p.phone_number AND s.has_been_messaged = TRUE
WHERE p.arm = ''treated''
  AND NOT EXISTS (SELECT 1 FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_HISTORY h
                  WHERE h.phone9 = p.phone9 AND h.selected_date = p.selected_date AND h.was_sent = TRUE)';
    EXECUTE IMMEDIATE :stmt;

    -- part 4 statement 2: DELETE FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAM...
    stmt := 'DELETE FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_SEND_TODAY
WHERE has_been_messaged = TRUE';
    EXECUTE IMMEDIATE :stmt;

    SELECT COUNT(*) INTO :n_sent FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_HISTORY
    WHERE selected_date = CURRENT_DATE AND was_sent = TRUE;
    SELECT COUNT(*) INTO :n_unsent FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_SEND_TODAY;
    RETURN 'OK: ' || n_sent || ' confirmed sends logged for today; ' || n_unsent
           || ' picked but not sent (left in SEND_TODAY)';
END;
$$;


/* -------------------------------------------------------------------------------------
   STEP 3 — test the procedures by hand BEFORE scheduling anything
   ------------------------------------------------------------------------------------- */
-- 3a. Safe test: scores the audience, picks NOBODY, writes nothing to the ledger.
--     Takes a few minutes. Expect: 'SCORE ONLY (nobody picked): model MMM_v3, eligible ..., selectable ...'
CALL PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.MMM_DAILY_PICK(100, 7, TRUE);

-- 3b. Look at what it built (pool size, held back by each rule, discount range):
SELECT audience, COUNT(*) AS eligible, COUNT_IF(phone_first) AS held_for_phone, COUNT_IF(in_cooldown) AS in_cooldown,
       COUNT_IF(selectable) AS selectable, ROUND(AVG(IFF(selectable, p_click, NULL)) * 100, 3) AS avg_p_click_pct,
       MIN(offered_discount_percentage) AS min_offer, MAX(offered_discount_percentage) AS max_offer
FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_AUDIENCE GROUP BY 1 ORDER BY 1;

-- 3c. ONLY when Make is ready to send: a real pick (logs picks to the ledger, fills SEND_TODAY).
-- CALL PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.MMM_DAILY_PICK(100, 7, FALSE);


/* -------------------------------------------------------------------------------------
   STEP 4 — create the two scheduled Tasks (they are created PAUSED)
   CRON format: minute hour day-of-month month day-of-week timezone
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE TASK PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.MMM_DAILY_PICK_TASK
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = 'USING CRON 30 10 * * MON-SAT Africa/Johannesburg'
    USER_TASK_TIMEOUT_MS = 3600000          -- give up after 1 hour
    COMMENT = 'MMM: score + pick today''s continuous-campaign audience into SEND_TODAY'
AS
    CALL PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.MMM_DAILY_PICK(100, 7, FALSE);

CREATE OR REPLACE TASK PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.MMM_CONFIRM_SENDS_TASK
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = 'USING CRON 0 18 * * MON-SAT Africa/Johannesburg'
    USER_TASK_TIMEOUT_MS = 1800000
    COMMENT = 'MMM: log confirmed sends from SEND_TODAY into the ledger'
AS
    CALL PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.MMM_CONFIRM_SENDS();

SHOW TASKS LIKE 'MMM_%' IN SCHEMA PINEAPPLE_DATABASE.MESSAGING_AUDIENCES;      -- both should show state = suspended


/* -------------------------------------------------------------------------------------
   STEP 5 — switch them on (ONLY when Make is reading SEND_TODAY and sending)
   ------------------------------------------------------------------------------------- */
-- ALTER TASK PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.MMM_DAILY_PICK_TASK RESUME;
-- ALTER TASK PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.MMM_CONFIRM_SENDS_TASK RESUME;
-- SHOW TASKS LIKE 'MMM_%' IN SCHEMA PINEAPPLE_DATABASE.MESSAGING_AUDIENCES;   -- state = started, next_scheduled_time filled in


/* -------------------------------------------------------------------------------------
   DAY-TO-DAY
   ------------------------------------------------------------------------------------- */
-- Did it run? (last 7 days — the most this function can look back: SUCCEEDED / FAILED,
-- the procedure's return message, any error)
SELECT name, state, scheduled_time, completed_time, return_value, error_message
FROM TABLE(PINEAPPLE_DATABASE.INFORMATION_SCHEMA.TASK_HISTORY(
        SCHEDULED_TIME_RANGE_START => DATEADD('day', -7, CURRENT_TIMESTAMP()),
        RESULT_LIMIT => 100))
WHERE name IN ('MMM_DAILY_PICK_TASK', 'MMM_CONFIRM_SENDS_TASK')
ORDER BY scheduled_time DESC;

-- Longer history (up to a year; can lag by up to ~45 minutes):
-- SELECT name, state, scheduled_time, completed_time, return_value, error_message
-- FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
-- WHERE name IN ('MMM_DAILY_PICK_TASK', 'MMM_CONFIRM_SENDS_TASK')
-- ORDER BY scheduled_time DESC LIMIT 100;

-- Run today's pick right now instead of waiting for 10:30 (e.g. after fixing a failure):
-- EXECUTE TASK PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.MMM_DAILY_PICK_TASK;

-- Pause (e.g. over December) / restart:
-- ALTER TASK PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.MMM_DAILY_PICK_TASK SUSPEND;      ALTER TASK PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.MMM_DAILY_PICK_TASK RESUME;

-- Change the daily volume to 150 (tasks must be suspended to be altered):
-- ALTER TASK PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.MMM_DAILY_PICK_TASK SUSPEND;
-- ALTER TASK PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.MMM_DAILY_PICK_TASK MODIFY AS CALL PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.MMM_DAILY_PICK(150, 7, FALSE);
-- ALTER TASK PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.MMM_DAILY_PICK_TASK RESUME;