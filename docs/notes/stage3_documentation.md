# Stage 3: dbt Transformation (Snowflake RAW -> ANALYTICS)

## 1. Overview

Stage 3 turns the raw table loaded in Stage 2 (`FINANCE_DB.RAW.RAW_TRANSACTIONS`) into a clean **star schema** in `FINANCE_DB.ANALYTICS`, using **dbt**.

- **Input:** `FINANCE_DB.RAW.RAW_TRANSACTIONS` (8 columns: source, txn_date, amount, direction, party, status, reference, raw_note)
- **Output:** 1 fact table + 4 dimension tables in `FINANCE_DB.ANALYTICS`
- **Tools:** dbt-snowflake (in a Python venv), Snowflake
- **No new technology** was added beyond the frozen V1 architecture.

## 2. Data flow

```
RAW.RAW_TRANSACTIONS
        |
        v
  stg_transactions          (view: clean names, types, spaces)
        |
        v
  stg_transactions_clean    (view: adds merchant_name + category from the seed)
        |
        +--> dim_source
        +--> dim_date
        +--> dim_merchant
        +--> dim_category
        +--> fact_transactions   (keys to all 4 dimensions)
```

The RAW schema holds only untouched raw data. Everything dbt builds goes in ANALYTICS.

## 3. Project structure

```
stage_three_dbt/
├── venv/
├── README.md
└── finance_dbt/
    ├── dbt_project.yml
    ├── seeds/
    │   └── merchant_mapping.csv
    └── models/
        ├── staging/
        │   ├── sources.yml
        │   ├── stg_transactions.sql
        │   └── stg_transactions_clean.sql
        └── marts/
            ├── dim_source.sql
            ├── dim_date.sql
            ├── dim_merchant.sql
            ├── dim_category.sql
            ├── fact_transactions.sql
            └── schema.yml
```

The Snowflake connection lives in `~/.dbt/profiles.yml`, outside the project, so the password is never committed to Git.

## 4. The 7 tasks

### Task 1: Install dbt and connect to Snowflake
- Created the `stage_three_dbt` folder and a virtual environment, then ran `pip install dbt-snowflake`.
- Created the dbt project with `dbt init finance_dbt`.
- Filled in `~/.dbt/profiles.yml` with account, user, role, warehouse, `database: FINANCE_DB` and `schema: ANALYTICS`.
- **Check:** `dbt debug` ended with `All checks passed!`

### Task 2: Declare the raw source
- Created `models/staging/sources.yml` pointing to `FINANCE_DB.RAW.raw_transactions`.
- Every model now reads raw data through `source('raw', 'raw_transactions')` instead of a hardcoded table name.
- **Check:** `dbt show --inline "select * from {{ source('raw', 'raw_transactions') }}" --limit 5` returned 5 rows with all 8 columns.

### Task 3: Staging model (`stg_transactions`)
- A view that cleans the raw data: trims text, upper-cases `direction` and `status`, converts `txn_date` with `try_to_date`, and converts `amount` with `try_to_number` after removing the currency symbol and commas.
- The `try_` functions return empty instead of crashing when a value does not fit.
- **Check:** total rows, valid dates and valid amounts all had the same count, so nothing was lost in conversion.

### Task 4: The four dimensions

| Dimension | How it is built | Key |
|---|---|---|
| `dim_source` | Distinct `source_name` (4 rows: credit_card, upi, ecommerce, bank_statement) | `md5(source_name)` |
| `dim_date` | A calendar generated with Snowflake `generator`, one row per day from the first to the last transaction date, with year, quarter, month, day name and `is_weekend` | `date_key` as YYYYMMDD |
| `dim_merchant` | Distinct cleaned `merchant_name` | `md5(merchant_name)` |
| `dim_category` | Distinct `category` | `md5(category)` |

**Merchant and category cleanup.** Raw names were messy: the same shop appeared as `AJIO`, `AJIO.IN BANGALORE IN` and `UPI-AJIO@...`. Instead of a long SQL rule, a small CSV seed was added:

- `seeds/merchant_mapping.csv` has three columns: `keyword`, `merchant_name`, `category`.
- `stg_transactions_clean` left-joins the raw name to the keyword list with `LIKE`:

