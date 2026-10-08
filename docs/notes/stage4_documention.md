# Stage 4: BI Reporting (Power BI)

This stage turns the star schema built by dbt (Stage 3) into a dashboard that answers simple money questions: how much came in, how much went out, where the money went, and how it changed over time.

> Airflow (orchestration) was skipped in V1 and is planned for the next version, so BI is Stage 4 in this repo.

---

## 1. Goal and result

**Goal:** build a small, clear dashboard on top of the `FINANCE_DB.ANALYTICS` tables.

**Result:** a 2-page Power BI report.

| Page | What it shows |
|------|---------------|
| **Overview** | 4 KPI cards (Total Income, Total Spend, Net Savings, Transaction Count), a monthly Income vs Spend line chart, and a date slicer |
| **Spending Breakdown** | Spend by Category, Top 10 Merchants by Spend, Spend by Source |

---

## 2. Tool choice

**Power BI Desktop, Import mode.**

- Free, runs on Windows, connects straight to Snowflake.
- No new infrastructure, so the V1 stack stays simple.
- No Microsoft account needed. Signing in is only needed to publish online, which V1 does not do.
- Import mode copies the data into the `.pbix` file, so the report still opens after the Snowflake trial ends.

---

## 3. What was built, task by task

### Task 1: Connect Power BI to Snowflake
- Get data, then Snowflake, then the account server and the `BATCH_WH` warehouse.
- Connectivity mode: **Import**. Signed in with the Snowflake username and password.
- Loaded 5 tables from `FINANCE_DB.ANALYTICS`: `FACT_TRANSACTIONS`, `DIM_DATE`, `DIM_MERCHANT`, `DIM_SOURCE`, `DIM_CATEGORY`.
- Check: all 5 tables loaded without errors.

### Task 2: Check the model
- Power BI found the relationships automatically.
- All 4 are **one-to-many**, single direction, from each dimension into `FACT_TRANSACTIONS`.
- `DIM_SOURCE` was hidden behind the fact table in the diagram, so it was checked in **Manage relationships**. All 4 links were present and active.

| Dimension | Key |
|-----------|-----|
| DIM_DATE | DATE_KEY |
| DIM_MERCHANT | MERCHANT_KEY |
| DIM_SOURCE | SOURCE_KEY |
| DIM_CATEGORY | CATEGORY_KEY |

### Task 3: Basic measures and a data check
- Created an empty table `_Measures` that only holds formulas.
- Added `Transaction Count` and `Total Amount`.
- Built a test table of DIRECTION and STATUS to see the real values.
  - Total: **1,459 transactions**, matching the row count of `FACT_TRANSACTIONS`.
  - DIRECTION has two values: `IN` and `OUT`.
  - STATUS mixes final and non-final rows.

**Finding:** adding up every row would count failed and cancelled transactions as real money.

**Decision (V1 rule):** only rows with STATUS `POSTED`, `SUCCESS` or `DELIVERED` count as real money movement. The rest are ignored (FAILED, FAILURE, CANCELLED, RETURNED, DISPUTED, PENDING, PROCESSING, SHIPPED). This is done inside Power BI, so the dbt models stay unchanged.

### Task 4: Overview page
- **4a, KPI cards:** four cards in one row. Transaction Count display units were set to **None** so it shows `1,459` and not `1K`.
- **4b, monthly trend:** line chart of Total Income and Total Spend by Year and Month, from September 2025 to September 2026.
  - September 2025 looks very low for spend because it is a partial month with only a few days of data.
- **4c, date slicer:** a date range slider that filters the cards and the chart together.

### Task 5: Spending Breakdown page
- **5a, Spend by Category:** horizontal bars, largest first, with data labels. The bars add up to the Total Spend card, which was used as a check.
- **5b, Top 10 Merchants:** bar chart with a **Top N** filter (Top 10 by Total Spend).
- **5c, Spend by Source:** columns for `bank_statement`, `upi`, `ecommerce` and `credit_card`.

### Task 6: Clean-up and export
- Deleted the test page and kept two pages: `Overview` and `Spending Breakdown`.
- Gave every chart a clear title and data labels.
- Saved the `.pbix`, a PDF export, and screenshots of both pages and of the model view.

---

## 4. Measures (DAX)

All measures live in the `_Measures` table.

```
Transaction Count = COUNTROWS(FACT_TRANSACTIONS)

Total Amount = SUM(FACT_TRANSACTIONS[AMOUNT])

Total Income =
CALCULATE(
    [Total Amount],
    FACT_TRANSACTIONS[DIRECTION] = "IN",
    FACT_TRANSACTIONS[STATUS] IN {"POSTED", "SUCCESS", "DELIVERED"}
)

Total Spend =
CALCULATE(
    [Total Amount],
    FACT_TRANSACTIONS[DIRECTION] = "OUT",
    FACT_TRANSACTIONS[STATUS] IN {"POSTED", "SUCCESS", "DELIVERED"},
    KEEPFILTERS(DIM_MERCHANT[MERCHANT_NAME] <> "CREDIT CARD BILL PAYMENT")
)

Net Savings = [Total Income] - [Total Spend]
```

---

## 5. Issues found and decisions

| # | Issue | What was done |
|---|-------|---------------|
| 1 | STATUS contains failed, cancelled and pending rows | Count only POSTED, SUCCESS and DELIVERED |
| 2 | Transaction Count showed `1K` | Display units set to None |
| 3 | September 2025 is a partial month | Left in the data. The date slicer lets a viewer leave it out |
| 4 | **Double counting:** the bank statement has a `CREDIT CARD BILL PAYMENT` (about 0.38M), and the `credit_card` source already holds the card purchases (about 0.40M) | Excluded the bill payment from Total Spend. Paying the bill is a transfer, not new spending |
| 5 | After excluding the bill payment, every merchant showed the same 2.2M | Cause: a filter on `MERCHANT_NAME` inside `CALCULATE` replaces the chart's own merchant filter. Fixed with `KEEPFILTERS` |
| 6 | `UNCATEGORIZED` is one of the largest categories (about 0.34M) | Accepted for V1. More merchants can be added to the `merchant_mapping.csv` seed later |

After the exclusion, Total Spend dropped by roughly 0.38M (from about 2.60M to about 2.2M), the Cash and Transfers category fell from about 0.44M to about 0.06M, and `bank_statement` spend fell by the same amount.

---

## 6. Files for this stage

| File | Location |
|------|----------|
| Power BI report | `stage_four_bi/finance_dashboard.pbix` |
| Dashboard PDF | `docs/finance_dashboard.pdf` |
| Overview screenshot | `docs/screenshots/dashboard_overview.png` |
| Spending Breakdown screenshot | `docs/screenshots/dashboard_spending_breakdown.png` |
| Data model screenshot | `docs/screenshots/power_bi_data_model.png` |

---

## 7. Limits of V1

- The data in the `.pbix` is a snapshot. The Snowflake free trial has ended, so the report cannot refresh. To refresh it, create a new Snowflake account, re-run the Stage 2 script and dbt, then update the server and warehouse in Power BI.
- The date slicer is on the Overview page only.
- There is no refund or reversal matching.
- The data is synthetic.
- No automatic scheduling yet. Airflow is planned for V2.

---

## 8. Short talking points

- Built a star-schema dashboard in Power BI on Snowflake data, using DAX measures.
- Found and fixed a double-counting problem: card bill payments were counted on top of the card purchases.
- Used a data check (sum of the chart against the KPI card) to confirm numbers at every step.
- Fixed a DAX filter-context bug using `KEEPFILTERS`.
