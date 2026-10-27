/* ==========================================================================
   Billing Delinquency Forecast & Scenario Model - Part 1
   Oracle SQL for APEX (SQL Workshop > SQL Commands)
   Run one query at a time: highlight it, then click Run.
   ========================================================================== */


/* --------------------------------------------------------------------------
   0. SANITY CHECKS - run these first
   DUE_DATE, PAID_DATE, EFFECTIVE_DATE, CANCEL_DATE should show as DATE.
   If they show VARCHAR2, the date format wasn't applied on load.
   -------------------------------------------------------------------------- */
SELECT table_name, column_name, data_type
FROM   user_tab_columns
WHERE  table_name IN ('POLICIES', 'INSTALLMENTS')
ORDER  BY table_name, column_id;

SELECT 'POLICIES' AS table_name, COUNT(*) AS row_count FROM policies
UNION ALL
SELECT 'INSTALLMENTS', COUNT(*) FROM installments;
-- Expect 20,000 and 131,425


/* --------------------------------------------------------------------------
   1. DELINQUENCY BY PAYMENT PLAN (CTE)
   Swap payment_plan for autopay_flag or score_tier to slice other ways.
   -------------------------------------------------------------------------- */
WITH inst AS (
    SELECT i.installment_status,
           i.written_off_amt,
           p.payment_plan,
           p.autopay_flag,
           p.score_tier
    FROM   installments i
    JOIN   policies p ON p.policy_id = i.policy_id
)
SELECT payment_plan,
       COUNT(*)                                                                    AS installments,
       ROUND(100 * AVG(CASE WHEN installment_status = 'PAID_LATE' THEN 1 ELSE 0 END), 2) AS late_pct,
       ROUND(100 * AVG(CASE WHEN installment_status = 'MISSED'    THEN 1 ELSE 0 END), 2) AS missed_pct,
       SUM(written_off_amt)                                                        AS written_off
FROM   inst
GROUP  BY payment_plan
ORDER  BY missed_pct DESC;


/* --------------------------------------------------------------------------
   2. RISK SEGMENTS (CTE + window functions)
   Plan x autopay x tier, ranked by missed rate, with each segment's share
   of total write-offs and a running cumulative share.
   Question it answers: "Which small set of segments drives most bad debt?"
   -------------------------------------------------------------------------- */
WITH seg AS (
    SELECT p.payment_plan,
           p.autopay_flag,
           p.score_tier,
           COUNT(*)                                                         AS n,
           AVG(CASE WHEN i.installment_status = 'MISSED' THEN 1 ELSE 0 END) AS missed_rate,
           SUM(i.written_off_amt)                                           AS written_off
    FROM   installments i
    JOIN   policies p ON p.policy_id = i.policy_id
    GROUP  BY p.payment_plan, p.autopay_flag, p.score_tier
)
SELECT payment_plan,
       autopay_flag,
       score_tier,
       n                                                          AS installments,
       ROUND(100 * missed_rate, 2)                                AS missed_pct,
       written_off,
       RANK() OVER (ORDER BY missed_rate DESC)                    AS risk_rank,
       ROUND(100 * RATIO_TO_REPORT(written_off) OVER (), 1)       AS pct_of_writeoff,
       ROUND(100 * SUM(written_off) OVER (ORDER BY written_off DESC
                                          ROWS UNBOUNDED PRECEDING)
                 / SUM(written_off) OVER (), 1)                   AS cumulative_pct
FROM   seg
WHERE  n >= 200            -- skip tiny segments
ORDER  BY risk_rank;


/* --------------------------------------------------------------------------
   3. MONTHLY TREND (CTE + LAG + moving average)
   Feeds the forecast. Look for the Dec/Jan bump and the slow upward drift.
   Early and late months have fewer installments, so they're noisier.
   -------------------------------------------------------------------------- */
