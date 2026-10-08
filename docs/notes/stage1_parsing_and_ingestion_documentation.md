# Stage 1 — Parsing & Ingestion (Sources → S3)

## Purpose

This stage takes the 4 raw source files and lands them in the S3 raw zone,
the entry point of the pipeline:

```
Sources → Python (Parsing + Ingestion) → AWS S3 → Snowflake → dbt → Analytics
```

It has two distinct steps:

1. **Parsing** — reads the 4 original raw files (2 CSVs, 1 JSON, 1 PDF) and
   reshapes each into a shared, common schema, producing one standardized
   CSV per source.
2. **Ingestion** — uploads those parsed CSVs, unmodified, to the S3 raw
   zone.

They're kept as two separate scripts on purpose: parsing is about making 4
very different sources *comparable*; ingestion is about getting files into
cloud storage reliably. Mixing the two would make each harder to test and
reason about on its own.

---

## Part A — Parsing (raw sources → common schema)

### What it does

Each of the 4 sources arrives in a completely different shape (two CSVs
with different columns, one JSON, one PDF table). This script reads all 4
and produces the **same 8 columns** for every one of them:

| Column | Meaning |
|---|---|
| `source` | which file this row came from |
| `txn_date` | transaction date, always `YYYY-MM-DD` text |
| `amount` | always a positive number |
| `direction` | `"OUT"` (money leaving) or `"IN"` (money coming in) |
| `party` | who the money went to / came from |
| `status` | whatever status the source gave (not cleaned yet) |
| `reference` | order ref / UTR / ref number, if the source has one |
| `raw_note` | original description text, kept as-is for reference |

**Deliberately out of scope at this stage** (per the script's own
docstring): no de-duplication, no refund/reversal matching, no
merchant-name cleanup, and the 4 outputs are not merged into one table.
Those are standardization/business-logic concerns better handled later
(likely in dbt), not during parsing.

### The 4 parsers

**1. Credit card CSV** (`parse_credit_card`)
- Dates converted to ISO format via a shared `to_iso_date()` helper
  (built on `dateutil.parser`, which handles multiple date text formats
  automatically).
- `amount` = absolute value of `amount_inr`.
- `direction`: a **negative** `amount_inr` in this file means a refund, so
  it's mapped to `"IN"`; everything else is `"OUT"`.
- `party` / `raw_note` both come from `merchant_name` — this source has no
  separate free-text description field.

**2. UPI CSV** (`parse_upi`)
- Same shared date helper handles the two different date styles present
  in this file.
- `direction` mapped from this source's own `DEBIT`/`CREDIT` wording to the
  common `OUT`/`IN`.
- `status` uppercased so `SUCCESS` / `Success` / `success` all collapse to
  one consistent value.
- `reference` (`utr_number`): placeholder values `"-"` and `"NA"` are
  normalized to a real missing value (`pd.NA`) instead of being treated as
  literal reference numbers.

**3. E-commerce JSON** (`parse_ecommerce`)
- Iterates the `orders` array in the JSON and pulls `pricing.total_amount`
  as the amount.
- `direction` is always `"OUT"` — placing an order is always money leaving,
  there's no ambiguity to check here.
- `reference` = `order_id`; `raw_note` = `refund_status`, kept for later
  reference but not acted on in this stage.

**4. Bank statement PDF** (`parse_bank_statement`)
- Uses `pdfplumber` to extract tables page by page, skipping header rows.
- A non-empty **withdrawal** value means `"OUT"`; a non-empty **deposit**
  means `"IN"`; rows with neither (e.g. an opening-balance line) are
  skipped entirely — they're not a transaction.
- `party` is **not clean here** — bank statements don't have a separate
  payee field, so the raw narration text is carried through as-is.
- `status` is hardcoded to `"POSTED"`, since a bank statement only ever
  shows settled transactions.
- **Known caveat** (noted directly in the script): some reference numbers
  are truncated by how this particular PDF's tables are laid out.

