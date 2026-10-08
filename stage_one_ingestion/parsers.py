"""
Stage: Parsing (raw files -> one common shape)

What this file does:
  Reads each of the 4 raw source files and turns each one into a table
  with the SAME columns, so all 4 sources look alike afterwards.

What this file does NOT do (on purpose, for this stage):
  - No de-duplication
  - No refund/reversal matching
  - No merchant-name cleanup
  - No merging the 4 tables together

Common output columns (same for all 4 sources):
  source        -> which file this row came from
  txn_date      -> transaction date, always as YYYY-MM-DD text
  amount        -> always a positive number
  direction     -> "OUT" (money leaving) or "IN" (money coming in)
  party         -> who the money went to / came from
  status        -> whatever status the source gave (not cleaned yet)
  reference     -> order ref / UTR / ref number, if the source has one
  raw_note      -> the original description text, kept as-is for reference
"""

import pandas as pd
import pdfplumber
import json
from dateutil import parser as dateparser

# ---- EDIT THESE 4 PATHS to match where your files actually are ----
CREDIT_CARD_CSV = "credit_card_transactions_26Sep2025-25Sep2026.csv"
UPI_CSV = "upi_transactions_26Sep2025-25Sep2026.csv"
ECOMMERCE_JSON = "ecommerce_orders_26Sep2025-25Sep2026.json"
BANK_STATEMENT_PDF = "bank_statement_26Sep2025-25Sep2026.pdf"
# ---------------------------------------------------------------


def to_iso_date(value):
    """Turn any date text (whatever format it's in) into YYYY-MM-DD text."""
    # dayfirst is left at default (False) on purpose: every date style in
    # these files is already unambiguous (YYYY-MM-DD, or DD-Mon-YYYY with a
    # month name), so forcing dayfirst=True actually misreads YYYY-MM-DD.
    return dateparser.parse(str(value)).strftime("%Y-%m-%d")


# 1) CREDIT CARD CSV -----------------------------------------------------
def parse_credit_card(path=CREDIT_CARD_CSV):
    df = pd.read_csv(path)

    out = pd.DataFrame(index=df.index)  # fixes row count upfront so scalar columns fill every row
    out["source"] = "credit_card"
    out["txn_date"] = df["transaction_date"].apply(to_iso_date)
    out["amount"] = df["amount_inr"].abs()
    # negative amount in this file = refund = money coming back IN
    out["direction"] = df["amount_inr"].apply(lambda x: "IN" if x < 0 else "OUT")
    out["party"] = df["merchant_name"]
    out["status"] = df["status"]
    out["reference"] = df["order_ref"]
    out["raw_note"] = df["merchant_name"]
    return out


# 2) UPI CSV --------------------------------------------------------------
def parse_upi(path=UPI_CSV):
    df = pd.read_csv(path)

    out = pd.DataFrame(index=df.index)  # fixes row count upfront so scalar columns fill every row
    out["source"] = "upi"
    out["txn_date"] = df["date"].apply(to_iso_date)   # handles both date styles in this file
    out["amount"] = df["amount_inr"].abs()
    out["direction"] = df["direction"].str.upper().map({"DEBIT": "OUT", "CREDIT": "IN"})
    out["party"] = df["counterparty_name"]
    out["status"] = df["status"].str.upper()          # SUCCESS / Success / success -> SUCCESS
    # treat blank, "-", "NA" all the same way: no reference available
    out["reference"] = df["utr_number"].replace(["-", "NA"], pd.NA)
    out["raw_note"] = df["remarks"]
    return out


# 3) E-COMMERCE JSON --------------------------------------------------------
def parse_ecommerce(path=ECOMMERCE_JSON):
    with open(path) as f:
        data = json.load(f)

    rows = []
    for order in data["orders"]:
        rows.append({
            "source": "ecommerce",
            "txn_date": to_iso_date(order["order_date"]),
            "amount": order["pricing"]["total_amount"],
            "direction": "OUT",   # order placement is always money going out
            "party": order["platform"],
            "status": order["status"],
            "reference": order["order_id"],
            "raw_note": order.get("refund_status"),  # kept for reference, not acted on yet
        })
    return pd.DataFrame(rows)


# 4) BANK STATEMENT PDF -----------------------------------------------------
def parse_bank_statement(path=BANK_STATEMENT_PDF):
    rows = []
    with pdfplumber.open(path) as pdf:
        for page in pdf.pages:
            for table in page.extract_tables():
                for row in table[1:]:  # skip header row
                    if not row or not row[0] or row[0] == "Date":
                        continue

                    date_txt, narration, ref_no, _value_dt, withdrawal, deposit, _bal = row
                    narration = (narration or "").replace("\n", " ").strip()

                    if withdrawal and withdrawal.strip():
                        amount = float(withdrawal.replace(",", ""))
                        direction = "OUT"
                    elif deposit and deposit.strip():
                        amount = float(deposit.replace(",", ""))
                        direction = "IN"
                    else:
                        continue  # opening balance line etc. - no actual amount

                    rows.append({
                        "source": "bank_statement",
                        "txn_date": to_iso_date(date_txt),
                        "amount": amount,
                        "direction": direction,
                        "party": narration,       # party name is buried in narration for now
                        "status": "POSTED",       # bank statement only ever shows posted lines
                        "reference": ref_no,       # NOTE: some refs are truncated in this file
                        "raw_note": narration,
                    })
    return pd.DataFrame(rows)


if __name__ == "__main__":
    parsed = {
        "credit_card": parse_credit_card(),
        "upi": parse_upi(),
        "ecommerce": parse_ecommerce(),
        "bank_statement": parse_bank_statement(),
    }

    for name, df in parsed.items():
        out_file = f"parsed_{name}.csv"
        df.to_csv(out_file, index=False)
        print(f"\n=== {name}: {len(df)} rows -> saved to {out_file} ===")
        print(df.head(5).to_string(index=False))