WITH monthly AS (
    SELECT TRUNC(due_date, 'MM')                                          AS due_month,
           COUNT(*)                                                       AS n,
           AVG(CASE WHEN installment_status = 'MISSED' THEN 1 ELSE 0 END) AS missed_rate,
           SUM(written_off_amt)                                           AS written_off
    FROM   installments
    GROUP  BY TRUNC(due_date, 'MM')
)
SELECT due_month,
       n                                                                AS installments,
       ROUND(100 * missed_rate, 3)                                      AS missed_pct,
       ROUND(100 * AVG(missed_rate) OVER (ORDER BY due_month
                     ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 3)      AS missed_pct_3mo_avg,
       ROUND(100 * (missed_rate - LAG(missed_rate, 12) OVER (ORDER BY due_month)), 3)
                                                                        AS yoy_change_pts,
       written_off
FROM   monthly
ORDER  BY due_month;


/* --------------------------------------------------------------------------
   4. A/B TEST - REMINDER EMAIL
   Treatment vs control missed rate, relative lift, and a two-proportion
   z-score. |z| > 1.96 means the difference is significant at 95%.
   -------------------------------------------------------------------------- */
WITH ab AS (
    SELECT p.reminder_group,
           COUNT(*)                                                         AS n,
           SUM(CASE WHEN i.installment_status = 'MISSED' THEN 1 ELSE 0 END) AS missed
    FROM   installments i
    JOIN   policies p ON p.policy_id = i.policy_id
    GROUP  BY p.reminder_group
),
r AS (
    SELECT reminder_group, n, missed, missed / n AS rate FROM ab
)
SELECT t.n                                             AS treatment_n,
       c.n                                             AS control_n,
       ROUND(100 * t.rate, 3)                          AS treatment_missed_pct,
       ROUND(100 * c.rate, 3)                          AS control_missed_pct,
       ROUND(100 * (t.rate - c.rate) / c.rate, 1)      AS relative_lift_pct,
       ROUND((t.rate - c.rate) /
             SQRT( ((t.missed + c.missed) / (t.n + c.n))
                 * (1 - (t.missed + c.missed) / (t.n + c.n))
                 * (1 / t.n + 1 / c.n) ), 2)           AS z_score
FROM   r t
CROSS  JOIN r c
WHERE  t.reminder_group = 'TREATMENT'
AND    c.reminder_group = 'CONTROL';


/* --------------------------------------------------------------------------
   5. SIMPLE FORECAST - linear trend with Oracle regression functions
   Fits missed rate vs month number, then projects the next 3 months.
   Only uses months with 500+ installments to keep the noise down.
   R-squared will be modest: this is a first-pass model. Adding a
   seasonal factor for Dec/Jan is a good Part 2 upgrade.
   -------------------------------------------------------------------------- */
WITH monthly AS (
    SELECT TRUNC(due_date, 'MM')                                          AS due_month,
           MONTHS_BETWEEN(TRUNC(due_date, 'MM'), DATE '2024-01-01')       AS m_idx,
           COUNT(*)                                                       AS n,
           AVG(CASE WHEN installment_status = 'MISSED' THEN 1 ELSE 0 END) AS missed_rate
    FROM   installments
    GROUP  BY TRUNC(due_date, 'MM'),
              MONTHS_BETWEEN(TRUNC(due_date, 'MM'), DATE '2024-01-01')
),
fit AS (
    SELECT REGR_SLOPE(missed_rate, m_idx)     AS slope,
           REGR_INTERCEPT(missed_rate, m_idx) AS intercept,
           REGR_R2(missed_rate, m_idx)        AS r2,
           MAX(m_idx)                         AS last_idx,
           MAX(due_month)                     AS last_month
    FROM   monthly
    WHERE  n >= 500
)
SELECT ADD_MONTHS(last_month, LEVEL)                               AS forecast_month,
       ROUND(100 * (intercept + slope * (last_idx + LEVEL)), 3)    AS forecast_missed_pct,
       ROUND(100 * slope * 12, 3)                                  AS trend_pts_per_year,
       ROUND(r2, 3)                                                AS r_squared
FROM   fit
CONNECT BY LEVEL <= 3;


/* --------------------------------------------------------------------------
   6. SCENARIO - WHAT IF AUTOPAY ADOPTION GOES UP?
   Enter a target autopay % when prompted (try 40, 60, 80).
   Uses installment-plan policies only (pay-in-full has one payment).
   Later this becomes the slider on your APEX scenario page.

   Interview point: this assumes customers who switch to autopay behave
   like current autopay customers. In reality autopay users skew toward
   better tiers, so the true effect is probably smaller. Calling out that
   bias is exactly what a strong analyst does.
   -------------------------------------------------------------------------- */
WITH base AS (
    SELECT p.autopay_flag,
           COUNT(*)               AS n,
           SUM(i.written_off_amt) AS wo
    FROM   installments i
    JOIN   policies p ON p.policy_id = i.policy_id
    WHERE  p.payment_plan <> 'PIF'
    GROUP  BY p.autopay_flag
),
r AS (
    SELECT MAX(CASE WHEN autopay_flag = 'Y' THEN wo / n END)       AS wo_per_inst_y,
           MAX(CASE WHEN autopay_flag = 'N' THEN wo / n END)       AS wo_per_inst_n,
           SUM(n)                                                  AS total_n,
           SUM(CASE WHEN autopay_flag = 'Y' THEN n END) / SUM(n)   AS current_share,
           SUM(wo)                                                 AS current_wo
    FROM   base
)
SELECT ROUND(100 * current_share, 1)                                         AS current_autopay_pct,
       :target_pct                                                           AS target_autopay_pct,
       ROUND(current_wo, 2)                                                  AS current_writeoff,
       ROUND(total_n * ((:target_pct / 100) * wo_per_inst_y
                    + (1 - :target_pct / 100) * wo_per_inst_n), 2)           AS projected_writeoff,
       ROUND(current_wo - total_n * ((:target_pct / 100) * wo_per_inst_y
                    + (1 - :target_pct / 100) * wo_per_inst_n), 2)           AS projected_savings
FROM   r;
