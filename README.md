# Billing Delinquency Analytics

Billing delinquency analysis and a collections workbench on a synthetic P&C insurance book, built with **Oracle SQL**, **PL/SQL**, and **Oracle APEX**.

**🔗 Live app:** [Billing Delinquency Analytics](https://oracleapex.com/ords/r/antdia4309_ecpi/billing-delinquency-analytics/home)

![Dashboard](screenshots/Billing-Delinquency-Analytics.png)

---

## The business question

Missed installments turn into cancellations and write-offs. This project looks at three questions a billing or finance team would ask:

1. **Where does delinquency come from?** Which payment plans, autopay statuses, and risk tiers drive missed payments and bad debt?
2. **Where is it heading?** What's the trend, and what should we expect over the next quarter?
3. **What would autopay adoption be worth?** If more customers moved to autopay, how much would write-offs change?
4. **How do we work the delinquent accounts?** Which accounts need attention today, how risky is each one, and what's happened on it so far?
5. **What changed overnight?** Which accounts just became high risk, and which promises to pay were broken?

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

Analysis queries 1–6 are in [`sql/analysis_queries.sql`](sql/analysis_queries.sql). Phase 1 queries 7–8 are in [`sql/phase1_explorer_queries.sql`](sql/phase1_explorer_queries.sql). Phase 2 objects 9–12 are in [`sql/phase2_collections.sql`](sql/phase2_collections.sql). Phase 3 objects 13–16 are in [`sql/phase3_collections_pkg.sql`](sql/phase3_collections_pkg.sql). Phase 4 objects 17–20 are in [`sql/phase4_automations.sql`](sql/phase4_automations.sql). Phase 5 setup and checks 21–23 are in [`sql/phase5_security.sql`](sql/phase5_security.sql).

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
| 9 | `COLLECTION_ACTIONS` table | Identity key, foreign key, check constraints, `DEFAULT ON NULL` audit columns | Collections workbench |
| 10 | `COLLECTIONS_QUEUE_V` view | `KEEP (DENSE_RANK LAST)` for latest action, derived status and priority | Collections Queue |
| 11 | Workbench validations | PL/SQL expressions on grid rows and form items | Policy Collections, Log Contact |
| 12 | Seed activity (optional) | Repeatable sample data with `ORA_HASH` | — |
| 13 | Audit table and trigger | Row-level `AFTER` trigger, `:OLD`/`:NEW`, `INSERTING`/`UPDATING` | Audit History |
| 14 | `DUNNING_NOTICES` table | Unique key on policy + level to prevent duplicate notices | Dunning Notices |
| 15 | `COLLECTIONS_PKG` package | Spec vs. body, functions and procedures, cursor FOR loop, `%TYPE`, exception handling, private helper | Queue risk score, Generate Notices |
| 16 | Package tests | Anonymous PL/SQL blocks, `DBMS_OUTPUT`, simulated dates | — |
| 17 | Batch tables | Composite primary key, function-based unique index (one open alert per policy and type), run log | Batch Runs, Open Alerts |
| 18 | `COLLECTIONS_PKG` batch procedures | `MERGE`, `SQL%ROWCOUNT`, `ROW_NUMBER()`, `PRAGMA AUTONOMOUS_TRANSACTION`, error logging with rollback and re-raise | Nightly batch |
| 19 | APEX Automation | Scheduled daily at 2 AM (`FREQ=DAILY;BYHOUR=2`) | Nightly batch |
| 20 | Batch tests | Baseline snapshot, full run, run history, alert counts | — |
| 21 | Roles and authorization setup | APEX Access Control roles, authorization schemes (documented, configured in APEX) | All workbench pages |
| 22 | Security verification queries | `APEX_APPL_ACL_USER_ROLES`, `APEX_APPLICATION_PAGES`, `APEX_APPLICATION_PAGE_REGIONS`, `APEX_APPLICATION_LIST_ENTRIES` | — |
| 23 | Security tests | Menu, URL, and browser-console attack checks as a collector | — |

---

## The app

Built in Oracle APEX. The analytics pages are public; the collections workbench requires a login, and what you can do there depends on your role.

### Roles

| | Collector | Manager |
|---|---|---|
| Work the queue, log contacts, acknowledge alerts | ✅ | ✅ |
| Edit contact history | ✅ | ✅ |
| Delete contact history | ❌ | ✅ |
| View dunning notices | ✅ | ✅ |
| Generate dunning notices | ❌ | ✅ |
| Batch Runs and Run Batch Now | ❌ | ✅ |
| Audit History | ❌ | ✅ |

Roles are APEX Access Control roles checked by two authorization schemes, **Manager** and **Collector or Manager**, applied at six layers:

| Layer | Example | What a collector gets |
|---|---|---|
| Menu | Batch Runs entry | Hidden |
| Page | Batch Runs page | "Access denied" if reached by URL |
| Button | Generate Notices | Hidden |
| Process | Generate notices process | Doesn't run, even if triggered from the browser console |
| Region | Audit History | Not rendered |
| Grid operation | Delete Row | Not offered |

**Hiding isn't securing.** The Generate Notices button just submits the page with a request of `GENERATE`, and anyone can do that from the browser console with `apex.submit('GENERATE')`. The Manager check on the **process** is what actually blocks it; hiding the button is just good UX. Both attacks were tested as a collector:

![Collector view](screenshots/Collector-View.png)

![Access denied by URL](screenshots/Access-Denied.png)

![Collector grid without Delete Row](screenshots/Collector-Grid.png)

### Analytics (public)

### Analytics (public)

**Dashboard.** Delinquency by payment plan, the monthly missed-payment trend with a 3-month moving average, and a 3-month forecast. Click any bar to drill into those policies.

**Policy Explorer.** A faceted search over all 20,000 policies. Filter by payment plan, autopay, score tier, missed-payment status, policy status, and state, with live counts on every facet. Click a policy ID to open its detail page.

![Policy Explorer](screenshots/Policy-Explorer.png)

**Policy Detail.** The policy's summary plus its full installment history: due and paid dates, days late, status, write-offs, and the balance left unpaid at each due date.

![Policy Detail](screenshots/Policy-Detail.png)

**Autopay Projections.** A what-if tool. Pick a target autopay adoption rate (40–80%) and the projected write-offs recalculate live.

![Autopay Projections](screenshots/Autopay-Projections.png)

### Collections workbench (login required)

**Collections Queue.** An **Open Alerts** panel at the top lists what the nightly batch flagged (new high-risk accounts and broken promises), and collectors acknowledge each one inline without leaving the page. Below it, every policy with a missed payment, prioritized for a collector: overdue follow-ups first, then accounts never contacted, then in-progress, then closed. Within each group, accounts are ordered by a 0–100 **risk score** calculated in PL/SQL. Overdue rows are highlighted red, HIGH-risk bands dark red, and written-off balances amber.

![Collections Queue](screenshots/Collections-Queue.png)

![Open Alerts](screenshots/Open-Alerts.png)

**Policy Collections.** One policy's contact history in an editable Interactive Grid. Collectors can add, fix, or remove contact attempts inline, and the policy's queue status updates on save. An **Audit History** region shows every change to that history, with who made it, when, and the before/after values, captured by a database trigger.

![Policy Collections](screenshots/Policy-Collections.png)

![Audit History](screenshots/Audit-History.png)

**Log Contact.** A modal form for logging a call, email, letter, or text. Promise-to-pay fields only appear when the outcome is Promise to Pay, and validations catch missing or inconsistent promises before they reach the database.

![Log Contact](screenshots/Log-Contact.png)

**Dunning Notices.** Escalating notices (first, second, final) for written-off balances. The **Generate Notices** button calls a PL/SQL procedure that skips closed accounts, honors active promises to pay, waits at least 14 days between notices, and never sends the same notice twice. Each notice carries the policy's risk score at the time it was generated.

![Dunning Notices](screenshots/Dunning-Notices.png)

**Batch Runs.** A nightly APEX Automation runs the collections batch at 2 AM: it snapshots every policy's risk score, flags accounts that just moved into HIGH risk, flags broken promises to pay, and generates any dunning notices that are due. Every run is logged with its timing, counts, and any error, and a **Run Batch Now** button runs it on demand.

![Batch Runs](screenshots/Batch-Runs.png)

![Nightly Collections Batch automation](screenshots/Automation.png)

### Setup

The APEX app export is in [`apex/f188112.sql`](apex/f188112.sql). To run it in your own workspace:
1. Import it through **App Builder → Import**.
2. Load the two tables from the generator's CSVs.
3. Run [`sql/phase1_explorer_queries.sql`](sql/phase1_explorer_queries.sql) to create the `POLICY_EXPLORER_V` view.
4. Run [`sql/phase2_collections.sql`](sql/phase2_collections.sql) to create the collections table and queue view (the seed script at the end is optional).
5. Run [`sql/phase3_collections_pkg.sql`](sql/phase3_collections_pkg.sql) to create the audit trigger, notices table, and `COLLECTIONS_PKG` package.
6. Run [`sql/phase4_automations.sql`](sql/phase4_automations.sql) to create the batch tables and replace `COLLECTIONS_PKG` with the version that includes the batch procedures.
7. Imported automations start out disabled, so set **Nightly Collections Batch** to **Active** under **Shared Components → Automations**.
8. Role assignments aren't part of the export. Under **Shared Components → Application Access Control**, assign users the **Collector** and/or **Manager** roles. See [`sql/phase5_security.sql`](sql/phase5_security.sql) for the full setup and verification queries.

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
- **Rule-based risk score.** The risk score is a transparent weighted rule set, not a trained model. Every score can be explained factor by factor, but the weights are judgment calls, not fitted to outcomes.
- **Free workspace scheduling.** The free Oracle APEX workspace may limit or pause scheduled jobs on inactive workspaces, so the nightly run isn't guaranteed there. **Run Batch Now** runs the same procedure on demand.
- **Seeded collections activity.** Contact history in the workbench is sample data from the seed script, tagged `SEED_DATA`. It shows how the queue behaves, not real collection results.
- **Synthetic data.** The patterns are built in on purpose. The point of the project is the method, not the specific numbers.

---

## Release history

| Version | Phase | What changed |
|---|---|---|
| v1.0 | Analytics dashboard | Dashboard, trend and forecast, autopay scenario tool |
| v1.1 | Phase 1: Drill-down & exploration | Policy Explorer (faceted search), Policy Detail page, chart-to-explorer drill-down |
| v1.2 | Phase 2: Collections workbench | Collections Queue, Policy Collections (editable grid), Log Contact modal form, login-protected pages |
| v1.3 | Phase 3: PL/SQL business logic | Audit trigger, `COLLECTIONS_PKG` (risk score, dunning notices), Dunning Notices page, Audit History region |
| v1.4 | Phase 4: Automations | Nightly batch (risk snapshots, new-high-risk and broken-promise alerts, dunning), APEX Automation, Batch Runs page, Open Alerts with inline acknowledge |
| v1.5 | Phase 5: Roles and authorization | Collector and Manager roles, authorization schemes on pages, menu, buttons, processes, regions, and grid operations, Sign In link |

**Implementation notes from Phase 1:**
- `AUTOPAY_FLAG` loaded as an Oracle `BOOLEAN`, which the faceted search wizard can't use as a facet. The view converts it to `'Y'`/`'N'` text.
- In APEX 26, a facet value passed through a link needs a one-character filter prefix: `I` to include, `E` to exclude. The chart links set `P4_PAYMENT_PLAN = I&PAYMENT_PLAN.` with Clear Cache `4,RP`.

**Implementation notes from Phase 2:**
- **Validation in two layers.** APEX validations give users clear, inline messages; table check constraints stay underneath as a backstop so bad data can't get in through any other path.
- **Grid values are text.** In Interactive Grid validations, values arrive formatted (`$500.00`, `Nov 18, 2026`), so the expressions strip currency symbols and parse dates with the column's format mask.
- **Database-owned audit columns.** `CREATED_BY` and `CREATED_ON` are filled by `DEFAULT ON NULL` defaults, so the APEX columns are set to Query Only and left out of inserts.
- **Priority, not alphabet.** Sorting the queue by status text put closed accounts first, so the view adds a numeric `QUEUE_PRIORITY` that drives the default sort.
- **Writable pages need a login.** The workbench pages require authentication and their menu entry is hidden from public visitors, while the analytics pages stay public.

**Implementation notes from Phase 3:**
- **Business logic lives in the database.** Risk scoring and dunning rules are in a PL/SQL package, so any screen, report, or future API gets the same answer. APEX only calls the package's public interface.
- **Private functions can't be called from SQL.** The notice-text helper is private to the package body, so the procedure computes it in PL/SQL before the `INSERT` instead of calling it inside the SQL statement.
- **Watch out for NULL in `NOT (...)`.** The first version of the promise-to-pay check silently skipped every never-contacted account, because `NOT (NULL = 'X' AND ...)` evaluates to unknown and the row is dropped. `NVL` around the nullable columns fixed it, taking first notices from 266 to the expected ~720.
- **Double protection against duplicate notices.** The procedure enforces a 14-day gap and a three-notice cap, and a unique key on policy + notice level backs it up in the database.
- **Audit rows outlive the data.** The audit table has no foreign key to the actions table, so history survives when a contact attempt is deleted.
- **New columns on a saved Interactive Report start hidden.** After changing a report's source, new columns land on the Do Not Display list and have to be added back through Actions → Columns.

**Implementation notes from Phase 4:**
- **Safe to rerun.** Every batch step can run twice without doubling anything: the snapshot uses `MERGE`, alerts are deduplicated, and notices respect the 14-day gap. Same-day reruns report zeros.
- **Logs that survive a failure.** Run logging uses `PRAGMA AUTONOMOUS_TRANSACTION`, so if a step fails, the batch rolls back its work but the FAILED log row (with the error and backtrace) is still saved. The error is then re-raised so the scheduler also sees the failure.
- **Bug found in testing: acknowledged alerts came back.** The first version only skipped a new-high-risk alert if an *open* one existed. After a collector acknowledged it, a same-day rerun compared today's snapshot to yesterday's again and raised a duplicate. The fix also skips any alert of that type already raised today, whatever its status.
- **Baseline first, alerts second.** The very first snapshot has nothing to compare against, so it flags nothing instead of raising hundreds of "new" alerts on day one.
- **IDs aren't timestamps.** Identity values are cached in blocks of 20 per session, so run IDs jumped (1, 21, 22, then 2 for a later run). The Batch Runs page sorts by start time, not ID.
- **Refreshing a report resets its pagination.** Acknowledging an alert removes just that row on screen with JavaScript instead of refreshing the whole region, so a collector on page 2 of the alerts stays on page 2.

**Implementation notes from Phase 5:**
- **Server-side checks are the real security.** Every action a collector shouldn't take is blocked where it runs (the page, the process, the grid operation), not just hidden in the UI. The browser-console test proves the difference.
- **Verify settings with the APEX dictionary views.** The menu authorizations looked saved but weren't: they'd been set from Page Designer's Shared Components tab, where **Save** saves the current page, not the menu. Querying `APEX_APPLICATION_LIST_ENTRIES` showed blanks, and the fix was editing the entries through **Shared Components → Navigation Menu**. That query also revealed the Phase 2 "Must Not Be Public User" menu settings had never saved either; page-level authentication had been the actual protection the whole time.
- **Static IDs are stored lowercase.** APEX saved the role static IDs as `collector` and `manager`. The built-in "Is In Role or Group" scheme matches on role names, so it's unaffected, but hand-written PL/SQL checks have to match the lowercase IDs.
- **Checked once per page view.** Authorization schemes re-evaluate on every page load, so removing someone's role takes effect immediately instead of at their next login.
- **A sign-in path for public visitors.** Signing out lands on a public page as `nobody`, so a **Sign In** link in the navigation bar shows only to the public user.

---

## Possible next steps

- Self-service user management for managers (assign roles from inside the app)
- REST endpoints for the risk score and alerts (ORDS)
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
│   ├── phase1_explorer_queries.sql   # Phase 1: explorer view + detail queries
│   ├── phase2_collections.sql        # Phase 2: collections table, queue view, seed data
│   ├── phase3_collections_pkg.sql    # Phase 3: audit trigger, notices table, COLLECTIONS_PKG
│   ├── phase4_automations.sql        # Phase 4: batch tables, batch procedures, automation
│   └── phase5_security.sql           # Phase 5: roles and authorization setup, checks
└── screenshots/
```

---

*Built by Antonio Diaz.*
