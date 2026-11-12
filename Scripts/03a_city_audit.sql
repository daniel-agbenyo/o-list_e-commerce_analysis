/* =====================================================================
   03a_city_audit.sql   Auditing city name spellings
   -----------------------------------------------------------------
   City names appear in three tables and each is dirty in a different
   way, so check all three rather than assuming one is representative:

     geolocation.geolocation_city   8,011 distinct  — accents, junk
     customers.customer_city        4,119 distinct  — already clean
     sellers.seller_city              611 distinct  — worst per capita

   Run after 02_load.sql. Read-only: this script only inspects. The
   fix belongs in 03_cleaning.sql once you have decided what to do.

   Sections
     A. Setup — a normalisation function
     B. The plain list of distinct spellings
     C. Variant groups (the query you actually want)
     D. Dirt patterns
     E. Cross-table disagreement
   ===================================================================== */

SET search_path = olist, staging, public;


/* =====================================================================
   SECTION A — NORMALISATION FUNCTION
   -----------------------------------------------------------------
   Comparing spellings requires a canonical form to group by. The
   obvious approach is a translate() table mapping 'á'->'a' and so on.
   Do not use one on this dataset. Here is why.

   THE INVISIBLE BUG
   Every accented city name in all three tables is stored precomposed
   (Unicode NFC) — 'ã' is the single codepoint U+00E3 — with exactly
   one exception. In olist_sellers_dataset.csv, 'são paulo' is stored
   decomposed (NFD): 's','a',U+0303 COMBINING TILDE,'o'.

   It renders identically on screen. It is a different string.

     - translate() leaves it untouched, because the 'a' is a plain 'a'
       and U+0303 is not in the mapping table
     - WHERE seller_city = 'são paulo' typed in any normal editor will
       not match it
     - it silently splits São Paulo, the single biggest seller city,
       into two groups

   The fix is to decompose everything to NFD first, then strip the
   combining marks by codepoint range. That handles every diacritic at
   once — precomposed or not — and needs no mapping table to maintain.

   normalize() requires PostgreSQL 13 or later. On an older server,
   use CREATE EXTENSION unaccent and substitute unaccent() for the
   normalize/regexp_replace pair, but be aware it will not fix the NFD
   row above.
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

/* Sanity checks. Every row must return 'sao paulo' / the folded form.
   Row 5 is the NFD case — build it explicitly so the test is real. */
SELECT olist.norm_city('São Paulo')                        AS precomposed,
       olist.norm_city('sao  paulo')                       AS double_space,
       olist.norm_city('  SAO PAULO ')                     AS padded_upper,
       olist.norm_city(normalize('são paulo', NFC))        AS nfc_form,
       olist.norm_city(normalize('são paulo', NFD))        AS nfd_form,
       olist.norm_city('santa barbara d''oeste')           AS apostrophe,
       olist.norm_city('nova iguaçu')                      AS cedilla;

\echo '=== A2. Find any other rows that are not in NFC form ==='
SELECT 'sellers' AS source_table, seller_city AS city, COUNT(*) AS n
FROM staging.sellers
WHERE seller_city <> normalize(seller_city, NFC)
GROUP BY 1, 2
UNION ALL
SELECT 'customers', customer_city, COUNT(*)
FROM staging.customers
WHERE customer_city <> normalize(customer_city, NFC)
GROUP BY 1, 2
UNION ALL
SELECT 'geolocation', geolocation_city, COUNT(*)
FROM staging.geolocation
WHERE geolocation_city <> normalize(geolocation_city, NFC)
GROUP BY 1, 2;
-- expect exactly one row: sellers / 'são paulo' / 1


/* =====================================================================
   SECTION B — THE PLAIN LIST
   The literal answer to "show me every distinct spelling". Useful for
   eyeballing, but 8,011 rows is too many to read, so B2 is the version
   worth actually running.
   ===================================================================== */

\echo '=== B1. Every distinct city spelling in geolocation (8,011 rows) ==='
SELECT geolocation_city AS city_spelling,
       COUNT(*)         AS rows,
       COUNT(DISTINCT geolocation_zip_code_prefix) AS zip_prefixes
FROM staging.geolocation
GROUP BY geolocation_city
ORDER BY geolocation_city;

