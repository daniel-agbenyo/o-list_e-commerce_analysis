--Data Cleaning

INSERT INTO product_category_translation VALUES
('pc_gamer', 'pc_gamer'),
('portateis_cozinha_e_preparadores_de_alimentos', 'portable_kitchen_and_food_preparers');

alter table orders alter column customer_id drop not null;
alter table orders alter column order_purchase_timestamp drop not null;
alter table orders alter column order_estimated_delivery_date drop not null;

alter table order_items 	
	alter column product_id drop not null,
	alter column product_id drop not null,
	alter column seller_id drop not null,
	alter column price drop not null,
	alter column freight_value drop not null;

alter table order_review alter column review_creation_date drop not null;

create index idx_review_id on order_review(review_id);
create index idx_order_id on order_review(order_id);

alter table products drop column product_description_lenght;
alter table products drop column product_lenght_cm;
alter table products drop column product_height_cm;
alter table products drop column product_width_cm;
alter table products drop column product_length_cm;

alter table customers drop column customer_zip_code_prefix;

alter table order_review drop column review_comment_message;
alter table order_review drop column review_comment_title;

alter table sellers drop column seller_zip_code_prefix;



-- Growth and aquisition
-- Total number of  active customers
select 
	count(distinct c.customer_unique_id) total_active_customers
from customers c;
	

-- Total number of active custumers by year
select
	extract(year from o.order_purchase_timestamp) years, 
	count(distinct c.customer_unique_id) number_of_customers
from customers c 
join orders o on o.customer_id = c.customer_id
group by years;

-- Cumulative quaterly breakdown of active customers
with customer_grain as(
select 
	c.customer_unique_id unique_customers,
	o.order_purchase_timestamp purchase_date
from customers c
join orders o on c.customer_id = o.customer_id
),
first_orders as(
select 
	cg.unique_customers,
	min(cg.purchase_date) first_purchase
from customer_grain cg
group by cg.unique_customers 
)
select 
	extract(year from fo.first_purchase) years,
	extract(quarter from fo.first_purchase) quarters,
	count(*) active_customers,
	sum(count(*)) over(order by extract(year from fo.first_purchase), 
								extract(quarter from fo.first_purchase)) 
								cumulative
from first_orders fo
where fo.first_purchase >= '2017-01-01' and 
fo.first_purchase < '2018-08-01'
group by 1,2
order by 1,2;

--- New customers by quarter and state
with customer_grain as(
select 
	c.customer_unique_id unique_customers,
	o.order_purchase_timestamp purchase_date,
	c.customer_state state,
	row_number() over(
            partition by c.customer_unique_id
            order by o.order_purchase_timestamp
        ) rn
from customers c
join orders o on c.customer_id = o.customer_id
),
first_order as(
select 
	cg.unique_customers,
	cg.purchase_date first_purchase,
	cg.state 
from customer_grain cg
where cg.rn = 1
)
select 
	extract(year from fo.first_purchase) years,
	extract(quarter from fo.first_purchase) quarters,
	count(*) new_customers,
	fo.state
from first_order fo 
where fo.first_purchase >=  '2017-01-01' and 
fo.first_purchase < '2018-08-01'
group by years, quarters, state
order by years, quarters, new_customers desc;

-- Returning customers by year and quater
-- returning customers are customers who 
--purchase items in two shopping setions spanning 24hrs
with orders_seq as(
select 
	c.customer_unique_id, 
	o.order_purchase_timestamp purchase_date,
	lag(o.order_purchase_timestamp) over(partition by c.customer_unique_id
										 order by o.order_purchase_timestamp)
										 prev_purchase,
	lag(c.customer_unique_id)over(partition by c.customer_unique_id
								  order by o.order_purchase_timestamp)
								  prev_customer
from customers c 
join orders o on c.customer_id = o.customer_id
),
customer_summary as (
select
	customer_unique_id,
	min(purchase_date) first_purchase,
	max(case
		when prev_purchase is not null
		and purchase_date - prev_purchase > interval '24 hours'
		then 1 else 0
		end) is_repeat
from orders_seq
group by customer_unique_id
)
select
    extract(year from first_purchase) as years,
    extract(quarter from first_purchase) as quarters,
    count(*) as customers,
    sum(is_repeat) as repeat_customers,
    round(100.0 * sum(is_repeat) / count(*), 2) as repeat_rate_pct
