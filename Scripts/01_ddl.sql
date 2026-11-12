/* =====================================================================
   TDI SQL DATA ANALYSIS CAPSTONE
   Olist Brazilian E-Commerce Public Dataset  |  PostgreSQL
   -----------------------------------------------------------------
   01_ddl.sql   Schema definition
   Author: Daniel Ragbenyo
   -----------------------------------------------------------------
   Pattern: raw CSVs land in the `staging` schema with no constraints,
   then 03_cleaning.sql transforms them into constrained tables in
   `olist`. Loading straight into constrained tables fails on this
   dataset, and staging is what lets the cleaning be visible in SQL
   rather than hidden in a spreadsheet.

   Run order:  01_ddl -> 02_load -> 03_cleaning -> 04_analysis
   ===================================================================== */

DROP SCHEMA IF EXISTS staging CASCADE;
DROP SCHEMA IF EXISTS olist   CASCADE;

CREATE SCHEMA staging;
CREATE SCHEMA olist;

SET search_path = olist, staging, public;


/* =====================================================================
   HELPER — olist.norm_city()
   -----------------------------------------------------------------
   City names are spelled inconsistently in all three tables that carry
   them. This canonicalises a name for grouping and joining.

   Decomposes to NFD, strips combining diacritics by codepoint range,
   folds the four apostrophe variants to a space, then collapses
   whitespace. Doing it by codepoint range rather than a translate()
   mapping table matters: one row in the sellers file stores 'são paulo'
   in decomposed form ('s','a',U+0303,'o') while every other accented
   string in the dataset is precomposed. A mapping table silently misses
   it and splits São Paulo into two groups. See 03a_city_audit.sql §A.

   Requires PostgreSQL 13+ for normalize().
   ===================================================================== */
CREATE OR REPLACE FUNCTION olist.norm_city(txt text)
RETURNS text AS $$
    SELECT regexp_replace(                            -- 4. collapse whitespace runs
             btrim(
               translate(                             -- 3. fold apostrophe variants
                 regexp_replace(                      -- 2. strip combining diacritics
                   normalize(lower(btrim($1)), NFD),  -- 1. decompose accents
                   '[̀-ͯ]', '', 'g'),
                 '´`''’', '    '
               )
             ),
             '\s+', ' ', 'g')
$$ LANGUAGE sql IMMUTABLE;


/* =====================================================================
   PART 1 — STAGING TABLES
   Column names mirror the CSV headers exactly, including the typos that
   are genuinely present in the source ("lenght"). No keys, no NOT NULL,
   no foreign keys: staging must accept whatever the file contains so
   that a bad row surfaces as a cleaning decision rather than a failed
   import.
   ===================================================================== */

CREATE TABLE staging.product_category_name_translation (
    product_category_name          text,
    product_category_name_english  text
);

CREATE TABLE staging.sellers (
    seller_id              text,
    seller_zip_code_prefix text,
    seller_city            text,
    seller_state           text
);

CREATE TABLE staging.products (
    product_id                  text,
    product_category_name       text,
    product_name_lenght         integer,   -- typo is in the source file
    product_description_lenght  integer,   -- typo is in the source file
    product_photos_qty          integer,
    product_weight_g            integer,
    product_length_cm           integer,
    product_height_cm           integer,
    product_width_cm            integer
);

CREATE TABLE staging.customers (
    customer_id              text,
    customer_unique_id       text,
    customer_zip_code_prefix text,
    customer_city            text,
    customer_state           text
);

/* 1,000,163 rows over only 19,015 distinct zip prefixes.
   No key of any kind here — see the note in 03_cleaning.sql. */
CREATE TABLE staging.geolocation (
    geolocation_zip_code_prefix text,
    geolocation_lat             double precision,
    geolocation_lng             double precision,
    geolocation_city            text,
    geolocation_state           text
);

CREATE TABLE staging.orders (
    order_id                      text,
    customer_id                   text,
    order_status                  text,
    order_purchase_timestamp      timestamp,
    order_approved_at             timestamp,
    order_delivered_carrier_date  timestamp,
    order_delivered_customer_date timestamp,
    order_estimated_delivery_date timestamp
);

