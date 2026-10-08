{{ config (materialized='table')}}

select
        md5(concat_ws('|',
        coalesce(source_name, ''), coalesce(reference_id, ''),
        coalesce(to_char(txn_date), ''), coalesce(to_char(amount), ''),
        coalesce(party_name, ''), coalesce(direction, ''),
        coalesce(raw_note, '')))                             as transaction_key,
    to_number(to_char(txn_date,'YYYYMMDD')) as date_key,
    md5(merchant_name) as merchant_key,
    md5(source_name) as source_key,
    md5(category) as category_key,
    amount,
    direction,
    status,
    reference_id
from {{ref('stg_transactions_clean')}}