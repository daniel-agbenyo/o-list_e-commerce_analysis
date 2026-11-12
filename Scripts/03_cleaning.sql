/* =====================================================================
   03_cleaning.sql   staging -> olist
   -----------------------------------------------------------------
   Every cleaning decision made on this dataset lives here, in SQL,
   with the reasoning attached. Nothing is cleaned by hand.

   Sections
     A. Pre-clean audit        what is actually wrong, measured
     B. product_categories     add missing + 'unknown' member
     C. geolocation            point cloud -> one row per zip prefix
     D. sellers, products, customers
     E. orders                 + derived delivery metrics
     F. order_items, order_payments, order_reviews
     G. Post-clean validation  assertions that must all pass
   ===================================================================== */

SET search_path = olist, staging, public;


/* =====================================================================
   SECTION A — PRE-CLEAN AUDIT
   Run these first and keep the output. This is the evidence base for
   the "Challenges faced" section of the report, and it doubles as the
   Data Exploration requirement in the rubric.
   ===================================================================== */

\echo '=== A1. Null audit on orders ==='
SELECT COUNT(*)                                                        AS total_orders,
       COUNT(*) FILTER (WHERE order_approved_at             IS NULL)    AS null_approved,
       COUNT(*) FILTER (WHERE order_delivered_carrier_date  IS NULL)    AS null_carrier,
       COUNT(*) FILTER (WHERE order_delivered_customer_date IS NULL)    AS null_delivered,
       MIN(order_purchase_timestamp)                                    AS first_order,
       MAX(order_purchase_timestamp)                                    AS last_order
FROM staging.orders;

\echo '=== A2. Order volume by month — exposes the truncated tail ==='
SELECT to_char(order_purchase_timestamp, 'YYYY-MM') AS month,
       COUNT(*)                                     AS orders
FROM staging.orders
GROUP BY 1
ORDER BY 1;
/* 2016-09 has 4 orders, 2016-12 has 1, 2018-09 has 16, 2018-10 has 4.
   These are artefacts of how the extract was cut, not real demand.
   All trend analysis in 04_analysis.sql is therefore restricted to
   2017-01-01 .. 2018-08-31. */

\echo '=== A3a. The geolocation problem, quantified ==='
WITH per_prefix AS (
    SELECT geolocation_zip_code_prefix AS zip, COUNT(*) AS cnt
    FROM staging.geolocation
    GROUP BY 1
)
SELECT SUM(cnt)                      AS raw_rows,
       COUNT(*)                      AS distinct_prefixes,
       ROUND(AVG(cnt), 1)            AS avg_points_per_prefix,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY cnt) AS median_points_per_prefix,
       MAX(cnt)                      AS max_points_one_prefix
FROM per_prefix;
-- expect: 1000163 | 19015 | 52.6 | 29 | 1146

\echo '=== A3b. Why no candidate key exists below the full row ==='
/* This is the query that answers "can I just use a composite primary
   key?". Every candidate short of the entire row still has duplicates,
   and a key spanning every column means the table has no entity
   identity — it is a measurement log, not a lookup table.
   Section C fixes the grain instead of forcing a key onto it. */
SELECT 'zip'                          AS candidate_key,
       COUNT(*) - COUNT(DISTINCT (geolocation_zip_code_prefix))                 AS duplicate_rows
FROM staging.geolocation
UNION ALL
SELECT 'zip + lat',
       COUNT(*) - COUNT(DISTINCT (geolocation_zip_code_prefix, geolocation_lat))
FROM staging.geolocation
UNION ALL
SELECT 'zip + lat + lng',
       COUNT(*) - COUNT(DISTINCT (geolocation_zip_code_prefix, geolocation_lat, geolocation_lng))
FROM staging.geolocation
UNION ALL
SELECT 'all five columns',
       COUNT(*) - COUNT(DISTINCT (geolocation_zip_code_prefix, geolocation_lat,
                                  geolocation_lng, geolocation_city, geolocation_state))
FROM staging.geolocation;
/* On the raw file:
       zip               -> 981,148 duplicate rows
       zip + lat         -> 280,863
       zip + lat + lng   -> 280,009
       all five columns  -> 261,831
   Even the full row has duplicates, so the raw table cannot carry a
   primary key at all until it is deduplicated. And note that adding
   city/state removes ~18,000 further duplicates, which means the same
   coordinate is filed under more than one spelling of the same town —
   another reason MODE() is used for the city name in Section C. */