CREATE TABLE staging.order_items (
    order_id            text,
    order_item_id       smallint,
    product_id          text,
    seller_id           text,
    shipping_limit_date timestamp,
    price               numeric(10,2),
    freight_value       numeric(10,2)
);

CREATE TABLE staging.order_payments (
    order_id             text,
    payment_sequential   smallint,
    payment_type         text,
    payment_installments smallint,
    payment_value        numeric(10,2)
);

/* The comment fields contain embedded newlines, so this file has
   104,719 physical lines but only 99,224 records. 02_load.sql asserts
   the record count after loading. */
CREATE TABLE staging.order_reviews (
    review_id               text,
    order_id                text,
    review_score            smallint,
    review_comment_title    text,
    review_comment_message  text,
    review_creation_date    timestamp,
    review_answer_timestamp timestamp
);


/* =====================================================================
   PART 2 — CLEAN TABLES
   Constrained, typed, documented. Populated by 03_cleaning.sql.
   Created in dependency order so the foreign keys resolve.
   ===================================================================== */

/* ---------------------------------------------------------------
   product_categories
   Source file has 71 rows. Two categories used by products are
   missing from it (pc_gamer, portateis_cozinha_e_preparadores_de_
   alimentos) and 609 products have no category at all, so an
   'unknown' member is added. Final row count: 74.
   --------------------------------------------------------------- */
CREATE TABLE olist.product_categories (
    category_name          text PRIMARY KEY,
    category_name_english  text NOT NULL
);

/* ---------------------------------------------------------------
   geolocation
   One row per zip prefix — the whole point of the cleaning step.
   The raw table is a point cloud (median 23 GPS pings per prefix,
   max 779); joining orders to it directly would multiply row
   counts and inflate every revenue total.
   --------------------------------------------------------------- */
CREATE TABLE olist.geolocation (
    zip_code_prefix char(5) PRIMARY KEY,
    latitude        double precision,   -- NULL where every point was an outlier
    longitude       double precision,
    city            text,
    state           char(2),
    point_count     integer NOT NULL,   -- raw points behind this row
    outlier_count   integer NOT NULL    -- points rejected as outside Brazil
);

CREATE TABLE olist.sellers (
    seller_id       char(32) PRIMARY KEY,
    zip_code_prefix char(5),
    city            text,
    state           char(2),
    CONSTRAINT sellers_state_len CHECK (char_length(state) = 2)
);

CREATE TABLE olist.products (
    product_id           char(32) PRIMARY KEY,
    category_name        text NOT NULL DEFAULT 'unknown',
    name_length          integer,
    description_length   integer,
    photos_qty           integer,
    weight_g             integer,
    length_cm            integer,
    height_cm            integer,
    width_cm             integer,
    volume_cm3           integer,        -- derived, NULL when any dimension is NULL
    CONSTRAINT products_category_fk
        FOREIGN KEY (category_name) REFERENCES olist.product_categories(category_name),
    CONSTRAINT products_weight_nonneg CHECK (weight_g IS NULL OR weight_g >= 0)
);

/* ---------------------------------------------------------------
   customers
   customer_id is unique per ORDER, not per person.
   customer_unique_id is the actual person: 99,441 customer_id
   values map to 96,096 customer_unique_id values.
   Every retention or repeat-purchase query must group by
   customer_unique_id.
   --------------------------------------------------------------- */
CREATE TABLE olist.customers (
    customer_id        char(32) PRIMARY KEY,
    customer_unique_id char(32) NOT NULL,
    zip_code_prefix    char(5)  NOT NULL,
    city               text     NOT NULL,
    state              char(2)  NOT NULL
);

CREATE INDEX ix_customers_unique_id ON olist.customers (customer_unique_id);
CREATE INDEX ix_customers_state     ON olist.customers (state);

