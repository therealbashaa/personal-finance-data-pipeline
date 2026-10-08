{{config(
    materialized='table'
)}}

select distinct
    md5(source_name) as source_key,
    source_name
from {{ref('stg_transactions')}}
where source_name is not null