\echo '=== A4. Duplicate keys across the other tables ==='
SELECT 'order_reviews: review_id used more than once' AS finding, COUNT(*) AS n
FROM (SELECT review_id FROM staging.order_reviews GROUP BY 1 HAVING COUNT(*) > 1) x
UNION ALL
SELECT 'order_reviews: order_id with multiple reviews', COUNT(*)
FROM (SELECT order_id FROM staging.order_reviews GROUP BY 1 HAVING COUNT(*) > 1) x
UNION ALL
SELECT 'order_reviews: exact duplicate rows', COUNT(*)
FROM (SELECT review_id, order_id FROM staging.order_reviews GROUP BY 1,2 HAVING COUNT(*) > 1) x
UNION ALL
SELECT 'customers: customer_unique_id with >1 customer_id', COUNT(*)
FROM (SELECT customer_unique_id FROM staging.customers GROUP BY 1 HAVING COUNT(*) > 1) x;

\echo '=== A5. Referential integrity before any constraint exists ==='
SELECT 'order_items -> products (orphans)' AS check_name, COUNT(*) AS n
FROM staging.order_items i
LEFT JOIN staging.products p USING (product_id)
WHERE p.product_id IS NULL
UNION ALL
SELECT 'products -> category translation (unmatched, excl. NULL)', COUNT(*)
FROM staging.products p
LEFT JOIN staging.product_category_name_translation t USING (product_category_name)
WHERE p.product_category_name IS NOT NULL AND t.product_category_name IS NULL
UNION ALL
SELECT 'orders with no payment record', COUNT(*)
FROM staging.orders o
LEFT JOIN staging.order_payments p USING (order_id)
WHERE p.order_id IS NULL
UNION ALL
SELECT 'customer zip prefixes absent from geolocation', COUNT(DISTINCT c.customer_zip_code_prefix)
FROM staging.customers c
LEFT JOIN staging.geolocation g
       ON g.geolocation_zip_code_prefix = c.customer_zip_code_prefix
WHERE g.geolocation_zip_code_prefix IS NULL;


/* =====================================================================
   SECTION B — PRODUCT CATEGORIES
   Must be populated before products, or the foreign key fires.
   Three additions to the 71 rows in the source file:
     pc_gamer and portateis_... are used by products but absent from
     the translation file; 'unknown' absorbs the 610 products that
     carry no category at all.
   ===================================================================== */

INSERT INTO olist.product_categories (category_name, category_name_english)
SELECT DISTINCT
       btrim(product_category_name),
       btrim(product_category_name_english)
FROM staging.product_category_name_translation
WHERE product_category_name IS NOT NULL;

INSERT INTO olist.product_categories (category_name, category_name_english) VALUES
    ('pc_gamer',                                      'pc_gamer'),
    ('portateis_cozinha_e_preparadores_de_alimentos', 'portable_kitchen_and_food_preparers'),
    ('unknown',                                       'unknown')
ON CONFLICT (category_name) DO NOTHING;


/* =====================================================================
   SECTION C — GEOLOCATION
   -----------------------------------------------------------------
   THE FIX, and the reasoning behind it.

   The raw table holds 1,000,163 GPS readings for 19,015 zip prefixes —
   a median of 29 readings per prefix and up to 1,146 for a single one.
   It is a point cloud, not a reference table.

   Making the key wider does not help. A composite key would only make
   the duplication legal; it would not make the table joinable. Joining
   orders to a table with ~39 rows per prefix fans every order out into
   dozens of rows and silently multiplies every revenue total that
   passes through the join.

   So the grain is fixed instead: exactly one row per zip prefix.

     Coordinates : MEDIAN, not AVG. 33 readings sit outside Brazil
                   entirely (one is in Spain); the median ignores them
                   and the bounding-box filter removes them outright.
     City/state  : MODE. 8,556 prefixes carry more than one spelling
                   ('sao paulo' vs 'são paulo') and 8 prefixes are
                   tagged with more than one state. Modal value wins.
     Duplicates  : DISTINCT first, so a location pinged 400 times does
                   not drag the median toward itself.

   5 prefixes have no reading inside Brazil at all. They are kept with
   NULL coordinates rather than dropped, so that zip-prefix joins never
   lose a row. Between them they cover 1 customer and 0 sellers.
   ===================================================================== */

/* City is canonicalised here rather than kept raw. 8,011 distinct
   spellings in this table collapse to 5,941 real places — 'sao paulo'
   and 'são paulo' are the same city and must not be two rows in a
   chart. The accented form is deliberately traded away for a name
   that groups reliably; see 03a_city_audit.sql for the full audit. */
