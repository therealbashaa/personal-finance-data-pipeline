{{ config(materialized='table') }}

select distinct
    md5(merchant_name) as merchant_key,
    merchant_name
from {{ ref('stg_transactions_clean') }}
where merchant_name is not null
