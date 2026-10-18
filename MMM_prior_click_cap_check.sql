/* =====================================================================================
   MMM — CHECK THE 20% PREVIOUS-CLICKER CAP (Sun 18 Oct 2026)
   Run AFTER recreating the MMM_DAILY_PICK procedure from the new MMM_snowflake_tasks.sql.
   Nothing here picks or logs anyone.
   ===================================================================================== */
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE SCHEMA PINEAPPLE_DATABASE.MESSAGING_AUDIENCES;

-- 1. Re-score the audience with the new procedure (score only: picks nobody, logs nothing)
CALL MMM_DAILY_PICK(100, 7, TRUE);

-- 2. Preview what a pick of 200 would look like with both caps (same logic as the procedure)
WITH c1 AS (
    SELECT a.* FROM CONTINUOUS_PUSH_CAMPAIGN_AUDIENCE a
    WHERE a.selectable
    QUALIFY a.f_prior_click <> 'yes'
         OR ROW_NUMBER() OVER (PARTITION BY a.f_prior_click ORDER BY a.p_click DESC, a.phone9) <= FLOOR(2 * 100 * 0.2)
),
c2 AS (
    SELECT * FROM c1
    QUALIFY f_disc_msg_age = 'none'
         OR ROW_NUMBER() OVER (PARTITION BY (f_disc_msg_age = 'none') ORDER BY p_click DESC, phone9) <= FLOOR(2 * 100 * 0.3)
),
pick AS (
    SELECT * FROM c2 QUALIFY ROW_NUMBER() OVER (ORDER BY p_click DESC, phone9) <= 200
)
SELECT IFF(f_prior_click = 'yes', 'previous clicker', 'not clicked before')            AS clicked_before,
       IFF(f_disc_msg_age = 'none', 'no discount msg before', 'got a discount msg before') AS sent_before,
       COUNT(*) AS picks, COUNT_IF(arm = 'treated') AS treated,
       ROUND(AVG(p_click) * 100, 2) AS avg_p_click_pct,
       ROUND(AVG(offered_discount_percentage), 1) AS avg_offer
FROM pick
GROUP BY ROLLUP (clicked_before, sent_before)
ORDER BY clicked_before NULLS LAST, sent_before NULLS LAST;
-- Expect: previous clickers <= 40; 'got a discount msg before' <= 60 in total; grand total 200.
