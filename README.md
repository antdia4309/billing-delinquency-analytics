# Billing Delinquency Analytics

Billing delinquency and autopay scenario analysis on a synthetic P&C insurance book, built with **Oracle SQL** and an interactive **Oracle APEX** dashboard.

**🔗 Live app:** [Billing Delinquency Analytics](https://oracleapex.com/ords/r/antdia4309_ecpi/billing-delinquency-analytics/home)

![Dashboard](screenshots/Billing-Delinquency-Analytics.png)

---

## The business question

Missed installments turn into cancellations and write-offs. This project looks at three questions a billing or finance team would ask:

1. **Where does delinquency come from?** Which payment plans, autopay statuses, and risk tiers drive missed payments and bad debt?
2. **Where is it heading?** What's the trend, and what should we expect over the next quarter?
3. **What would autopay adoption be worth?** If more customers moved to autopay, how much would write-offs change?

---

## The data

All data is **synthetic**. No real policyholder data is used.

| Table | Rows | Grain |
|---|---|---|
| `POLICIES` | 20,000 | One row per policy: payment plan, autopay flag, score tier, A/B group |
| `INSTALLMENTS` | 131,425 | One row per billed installment: due date, status (paid / late / missed), written-off amount |

The data was generated with [`data/generate_billing_data.py`](data/generate_billing_data.py), which builds in realistic patterns:

- Three payment plans: **Monthly**, **Quarterly**, and **Paid in Full (PIF)**
- Autopay users skew toward better score tiers
- A Dec/Jan seasonal bump in missed payments
- A slow upward drift in delinquency over time
- A reminder-email A/B test, split by even vs. odd policy number
- A missed installment cancels the policy after a 10-day grace period
- About **35% of missed installments are recovered** through collections ($0 written off); the rest are written off in full

**Reproducible:** the generator uses a fixed random seed, so running

```bash
pip install pandas numpy
python generate_billing_data.py --policies 20000
```

recreates the exact dataset used in the app. The CSVs were then loaded into Oracle APEX through **SQL Workshop → Data Workshop**.

---

## The SQL

Analysis queries 1–6 are in [`sql/analysis_queries.sql`](sql/analysis_queries.sql). Phase 1 queries 7–8 are in [`sql/phase1_explorer_queries.sql`](sql/phase1_explorer_queries.sql).

| # | Query | Techniques | Used in app |
|---|---|---|---|
| 1 | Delinquency by payment plan | CTE, conditional aggregation | Bar chart |
| 2 | Risk segments (plan × autopay × tier) | `RANK()`, `RATIO_TO_REPORT`, running totals | — |
| 3 | Monthly trend | `LAG` (year-over-year), 3-month moving average | Line chart |
| 4 | Reminder email A/B test | Relative lift, two-proportion z-score | — |
| 5 | 3-month forecast | `REGR_SLOPE`, `REGR_INTERCEPT`, `REGR_R2`, `CONNECT BY LEVEL` | Forecast table |
| 6 | Autopay scenario | Bind variable from page input, weighted projection | Autopay Projections page |
| 7 | `POLICY_EXPLORER_V` view | `LEFT JOIN` rollup, conditional aggregation, BOOLEAN → text conversion | Policy Explorer |
| 8 | Policy detail | Bind variable from link, derived balance column | Policy Detail |

---

## The app

Built in Oracle APEX with four pages:

**Dashboard.** Delinquency by payment plan, the monthly missed-payment trend with a 3-month moving average, and a 3-month forecast. Click any bar to drill into those policies.

**Policy Explorer.** A faceted search over all 20,000 policies. Filter by payment plan, autopay, score tier, missed-payment status, policy status, and state, with live counts on every facet. Click a policy ID to open its detail page.

![Policy Explorer](screenshots/Policy-Explorer.png)

**Policy Detail.** The policy's summary plus its full installment history: due and paid dates, days late, status, write-offs, and the balance left unpaid at each due date.

![Policy Detail](screenshots/Policy-Detail.png)

**Autopay Projections.** A what-if tool. Pick a target autopay adoption rate (40–80%) and the projected write-offs recalculate live.

![Autopay Projections](screenshots/Autopay-Projections.png)

The APEX app export is in [`apex/f188112.sql`](apex/f188112.sql). Import it through **App Builder → Import** in any APEX workspace, load the two tables, then run [`sql/phase1_explorer_queries.sql`](sql/phase1_explorer_queries.sql) to create the `POLICY_EXPLORER_V` view.

---

## Key findings

**Payment plan matters most.** Monthly plans have the highest late rate (~6.4%) and missed rate (~1.0%). Quarterly plans come next (~4.9% late), and Paid in Full is lowest (~2.3% late, ~0.5% missed).

**Delinquency is seasonal.** Missed payments spike in December/January both years, peaking around 1.5% in Jan 2026, then fall back.

**The trend is drifting up.** The regression trend adds about **0.19 points per year** to the missed rate, with a forecast of ~1.15–1.18% for Oct–Dec 2026.

**Every miss ends in cancellation.** 1,224 policies have a missed payment, and the same 1,224 are cancelled for nonpayment. Of those, 1,113 (91%) are on monthly plans.

**Autopay adoption has real value.** Current autopay adoption is **49.7%**, with **$111K** in write-offs. The scenario model projects:

| Target autopay | Projected write-offs | Change |
|---|---|---|
| 40% | $124,698 | −$13,539 |
| 60% | $96,674 | +$14,484 |
| 70% | $82,663 | +$28,496 |
| 80% | $68,651 | +$42,507 |

---

## Caveats

- **Autopay selection bias.** The scenario assumes customers who switch to autopay behave like current autopay users. Current users skew toward better score tiers, so real savings would likely be **smaller** than projected. A fairer estimate would compare autopay vs. non-autopay *within* each score tier.
- **Moderate forecast fit.** The linear trend has an R² of **0.38**, so it explains only part of the month-to-month variation. Seasonality accounts for much of the rest. Treat the forecast as directional.
- **Early-month ramp-up.** Jan–Mar 2024 are excluded from the trend chart. The book was still ramping up and only first installments were due, which made those months look artificially low.
- **Write-offs are per installment.** Only the missed installment is written off. Once a policy cancels, its remaining installments are never billed, so unearned premium isn't counted.
- **Synthetic data.** The patterns are built in on purpose. The point of the project is the method, not the specific numbers.

---

## Release history

| Version | Phase | What changed |
|---|---|---|
| v1.0 | Analytics dashboard | Dashboard, trend and forecast, autopay scenario tool |
| v1.1 | Phase 1: Drill-down & exploration | Policy Explorer (faceted search), Policy Detail page, chart-to-explorer drill-down |

**Implementation notes from Phase 1:**
- `AUTOPAY_FLAG` loaded as an Oracle `BOOLEAN`, which the faceted search wizard can't use as a facet. The view converts it to `'Y'`/`'N'` text.
- In APEX 26, a facet value passed through a link needs a one-character filter prefix: `I` to include, `E` to exclude. The chart links set `P4_PAYMENT_PLAN = I&PAYMENT_PLAN.` with Clear Cache `4,RP`.

---

## Possible next steps

- **Phase 2:** collections workbench with an editable work queue (Interactive Grid, forms, validations)
- **Phase 3:** PL/SQL package for risk scoring and dunning notices, plus an audit trigger
- Add a seasonal factor to the forecast
- Add a grace-period scenario (e.g., 10 → 20 days)
- Re-run the autopay scenario within score tiers to correct for selection bias

---

## Repo structure

```
├── README.md
├── apex/
│   └── f188112.sql                   # Oracle APEX app export
├── data/
│   └── generate_billing_data.py      # Synthetic data generator
├── sql/
│   ├── analysis_queries.sql          # Analysis queries 1–6
│   └── phase1_explorer_queries.sql   # Phase 1: explorer view + detail queries
└── screenshots/
```

---

*Built by Antonio Diaz.*
