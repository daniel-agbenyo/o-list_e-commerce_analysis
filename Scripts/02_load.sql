/* =====================================================================
   02_load.sql   Load raw CSVs into the staging schema
   -----------------------------------------------------------------
   Run with psql from the project root:
       psql -d olist_capstone -f Scripts/02_load.sql

   These are \copy (client-side) rather than COPY (server-side) so no
   superuser privilege is needed and the paths resolve on your machine.
   Each \copy must stay on ONE line — psql meta-commands do not wrap.

   If you move the project, find-and-replace the folder path below.

   PREREQUISITE: run Scripts/00_restore_raw_data.sh first. The load
   asserts source row counts and will fail loudly if the CSVs have
   been edited.
   ===================================================================== */

SET search_path = olist, staging, public;


/* ---------------------------------------------------------------------
   Load order does not matter here — staging has no foreign keys.
   It matters in 03_cleaning.sql, where the constrained tables are
   populated parent-first.
   --------------------------------------------------------------------- */

\echo '>> loading product_category_name_translation'
\copy staging.product_category_name_translation FROM '/Users/danieljr/Desktop/TDI CAPSTONE PROJECT/SQL Capstone/Kaggle Brazilian E-commerce Public Dataset/product_category_name_translation.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

\echo '>> loading sellers'
\copy staging.sellers FROM '/Users/danieljr/Desktop/TDI CAPSTONE PROJECT/SQL Capstone/Kaggle Brazilian E-commerce Public Dataset/olist_sellers_dataset.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

\echo '>> loading products'
\copy staging.products FROM '/Users/danieljr/Desktop/TDI CAPSTONE PROJECT/SQL Capstone/Kaggle Brazilian E-commerce Public Dataset/olist_products_dataset.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

\echo '>> loading customers'
\copy staging.customers FROM '/Users/danieljr/Desktop/TDI CAPSTONE PROJECT/SQL Capstone/Kaggle Brazilian E-commerce Public Dataset/olist_customers_dataset.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

\echo '>> loading geolocation (1,000,163 rows — this one takes a moment)'
\copy staging.geolocation FROM '/Users/danieljr/Desktop/TDI CAPSTONE PROJECT/SQL Capstone/Kaggle Brazilian E-commerce Public Dataset/olist_geolocation_dataset.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

\echo '>> loading orders'
\copy staging.orders FROM '/Users/danieljr/Desktop/TDI CAPSTONE PROJECT/SQL Capstone/Kaggle Brazilian E-commerce Public Dataset/olist_orders_dataset.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

\echo '>> loading order_items'
\copy staging.order_items FROM '/Users/danieljr/Desktop/TDI CAPSTONE PROJECT/SQL Capstone/Kaggle Brazilian E-commerce Public Dataset/olist_order_items_dataset.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

\echo '>> loading order_payments'
\copy staging.order_payments FROM '/Users/danieljr/Desktop/TDI CAPSTONE PROJECT/SQL Capstone/Kaggle Brazilian E-commerce Public Dataset/olist_order_payments_dataset.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

/* The review comment fields contain embedded newlines. Standard CSV
   quoting handles this correctly — the assertion below proves it. */
\echo '>> loading order_reviews'
\copy staging.order_reviews FROM '/Users/danieljr/Desktop/TDI CAPSTONE PROJECT/SQL Capstone/Kaggle Brazilian E-commerce Public Dataset/olist_order_reviews_dataset.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')


/* =====================================================================
   LOAD VERIFICATION
   Expected counts were established by profiling the source files.
   Anything else means a file was edited or a parse went wrong.
   ===================================================================== */

\echo ''
\echo '=== staging row counts (actual vs expected) ==='

SELECT 'product_category_name_translation' AS table_name,
       COUNT(*) AS actual, 71 AS expected,
       CASE WHEN COUNT(*) = 71      THEN 'OK' ELSE 'MISMATCH' END AS status
FROM staging.product_category_name_translation
UNION ALL SELECT 'sellers',        COUNT(*),    3095, CASE WHEN COUNT(*)=3095    THEN 'OK' ELSE 'MISMATCH' END FROM staging.sellers
UNION ALL SELECT 'products',       COUNT(*),   32951, CASE WHEN COUNT(*)=32951   THEN 'OK' ELSE 'MISMATCH' END FROM staging.products
UNION ALL SELECT 'customers',      COUNT(*),   99441, CASE WHEN COUNT(*)=99441   THEN 'OK' ELSE 'MISMATCH' END FROM staging.customers
UNION ALL SELECT 'geolocation',    COUNT(*), 1000163, CASE WHEN COUNT(*)=1000163 THEN 'OK' ELSE 'MISMATCH' END FROM staging.geolocation
UNION ALL SELECT 'orders',         COUNT(*),   99441, CASE WHEN COUNT(*)=99441   THEN 'OK' ELSE 'MISMATCH' END FROM staging.orders
UNION ALL SELECT 'order_items',    COUNT(*),  112650, CASE WHEN COUNT(*)=112650  THEN 'OK' ELSE 'MISMATCH' END FROM staging.order_items
UNION ALL SELECT 'order_payments', COUNT(*),  103886, CASE WHEN COUNT(*)=103886  THEN 'OK' ELSE 'MISMATCH' END FROM staging.order_payments
UNION ALL SELECT 'order_reviews',  COUNT(*),   99224, CASE WHEN COUNT(*)=99224   THEN 'OK' ELSE 'MISMATCH' END FROM staging.order_reviews
ORDER BY table_name;


/* Hard stop if the reviews file was mis-parsed. 99,224 records across
   104,719 physical lines is the specific thing being checked. */
DO $$
DECLARE n bigint;
BEGIN
    SELECT COUNT(*) INTO n FROM staging.order_reviews;
    IF n <> 99224 THEN
        RAISE EXCEPTION
          'order_reviews loaded % rows, expected 99224. The embedded newlines in review_comment_message were not parsed as quoted CSV.', n;
    END IF;
END $$;

/* Hard stop if the deleted product was not restored — this is the row
   that breaks order_items -> products. */
DO $$
DECLARE n bigint;
BEGIN
    SELECT COUNT(*) INTO n FROM staging.products
    WHERE product_id = 'a41e356c76fab66334f36de622ecbd3a';
    IF n = 0 THEN
        RAISE EXCEPTION
          'product a41e356c76fab66334f36de622ecbd3a is missing from products but is referenced by order_items. Run Scripts/00_restore_raw_data.sh.';
    END IF;
END $$;

\echo ''
\echo '>> staging load complete. Next: 03_cleaning.sql'
