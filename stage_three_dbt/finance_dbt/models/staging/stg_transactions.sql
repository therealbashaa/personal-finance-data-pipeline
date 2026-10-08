{{config(
    materialized='view'
)}}

select
    trim(source) as source_name,
    try_to_date(txn_date) as txn_date,
    try_to_number(replace(replace(amount,'₹',''),',','')) as amount,
    upper(trim(direction)) as direction,
    trim(party) as party_name,
    upper(trim(status)) as status,
    trim(reference) as reference_id,
    raw_note
from {{source('raw','raw_transactions')}}