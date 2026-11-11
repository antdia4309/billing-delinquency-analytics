-- =====================================================================
-- Billing Delinquency Analytics - Phase 1: Drill-down & exploration
-- Oracle SQL (run in APEX SQL Workshop -> SQL Commands)
-- =====================================================================

-- ---------------------------------------------------------------------
-- Query 7: POLICY_EXPLORER_V
-- One row per policy with installment-level delinquency rolled up.
-- Source for the Policy Explorer faceted search page (page 4).
-- Notes:
--   * AUTOPAY_FLAG is stored as BOOLEAN after the Data Workshop load,
--     so it's converted to 'Y'/'N' text so it can be used as a facet.
--   * Late payments are stored as 'PAID_LATE' (not 'LATE').
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW policy_explorer_v AS
SELECT p.policy_id,
       p.state_code,
       p.payment_plan,
       CASE WHEN p.autopay_flag THEN 'Y' ELSE 'N' END                        AS autopay_flag,
       p.score_tier,
       p.policy_status,
       p.tenure_years,
       p.annual_premium,
       COUNT(i.installment_id)                                               AS installments,
       SUM(CASE WHEN i.installment_status = 'PAID_LATE' THEN 1 ELSE 0 END)   AS late_count,
       SUM(CASE WHEN i.installment_status = 'MISSED'    THEN 1 ELSE 0 END)   AS missed_count,
       NVL(SUM(i.written_off_amt), 0)                                        AS written_off,
       CASE WHEN SUM(CASE WHEN i.installment_status = 'MISSED' THEN 1 ELSE 0 END) > 0
            THEN 'Y' ELSE 'N' END                                            AS has_missed
FROM   policies p
       LEFT JOIN installments i ON i.policy_id = p.policy_id
GROUP  BY p.policy_id, p.state_code, p.payment_plan, p.autopay_flag,
          p.score_tier, p.policy_status, p.tenure_years, p.annual_premium;


-- ---------------------------------------------------------------------
-- Query 8a: Policy Detail - summary (page 3, Policy Summary region)
-- :P3_POLICY_ID is set by the POLICY_ID link on the Policy Explorer.
-- ---------------------------------------------------------------------
SELECT policy_id,
       state_code,
       payment_plan,
       CASE WHEN autopay_flag THEN 'Y' ELSE 'N' END AS autopay_flag,
       score_tier,
       tenure_years,
       term_months,
       annual_premium,
       policy_status,
       effective_date,
       cancel_date
FROM   policies
WHERE  policy_id = :P3_POLICY_ID;


-- ---------------------------------------------------------------------
-- Query 8b: Policy Detail - installment history (page 3)
-- BALANCE_REMAINING = amount unpaid at the due date. Missed installments
-- recovered through collections still show a balance here, since
-- AMOUNT_PAID stays 0; WRITTEN_OFF_AMT is $0 for those.
-- ---------------------------------------------------------------------
SELECT installment_num,
       due_date,
       amount_due,
       paid_date,
       amount_paid,
       days_late,
       installment_status,
       written_off_amt,
       amount_due - NVL(amount_paid, 0) AS balance_remaining
FROM   installments
WHERE  policy_id = :P3_POLICY_ID
ORDER  BY installment_num;


-- ---------------------------------------------------------------------
-- Chart drill-down (page 1 -> page 4)
-- Each bar chart series links to page 4 with:
--   Set Items:   P4_PAYMENT_PLAN = I&PAYMENT_PLAN.
--   Clear Cache: 4,RP
-- In APEX 26 a facet value passed in a URL needs a one-character
-- prefix: I = include, E = exclude.
-- ---------------------------------------------------------------------
