/* =====================================================================================
   MMM — BUILD THE TRAINING FRAME (build only, no outputs)
   -------------------------------------------------------------------------------------
   Run by MMM_auto_retrain.py before every retrain (or by hand in a worksheet).
   Same logic as cpc_batch4_training_frame_v2.sql, plus:
     * the continuous process's own sends: every row of CONTINUOUS_PUSH_CAMPAIGN_HISTORY
       becomes a frame row, campaign = 'CPC_YYYYMMDD' (the pick date). Control picks get
       segment '<audience>_CTRL' (never trained on, kept for the holdout read).
     * first_all_src (first lead's all_sources) so continuous rows have the same
       first-channel feature the campaign tables used to supply.
   One row = one person x one campaign/pick-day. Features as of the send, labels after it.
   ===================================================================================== */

-- To run this by hand in a worksheet, first run:  USE ROLE ACCOUNTADMIN

SET aug_win_start = '2026-08-25';
SET aug_win_end   = '2026-09-14';
SET sep_win_start = '2026-09-16';
SET sep_win_end   = '2026-10-01';

CREATE OR REPLACE TABLE sandbox.pineapp_will.cpc_training_frame AS
WITH
sep_gt45_ranked AS (
    SELECT RIGHT(REGEXP_REPLACE(phone_number, '[^0-9]', ''), 9) AS phone9,
           prior_discount_percentage, new_cumulative_discount_percentage, premium_without_any_discounts,
           first_source, first_all_source, days_since_quote, days_since_lead, days_since_last_call,
           composite_score,
           ROW_NUMBER() OVER (ORDER BY composite_score DESC, days_since_quote ASC,
                                       days_since_lead ASC NULLS LAST, days_since_last_call ASC NULLS LAST,
                                       phone_number ASC) AS gt45_rank
    FROM sandbox.pineapp_will.phase2_q2s_all_scored_sep2026
    WHERE days_since_quote > 45
),
aud AS (
    SELECT 'AUG' AS campaign, 'Q2S_LT45' AS segment, RIGHT(REGEXP_REPLACE(PHONE_NUMBER, '[^0-9]', ''), 9) AS phone9,
           HAS_BEEN_MESSAGED AS marked_messaged, PRIOR_DISCOUNT_PERCENTAGE AS prior_disc,
           NEW_CUMULATIVE_DISCOUNT_PERCENTAGE AS offer_pct, PREMIUM_WITHOUT_ANY_DISCOUNTS AS pre_prem,
           FIRST_SOURCE AS first_source_tbl, FIRST_ALL_SOURCE AS first_all_source_tbl,
           DAYS_SINCE_QUOTE AS dsq_build, DAYS_SINCE_LEAD AS dsl_build, DAYS_SINCE_LAST_CALL AS dslc_build,
           COMPOSITE_SCORE::FLOAT AS composite_score, NULL::NUMBER AS gt45_rank,
           $aug_win_start::TIMESTAMP_NTZ AS win_start, $aug_win_end::TIMESTAMP_NTZ AS win_end,
           '2026-08-25 08:00:00'::TIMESTAMP_NTZ AS default_anchor
    FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_Q2S_LESSTHAN45D_AUG2026
    UNION ALL
    SELECT 'AUG', 'Q2S_GT45', RIGHT(REGEXP_REPLACE(PHONE_NUMBER, '[^0-9]', ''), 9),
           HAS_BEEN_MESSAGED, PRIOR_DISCOUNT_PERCENTAGE, NEW_CUMULATIVE_DISCOUNT_PERCENTAGE, PREMIUM_WITHOUT_ANY_DISCOUNTS,
           FIRST_SOURCE, FIRST_ALL_SOURCE, DAYS_SINCE_QUOTE, DAYS_SINCE_LEAD, DAYS_SINCE_LAST_CALL,
           COMPOSITE_SCORE::FLOAT, NULL::NUMBER,
           $aug_win_start::TIMESTAMP_NTZ, $aug_win_end::TIMESTAMP_NTZ, '2026-08-25 08:00:00'::TIMESTAMP_NTZ
    FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_Q2S_MORETHAN45D_AUG2026
    UNION ALL
    SELECT 'AUG', 'L2S', RIGHT(REGEXP_REPLACE(PHONE_NUMBER, '[^0-9]', ''), 9),
           HAS_BEEN_MESSAGED, PRIOR_DISCOUNT_PERCENTAGE, NEW_CUMULATIVE_DISCOUNT_PERCENTAGE, NULL::NUMBER,
           FIRST_SOURCE, FIRST_ALL_SOURCE, NULL::NUMBER, DAYS_SINCE_LEAD, DAYS_SINCE_LAST_CALL,
           COMPOSITE_SCORE::FLOAT, NULL::NUMBER,
           $aug_win_start::TIMESTAMP_NTZ, $aug_win_end::TIMESTAMP_NTZ, '2026-08-25 08:00:00'::TIMESTAMP_NTZ
    FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_L2S_AUG2026
    UNION ALL
    SELECT 'SEP', 'Q2S_LT45', RIGHT(REGEXP_REPLACE(PHONE_NUMBER, '[^0-9]', ''), 9),
           HAS_BEEN_MESSAGED, PRIOR_DISCOUNT_PERCENTAGE, NEW_CUMULATIVE_DISCOUNT_PERCENTAGE, PREMIUM_WITHOUT_ANY_DISCOUNTS,
           FIRST_SOURCE, FIRST_ALL_SOURCE, DAYS_SINCE_QUOTE, DAYS_SINCE_LEAD, DAYS_SINCE_LAST_CALL,
           COMPOSITE_SCORE::FLOAT, NULL::NUMBER,
           $sep_win_start::TIMESTAMP_NTZ, $sep_win_end::TIMESTAMP_NTZ, '2026-09-16 08:00:00'::TIMESTAMP_NTZ
    FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_Q2S_LESSTHAN45D_SEP2026
    UNION ALL
    SELECT 'SEP', 'Q2S_GT45', t.phone9, t.HAS_BEEN_MESSAGED, t.PRIOR_DISCOUNT_PERCENTAGE, t.NEW_CUMULATIVE_DISCOUNT_PERCENTAGE,
           t.PREMIUM_WITHOUT_ANY_DISCOUNTS, t.FIRST_SOURCE, t.FIRST_ALL_SOURCE, t.DAYS_SINCE_QUOTE, t.DAYS_SINCE_LEAD,
           t.DAYS_SINCE_LAST_CALL, t.COMPOSITE_SCORE::FLOAT, r.gt45_rank,
           $sep_win_start::TIMESTAMP_NTZ, $sep_win_end::TIMESTAMP_NTZ, '2026-09-16 08:00:00'::TIMESTAMP_NTZ
    FROM (SELECT x.*, RIGHT(REGEXP_REPLACE(x.PHONE_NUMBER, '[^0-9]', ''), 9) AS phone9
          FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_Q2S_MORETHAN45D_SEP2026 x) t
    LEFT JOIN sep_gt45_ranked r ON r.phone9 = t.phone9
    UNION ALL
    SELECT 'SEP', 'L2S', RIGHT(REGEXP_REPLACE(PHONE_NUMBER, '[^0-9]', ''), 9),
           HAS_BEEN_MESSAGED, PRIOR_DISCOUNT_PERCENTAGE, NEW_CUMULATIVE_DISCOUNT_PERCENTAGE, NULL::NUMBER,
           FIRST_SOURCE, FIRST_ALL_SOURCE, NULL::NUMBER, DAYS_SINCE_LEAD, DAYS_SINCE_LAST_CALL,
           COMPOSITE_SCORE::FLOAT, NULL::NUMBER,
           $sep_win_start::TIMESTAMP_NTZ, $sep_win_end::TIMESTAMP_NTZ, '2026-09-16 08:00:00'::TIMESTAMP_NTZ
    FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_L2S_SEP2026
    UNION ALL
    -- natural control: eligible + scored under the same Sept rules, cut only by LIMIT 15000
    SELECT 'SEP', 'Q2S_GT45_CTRL', phone9, FALSE, prior_discount_percentage, new_cumulative_discount_percentage,
           premium_without_any_discounts, first_source, first_all_source, days_since_quote, days_since_lead,
           days_since_last_call, composite_score::FLOAT, gt45_rank,
           $sep_win_start::TIMESTAMP_NTZ, $sep_win_end::TIMESTAMP_NTZ, '2026-09-16 08:00:00'::TIMESTAMP_NTZ
    FROM sep_gt45_ranked
    WHERE gt45_rank BETWEEN 15001 AND 30000
    UNION ALL
    -- the continuous process: one row per person per pick day (treated and control)
    SELECT 'CPC_' || TO_CHAR(h.selected_date, 'YYYYMMDD'),
           IFF(h.arm = 'control', h.audience || '_CTRL', h.audience),
           h.phone9, IFF(h.arm = 'control', FALSE, TRUE),
           h.prior_discount_percentage, h.offered_discount_percentage, h.premium_without_any_discounts,
           NULL::VARCHAR, NULL::VARCHAR, NULL::NUMBER, NULL::NUMBER, NULL::NUMBER,
           h.p_click::FLOAT, NULL::NUMBER,
           h.selected_date::TIMESTAMP_NTZ, DATEADD('day', 3, h.selected_date)::TIMESTAMP_NTZ,
           DATEADD('hour', 9, h.selected_date::TIMESTAMP_NTZ)
    FROM (SELECT * FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_HISTORY
          QUALIFY ROW_NUMBER() OVER (PARTITION BY phone9, selected_date ORDER BY was_sent DESC NULLS LAST) = 1) h
),
ph AS (SELECT DISTINCT phone9 FROM aud),
tmsg AS (      -- ONE ROW PER MESSAGE: status events collapsed onto their SID
    SELECT RIGHT(REGEXP_REPLACE(SPLIT_PART(w.NUMBER::STRING, '.', 1), '[^0-9]', ''), 9) AS phone9,
           w.MESSAGE_SID                                                                  AS sid,
           MAX(w.TEMPLATE_ID)                                                             AS TEMPLATE_ID,
           MAX(w.AUDIENCE_ID)                                                             AS AUDIENCE_ID,
           MAX(IFF(w.MESSAGE_BODY ILIKE '%discount%' OR CONTAINS(w.MESSAGE_BODY, '%'), 1, 0)) AS is_discount_body,
           MIN(m.DATE_SENT)                                                               AS sent_ts,
           MAX(IFF(m.STATUS IN ('delivered', 'read'), 1, 0))                             AS was_delivered,
           MAX(IFF(m.STATUS = 'read', 1, 0))                                              AS was_read,
           MAX(IFF(m.STATUS IN ('undelivered', 'failed'), 1, 0))                          AS was_failed,
           MAX(IFF(dt.template_id IS NOT NULL, 1, 0))                                     AS is_disc_template
    FROM TWILIO_DATABASE.DATA.WHATSAPPTEMPLATEDATA w
    JOIN TWILIO_DATABASE.DATA.MESSAGES m ON m.SID = w.MESSAGE_SID
    JOIN ph ON ph.phone9 = RIGHT(REGEXP_REPLACE(SPLIT_PART(w.NUMBER::STRING, '.', 1), '[^0-9]', ''), 9)
    LEFT JOIN PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CPC_DISCOUNT_TEMPLATES dt ON dt.template_id = TRIM(w.TEMPLATE_ID)
    WHERE m.STATUS <> 'received' AND m.DATE_SENT >= '2026-02-01'
    GROUP BY 1, 2
),
inbound AS (
    SELECT RIGHT(REGEXP_REPLACE(COALESCE(m."from", ''), '[^0-9]', ''), 9) AS phone9, m.DATE_SENT AS reply_ts
    FROM TWILIO_DATABASE.DATA.MESSAGES m
    JOIN ph ON ph.phone9 = RIGHT(REGEXP_REPLACE(COALESCE(m."from", ''), '[^0-9]', ''), 9)
    WHERE m.STATUS = 'received' AND m.DATE_SENT >= '2026-02-01'
),
send AS (
    SELECT a.campaign, a.segment, a.phone9, t.sent_ts AS send_ts,
           CASE WHEN t.was_read = 1 THEN 'read' WHEN t.was_delivered = 1 THEN 'delivered'
                WHEN t.was_failed = 1 THEN 'failed' ELSE 'sent' END AS send_status,
           t.TEMPLATE_ID AS template_id, t.AUDIENCE_ID AS audience_id, t.is_discount_body
    FROM aud a
    JOIN tmsg t ON t.phone9 = a.phone9 AND t.sent_ts >= a.win_start AND t.sent_ts < a.win_end
    QUALIFY ROW_NUMBER() OVER (PARTITION BY a.campaign, a.segment, a.phone9
                               ORDER BY t.is_discount_body DESC, t.sent_ts) = 1
),
base AS (
    SELECT a.*, s.send_ts, s.send_status, s.template_id, s.audience_id, s.is_discount_body,
           IFF(ENDSWITH(a.segment, '_CTRL'), a.default_anchor, COALESCE(s.send_ts, a.default_anchor)) AS anchor_ts
    FROM aud a
    LEFT JOIN send s ON s.campaign = a.campaign AND s.segment = a.segment AND s.phone9 = a.phone9
),
leads AS (
    SELECT RIGHT(REGEXP_REPLACE(COALESCE(l.contact_number, ''), '[^0-9]', ''), 9) AS phone9,
           TRY_TO_TIMESTAMP_NTZ(l.usercreatedat)                                  AS lead_ts,
           LOWER(COALESCE(l.final_attributed_source_fixed, 'unknown'))            AS attr_source,
           CASE WHEN l.final_attributed_source_fixed = 'lead_provider' THEN l.sub_sources
                ELSE l.all_sources END                                            AS channel_key,
           LOWER(COALESCE(l.all_sources, 'unknown'))                              AS all_src,
           COALESCE(l.lead_source_reference_UCID, '')                             AS ucid
    FROM pineapple_database.pineapple_mongo.lead_channel_labels l
    JOIN ph ON ph.phone9 = RIGHT(REGEXP_REPLACE(COALESCE(l.contact_number, ''), '[^0-9]', ''), 9)
    WHERE TRY_TO_TIMESTAMP_NTZ(l.usercreatedat) IS NOT NULL
),
lead_agg AS (
    SELECT b.campaign, b.segment, b.phone9,
           COUNT_IF(l.lead_ts < b.anchor_ts)                                                           AS n_leads_before,
           COUNT_IF(l.lead_ts < b.anchor_ts AND l.lead_ts >= DATEADD('day', -30, b.anchor_ts))         AS n_leads_30d_before,
           COUNT_IF(l.lead_ts < b.anchor_ts AND l.ucid ILIKE 'PINCARDISC%')                            AS n_prior_campaign_clicks,
           MIN(IFF(l.lead_ts < b.anchor_ts, l.lead_ts, NULL))                                          AS first_lead_ts,
           MAX(IFF(l.lead_ts < b.anchor_ts, l.lead_ts, NULL))                                          AS last_lead_ts,
           MIN(IFF(l.ucid ILIKE 'PINCARDISC%' AND l.lead_ts >= b.anchor_ts
                   AND l.lead_ts < DATEADD('day', 14, b.anchor_ts), l.lead_ts, NULL))                  AS first_click_ts,
           MIN(IFF(l.ucid NOT ILIKE 'PINCARDISC%' AND l.lead_ts >= b.anchor_ts
                   AND l.lead_ts < DATEADD('day', 14, b.anchor_ts), l.lead_ts, NULL))                  AS first_other_lead_ts
    FROM base b
    LEFT JOIN leads l ON l.phone9 = b.phone9
    GROUP BY b.campaign, b.segment, b.phone9
),
latest_lead AS (
    SELECT b.campaign, b.segment, b.phone9, l.channel_key AS last_channel_key,
           l.attr_source AS last_attr_source, l.all_src AS last_all_src
    FROM base b
    JOIN leads l ON l.phone9 = b.phone9 AND l.lead_ts < b.anchor_ts
    QUALIFY ROW_NUMBER() OVER (PARTITION BY b.campaign, b.segment, b.phone9 ORDER BY l.lead_ts DESC) = 1
),
first_lead AS (
    SELECT b.campaign, b.segment, b.phone9, l.channel_key AS first_channel_key, l.attr_source AS first_attr_source,
           l.all_src AS first_all_src
    FROM base b
    JOIN leads l ON l.phone9 = b.phone9 AND l.lead_ts < b.anchor_ts
    QUALIFY ROW_NUMBER() OVER (PARTITION BY b.campaign, b.segment, b.phone9 ORDER BY l.lead_ts ASC) = 1
),
calls AS (
    SELECT RIGHT(REGEXP_REPLACE(COALESCE(i.subject, ''), '[^0-9]', ''), 9) AS phone9,
           DATEADD('hour', -2, i.start_time)                              AS call_ts,
           COALESCE(o.name, '')                                           AS outcome
    FROM connex_db.data.cxm_interactions i
    LEFT JOIN connex_db.data.cxm_outcomes o ON o.id = i.outcome_id
    JOIN ph ON ph.phone9 = RIGHT(REGEXP_REPLACE(COALESCE(i.subject, ''), '[^0-9]', ''), 9)
    WHERE i.direction = 'outbound' AND i.start_time IS NOT NULL
      AND i.campaign_id IN ('568752c7-ffbc-4edb-9665-0a6792c1f7e7', '6c7bc2df-17f5-4c06-8b4f-c7274bfde6ca',
                            '90ae6979-ab80-48fc-b7e1-29e2ef46c6d6')
),
call_agg AS (
    SELECT b.campaign, b.segment, b.phone9,
           COUNT_IF(c.call_ts < b.anchor_ts)                                                         AS n_calls_before,
           COUNT_IF(c.call_ts < b.anchor_ts AND c.call_ts >= DATEADD('day', -30, b.anchor_ts))       AS n_calls_30d_before,
           MAX(IFF(c.call_ts < b.anchor_ts, c.call_ts, NULL))                                        AS last_call_ts,
           MAX(IFF(c.call_ts < b.anchor_ts AND c.outcome ILIKE 'Callback Scheduled%', c.call_ts, NULL)) AS last_callback_ts,
           COUNT_IF(c.call_ts >= b.anchor_ts AND c.call_ts < DATEADD('day', 7, b.anchor_ts))         AS n_calls_7d_after,
           MIN(IFF(c.call_ts >= b.anchor_ts AND c.outcome ILIKE 'Sale Made%', c.call_ts, NULL))      AS first_salemade_call_after
    FROM base b
    LEFT JOIN calls c ON c.phone9 = b.phone9
    GROUP BY b.campaign, b.segment, b.phone9
),
last_outcome AS (
    SELECT b.campaign, b.segment, b.phone9, c.outcome AS last_outcome
    FROM base b
    JOIN calls c ON c.phone9 = b.phone9 AND c.call_ts < b.anchor_ts
    QUALIFY ROW_NUMBER() OVER (PARTITION BY b.campaign, b.segment, b.phone9 ORDER BY c.call_ts DESC) = 1
),
gq AS (
    SELECT RIGHT(REGEXP_REPLACE(COALESCE(g.FORMATTED_PHONE, ''), '[^0-9]', ''), 9)                      AS phone9,
           COALESCE(g.QUOTED_AT, g.QUOTE_JOURNEY_START_AT, CAST(g.QUOTE_DATE AS TIMESTAMP))::TIMESTAMP_NTZ  AS q_ts,
           g.SOLD_AT::TIMESTAMP_NTZ                                                                       AS sold_ts
    FROM ACTUARIAL_DATABASE.SANDBOX.GOLDEN_QUOTE_JOURNEY_DATASET g
    JOIN ph ON ph.phone9 = RIGHT(REGEXP_REPLACE(COALESCE(g.FORMATTED_PHONE, ''), '[^0-9]', ''), 9)
),
quote_agg AS (
    SELECT b.campaign, b.segment, b.phone9,
           COUNT_IF(q.q_ts < b.anchor_ts)                                                             AS n_quotes_before,
           MAX(IFF(q.q_ts < b.anchor_ts, q.q_ts, NULL))                                               AS last_quote_ts,
           MIN(IFF(q.q_ts >= b.anchor_ts AND q.q_ts < DATEADD('day', 14, b.anchor_ts), q.q_ts, NULL))   AS first_quote_after_ts,
           MIN(IFF(q.sold_ts >= b.anchor_ts AND q.sold_ts < DATEADD('day', 14, b.anchor_ts), q.sold_ts, NULL)) AS golden_sale_ts
    FROM base b
    LEFT JOIN gq q ON q.phone9 = b.phone9
    GROUP BY b.campaign, b.segment, b.phone9
),
mtr AS (
    SELECT RIGHT(REGEXP_REPLACE(SPLIT_PART(p.vehicle_ownerperson_cellphonenumber::STRING, '.', 1), '[^0-9]', ''), 9) AS phone9,
           COALESCE(TRY_TO_TIMESTAMP_NTZ(p.createdat::VARCHAR),
                    TO_TIMESTAMP_NTZ(TRY_TO_NUMBER(p.createdat::VARCHAR, 38, 0), 9))                                   AS sale_ts
    FROM pineapple_database.pineapple_mongo.mtr_policy_requests_full p
    JOIN ph ON ph.phone9 = RIGHT(REGEXP_REPLACE(SPLIT_PART(p.vehicle_ownerperson_cellphonenumber::STRING, '.', 1), '[^0-9]', ''), 9)
    WHERE p.type IN ('createPolicy', 'additionalVehiclePolicy') AND TRY_CAST(p.response_status AS INTEGER) = 200
),
mtr_agg AS (
    SELECT b.campaign, b.segment, b.phone9,
           MIN(IFF(s.sale_ts >= b.anchor_ts AND s.sale_ts < DATEADD('day', 14, b.anchor_ts), s.sale_ts, NULL)) AS mtr_sale_ts,
           MAX(IFF(s.sale_ts < b.anchor_ts, 1, 0))                                                           AS sold_before_anchor
    FROM base b
    LEFT JOIN mtr s ON s.phone9 = b.phone9
    GROUP BY b.campaign, b.segment, b.phone9
),
wa_agg AS (
    SELECT b.campaign, b.segment, b.phone9,
           COUNT_IF(t.sent_ts < DATEADD('day', -1, b.anchor_ts) AND t.sent_ts >= DATEADD('day', -180, b.anchor_ts))   AS n_wa_sent_180d,
           COUNT_IF(t.sent_ts < DATEADD('day', -1, b.anchor_ts) AND t.sent_ts >= DATEADD('day', -180, b.anchor_ts)
                    AND t.was_delivered = 1)                                                                      AS n_wa_delivered_180d,
           COUNT_IF(t.sent_ts < DATEADD('day', -1, b.anchor_ts) AND t.sent_ts >= DATEADD('day', -180, b.anchor_ts)
                    AND t.was_read = 1)                                                                           AS n_wa_read_180d,
           COUNT_IF(t.sent_ts < DATEADD('day', -1, b.anchor_ts) AND t.sent_ts >= DATEADD('day', -180, b.anchor_ts)
                    AND t.was_failed = 1)                                                                         AS n_wa_failed_180d,
           COUNT_IF(t.sent_ts >= b.anchor_ts AND t.sent_ts < DATEADD('day', 7, b.anchor_ts))                       AS n_wa_sent_7d_after,
           -- repeat-messaging history: delivered DISCOUNT messages before this send (same 181-day reach as scoring)
           MAX(IFF(t.is_disc_template = 1 AND t.was_delivered = 1 AND t.sent_ts < DATEADD('hour', -1, b.anchor_ts)
                   AND t.sent_ts >= DATEADD('day', -181, b.anchor_ts), t.sent_ts, NULL))                          AS last_disc_ts,
           COUNT_IF(t.is_disc_template = 1 AND t.was_delivered = 1 AND t.sent_ts < DATEADD('hour', -1, b.anchor_ts)
                    AND t.sent_ts >= DATEADD('day', -28, b.anchor_ts))                                             AS n_disc_delivered_28d
    FROM base b
    LEFT JOIN tmsg t ON t.phone9 = b.phone9
    GROUP BY b.campaign, b.segment, b.phone9
),
reply_agg AS (
    SELECT b.campaign, b.segment, b.phone9,
           COUNT_IF(r.reply_ts < DATEADD('day', -1, b.anchor_ts) AND r.reply_ts >= DATEADD('day', -180, b.anchor_ts)) AS n_replies_180d,
           MIN(IFF(r.reply_ts >= b.anchor_ts AND r.reply_ts < DATEADD('day', 7, b.anchor_ts), r.reply_ts, NULL))       AS first_reply_ts
    FROM base b
    LEFT JOIN inbound r ON r.phone9 = b.phone9
    GROUP BY b.campaign, b.segment, b.phone9
),
prev_msg AS (
    SELECT phone9,
           MAX(IFF(src = 'MAR', 1, 0)) AS msg_mar, MAX(IFF(src = 'JUL', 1, 0)) AS msg_jul, MAX(IFF(src = 'AUG', 1, 0)) AS msg_aug
    FROM (
        SELECT 'MAR' AS src, RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING, '[^0-9]', ''), 9) AS phone9, HAS_BEEN_MESSAGED AS hbm FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_20_PERCENT_DAY_1
        UNION ALL SELECT 'MAR', RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING, '[^0-9]', ''), 9), HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_20_DAY_1
        UNION ALL SELECT 'MAR', RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING, '[^0-9]', ''), 9), HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_10_DAY_1
        UNION ALL SELECT 'JUL', RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING, '[^0-9]', ''), 9), HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_20_Q2S_LESS_45DAYS_JUL2026
        UNION ALL SELECT 'JUL', RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING, '[^0-9]', ''), 9), HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_20_Q2S_OVER_45DAYS_JUL2026
        UNION ALL SELECT 'JUL', RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING, '[^0-9]', ''), 9), HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_15_L2S_JUL2026
        UNION ALL SELECT 'AUG', RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING, '[^0-9]', ''), 9), HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_Q2S_LESSTHAN45D_AUG2026
        UNION ALL SELECT 'AUG', RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING, '[^0-9]', ''), 9), HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_Q2S_MORETHAN45D_AUG2026
        UNION ALL SELECT 'AUG', RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING, '[^0-9]', ''), 9), HAS_BEEN_MESSAGED FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_L2S_AUG2026
    ) u
    WHERE hbm = TRUE
    GROUP BY phone9
),
prev_camp AS (   -- every earlier discount campaign a person was messaged in, with its offer %
    SELECT 'MAR' AS pcamp, '2026-03-25'::TIMESTAMP_NTZ AS p_start, '2026-04-15'::TIMESTAMP_NTZ AS p_end,
           RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING, '[^0-9]', ''), 9) AS phone9, 20::FLOAT AS p_offer
    FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_20_PERCENT_DAY_1 WHERE HAS_BEEN_MESSAGED = TRUE
    UNION ALL
    SELECT 'MAR', '2026-03-25'::TIMESTAMP_NTZ, '2026-04-15'::TIMESTAMP_NTZ,
           RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING, '[^0-9]', ''), 9), 20::FLOAT
    FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_20_DAY_1 WHERE HAS_BEEN_MESSAGED = TRUE
    UNION ALL
    SELECT 'MAR', '2026-03-25'::TIMESTAMP_NTZ, '2026-04-15'::TIMESTAMP_NTZ,
           RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING, '[^0-9]', ''), 9), 10::FLOAT
    FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_10_DAY_1 WHERE HAS_BEEN_MESSAGED = TRUE
    UNION ALL
    SELECT 'JUL', '2026-07-23'::TIMESTAMP_NTZ, '2026-08-24'::TIMESTAMP_NTZ,
           RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING, '[^0-9]', ''), 9), 17::FLOAT
    FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_20_Q2S_LESS_45DAYS_JUL2026 WHERE HAS_BEEN_MESSAGED = TRUE
    UNION ALL
    SELECT 'JUL', '2026-07-23'::TIMESTAMP_NTZ, '2026-08-24'::TIMESTAMP_NTZ,
           RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING, '[^0-9]', ''), 9), 17::FLOAT
    FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_20_Q2S_OVER_45DAYS_JUL2026 WHERE HAS_BEEN_MESSAGED = TRUE
    UNION ALL
    SELECT 'JUL', '2026-07-23'::TIMESTAMP_NTZ, '2026-08-24'::TIMESTAMP_NTZ,
           RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING, '[^0-9]', ''), 9), 15::FLOAT
    FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_15_L2S_JUL2026 WHERE HAS_BEEN_MESSAGED = TRUE
    UNION ALL
    SELECT 'AUG', '2026-08-25'::TIMESTAMP_NTZ, '2026-09-15'::TIMESTAMP_NTZ,
           RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING, '[^0-9]', ''), 9), NEW_CUMULATIVE_DISCOUNT_PERCENTAGE::FLOAT
    FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_Q2S_LESSTHAN45D_AUG2026 WHERE HAS_BEEN_MESSAGED = TRUE
    UNION ALL
    SELECT 'AUG', '2026-08-25'::TIMESTAMP_NTZ, '2026-09-15'::TIMESTAMP_NTZ,
           RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING, '[^0-9]', ''), 9), NEW_CUMULATIVE_DISCOUNT_PERCENTAGE::FLOAT
    FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_Q2S_MORETHAN45D_AUG2026 WHERE HAS_BEEN_MESSAGED = TRUE
    UNION ALL
    SELECT 'AUG', '2026-08-25'::TIMESTAMP_NTZ, '2026-09-15'::TIMESTAMP_NTZ,
           RIGHT(REGEXP_REPLACE(PHONE_NUMBER::STRING, '[^0-9]', ''), 9), NEW_CUMULATIVE_DISCOUNT_PERCENTAGE::FLOAT
    FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.PUSH_CAMPAIGN_L2S_AUG2026 WHERE HAS_BEEN_MESSAGED = TRUE
),
prev_pick AS (   -- the MOST RECENT earlier discount campaign, finished before this send
    SELECT b.campaign, b.segment, b.phone9, pc.pcamp, pc.p_offer, pc.p_start, pc.p_end,
           COUNT(*) OVER (PARTITION BY b.campaign, b.segment, b.phone9) AS n_prev_campaign_rows
    FROM base b
    JOIN prev_camp pc ON pc.phone9 = b.phone9 AND pc.p_end <= b.anchor_ts
    QUALIFY ROW_NUMBER() OVER (PARTITION BY b.campaign, b.segment, b.phone9
                               ORDER BY pc.p_start DESC, pc.p_offer DESC) = 1
),
prev_status AS ( -- was that previous discount message delivered / read? (first template msg in its window)
    SELECT pp.campaign, pp.segment, pp.phone9, t.sent_ts AS prev_sent_ts,
           t.was_delivered AS prev_delivered, t.was_read AS prev_read, t.was_failed AS prev_failed
    FROM prev_pick pp
    JOIN tmsg t ON t.phone9 = pp.phone9 AND t.sent_ts >= pp.p_start AND t.sent_ts < pp.p_end
    QUALIFY ROW_NUMBER() OVER (PARTITION BY pp.campaign, pp.segment, pp.phone9 ORDER BY t.sent_ts) = 1
)
SELECT
    b.campaign, b.segment, b.phone9, b.marked_messaged,
    IFF(b.send_ts IS NOT NULL, 1, 0)                                             AS send_found,
    b.send_ts, b.send_status, b.template_id, b.audience_id, b.is_discount_body, b.anchor_ts,
    HOUR(DATEADD('hour', 2, b.anchor_ts))                                        AS send_hour_sast,
    DAYNAME(DATEADD('hour', 2, b.anchor_ts))                                     AS send_dow,
    DATEDIFF('day', b.anchor_ts, SYSDATE())                                      AS days_observed,
    -- audience-table features (as of build)
    b.prior_disc, b.offer_pct, b.pre_prem, b.first_source_tbl, b.first_all_source_tbl,
    b.dsq_build, b.dsl_build, b.dslc_build, b.composite_score, b.gt45_rank,
    -- recomputed as of the send
    la.n_leads_before, la.n_leads_30d_before, la.n_prior_campaign_clicks,
    IFF(la.n_leads_before >= 2, 'reengaged', 'first_time')                       AS lead_type,
    DATEDIFF('day', la.first_lead_ts, b.anchor_ts)                               AS days_since_first_lead,
    DATEDIFF('day', la.last_lead_ts,  b.anchor_ts)                               AS days_since_last_lead,
    ll.last_channel_key, ll.last_attr_source, ll.last_all_src,
    fl.first_channel_key, fl.first_attr_source, fl.first_all_src,
    cf.channel_factor                                                            AS dialer_channel_factor,
    qa.n_quotes_before,
    DATEDIFF('day', qa.last_quote_ts, b.anchor_ts)                               AS days_since_last_quote,
    ca.n_calls_before, ca.n_calls_30d_before,
    DATEDIFF('hour', ca.last_call_ts, b.anchor_ts) / 24.0                        AS days_since_last_call,
    DATEDIFF('hour', ca.last_callback_ts, b.anchor_ts) / 24.0                    AS days_since_last_callback,
    lo.last_outcome,
    CASE WHEN lo.last_outcome IS NULL                                  THEN 'no_prior_call'
         WHEN lo.last_outcome ILIKE 'Do Not Call%'                     THEN 'dnc'
         WHEN lo.last_outcome ILIKE 'Sale Made%'                       THEN 'sale_made'
         WHEN lo.last_outcome ILIKE '%Existing%Policyholder%'          THEN 'existing_policyholder'
         WHEN lo.last_outcome ILIKE '%No Insurable Risk%'              THEN 'no_insurable_risk'
         WHEN lo.last_outcome ILIKE 'Callback Scheduled%'              THEN 'callback_scheduled'
         WHEN lo.last_outcome ILIKE '%Disconnect%'                     THEN 'auto_disconnected'
         WHEN lo.last_outcome IN ('Not Reached', 'No Answer Autodial', 'Auto Engaged', 'Voicemail') THEN 'never_connected'
         ELSE 'other_connected' END                                              AS last_outcome_group,
    wa.n_wa_sent_180d, wa.n_wa_read_180d, ra.n_replies_180d,
    COALESCE(pm.msg_mar, 0) AS msg_mar, COALESCE(pm.msg_jul, 0) AS msg_jul,
    IFF(b.campaign = 'SEP', COALESCE(pm.msg_aug, 0), 0)                          AS msg_aug_before_sep,
    ma.sold_before_anchor,
    -- previous discount message (new)
    pp.pcamp                                                                     AS prev_disc_campaign,
    pp.p_offer                                                                   AS prev_disc_offer_pct,
    pp.n_prev_campaign_rows,
    CASE WHEN pp.pcamp IS NULL          THEN 'none'
         WHEN ps.prev_sent_ts IS NULL   THEN 'no_twilio_record'
         WHEN ps.prev_read = 1          THEN 'read'
         WHEN ps.prev_delivered = 1     THEN 'delivered_not_read'
         WHEN ps.prev_failed = 1        THEN 'failed'
         ELSE 'sent_no_status' END                                               AS prev_disc_msg_status,
    DATEDIFF('day', ps.prev_sent_ts, b.anchor_ts)                                AS days_since_prev_disc_msg,
    wa.n_wa_delivered_180d, wa.n_wa_failed_180d,
    DATEDIFF('day', wa.last_disc_ts, b.anchor_ts)                                AS days_since_last_disc_msg,
    wa.n_disc_delivered_28d,
    -- what happened after the anchor
    ca.n_calls_7d_after, wa.n_wa_sent_7d_after,
    la.first_click_ts, la.first_other_lead_ts, ra.first_reply_ts, qa.first_quote_after_ts,
    ma.mtr_sale_ts, qa.golden_sale_ts, ca.first_salemade_call_after,
    LEAST(COALESCE(ma.mtr_sale_ts, qa.golden_sale_ts), COALESCE(qa.golden_sale_ts, ma.mtr_sale_ts)) AS sale_ts,
    IFF(la.first_click_ts < DATEADD('day', 7, b.anchor_ts), 1, 0)                AS click_7d,
    IFF(ra.first_reply_ts IS NOT NULL, 1, 0)                                     AS reply_7d,
    IFF(qa.first_quote_after_ts IS NOT NULL, 1, 0)                               AS quote_14d,
    IFF(COALESCE(ma.mtr_sale_ts, qa.golden_sale_ts) IS NOT NULL, 1, 0)           AS sale_14d,
    IFF(COALESCE(ma.mtr_sale_ts, qa.golden_sale_ts) IS NOT NULL
        AND la.first_click_ts <= LEAST(COALESCE(ma.mtr_sale_ts, qa.golden_sale_ts),
                                       COALESCE(qa.golden_sale_ts, ma.mtr_sale_ts)), 1, 0) AS msg_path_sale,
    IFF(COALESCE(ma.mtr_sale_ts, qa.golden_sale_ts) IS NOT NULL
        AND (la.first_click_ts IS NULL
             OR la.first_click_ts > LEAST(COALESCE(ma.mtr_sale_ts, qa.golden_sale_ts),
                                          COALESCE(qa.golden_sale_ts, ma.mtr_sale_ts)))
        AND ABS(DATEDIFF('hour', ca.first_salemade_call_after,
                LEAST(COALESCE(ma.mtr_sale_ts, qa.golden_sale_ts), COALESCE(qa.golden_sale_ts, ma.mtr_sale_ts)))) <= 24,
        1, 0)                                                                    AS phone_path_sale
