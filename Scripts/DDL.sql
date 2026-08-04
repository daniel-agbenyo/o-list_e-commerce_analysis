create table olist_customers_table(
customer_id varchar(100),
customer_unique_id varchar(100),
customer_zip_code_prefix integer,
customer_city varchar(50),
customer_state varchar(2)
)

create table olist_geolocation_table(
geolocation_zip_code_prefix int,
golocation_lat int,
geolocation_lng int,
geolocation_city varchar(50),
geolocation_state varchar(2)
)

create table olist_order_items_table(
order_id,
order_item_id,
product_id,
seller_id,
shipping_limit_date,
price,
freight_value
)

create table olist_order_payments_table(
order_id,
payment_sequential,
payment_type,
payment_installments,
payment_value
)

create table olist_order_review_table(
review_id,
order_id,
review_score,
review_comment_title,
review_comment_message,
review_creation_date
)

create table olist_order_table(
order_id,
customer_id,
order_status,
order_purchase_timestamp,
order_approved_at,
order_delivered_carrier_date,
order_delivered_customer_date,
order_estimated_delivry_date
)

create table olist_products_table(
product_id,
product_category_name,
product_name_lenght,
product_description_lenght,
product_photo_qty,
product_weight_g,
product_lenght_cm,
product_height_cm,
product_width_cm
)

create table olist_seller_table(
seller_id,
seller_zip_code_prefix,
seller_city,
seller_sate
)

create table product_category_name_translation_table(
product_category_name,
product_category_name_english
)