\echo '=== B2. How much do the three tables disagree on spelling style? ==='
SELECT 'geolocation' AS source_table,
       COUNT(DISTINCT geolocation_city)                  AS raw_spellings,
       COUNT(DISTINCT olist.norm_city(geolocation_city)) AS normalised,
       COUNT(DISTINCT geolocation_city)
         - COUNT(DISTINCT olist.norm_city(geolocation_city)) AS collapsed
FROM staging.geolocation
UNION ALL
SELECT 'customers',
       COUNT(DISTINCT customer_city),
       COUNT(DISTINCT olist.norm_city(customer_city)),
       COUNT(DISTINCT customer_city) - COUNT(DISTINCT olist.norm_city(customer_city))
FROM staging.customers
UNION ALL
SELECT 'sellers',
       COUNT(DISTINCT seller_city),
       COUNT(DISTINCT olist.norm_city(seller_city)),
       COUNT(DISTINCT seller_city) - COUNT(DISTINCT olist.norm_city(seller_city))
FROM staging.sellers;
/* Expected:
     geolocation  8,011 -> 5,941   (2,070 collapse)
     customers    4,119 -> 4,114   (5 collapse)
     sellers        611 ->   605   (6 collapse)

   Note how differently the three were treated at source. geolocation
   keeps its accents; customers was already stripped of them before the
   file was written; sellers is mostly stripped but not consistently.
   That is why customers must be joined to geolocation on
   zip_code_prefix and never on city name — the strings genuinely do
   not match.

   The 5 customer collapses are all apostrophes rather than accents:
     santa barbara d'oeste / santa barbara d oeste   124 customers
     dias d'avila          / dias d avila             25
     arraial d'ajuda       / arraial d ajuda           9
     palmeira d'oeste      / palmeira d oeste          6
     estrela d'oeste       / estrela d oeste           2  */


/* =====================================================================
   SECTION C — VARIANT GROUPS
   This is the query to actually use. One row per real place, with
   every spelling it appears under, ordered by how much data is at stake.
   ===================================================================== */

\echo '=== C1. Cities with more than one spelling — geolocation ==='
SELECT olist.norm_city(geolocation_city)                    AS canonical_name,
       COUNT(DISTINCT geolocation_city)                     AS n_spellings,
       STRING_AGG(DISTINCT geolocation_city, ' | '
                  ORDER BY geolocation_city)                AS spellings_found,
       COUNT(*)                                             AS total_rows
FROM staging.geolocation
GROUP BY olist.norm_city(geolocation_city)
HAVING COUNT(DISTINCT geolocation_city) > 1
ORDER BY total_rows DESC;
/* 2,051 groups. The top of the list:
     sao paulo              160,718 rows   sao paulo | são paulo
     brasilia                12,650         brasilia | brasília
     salvador                11,866         salvador | 'salvador '   <- trailing space
     sao bernardo do campo    9,629         sao bernardo do campo | são bernardo do campo
     santo andre              8,051         santo andre | santo andré
   Almost all of it is accents, but 'salvador ' is a whitespace bug
   and would survive a naive unaccent-only fix. */

\echo '=== C2. Same, for sellers — small enough to read in full ==='
SELECT olist.norm_city(seller_city)                  AS canonical_name,
       COUNT(DISTINCT seller_city)                   AS n_spellings,
       STRING_AGG(DISTINCT seller_city, ' | '
                  ORDER BY seller_city)              AS spellings_found,
       COUNT(*)                                      AS n_sellers
FROM staging.sellers
GROUP BY olist.norm_city(seller_city)
HAVING COUNT(DISTINCT seller_city) > 1
ORDER BY n_sellers DESC;
/* Expected 4 groups:
     sao paulo              696 sellers   sao  paulo | sao paulo | são paulo
     sao jose dos pinhais    11           sao  jose dos pinhais | sao jose dos pinhais
     santa barbara d oeste    7           santa barbara d oeste | santa barbara d'oeste
                                          | santa barbara d´oeste
     ferraz de vasconcelos    4           ferraz de  vasconcelos | ferraz de vasconcelos

   If the sao paulo group comes back with 695 sellers and only two
   spellings, your norm_city is not handling the NFD row — go back to
   Section A. That single row is the difference between 695 and 696. */


/* =====================================================================
   SECTION D — DIRT PATTERNS
   Variant grouping only catches spellings that normalise to the same
   string. These regex checks catch the rest.
   ===================================================================== */