### Output of parsing

Running the parsing script produces 4 local CSV files, each sharing the
same 8 columns:

```
parsed_credit_card.csv
parsed_upi.csv
parsed_ecommerce.csv
parsed_bank_statement.csv
```

A row count and a 5-row preview are printed for each, as a quick sanity
check that nothing silently failed.

These 4 files are exactly what then goes into the ingestion script's local
source folder for upload to S3.

---

## Part B — Ingestion (parsed CSVs → S3)

### Prerequisites

- **AWS CLI configured** (`aws configure`) so `boto3` authenticates
  automatically — no AWS keys are ever stored in code.
- **S3 bucket already created** — a one-time infrastructure step, done
  separately from this script.
- **Python virtual environment** active, with dependencies installed.
- The 4 `parsed_*.csv` files present in the configured local folder.

### The script

```python
import os
import boto3

LOCAL_FOLDER = 'path/to/your/local/folder'
BUCKET_NAME = 'your-s3-bucket-name'
S3_FOLDER = 'target-s3-folder'

s3 = boto3.client('s3')

for filename in os.listdir(LOCAL_FOLDER):
    local_path = os.path.join(LOCAL_FOLDER, filename)
    if os.path.isfile(local_path):
        s3_key = f"{S3_FOLDER}/{filename}"
        s3.upload_file(local_path, BUCKET_NAME, s3_key)
        print(f"Successfully uploaded: {filename}")
```

### How it works

1. **Authenticate** — `boto3.client('s3')` resolves credentials
   automatically; nothing is hardcoded.
2. **List local files** — every entry in `LOCAL_FOLDER`.
3. **Filter to files only** — `os.path.isfile()` skips subdirectories.
4. **Build the destination key** — each file lands at
   `s3://BUCKET_NAME/S3_FOLDER/<filename>`.
5. **Upload** — `s3.upload_file()` sends it as-is, no modification.
6. **Confirm** — one printed line per file as it uploads.

### How to verify it worked

```bash
aws s3 ls s3://your-s3-bucket-name/target-s3-folder/
```

Or check AWS Console → S3 → bucket → folder, and confirm all 4 files
appear with the expected sizes.

---

## Design note: what "raw zone" means in this pipeline

Worth naming explicitly, since it affects how the S3 raw zone should be
read later: because parsing already reshapes each source into a common
schema, what lands in S3 is a **standardized** version of the data, not a
byte-for-byte copy of the original CSV/JSON/PDF files. Some pipelines keep
the raw zone as the completely untouched original files, deferring all
shaping to a later transform step — this project instead standardizes
column shape during parsing and defers business-logic cleanup (dedup,
refund matching, merchant cleanup) to later. Either approach is valid; this
doc records which one was actually built.

## Known limitations / follow-ups

- **New dependencies for parsing**: `pdfplumber` and `python-dateutil` are
  used but not yet in `requirements.txt` (only `boto3`, `pandas`,
  `python-dotenv` are installed so far):
  ```bash
  pip install pdfplumber python-dateutil
  ```
- **Bank statement references may be truncated**, depending on the PDF's
  table layout (noted directly in the parsing script).
- **No de-duplication, refund/reversal matching, or merchant-name
  cleanup** happens yet — explicitly deferred, likely to dbt.
- **Ingestion config is hardcoded in-script** (`LOCAL_FOLDER`,
  `BUCKET_NAME`, `S3_FOLDER`) rather than read from `.env` / `config.py`.
- **No idempotency or validation** in the ingestion step — rerunning
  overwrites existing S3 objects at the same key; acceptable for this
  project's scope.

## Pipeline position recap

```
4 raw sources (CSV/JSON/PDF)
   -> [Parsing script] -> parsed_*.csv (common 8-column schema)
   -> [Ingestion script] -> S3 raw zone
   -> (next: Snowflake)
```
