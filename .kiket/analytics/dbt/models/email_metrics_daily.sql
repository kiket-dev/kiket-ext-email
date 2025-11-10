{{
  config(
    materialized='incremental',
    unique_key=['delivery_date', 'template_name']
  )
}}

with daily_metrics as (
  select
    date(sent_at) as delivery_date,
    template_name,
    delivery_type,
    count(*) as total_sent,
    count(case when status = 'delivered' then 1 end) as delivered_count,
    count(case when status = 'bounced' then 1 end) as bounced_count,
    count(case when status = 'failed' then 1 end) as failed_count,
    count(case when opened_at is not null then 1 end) as opened_count,
    count(case when clicked_at is not null then 1 end) as clicked_count,
    count(distinct recipient) as unique_recipients
  from {{ source('email_deliveries', 'deliveries') }}
  where sent_at is not null
  {% if is_incremental() %}
    and sent_at >= (select max(delivery_date) - interval '7 days' from {{ this }})
  {% endif %}
  group by 1, 2, 3
)

select
  delivery_date,
  template_name,
  delivery_type,
  total_sent,
  delivered_count,
  bounced_count,
  failed_count,
  opened_count,
  clicked_count,
  unique_recipients,
  round(100.0 * delivered_count / nullif(total_sent, 0), 2) as delivery_rate_pct,
  round(100.0 * bounced_count / nullif(total_sent, 0), 2) as bounce_rate_pct,
  round(100.0 * opened_count / nullif(delivered_count, 0), 2) as open_rate_pct,
  round(100.0 * clicked_count / nullif(opened_count, 0), 2) as click_through_rate_pct
from daily_metrics
