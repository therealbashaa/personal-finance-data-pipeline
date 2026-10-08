{{config(materialized= 'view')}}

select
    t.*,
    coalesce(m.merchant_name, upper(t.party_name)) as merchant_name,
    coalesce(m.category, 'UNCATEGORIZED') as category
from {{ref('stg_transactions')}} t
left join {{ref ('merchant_mapping')}} m
    on upper(t.party_name) like '%' || m.keyword || '%'