# Stage 2: S3 to Snowflake (Raw Layer)

**Project:** batch_processing_project (personal finance batch pipeline)
**Pipeline position:** Sources -> Python -> AWS S3 -> **Snowflake (this stage)** -> dbt -> Airflow -> Analytics
**Status:** Complete

---

## 1. Purpose

Load the parsed CSV files from the S3 raw zone into Snowflake exactly as they arrived. This stage does **no cleaning**. De-duplication, type conversion, merchant cleanup and refund matching belong to dbt (Stage 3).

## 2. Scope

**In scope**
- Snowflake warehouse, database and RAW schema
- Connecting Snowflake to S3
- File format and external stage
- One raw table for all sources
- Loading with `COPY INTO`
- Validation against the source CSVs
- Rerun (idempotency) behavior
- Credential handling

**Out of scope (handled later)**
- Cleaning and typing (dbt staging, Stage 3)
- Star schema build (dbt marts, Stage 3)
- Scheduling (Airflow, Stage 4)
- Role-based access control, resource monitors, Snowpipe (production extras, not needed for V1)

## 3. Inputs and outputs

| | Details |
|---|---|
| Input | 4 parsed CSVs (`parsed_*.csv`) in the S3 raw folder: credit card, UPI, e-commerce, bank statement |
| Input schema | `source, txn_date, amount, direction, party, status, reference, raw_note` (8 columns, one header row) |
| Output | `FINANCE_DB.RAW.RAW_TRANSACTIONS` |

## 4. Snowflake objects created

| Object | Name | Notes |
|---|---|---|
| Warehouse | `BATCH_WH` | XSMALL, auto-suspend 60 seconds, auto-resume |
| Database | `FINANCE_DB` | One database for the whole project |
| Schema | `RAW` | Data exactly as it arrived |
| File format | `csv_format` | Comma delimited, skip 1 header row, quoted fields, empty values as NULL |
| Stage | `raw_s3_stage` | Points to the S3 raw folder, access keys of a read-only IAM user |
| Table | `RAW_TRANSACTIONS` | 8 source columns + 2 metadata columns |

## 5. Raw table design

| Column | Type | Meaning |
|---|---|---|
| `source` | VARCHAR | Which source the row came from |
| `txn_date` | VARCHAR | Transaction date as text |
| `amount` | VARCHAR | Amount as text |
| `direction` | VARCHAR | Debit or credit |
| `party` | VARCHAR | Merchant or counterparty |
| `status` | VARCHAR | Transaction status |
| `reference` | VARCHAR | Reference or transaction ID |
| `raw_note` | VARCHAR | Original description text |
| `_source_file` | VARCHAR | S3 file the row came from (`METADATA$FILENAME`) |
| `_loaded_at` | TIMESTAMP_NTZ | Load time, default `CURRENT_TIMESTAMP()` |

**Why all VARCHAR:** a raw layer should never fail or silently change data because of a type problem. Typing happens in dbt staging.
**Why the two `_` columns:** every row can be traced to its file and load time, which is standard practice for debugging.

## 6. Task-by-task implementation

Repo layout:

```
sql/stage2/
  01_setup.sql
  02_storage_integration.sql      (attempted, not used in the final design, see section 7)
  03_file_format_and_stage.sql
  04_raw_table.sql
  05_copy_into_raw.sql
  06_validation.sql
  07_rerun_test.sql
docs/
  stage2_documentation.md
```

### Task 1: Warehouse, database, schema (`01_setup.sql`)

```sql
USE ROLE SYSADMIN;

CREATE WAREHOUSE IF NOT EXISTS BATCH_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE;

CREATE DATABASE IF NOT EXISTS FINANCE_DB;
CREATE SCHEMA IF NOT EXISTS FINANCE_DB.RAW;

USE WAREHOUSE BATCH_WH;
USE DATABASE FINANCE_DB;
USE SCHEMA RAW;

SELECT CURRENT_WAREHOUSE(), CURRENT_DATABASE(), CURRENT_SCHEMA();
```