from customer_summary
where  first_purchase::date >= '2017-01-01'
	   and first_purchase::date < '2018-10-01'
group by 1, 2
order by 1, 2;

-- Delivery Perfomance
--Distribution of orders per delivery duration
select
    order_delivered_customer_date::date - order_estimated_delivery_date::date actual_vs_estimate,
    count(*) orders
from orders
where order_status = 'delivered'
  and order_delivered_customer_date is not null
group by 1
order by 1;


--Comparitive look at late and early deliveries
with order_metrics as(
select 
	(order_delivered_customer_date::date > order_estimated_delivery_date::date) late_delivey_orders,
	(order_delivered_customer_date::date - order_estimated_delivery_date::date) acctual_delivery_duration,
	(order_delivered_customer_date::date <= order_estimated_delivery_date::date) early_delivery_orders
from orders
where order_status = 'delivered'
  and order_delivered_customer_date is not null
)
select
    count(*) as delivered_orders,
    count(*) filter (where late_delivey_orders) late_orders,
    round(100.0 * count(*) filter (where late_delivey_orders) / count(*), 2) late_rate_pct,
    round(avg(acctual_delivery_duration) filter (where late_delivey_orders), 1) avg_late_delivery_days,
    percentile_cont(0.5) within group (order by acctual_delivery_duration) filter (where late_delivey_orders) median_late_delivery_days,
	round(avg(acctual_delivery_duration) filter (where early_delivery_orders), 1) avg_early_deliivery_days
from order_metrics; 


--Delivery bin per Order Volume
with delivery as (
    select
        order_id,
        order_delivered_customer_date::date
          - order_estimated_delivery_date::date as days_vs_estimate
    from orders
    where order_status = 'delivered'
      and order_delivered_customer_date is not null
)
select
    case
        when days_vs_estimate <= -15 then '15+ days early'
        when days_vs_estimate <=  -8 then '8-14 days early'
        when days_vs_estimate <=  -1 then '1-7 days early'
        when days_vs_estimate =    0 then 'On time'
        when days_vs_estimate <=   7 then '1-7 days late'
        when days_vs_estimate <=  14 then '8-14 days late'
        else '15+ days late'
    end as delivery_bin,
    count(*) as orders,
    round(100.0 * count(*) / sum(count(*)) over (), 2) as pct_of_orders
from delivery
group by 1
order by min(days_vs_estimate);


--Delivery duration per Customer Sate
select
    c.customer_state,
    count(*) as delivered_orders,
    count(*) filter (
        where o.order_delivered_customer_date::date > o.order_estimated_delivery_date::date
    ) as late_orders,
    round(100.0 * count(*) filter (
        where o.order_delivered_customer_date::date > o.order_estimated_delivery_date::date
    ) / count(*), 2) as late_rate_pct,
    round(avg(
        o.order_delivered_customer_date::date - o.order_purchase_timestamp::date
    ), 1) as avg_delivery_days
from orders o
join customers c on c.customer_id = o.customer_id
where o.order_status = 'delivered'
  and o.order_delivered_customer_date is not null
group by c.customer_state
having count(*) >= 100
order by late_rate_pct desc;


--Investigating if increament in deliveries during Black Friday and Christmas Promo
--season worsens delivery delays
select 
	order_purchase_timestamp::date dates,
	extract(days from o.order_delivered_customer_date)-
	(extract(days from o.order_purchase_timestamp)) actual_delivery_duration,
	count(*) filter (
        where o.order_delivered_customer_date::date > o.order_estimated_delivery_date::date
    ) as late_orders
