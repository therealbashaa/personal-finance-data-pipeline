-- =====================================================================
-- Stage 2: S3 -> Snowflake raw layer
-- Project : finance_data_pipeline (batch pipeline, V1)
-- Run the numbered sections in order in a Snowflake worksheet.
--
-- SECURITY: replace every <PLACEHOLDER> on your own machine only.
-- NEVER commit real AWS keys. Use a read-only IAM user
-- (for example: snowflake_s3_loader) that can only read this bucket.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Warehouse, database and schemas
-- ---------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS BATCH_WH
  WAREHOUSE_SIZE      = 'XSMALL'
  AUTO_SUSPEND        = 60
  AUTO_RESUME         = TRUE
  INITIALLY_SUSPENDED = TRUE;

CREATE DATABASE IF NOT EXISTS FINANCE_DB;
CREATE SCHEMA   IF NOT EXISTS FINANCE_DB.RAW;        -- raw data loaded from S3
CREATE SCHEMA   IF NOT EXISTS FINANCE_DB.ANALYTICS;  -- dbt models (Stage 3)

USE WAREHOUSE BATCH_WH;
USE SCHEMA FINANCE_DB.RAW;


-- ---------------------------------------------------------------------
-- 2. File format (how Snowflake reads the CSV files)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FILE FORMAT csv_format
  TYPE                         = 'CSV'
  FIELD_DELIMITER              = ','
  SKIP_HEADER                  = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  NULL_IF                      = ('', 'NULL')
  EMPTY_FIELD_AS_NULL          = TRUE
  TRIM_SPACE                   = TRUE;


-- ---------------------------------------------------------------------
-- 3. External stage (points Snowflake at the S3 folder)
--    Replace the 3 placeholders locally. Do not commit the real values.
-- ---------------------------------------------------------------------
CREATE OR REPLACE STAGE raw_s3_stage
  URL         = 's3://<YOUR_BUCKET_NAME>/<YOUR_S3_FOLDER>/'
  CREDENTIALS = (AWS_KEY_ID     = '<YOUR_ACCESS_KEY_ID>'
                 AWS_SECRET_KEY = '<YOUR_SECRET_ACCESS_KEY>')
  FILE_FORMAT = csv_format;

-- Check that Snowflake can see the files in S3
LIST @raw_s3_stage;


-- ---------------------------------------------------------------------
-- 4. Raw table (one table for all 4 sources, 8 columns)
--    The raw layer keeps everything as text. dbt (Stage 3) casts the
--    dates and amounts and checks that they are valid.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE RAW_TRANSACTIONS (
    source     STRING,   -- credit_card / upi / ecommerce / bank_statement
    txn_date   STRING,
    amount     STRING,
    direction  STRING,   -- IN / OUT
    party      STRING,   -- merchant or person name
    status     STRING,
    reference  STRING,
    raw_note   STRING
);


-- ---------------------------------------------------------------------
-- 5. Load the data from S3 into the raw table
-- ---------------------------------------------------------------------
COPY INTO RAW_TRANSACTIONS
FROM @raw_s3_stage
PATTERN  = '.*parsed_.*[.]csv'
ON_ERROR = 'ABORT_STATEMENT';


-- ---------------------------------------------------------------------
-- 6. Validation (run each query and check the result)
-- ---------------------------------------------------------------------
-- 6a. Total rows (should equal the row count of FACT_TRANSACTIONS)
SELECT COUNT(*) AS total_rows FROM RAW_TRANSACTIONS;

-- 6b. Rows per source (expect 4 sources)
SELECT source, COUNT(*) AS rows_per_source
FROM RAW_TRANSACTIONS
GROUP BY source
ORDER BY source;

-- 6c. Missing values in the key columns (all counts should be 0)
SELECT
    COUNT_IF(txn_date  IS NULL) AS null_dates,
    COUNT_IF(amount    IS NULL) AS null_amounts,
    COUNT_IF(direction IS NULL) AS null_directions
FROM RAW_TRANSACTIONS;

-- 6d. Direction and status values
SELECT direction, status, COUNT(*) AS row_count
FROM RAW_TRANSACTIONS
GROUP BY direction, status
ORDER BY direction, status;


-- ---------------------------------------------------------------------
-- 7. Rerun test (optional)
--    COPY INTO remembers which files it already loaded, so running it
--    twice loads nothing new. To reload everything from scratch,
--    uncomment and run these two statements.
-- ---------------------------------------------------------------------
-- TRUNCATE TABLE RAW_TRANSACTIONS;
--
-- COPY INTO RAW_TRANSACTIONS
-- FROM @raw_s3_stage
-- PATTERN  = '.*parsed_.*[.]csv'
-- ON_ERROR = 'ABORT_STATEMENT'
-- FORCE    = TRUE;