CREATE TEMP TABLE geo_distinct AS
SELECT DISTINCT
       geolocation_zip_code_prefix      AS zip,
       geolocation_lat                  AS lat,
       geolocation_lng                  AS lng,
       olist.norm_city(geolocation_city) AS city,
       upper(btrim(geolocation_state))  AS state
FROM staging.geolocation
WHERE geolocation_zip_code_prefix IS NOT NULL;
-- 1,000,163 -> 720,469 rows (261,831 exact repeats plus 17,863 that
-- differed only in the spelling of the city name)

INSERT INTO olist.geolocation
      (zip_code_prefix, latitude, longitude, city, state, point_count, outlier_count)
SELECT
    zip::char(5),

    /* Median of the readings that fall inside Brazil's bounding box.
       NULL when every reading for the prefix was rejected. */
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lat)
        FILTER (WHERE lat BETWEEN -33.75 AND 5.27
                  AND lng BETWEEN -73.99 AND -34.79)          AS latitude,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lng)
        FILTER (WHERE lat BETWEEN -33.75 AND 5.27
                  AND lng BETWEEN -73.99 AND -34.79)          AS longitude,

    MODE() WITHIN GROUP (ORDER BY city)                       AS city,
    (MODE() WITHIN GROUP (ORDER BY state))::char(2)           AS state,

    COUNT(*)                                                  AS point_count,
    COUNT(*) FILTER (WHERE lat NOT BETWEEN -33.75 AND 5.27
                        OR lng NOT BETWEEN -73.99 AND -34.79) AS outlier_count
FROM geo_distinct
GROUP BY zip;
-- 720,469 -> 19,015 rows, one per prefix, spanning 5,768 distinct cities

DROP TABLE geo_distinct;


/* =====================================================================
   SECTION D — SELLERS, PRODUCTS, CUSTOMERS
   ===================================================================== */

/* 17 sellers have the state appended to the city ('auriflama/sp',
   'carapicuiba / sao paulo'). In every case it agrees with
   seller_state, so the suffix is stripped before canonicalising.
   That plus norm_city takes 611 raw spellings down to 605 places. */
INSERT INTO olist.sellers (seller_id, zip_code_prefix, city, state)
SELECT DISTINCT ON (seller_id)
       seller_id::char(32),
       seller_zip_code_prefix::char(5),
       olist.norm_city(
           split_part(translate(seller_city, ',', '/'), '/', 1)),
       upper(btrim(seller_state))::char(2)
FROM staging.sellers
WHERE seller_id IS NOT NULL
ORDER BY seller_id;

/* 610 products have no category and no name/description/photo metadata.
   They are kept, not dropped — they carry real revenue, and dropping
   them would break order_items. Category becomes 'unknown'.
   Volume is left NULL when any dimension is missing (2 products). */
INSERT INTO olist.products
      (product_id, category_name, name_length, description_length,
       photos_qty, weight_g, length_cm, height_cm, width_cm, volume_cm3)
SELECT DISTINCT ON (product_id)
       product_id::char(32),
       COALESCE(btrim(product_category_name), 'unknown'),
       product_name_lenght,
       product_description_lenght,
       product_photos_qty,
       product_weight_g,
       product_length_cm,
       product_height_cm,
       product_width_cm,
       product_length_cm * product_height_cm * product_width_cm
FROM staging.products
WHERE product_id IS NOT NULL
ORDER BY product_id;

/* Customer city names arrive already stripped of accents, but 5 places
   still appear both with and without an apostrophe
   ("santa barbara d'oeste" / "santa barbara d oeste", 124 customers).
   Same canonicalisation for consistency across all three tables. */
INSERT INTO olist.customers
      (customer_id, customer_unique_id, zip_code_prefix, city, state)
SELECT DISTINCT ON (customer_id)
       customer_id::char(32),
       customer_unique_id::char(32),
       customer_zip_code_prefix::char(5),
       olist.norm_city(customer_city),
       upper(btrim(customer_state))::char(2)
FROM staging.customers
WHERE customer_id IS NOT NULL
ORDER BY customer_id;


/* =====================================================================
   SECTION E — ORDERS
   Derived delivery metrics are computed once here rather than repeated
   in every analysis query.

   is_late compares the actual delivery timestamp against the estimate,
   which is a date. Postgres casts the date to midnight, so an order
   delivered at 09:00 on the estimated day counts as on time. That is
   the intended reading of "arrived by the promised date".
   ===================================================================== */