Expected: one row with `BATCH_WH`, `FINANCE_DB`, `RAW`.

### Task 2: Storage integration (`02_storage_integration.sql`), attempted

The first connection design was a storage integration: an AWS role that Snowflake assumes, so no keys are stored anywhere.

AWS side: a read-only policy `snowflake_s3_read_policy` limited to the raw folder (`s3:GetObject`, `s3:GetObjectVersion`, and `s3:ListBucket` with a folder prefix condition), attached to a role `snowflake_s3_role`.

Snowflake side:

```sql
USE ROLE ACCOUNTADMIN;

CREATE STORAGE INTEGRATION IF NOT EXISTS s3_finance_int
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = '<role-arn>'
  STORAGE_ALLOWED_LOCATIONS = ('s3://<bucket>/<folder>/');

GRANT USAGE ON INTEGRATION s3_finance_int TO ROLE SYSADMIN;
DESC INTEGRATION s3_finance_int;
```

The trust policy of the AWS role must then contain the `STORAGE_AWS_IAM_USER_ARN` and `STORAGE_AWS_EXTERNAL_ID` from `DESC INTEGRATION`.

**Outcome:** `LIST @stage` kept failing with an AssumeRole error even after rechecking and resetting the trust policy. See section 7. The final design uses access keys instead.

### Task 3: File format and stage (`03_file_format_and_stage.sql`)

```sql
USE ROLE SYSADMIN;
USE WAREHOUSE BATCH_WH;
USE DATABASE FINANCE_DB;
USE SCHEMA RAW;

CREATE FILE FORMAT IF NOT EXISTS csv_format
  TYPE = 'CSV'
  FIELD_DELIMITER = ','
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  NULL_IF = ('', 'NULL', 'null')
  EMPTY_FIELD_AS_NULL = TRUE
  TRIM_SPACE = TRUE;
```

The stage is created in Task 5 in its final form (with keys).

### Task 4: Raw table (`04_raw_table.sql`)

```sql
CREATE TABLE IF NOT EXISTS RAW_TRANSACTIONS (
    source        VARCHAR,
    txn_date      VARCHAR,
    amount        VARCHAR,
    direction     VARCHAR,
    party         VARCHAR,
    status        VARCHAR,
    reference     VARCHAR,
    raw_note      VARCHAR,
    _source_file  VARCHAR,
    _loaded_at    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
```

Expected: `DESC TABLE` shows 10 columns, `COUNT(*)` is 0 before the first load.

### Task 5: Stage with keys and load (`05_copy_into_raw.sql`)

**AWS side:** create an IAM user `snowflake_s3_loader` with no console access, attach only `snowflake_s3_read_policy`, create an access key (use case: third-party service).

**Snowflake side:**

```sql
USE ROLE SYSADMIN;
USE WAREHOUSE BATCH_WH;
USE DATABASE FINANCE_DB;
USE SCHEMA RAW;

CREATE OR REPLACE STAGE raw_s3_stage
  URL = 's3://<bucket>/<folder>/'
  CREDENTIALS = (AWS_KEY_ID = '<access-key-id>' AWS_SECRET_KEY = '<secret-access-key>')
  FILE_FORMAT = csv_format;

LIST @raw_s3_stage;

COPY INTO RAW_TRANSACTIONS
  (source, txn_date, amount, direction, party, status, reference, raw_note, _source_file)
FROM (
  SELECT $1, $2, $3, $4, $5, $6, $7, $8, METADATA$FILENAME
  FROM @raw_s3_stage
)
PATTERN = '.*parsed_.*[.]csv'
FILE_FORMAT = (FORMAT_NAME = 'csv_format')
ON_ERROR = 'ABORT_STATEMENT';
```

**Important:** in the repo the file keeps the placeholders `<access-key-id>` and `<secret-access-key>`. The real values are typed only in the Snowflake worksheet.