\echo '=== D1. Suspicious city strings across all three tables ==='
WITH all_cities AS (
    SELECT 'geolocation' AS source_table, geolocation_city AS city FROM staging.geolocation
    UNION
    SELECT 'customers',   customer_city   FROM staging.customers
    UNION
    SELECT 'sellers',     seller_city     FROM staging.sellers
)
SELECT source_table,
       CASE
           WHEN city ~ '%[0-9A-Fa-f]{2}'   THEN '1. percent-encoded characters'
           WHEN city ~ '[,/]'              THEN '2. city and state in one field'
           WHEN city ~ '[0-9]'             THEN '3. contains digits'
           WHEN city <> btrim(city)        THEN '4. leading or trailing space'
           WHEN city ~ '\s{2,}'            THEN '5. repeated spaces'
           WHEN city ~ '[´`''’]'           THEN '6. apostrophe variant'
           WHEN char_length(city) <= 3     THEN '7. very short (abbreviation?)'
       END                                 AS issue,
       COUNT(*)                            AS n_distinct_strings,
       STRING_AGG(city, ' | ' ORDER BY city) AS examples
FROM all_cities
WHERE city ~ '%[0-9A-Fa-f]{2}' OR city ~ '[,/]' OR city ~ '[0-9]'
   OR city <> btrim(city)      OR city ~ '\s{2,}'
   OR city ~ '[´`''’]'         OR char_length(city) <= 3
GROUP BY source_table, issue
ORDER BY source_table, issue;
/* What this surfaces, and what to do about each:

   geolocation
     'lambari d%26apos%3boeste'                     URL-encoded &apos;
     'rio de janeiro, rio de janeiro, brasil'       full address, not a city
     'campo alegre de lourdes, bahia, brasil'       same
     '4o. centenario' vs '4º centenario'            ordinal written two ways
     'salvador '                                    trailing space
     'diamante d  oeste'                            apostrophe lost to a space

   sellers
     '04482255'                                     a zip code in the city field
     'auriflama/sp', 'carapicuiba / sao paulo'      17 rows with the state appended
     'sbc', 'sp'                                    abbreviations for real cities
     'santa barbara d´oeste'                        acute accent used as apostrophe

   customers
     'quilometro 14 do mutum'                       a real place; leave it alone
     'acu', 'itu', 'ipu'                            real 3-letter towns; leave alone

   Not every hit is a defect. Rule 7 in particular is mostly false
   positives, which is why the query reports examples rather than
   deleting anything. */

\echo '=== D2. Sellers where the state was appended to the city ==='
SELECT seller_id,
       seller_city                                          AS raw,
       btrim(split_part(translate(seller_city, ',', '/'), '/', 1)) AS city_part,
       btrim(split_part(translate(seller_city, ',', '/'), '/', 2)) AS state_part,
       seller_state                                         AS declared_state
FROM staging.sellers
WHERE seller_city ~ '[,/]'
ORDER BY seller_city;
/* 17 rows. In every case the appended state agrees with seller_state,
   so the suffix carries no new information and can simply be stripped. */


/* =====================================================================
   SECTION E — CROSS-TABLE AGREEMENT
   The real test of whether the names matter: for a given zip prefix,
   do customers and geolocation call the place the same thing?
   ===================================================================== */

\echo '=== E1. Zip prefixes where customer city disagrees with geolocation ==='
WITH geo_modal AS (
    SELECT geolocation_zip_code_prefix AS zip,
           MODE() WITHIN GROUP (ORDER BY olist.norm_city(geolocation_city)) AS geo_city
    FROM staging.geolocation
    GROUP BY 1
)
SELECT olist.norm_city(c.customer_city) AS customer_city,
       g.geo_city,
       COUNT(*)                         AS n_customers
FROM staging.customers c
JOIN geo_modal g ON g.zip = c.customer_zip_code_prefix
WHERE olist.norm_city(c.customer_city) <> g.geo_city
GROUP BY 1, 2
ORDER BY n_customers DESC;
/* Only 171 customers of 99,163 matched — 0.17%. And most are not
   errors at all:
     paraty / parati            both spellings are in official use
     embu / embu das artes      the town was renamed in 2001
     piumhii / piumhi           a typo, in the customers table
     mogi-guacu / mogi guacu    hyphenation

   Conclusion: city names are inconsistent but the zip prefix is
   reliable. Join on zip_code_prefix, treat the city name as a display
   label, and normalise it only for grouping and charts.  */
