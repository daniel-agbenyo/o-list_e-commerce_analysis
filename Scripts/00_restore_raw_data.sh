#!/usr/bin/env bash
# =====================================================================
#  TDI SQL Capstone — restore the raw source CSVs
#
#  WHY THIS EXISTS
#  Two source files were edited outside SQL after the initial commit:
#
#   1. olist_products_dataset.csv   32,951 -> 32,950 rows
#      One row was deleted: product_id a41e356c76fab66334f36de622ecbd3a
#      That product has a NULL category (which is presumably why it was
#      removed) but it IS referenced by olist_order_items_dataset.csv.
#      With it missing, the order_items -> products foreign key fails.
#      This one MUST be restored.
#
#   2. olist_geolocation_dataset.csv   1,000,163 -> 738,327 rows
#      Exact duplicate rows were removed and coordinates were rounded
#      to 8 decimal places. The dedup itself was correct, and the
#      precision loss is immaterial (8 dp is roughly 1 mm).
#      But the capstone brief requires that ALL cleaning be done in SQL.
#      Restoring the raw file lets 03_cleaning.sql do the dedup, which
#      is what actually earns the marks.
#
#  Run from the project root.
# =====================================================================

set -euo pipefail
cd "$(dirname "$0")/.."

DATA="Kaggle Brazilian E-commerce Public Dataset"

echo "Restoring raw source files from the initial commit..."
git checkout HEAD -- "$DATA/olist_products_dataset.csv"
git checkout HEAD -- "$DATA/olist_geolocation_dataset.csv"

echo
echo "Row counts now (excluding headers):"
for f in olist_products_dataset.csv olist_geolocation_dataset.csv; do
    printf '  %-38s %s\n' "$f" "$(($(wc -l < "$DATA/$f") - 1))"
done

echo
echo "Expected: products 32,951   geolocation 1,000,163"
echo "From here on, do all cleaning in SQL (03_cleaning.sql). Never edit the CSVs."