from orders o 
where order_purchase_timestamp >= '2017-11-01' and 
	  order_purchase_timestamp <= '2017-12-31'
group by 1,2
order by 1,2;


--Revenue and Product mix

--Revebue per Category
with item_revenue as (
    select
        coalesce(t.product_category_name_english, 'unknown') as category,
        oi.order_id,
        oi.price
    from order_items oi
    join products p on p.product_id = oi.product_id
    left join product_category_translation t
           on t.product_category_name = p.product_category_name
    join orders o on o.order_id = oi.order_id
    where o.order_status = 'delivered'
)
select
    category,
    round(sum(price), 2)     as revenue,
    round(100.0 * sum(price) / sum(sum(price)) over (), 2) as revenue_share_pct
from item_revenue
group by category
order by revenue desc;


-- Average price of items per Category
with item_revenue as (
    select
        coalesce(t.product_category_name_english, 'unknown') as category,
        oi.order_id,
        oi.price
    from order_items oi
    join products p on p.product_id = oi.product_id
    left join product_category_translation t
           on t.product_category_name = p.product_category_name
    join orders o on o.order_id = oi.order_id
    where o.order_status = 'delivered'
)
select
    category,
    round(avg(price), 2)     as avg_item_price
from item_revenue
group by category
order by avg_item_price desc;



--Category per Items ordered
with item_revenue as (
    select
        coalesce(t.product_category_name_english, 'unknown') as category,
        oi.order_id,
        oi.price
    from order_items oi
    join products p on p.product_id = oi.product_id
    left join product_category_translation t
           on t.product_category_name = p.product_category_name
    join orders o on o.order_id = oi.order_id
    where o.order_status = 'delivered'
)
select
    category,
    count(*)                 as items
from item_revenue
group by category
order by items desc;


--Price distribution by Category
with item_prices as (
    select
        coalesce(t.product_category_name_english, 'unknown') as category,
        oi.price
    from order_items oi
    join products p on p.product_id = oi.product_id
    left join product_category_translation t
           on t.product_category_name = p.product_category_name
    join orders o on o.order_id = oi.order_id
    where o.order_status = 'delivered'
)
select
    category,
    count(*) as items,
    round(avg(price), 2) as avg_price,
    round(percentile_cont(0.50) within group (order by price)::numeric, 2) as median_price,
    round(min(price), 2) as min_price,
    round(max(price), 2) as max_price,
    round(stddev_samp(price), 2) as std_dev
from item_prices
group by category
having count(*) >= 30
order by items desc;


-- checking for duplicates 
select count(*) n_rows,
	(select count(*) from (select distinct * from geolocation)d ) distinct_rows
from geolocation;

-- cehcking for null or empty values
select
	count(*) total_orders,
	count(*) filter(where order_status is null) null_status,
	count(*) filter(where order_purchase_timestamp is null) null_purchase,
	count(*) filter(where order_approved_at is null) null_approved,
	count(*) filter(where order_delivered_carrier_date is null) null_carrier,
	count(*) filter(where order_delivered_customer_date is null) null_customer,
	count(*) filter(where order_estimated_delivery_date is null) null_estimated
from 
	orders;

-- products categories for checking for null or empty values
select 
	count(*) total_products,
	count(*) filter(where product_category_name = 'unknown') null_english
from 
	products;
	
-- 

select * from customers c;

select 
	count(*) total_customers,
	count(distinct(customer_id)) distinct_c
from customers c;

select 
	distinct(customer_city) distinct_cc
from customers c;

select 
	count(distinct(customer_zip_code_prefix)) distinct_zc
from customers c;

-- Descriptive Statisctics(Profiling)





-- Top 5 customer cities 
select 
	customer_city city,
	customer_state state,
	count(*) customer_count
from customers c
group by city, state 
order by customer_count desc
limit 5;



