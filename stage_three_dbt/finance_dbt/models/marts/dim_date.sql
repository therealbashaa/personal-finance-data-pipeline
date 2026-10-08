{{config(
    materialized='table'
)}}

with bounds as (
    select min(txn_date) as start_date, max(txn_date) as end_date
    from {{ref('stg_transactions')}}
),

dates as (
    select dateadd(day, row_number() over (order by seq4())-1, b.start_date) as date_day,
    b.end_date
    from bounds b, table(generator(rowcount => 3650))
)

select 
    to_number(to_char(date_day, 'YYYYMMDD')) as date_key,
    date_day,
    year(date_day) as year,
    quarter(date_day) as quarter_number,
    month(date_day) as month_number,
    monthname(date_day) as month_name,
    day(date_day) as day_of_month,
    dayname(date_day) as day_name,
    dayofweekiso(date_day) as is_weekend
from dates
where date_day <= end_date