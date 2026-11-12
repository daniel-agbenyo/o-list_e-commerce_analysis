
CREATE TABLE product_category_translation(
product_category_name varchar PRIMARY KEY,
product_category_name_english varchar UNIQUE
);

CREATE TABLE sellers(
seller_id char(32) PRIMARY KEY,
seller_zip_code_prefix char(5),
seller_city varchar,
seller_state char(2) 
);

CREATE TABLE products(
product_id char(32) PRIMARY KEY,
product_category_name varchar,
product_name_lenght int,
product_description_lenght int,
product_photos_qty int,
product_weight_g int,
product_lenght_cm int,
product_height_cm int,
product_width_cm int,
FOREIGN KEY (product_category_name) REFERENCES product_category_translation(product_category_name)
);

CREATE TABLE customers(
customer_id char(32) PRIMARY KEY,
customer_unique_id char(32) NOT NULL,
customer_zip_code_prefix char(5) NOT NULL,
customer_city varchar NOT NULL,
customer_state char(2) NOT NULL 
);


CREATE table orders(
order_id char(32) PRIMARY KEY,
customer_id char(32) NOT NULL,
order_status varchar,
order_purchase_timestamp timestamp NOT NULL,
order_approved_at timestamp,
order_delivered_carrier_date timestamp,
order_delivered_customer_date timestamp,
order_estimated_delivery_date date NOT NULL,
FOREIGN KEY (customer_id) REFERENCES customers(customer_id)
);

CREATE TABLE order_items(
order_id char(32),
order_item_id SMALLINT NOT NULL,
product_id char(32) NOT NULL,
seller_id char(32) NOT NULL,
shipping_limit_date timestamp,
price numeric(10,2) NOT NULL,
freight_value numeric(10,2) NOT NULL,
PRIMARY KEY (order_id, order_item_id),
FOREIGN KEY (order_id) REFERENCES orders(order_id),
FOREIGN KEY (product_id) REFERENCES products(product_id),
FOREIGN KEY (seller_id) REFERENCES sellers(seller_id)
);

CREATE TABLE order_payments(
order_id char(32),
payment_sequential SMALLINT NOT NULL,
payment_type varchar,
payment_installments SMALLINT NOT NULL,
payment_value numeric(10,2),
PRIMARY KEY (order_id, payment_sequential),
FOREIGN KEY (order_id) REFERENCES orders(order_id)
);

CREATE TABLE order_review(
review_id char(32),
order_id char(32) NOT NULL,
review_score SMALLINT,
review_comment_title varchar,
review_comment_message varchar,
review_creation_date timestamp NOT NULL,
review_answer_timestamp timestamp not null,
PRIMARY KEY (review_id, order_id),
FOREIGN KEY (order_id) REFERENCES orders(order_id)
);