CREATE TABLE olist.orders (
    order_id                      char(32) PRIMARY KEY,
    customer_id                   char(32) NOT NULL,
    order_status                  text     NOT NULL,
    order_purchase_timestamp      timestamp NOT NULL,
    order_approved_at             timestamp,          -- NULL on 160 orders
    order_delivered_carrier_date  timestamp,          -- NULL on 1,783 orders
    order_delivered_customer_date timestamp,          -- NULL on 2,965 orders
    order_estimated_delivery_date date NOT NULL,
    /* derived in 03_cleaning.sql, used heavily in 04_analysis.sql */
    delivery_days                 numeric(8,2),       -- purchase -> customer
    delivery_delay_days           numeric(8,2),       -- actual - estimated; negative = early
    is_late                       boolean,
    CONSTRAINT orders_customer_fk
        FOREIGN KEY (customer_id) REFERENCES olist.customers(customer_id),
    CONSTRAINT orders_status_chk CHECK (order_status IN
        ('delivered','shipped','canceled','unavailable',
         'invoiced','processing','created','approved'))
);

CREATE INDEX ix_orders_status   ON olist.orders (order_status);
CREATE INDEX ix_orders_purchase ON olist.orders (order_purchase_timestamp);
CREATE INDEX ix_orders_customer ON olist.orders (customer_id);

CREATE TABLE olist.order_items (
    order_id            char(32),
    order_item_id       smallint,
    product_id          char(32) NOT NULL,
    seller_id           char(32) NOT NULL,
    shipping_limit_date timestamp,
    price               numeric(10,2) NOT NULL,
    freight_value       numeric(10,2) NOT NULL,
    PRIMARY KEY (order_id, order_item_id),
    CONSTRAINT order_items_order_fk   FOREIGN KEY (order_id)   REFERENCES olist.orders(order_id),
    CONSTRAINT order_items_product_fk FOREIGN KEY (product_id) REFERENCES olist.products(product_id),
    CONSTRAINT order_items_seller_fk  FOREIGN KEY (seller_id)  REFERENCES olist.sellers(seller_id),
    CONSTRAINT order_items_price_chk   CHECK (price >= 0),
    CONSTRAINT order_items_freight_chk CHECK (freight_value >= 0)
);

CREATE INDEX ix_order_items_product ON olist.order_items (product_id);
CREATE INDEX ix_order_items_seller  ON olist.order_items (seller_id);

CREATE TABLE olist.order_payments (
    order_id             char(32),
    payment_sequential   smallint,
    payment_type         text NOT NULL,   -- 'not_defined' recoded to 'unknown'
    payment_installments smallint,
    payment_value        numeric(10,2),
    PRIMARY KEY (order_id, payment_sequential),
    CONSTRAINT order_payments_order_fk FOREIGN KEY (order_id) REFERENCES olist.orders(order_id),
    CONSTRAINT order_payments_type_chk CHECK (payment_type IN
        ('credit_card','boleto','voucher','debit_card','unknown'))
);

/* ---------------------------------------------------------------
   order_reviews
   789 review_id values appear more than once and 547 order_id
   values carry more than one review, so neither column alone can
   be the key. The composite (review_id, order_id) is unique.
   For a per-order score, aggregate with AVG(review_score).
   --------------------------------------------------------------- */
CREATE TABLE olist.order_reviews (
    review_id               char(32),
    order_id                char(32) NOT NULL,
    review_score            smallint NOT NULL,
    review_comment_title    text,
    review_comment_message  text,
    has_comment             boolean NOT NULL,   -- derived
    review_creation_date    timestamp NOT NULL,
    review_answer_timestamp timestamp,
    response_hours          numeric(10,2),      -- derived
    PRIMARY KEY (review_id, order_id),
    CONSTRAINT order_reviews_order_fk FOREIGN KEY (order_id) REFERENCES olist.orders(order_id),
    CONSTRAINT order_reviews_score_chk CHECK (review_score BETWEEN 1 AND 5)
);

CREATE INDEX ix_order_reviews_order ON olist.order_reviews (order_id);
CREATE INDEX ix_order_reviews_score ON olist.order_reviews (review_score);