FROM base b
LEFT JOIN lead_agg    la ON la.campaign = b.campaign AND la.segment = b.segment AND la.phone9 = b.phone9
LEFT JOIN latest_lead ll ON ll.campaign = b.campaign AND ll.segment = b.segment AND ll.phone9 = b.phone9
LEFT JOIN first_lead  fl ON fl.campaign = b.campaign AND fl.segment = b.segment AND fl.phone9 = b.phone9
LEFT JOIN call_agg    ca ON ca.campaign = b.campaign AND ca.segment = b.segment AND ca.phone9 = b.phone9
LEFT JOIN last_outcome lo ON lo.campaign = b.campaign AND lo.segment = b.segment AND lo.phone9 = b.phone9
LEFT JOIN quote_agg   qa ON qa.campaign = b.campaign AND qa.segment = b.segment AND qa.phone9 = b.phone9
LEFT JOIN mtr_agg     ma ON ma.campaign = b.campaign AND ma.segment = b.segment AND ma.phone9 = b.phone9
LEFT JOIN wa_agg      wa ON wa.campaign = b.campaign AND wa.segment = b.segment AND wa.phone9 = b.phone9
LEFT JOIN reply_agg   ra ON ra.campaign = b.campaign AND ra.segment = b.segment AND ra.phone9 = b.phone9
LEFT JOIN prev_msg    pm ON pm.phone9 = b.phone9
LEFT JOIN prev_pick   pp ON pp.campaign = b.campaign AND pp.segment = b.segment AND pp.phone9 = b.phone9
LEFT JOIN prev_status ps ON ps.campaign = b.campaign AND ps.segment = b.segment AND ps.phone9 = b.phone9
LEFT JOIN sandbox.william_connect_rates.postcutoff_channel_factor cf ON cf.channel_key = ll.last_channel_key;