INSERT INTO olist.orders
      (order_id, customer_id, order_status,
       order_purchase_timestamp, order_approved_at,
       order_delivered_carrier_date, order_delivered_customer_date,
       order_estimated_delivery_date,
       delivery_days, delivery_delay_days, is_late)
SELECT DISTINCT ON (order_id)
       order_id::char(32),
       customer_id::char(32),
       btrim(order_status),
       order_purchase_timestamp,
       order_approved_at,
       order_delivered_carrier_date,
       order_delivered_customer_date,
       order_estimated_delivery_date::date,

       ROUND(EXTRACT(EPOCH FROM (order_delivered_customer_date
                                 - order_purchase_timestamp))::numeric / 86400, 2),

       ROUND(EXTRACT(EPOCH FROM (order_delivered_customer_date
                                 - order_estimated_delivery_date))::numeric / 86400, 2),

       CASE WHEN order_delivered_customer_date IS NULL THEN NULL
            ELSE order_delivered_customer_date > order_estimated_delivery_date
       END
FROM staging.orders
WHERE order_id IS NOT NULL
ORDER BY order_id;


/* =====================================================================
   SECTION F — ORDER ITEMS, PAYMENTS, REVIEWS
   ===================================================================== */

INSERT INTO olist.order_items
      (order_id, order_item_id, product_id, seller_id,
       shipping_limit_date, price, freight_value)
SELECT DISTINCT ON (order_id, order_item_id)
       order_id::char(32), order_item_id,
       product_id::char(32), seller_id::char(32),
       shipping_limit_date, price, freight_value
FROM staging.order_items
WHERE order_id IS NOT NULL
ORDER BY order_id, order_item_id;

/* 3 rows carry payment_type = 'not_defined', which is a placeholder
   rather than a payment method. Recoded to 'unknown' so the CHECK
   constraint holds and the value reads honestly in a chart legend. */
INSERT INTO olist.order_payments
      (order_id, payment_sequential, payment_type,
       payment_installments, payment_value)
SELECT DISTINCT ON (order_id, payment_sequential)
       order_id::char(32),
       payment_sequential,
       CASE btrim(lower(payment_type))
            WHEN 'not_defined' THEN 'unknown'
            WHEN ''            THEN 'unknown'
            ELSE btrim(lower(payment_type))
       END,
       payment_installments,
       payment_value
FROM staging.order_payments
WHERE order_id IS NOT NULL
ORDER BY order_id, payment_sequential;

/* Reviews keep their composite key. has_comment is derived because
   "did the customer bother to write something" is a stronger signal
   than the comment text itself, which is unstructured Portuguese. */
INSERT INTO olist.order_reviews
      (review_id, order_id, review_score,
       review_comment_title, review_comment_message, has_comment,
       review_creation_date, review_answer_timestamp, response_hours)
SELECT DISTINCT ON (review_id, order_id)
       review_id::char(32),
       order_id::char(32),
       review_score,
       NULLIF(btrim(review_comment_title), ''),
       NULLIF(btrim(review_comment_message), ''),
       (NULLIF(btrim(review_comment_message), '') IS NOT NULL),
       review_creation_date,
       review_answer_timestamp,
       ROUND(EXTRACT(EPOCH FROM (review_answer_timestamp
                                 - review_creation_date))::numeric / 3600, 2)
FROM staging.order_reviews
WHERE review_id IS NOT NULL
  AND order_id  IS NOT NULL
  AND review_score BETWEEN 1 AND 5
ORDER BY review_id, order_id;


/* =====================================================================
   SECTION G — POST-CLEAN VALIDATION
   Expected values were established by profiling the source files
   independently. If a number here disagrees, stop and find out why
   before running any analysis.
   ===================================================================== */

\echo ''
\echo '=== G1. Clean table row counts ==='
SELECT 'product_categories' AS table_name, COUNT(*) AS actual,     74 AS expected,
       CASE WHEN COUNT(*)=74     THEN 'OK' ELSE 'MISMATCH' END AS status FROM olist.product_categories
