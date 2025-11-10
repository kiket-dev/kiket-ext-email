with template_stats as (
  select
    template_name,
    count(*) as total_sent,
    count(case when status = 'delivered' then 1 end) as delivered,
    count(case when opened_at is not null then 1 end) as opened,
    count(case when clicked_at is not null then 1 end) as clicked,
    count(case when status = 'bounced' then 1 end) as bounced,
    count(case when status = 'failed' then 1 end) as failed,
    avg(case
      when delivered_at is not null and sent_at is not null
      then extract(epoch from (delivered_at - sent_at)) / 60
    end) as avg_delivery_time_minutes,
    max(sent_at) as last_sent_at
  from {{ source('email_deliveries', 'deliveries') }}
  where template_name is not null
  group by 1
)

select
  template_name,
  total_sent,
  delivered,
  opened,
  clicked,
  bounced,
  failed,
  round(cast(avg_delivery_time_minutes as numeric), 2) as avg_delivery_time_minutes,
  round(100.0 * delivered / nullif(total_sent, 0), 2) as delivery_rate_pct,
  round(100.0 * opened / nullif(delivered, 0), 2) as open_rate_pct,
  round(100.0 * clicked / nullif(opened, 0), 2) as click_through_rate_pct,
  round(100.0 * bounced / nullif(total_sent, 0), 2) as bounce_rate_pct,
  last_sent_at
from template_stats
order by total_sent desc
