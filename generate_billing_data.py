"""
Synthetic P&C billing dataset generator for the
Billing Delinquency Forecast & Scenario Model project.

Outputs two CSVs ready for Oracle APEX Data Workshop:
  POLICIES.csv      - one row per policy
  INSTALLMENTS.csv  - one row per billed installment

All data is synthetic. Patterns are built in on purpose so the
analysis has something real to find:
  - Monthly plans are late/miss more often than pay-in-full
  - Autopay sharply reduces late and missed payments
  - Lower insurance-score tiers are riskier
  - Longer tenure lowers risk
  - Reminder email (A/B treatment group) modestly reduces misses
  - December/January run worse (holiday seasonality)
  - Delinquency drifts slightly worse over time (economic trend)

Usage:
  python generate_billing_data.py                 # 50,000 policies
  python generate_billing_data.py --policies 20000
"""
import argparse
from datetime import date, timedelta

import numpy as np
import pandas as pd

SEED = 42
START = date(2024, 1, 1)          # earliest effective date
END = date(2026, 6, 30)           # latest effective date
AS_OF = date(2026, 9, 30)         # nothing billed after this date
GRACE_DAYS = 10                   # days after due date before cancellation

STATES = ["VA", "MD", "TX", "IL", "OH", "PA", "GA", "NC"]
TIERS = ["A", "B", "C", "D"]      # insurance-score tier, A = best
PLANS = {"PIF": 1, "QUARTERLY": 4, "MONTHLY": 12}  # installments per year


def add_months(d, months):
    m = d.month - 1 + months
    y = d.year + m // 12
    m = m % 12 + 1
    day = min(d.day, 28)          # keep it simple, avoid month-end issues
    return date(y, m, day)


def build_policies(n, rng):
    span = (END - START).days
    eff = [START + timedelta(days=int(x)) for x in rng.integers(0, span, n)]
    plan = rng.choice(list(PLANS), n, p=[0.30, 0.15, 0.55])
    tier = rng.choice(TIERS, n, p=[0.30, 0.35, 0.22, 0.13])
    tenure = np.clip(rng.exponential(3.0, n).round().astype(int), 0, 25)
    # autopay is more common on monthly plans and better tiers
    autopay_p = np.where(plan == "MONTHLY", 0.50, 0.25)
    autopay_p = autopay_p + np.select([tier == "A", tier == "D"], [0.10, -0.15], 0)
    autopay = np.where(rng.random(n) < autopay_p, "Y", "N")
    base = rng.lognormal(mean=7.15, sigma=0.35, size=n)       # ~ $1,300 avg
    tier_mult = pd.Series(tier).map({"A": 0.85, "B": 1.0, "C": 1.15, "D": 1.35}).values
    premium = (base * tier_mult).round(2)

    return pd.DataFrame({
        "POLICY_ID": [f"PA{100000 + i}" for i in range(n)],
        "STATE_CODE": rng.choice(STATES, n),
        "EFFECTIVE_DATE": eff,
        "TERM_MONTHS": 12,
        "ANNUAL_PREMIUM": premium,
        "PAYMENT_PLAN": plan,
        "AUTOPAY_FLAG": autopay,
        "SCORE_TIER": tier,
        "TENURE_YEARS": tenure,
        # 50/50 A/B split on the last digit of the policy number,
        # same idea as the Elephant portal test
        "REMINDER_GROUP": ["TREATMENT" if i % 2 == 0 else "CONTROL" for i in range(n)],
    })


def miss_and_late_prob(p, due):
    """Probability an installment is missed entirely, and paid late."""
    miss = 0.010
    late = 0.060
    plan_mult = {"PIF": 0.4, "QUARTERLY": 0.8, "MONTHLY": 1.4}[p.PAYMENT_PLAN]
    tier_mult = {"A": 0.5, "B": 0.9, "C": 1.5, "D": 2.6}[p.SCORE_TIER]
    autopay_mult = 0.30 if p.AUTOPAY_FLAG == "Y" else 1.0
    tenure_mult = max(0.55, 1.0 - 0.04 * p.TENURE_YEARS)
    reminder_mult = 0.85 if p.REMINDER_GROUP == "TREATMENT" else 1.0
    season_mult = 1.25 if due.month in (12, 1) else 1.0
    months_in = (due.year - START.year) * 12 + due.month - START.month
    trend_mult = 1.0 + 0.008 * months_in               # slow upward drift
    common = plan_mult * tier_mult * autopay_mult * tenure_mult * season_mult * trend_mult
    return min(miss * common * reminder_mult, 0.5), min(late * common, 0.6)