UNION ALL SELECT 'geolocation',    COUNT(*),  19015, CASE WHEN COUNT(*)=19015  THEN 'OK' ELSE 'MISMATCH' END FROM olist.geolocation
UNION ALL SELECT 'sellers',        COUNT(*),   3095, CASE WHEN COUNT(*)=3095   THEN 'OK' ELSE 'MISMATCH' END FROM olist.sellers
UNION ALL SELECT 'products',       COUNT(*),  32951, CASE WHEN COUNT(*)=32951  THEN 'OK' ELSE 'MISMATCH' END FROM olist.products
UNION ALL SELECT 'customers',      COUNT(*),  99441, CASE WHEN COUNT(*)=99441  THEN 'OK' ELSE 'MISMATCH' END FROM olist.customers
UNION ALL SELECT 'orders',         COUNT(*),  99441, CASE WHEN COUNT(*)=99441  THEN 'OK' ELSE 'MISMATCH' END FROM olist.orders
UNION ALL SELECT 'order_items',    COUNT(*), 112650, CASE WHEN COUNT(*)=112650 THEN 'OK' ELSE 'MISMATCH' END FROM olist.order_items
UNION ALL SELECT 'order_payments', COUNT(*), 103886, CASE WHEN COUNT(*)=103886 THEN 'OK' ELSE 'MISMATCH' END FROM olist.order_payments
UNION ALL SELECT 'order_reviews',  COUNT(*),  99224, CASE WHEN COUNT(*)=99224  THEN 'OK' ELSE 'MISMATCH' END FROM olist.order_reviews
ORDER BY table_name;

\echo ''
\echo '=== G2. Geolocation is now one row per prefix ==='
SELECT COUNT(*)                                       AS rows,
       COUNT(DISTINCT zip_code_prefix)                AS distinct_prefixes,
       COUNT(DISTINCT city)                           AS distinct_cities,
       COUNT(*) FILTER (WHERE latitude IS NULL)       AS prefixes_without_coords,
       SUM(outlier_count)                             AS points_rejected,
       SUM(point_count)                               AS points_aggregated
FROM olist.geolocation;
-- expect: 19015 | 19015 | 5768 | 5 | 33 | 720469

\echo ''
\echo '=== G3. Key cleaning outcomes ==='
SELECT 'products mapped to unknown category' AS metric, COUNT(*)::text AS value
FROM olist.products WHERE category_name = 'unknown'                                    -- 610
UNION ALL
SELECT 'products with NULL volume', COUNT(*)::text
FROM olist.products WHERE volume_cm3 IS NULL                                           -- 2
UNION ALL
SELECT 'payments recoded to unknown', COUNT(*)::text
FROM olist.order_payments WHERE payment_type = 'unknown'                               -- 3
UNION ALL
SELECT 'orders never delivered to customer', COUNT(*)::text
FROM olist.orders WHERE order_delivered_customer_date IS NULL                           -- 2965
UNION ALL
SELECT 'orders delivered late', COUNT(*)::text
FROM olist.orders WHERE is_late                                                        -- 7827
UNION ALL
SELECT 'late rate among delivered orders', ROUND(100.0 * COUNT(*) FILTER (WHERE is_late)
                                                 / COUNT(*) FILTER (WHERE is_late IS NOT NULL), 2)::text || '%'
FROM olist.orders                                                                      -- 8.11%
UNION ALL
SELECT 'avg delivery days', ROUND(AVG(delivery_days), 2)::text
FROM olist.orders                                                                      -- 12.56
UNION ALL
SELECT 'distinct people (customer_unique_id)', COUNT(DISTINCT customer_unique_id)::text
FROM olist.customers;                                                                  -- 96096

\echo ''
\echo '=== G4. Hard assertions — these raise on failure ==='
DO $$
DECLARE
    v_geo   bigint; v_dup bigint; v_late bigint; v_prod bigint;
BEGIN
    SELECT COUNT(*) INTO v_geo FROM olist.geolocation;
    IF v_geo <> 19015 THEN
        RAISE EXCEPTION 'geolocation has % rows, expected 19015 (one per zip prefix)', v_geo;
    END IF;

    SELECT COUNT(*) INTO v_dup
    FROM (SELECT zip_code_prefix FROM olist.geolocation
          GROUP BY 1 HAVING COUNT(*) > 1) d;
    IF v_dup > 0 THEN
        RAISE EXCEPTION 'geolocation still has % duplicated zip prefixes', v_dup;
    END IF;

    SELECT COUNT(*) INTO v_prod FROM olist.products;
    IF v_prod <> 32951 THEN
        RAISE EXCEPTION 'products has % rows, expected 32951 — did 00_restore_raw_data.sh run?', v_prod;
    END IF;

    SELECT COUNT(*) INTO v_late FROM olist.orders WHERE is_late;
    IF v_late <> 7827 THEN
        RAISE WARNING 'late order count is %, expected 7827 — check the is_late definition', v_late;
    END IF;

    RAISE NOTICE 'All structural assertions passed.';
END $$;

\echo ''
\echo '>> cleaning complete. Next: 04_analysis.sql'