Design points:
- `PATTERN` loads only `parsed_*.csv`, so other files in the folder are ignored.
- `ON_ERROR = 'ABORT_STATEMENT'` stops the whole load if any row is bad, so there are no partial loads.
- Columns map by **position**, so the CSV column order must stay `source, txn_date, amount, direction, party, status, reference, raw_note`.

Expected: `COPY INTO` returns one row per file with status `LOADED` and a `rows_loaded` count.

### Task 6: Validation (`06_validation.sql`)

**Check A: row counts per file in Snowflake**

```sql
SELECT _source_file, source, COUNT(*) AS row_count
FROM RAW_TRANSACTIONS
GROUP BY _source_file, source
ORDER BY _source_file;

SELECT COUNT(*) AS total_rows FROM RAW_TRANSACTIONS;
```

**Check B: row counts per file locally (pandas, not line counts, because a note with a line break would inflate a line count)**

```python
import os
import pandas as pd

LOCAL_FOLDER = "<local-folder>"
total = 0
for f in sorted(os.listdir(LOCAL_FOLDER)):
    if f.startswith("parsed_") and f.endswith(".csv"):
        n = len(pd.read_csv(os.path.join(LOCAL_FOLDER, f), dtype=str))
        total += n
        print(f, n)
print("TOTAL", total)
```

**Check C: column alignment**

```sql
SELECT * FROM RAW_TRANSACTIONS LIMIT 10;

SELECT source,
       MIN(txn_date) AS min_date, MAX(txn_date) AS max_date,
       COUNT_IF(amount IS NULL) AS null_amount,
       COUNT_IF(txn_date IS NULL) AS null_date,
       COUNT_IF(direction IS NULL) AS null_direction
FROM RAW_TRANSACTIONS
GROUP BY source;
```

**Check D: load history**

```sql
SELECT file_name, status, row_count, row_parsed, error_count
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
  TABLE_NAME => 'RAW_TRANSACTIONS',
  START_TIME => DATEADD(hours, -24, CURRENT_TIMESTAMP())));
```

Pass criteria:
- Per-file counts and the total match between Snowflake and the local CSVs.
- Sample rows show dates in `txn_date`, numbers in `amount`, debit/credit in `direction`.
- Every file shows `LOADED` and `error_count` = 0.

Nulls in some columns (for example `reference` on some UPI rows) can be normal. They are recorded, not fixed, in the raw layer.

### Task 7: Rerun test (`07_rerun_test.sql`)

```sql
SELECT COUNT(*) AS rows_before FROM RAW_TRANSACTIONS;

-- run the exact same COPY INTO from Task 5 again

SELECT COUNT(*) AS rows_after FROM RAW_TRANSACTIONS;
```

Pass criteria: `rows_before` equals `rows_after`, and the second `COPY INTO` reports no files processed.

## 7. Issue log: storage integration AssumeRole error

**Symptom:** `LIST @raw_s3_stage` failed with "Error assuming AWS_ROLE: User ... is not authorized to perform: sts:AssumeRole on resource ... snowflake_s3_role".

**Meaning:** Snowflake's AWS user was not accepted by the role's trust policy.

**Checked:**
- Trust policy replaced with the values from `DESC INTEGRATION` (Snowflake user ARN and external ID).
- The 3 values compared: role ARN in the integration, Snowflake user ARN, external ID.
- Clean reset order: recreate the integration, copy the new external ID, replace the trust policy once, recreate the stage, test.

**Common causes for this error:** placeholder statement still in the trust policy, an old external ID after the integration was recreated, an unsaved trust policy edit, a wrong role ARN, or an AWS Organization policy blocking AssumeRole.

**Decision:** time-boxed the investigation, then switched to access keys on a dedicated read-only IAM user. The integration route stays on the V2 list.

## 8. Design decisions