```sql
select
    t.*,
    coalesce(m.merchant_name, upper(t.party_name)) as merchant_name,
    coalesce(m.category, 'UNCATEGORIZED')          as category
from {{ ref('stg_transactions') }} t
left join {{ ref('merchant_mapping') }} m
    on upper(t.party_name) like '%' || m.keyword || '%'
```

To fix or add a merchant later, edit one line in the CSV and run `dbt seed`. The SQL does not change.

### Task 5: Fact table (`fact_transactions`)
- One row per transaction, holding `amount`, `direction`, `status`, `reference_id`, and four keys.
- Each key uses the same formula as its dimension, so no joins are needed:

```sql
to_number(to_char(txn_date, 'YYYYMMDD')) as date_key,
md5(merchant_name)                       as merchant_key,
md5(source_name)                         as source_key,
md5(category)                            as category_key
```

- `transaction_key` is an `md5` of all identifying fields, with each field wrapped in `coalesce(..., '')` so empty values do not cause two different transactions to share an ID.
- **Check:** `fact_rows` equals `stg_rows`, all IDs are unique, and there are no orphan keys.

### Task 6: Tests
`models/marts/schema.yml` defines 18 tests:
- `unique` and `not_null` on the key of every dimension and on `transaction_key` (10 tests)
- `not_null` and `relationships` on the 4 foreign keys in the fact table (8 tests)

**Result:** `dbt test` ended with `PASS=18 WARN=0 ERROR=0`.

### Task 7: Full build and documentation
- Ran `dbt build --full-refresh`, which loads the seed, builds all 7 models and runs all 18 tests in one command, to prove a clean rerun works.
- Ran a first analytical query on the star schema (spending per category and direction):

```sql
select c.category, f.direction, count(*) as txns, sum(f.amount) as total_amount
from FINANCE_DB.ANALYTICS.FACT_TRANSACTIONS f
join FINANCE_DB.ANALYTICS.DIM_CATEGORY c on f.category_key = c.category_key
group by c.category, f.direction
order by total_amount desc;
```

- Wrote the stage README.

## 5. Problems met and how they were fixed

| Problem | Cause | Fix |
|---|---|---|
| `dbt show` failed with a `limit` syntax error | dbt adds its own `limit`, and the query had one too | Pass `--limit 5` as a dbt option, outside the query |
| Same merchant under many names | Raw names include city, phone, refund and bank text | Keyword seed `merchant_mapping.csv` plus `stg_transactions_clean` |
| `dim_merchant` failed with a `group by` error | An old version of the file with `group by` was still on disk | Overwrote the file with the simple `select distinct` version |
| dbt tables appeared in the `RAW` schema | The `schema:` in `profiles.yml` was `RAW` | Changed it to `ANALYTICS`, rebuilt, and dropped the leftover objects from `RAW` |
| `unique_ids` was lower than `fact_rows` | `concat_ws` skips empty values, so different rows could produce the same text | Wrapped each field in `coalesce(..., '')` and added `raw_note` to the key |

## 6. How to run the whole stage

1. Activate the virtual environment in `stage_three_dbt`.
2. Make sure `~/.dbt/profiles.yml` has `schema: ANALYTICS`.
3. From `stage_three_dbt/finance_dbt`, run:

```
dbt build --full-refresh
```

Useful single commands: `dbt seed`, `dbt run --select <model>`, `dbt test`, `dbt debug`.

## 7. Decisions and V1 limits

- Models are views in staging and tables in marts.
- Keys are md5 hashes, so reruns produce the same keys (important for scheduled runs).
- Merchant cleanup is a simple keyword list. Personal UPI transfers to people stay `UNCATEGORIZED`.
- No SCD Type 2, no account-level detail, no de-duplication or refund/reversal matching in V1, as agreed in the frozen warehouse model.
- Everything dbt creates lives in `ANALYTICS`. `RAW` is never modified by dbt.

## 8. What comes next

The next stage in the frozen architecture is orchestration: Airflow runs the pipeline on a schedule (Python ingestion -> S3 -> Snowflake load -> `dbt build`).
