{{config(materialized= 'table')}}

select distinct
    md5(category) as category_key,
    category
from {{ ref('stg_transactions_clean')}}