| Decision | Reason |
|---|---|
| One raw table for all 4 sources | Parsing already unifies the sources into one 8-column schema. One table and one `COPY INTO` is simpler. The `source` column keeps lineage. |
| Unified schema | Matches the frozen star schema (`fact_transactions` + `dim_source`). Trade-off: source-specific fields (e-commerce item detail, UPI app, running balance) are squeezed into shared columns or `raw_note`. Accepted for V1. |
| All VARCHAR in raw | Loads never fail on types. Typing is dbt's job. |
| `_source_file`, `_loaded_at` | Row-level traceability. |
| Access keys instead of storage integration | Integration trust kept failing. Keys on a read-only, folder-limited IAM user are acceptable for a portfolio project. |
| `ON_ERROR = ABORT_STATEMENT` | No partial loads. |
| `PATTERN` on `parsed_*.csv` | Only intended files are loaded. |
| XSMALL warehouse, 60 second auto-suspend | Lowest cost for a small dataset. |

**Portfolio vs production**

| Area | This project | Production |
|---|---|---|
| S3 access | Access keys, read-only IAM user | Storage integration (no keys) |
| Roles | SYSADMIN and ACCOUNTADMIN | Dedicated roles per layer and per task |
| Loading | Manual `COPY INTO` (Airflow later) | Orchestrated, or Snowpipe for continuous loads |
| Monitoring | Manual validation queries | Automated checks, alerts, resource monitors |
| Secrets | Typed in worksheet only | Secrets manager |

## 9. Idempotency and reruns

- `COPY INTO` keeps load history for each file for 64 days. Running it again skips files it already loaded, so there are no duplicates.
- **Limit:** a file re-uploaded with the **same name** and new content is skipped, so the table keeps the old data.
- **Full reload (dev only):**

```sql
TRUNCATE TABLE RAW_TRANSACTIONS;

COPY INTO RAW_TRANSACTIONS
  (source, txn_date, amount, direction, party, status, reference, raw_note, _source_file)
FROM (
  SELECT $1, $2, $3, $4, $5, $6, $7, $8, METADATA$FILENAME
  FROM @raw_s3_stage
)
PATTERN = '.*parsed_.*[.]csv'
FILE_FORMAT = (FORMAT_NAME = 'csv_format')
FORCE = TRUE
ON_ERROR = 'ABORT_STATEMENT';
```

Never use `FORCE = TRUE` without `TRUNCATE` first, or every row loads twice.

## 10. Security and credentials

- Dedicated IAM user `snowflake_s3_loader`, no console access, one read-only policy limited to the raw folder.
- Real keys live only in the Snowflake worksheet. Repo files keep placeholders.
- Keep trust policy files and any file with real values out of GitHub (`.gitignore`).
- Snowflake query history keeps the text of the stage creation statement, which is one reason keys are a portfolio choice and not a production one.
- Delete the IAM access key if the project is paused.

## 11. Results (fill in after running)

| Check | Result |
|---|---|
| Rows per file, Snowflake vs local CSV | |
| Total rows | |
| `COPY_HISTORY` errors | |
| Rerun: `rows_before` / `rows_after` | |
| Keys absent from repo | |

## 12. Known limitations and V2 ideas

- Switch to a storage integration (fix the trust policy) and remove stored keys.
- Add dedicated roles and permissions per layer.
- Add `_batch_id` for per-run tracking.
- Add source-specific columns if V1 analytics need them.
- Add automated row-count checks inside the Airflow DAG.

## 13. Handoff to Stage 3 (dbt)

- dbt reads from `FINANCE_DB.RAW.RAW_TRANSACTIONS`.
- Staging models cast types (`txn_date` to DATE, `amount` to NUMBER), standardize `direction` and `status`, and clean `party`.
- Marts build the frozen star schema: `fact_transactions` with `dim_date`, `dim_merchant`, `dim_source`, `dim_category`.
- De-duplication and refund/reversal matching are done in dbt, using `source`, `reference` and `_source_file` for lineage.