def build_installments(policies, rng):
    rows = []
    status_out, cancel_out = [], []
    inst_id = 1
    for p in policies.itertuples(index=False):
        n_inst = PLANS[p.PAYMENT_PLAN]
        amt = round(p.ANNUAL_PREMIUM / n_inst, 2)
        step = 12 // n_inst
        status, cancel_date = "ACTIVE", None
        for k in range(n_inst):
            due = add_months(p.EFFECTIVE_DATE, k * step)
            if due > AS_OF:
                break
            miss_p, late_p = miss_and_late_prob(p, due)
            r = rng.random()
            if r < miss_p:
                # missed: policy cancels for nonpayment after grace period
                cancel_date = due + timedelta(days=GRACE_DAYS)
                recovered = rng.random() < 0.35            # some collections recovery
                rows.append([inst_id, p.POLICY_ID, k + 1, due, amt, None, 0.0,
                             None, "MISSED", 0.0 if recovered else amt])
                status = "CANCELLED_NONPAY"
                inst_id += 1
                break
            elif r < miss_p + late_p:
                days_late = int(rng.integers(1, GRACE_DAYS + 1))
                rows.append([inst_id, p.POLICY_ID, k + 1, due, amt,
                             due + timedelta(days=days_late), amt, days_late, "PAID_LATE", 0.0])
            else:
                days_early = int(rng.integers(0, 6))
                rows.append([inst_id, p.POLICY_ID, k + 1, due, amt,
                             due - timedelta(days=days_early), amt, 0, "PAID_ON_TIME", 0.0])
            inst_id += 1
        if status == "ACTIVE" and add_months(p.EFFECTIVE_DATE, 12) <= AS_OF:
            status = "EXPIRED"
        status_out.append(status)
        cancel_out.append(cancel_date)

    inst = pd.DataFrame(rows, columns=[
        "INSTALLMENT_ID", "POLICY_ID", "INSTALLMENT_NUM", "DUE_DATE", "AMOUNT_DUE",
        "PAID_DATE", "AMOUNT_PAID", "DAYS_LATE", "INSTALLMENT_STATUS", "WRITTEN_OFF_AMT"])
    inst["DAYS_LATE"] = inst["DAYS_LATE"].astype("Int64")   # whole days, blank when missed
    return inst, status_out, cancel_out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--policies", type=int, default=50000)
    args = ap.parse_args()
    rng = np.random.default_rng(SEED)

    policies = build_policies(args.policies, rng)
    inst, status, cancel = build_installments(policies, rng)
    policies["POLICY_STATUS"] = status
    policies["CANCEL_DATE"] = cancel

    # Oracle-friendly dates: YYYY-MM-DD (use format mask YYYY-MM-DD on load)
    for df, cols in ((policies, ["EFFECTIVE_DATE", "CANCEL_DATE"]),
                     (inst, ["DUE_DATE", "PAID_DATE"])):
        for c in cols:
            df[c] = pd.to_datetime(df[c]).dt.strftime("%Y-%m-%d")

    policies.to_csv("POLICIES.csv", index=False)
    inst.to_csv("INSTALLMENTS.csv", index=False)

    print(f"POLICIES.csv:     {len(policies):,} rows")
    print(f"INSTALLMENTS.csv: {len(inst):,} rows")
    print("\nPolicy status mix:")
    print(policies["POLICY_STATUS"].value_counts(normalize=True).round(3).to_string())
    print("\nInstallment status mix:")
    print(inst["INSTALLMENT_STATUS"].value_counts(normalize=True).round(4).to_string())
    print(f"\nTotal written off: ${inst['WRITTEN_OFF_AMT'].sum():,.2f}")


if __name__ == "__main__":
    main()
