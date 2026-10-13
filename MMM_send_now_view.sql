-- SEND_NOW: what Make should read. Same rows as SEND_TODAY, minus anyone who has BOUGHT since the
-- 10:30 pick (policy created, golden sale, or a Sale Made call outcome), re-checked every time Make
-- queries it (a view recomputes on every read). Only today's list, only rows not yet sent.
-- Every row comes from SEND_TODAY (one row per phone), so the view can never return duplicates.
CREATE OR REPLACE VIEW PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_SEND_NOW AS
WITH bought AS (
    SELECT RIGHT(REGEXP_REPLACE(SPLIT_PART(vehicle_ownerperson_cellphonenumber::STRING, '.', 1), '[^0-9]', ''), 9) AS phone9
    FROM pineapple_database.pineapple_mongo.mtr_policy_requests_full
    WHERE type IN ('createPolicy', 'additionalVehiclePolicy') AND TRY_CAST(response_status AS INTEGER) = 200
    UNION
    SELECT RIGHT(REGEXP_REPLACE(COALESCE(FORMATTED_PHONE, ''), '[^0-9]', ''), 9)
    FROM ACTUARIAL_DATABASE.SANDBOX.GOLDEN_QUOTE_JOURNEY_DATASET
    WHERE SOLD_AT IS NOT NULL
    UNION
    SELECT RIGHT(REGEXP_REPLACE(COALESCE(i.subject, ''), '[^0-9]', ''), 9)
    FROM connex_db.data.cxm_interactions i
    JOIN connex_db.data.cxm_outcomes o ON o.id = i.outcome_id
    WHERE o.name ILIKE '%sale made%'
)
SELECT t.*
FROM PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_SEND_TODAY t
WHERE t.selected_date = CURRENT_DATE
  AND t.has_been_messaged = FALSE
  AND RIGHT(REGEXP_REPLACE(t.phone_number, '[^0-9]', ''), 9) NOT IN (SELECT phone9 FROM bought WHERE phone9 IS NOT NULL);
