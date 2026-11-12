# TDI SQL Capstone — Project Plan

**Analyst:** Daniel Agbenyo
**Dataset:** Olist Brazilian E-Commerce Public Dataset (Kaggle, 2016–2018)
**Engine:** PostgreSQL
**Plan written:** 10 Aug 2026
**Assumed deadline:** 17 Aug 2026 (2 weeks from the 3 Aug brief).

---

## 1. Project narrative 


> **Olist tripled revenue in a year, then stalled — and the two things holding it back are delivery time and the fact that almost nobody comes back.**

Three acts:

1. **Growth is real but plateauing.** Revenue rose 141% from Jan–Aug 2017 to Jan–Aug 2018, but flattened from March 2018 onward (R$953k → R$839k).
2. **Delivery speed is the single strongest lever on satisfaction.** Orders delivered in 0–3 days average a 4.48 review score; orders taking 30+ days average 2.25, with 63% of them scoring 1–2 stars.
3. **The business is not compounding.** Only 3.0% of customers ever order twice. Growth is bought entirely through acquisition.


---

## 2. Dataset and schema

Nine CSVs, eight tables after loading. This comfortably exceeds the "at least 4 related tables, main table 5+ columns" requirement — `orders` has 8 columns and links to 4 other tables.

| Table | Rows | Grain | Key |
|---|---|---|---|
| `orders` **(main)** | 99,441 | one order | `order_id` PK, `customer_id` FK |
| `order_items` | 112,650 | one item line | `(order_id, order_item_id)` PK; FKs to orders, products, sellers |
| `order_payments` | 103,886 | one payment leg | `(order_id, payment_sequential)` PK |
| `order_reviews` | 99,224 | one review | `(review_id, order_id)` PK |
| `customers` | 99,441 | one order-customer | `customer_id` PK; `customer_unique_id` = the actual person |
| `products` | 32,950 | one product | `product_id` PK |
| `sellers` | 3,095 | one seller | `seller_id` PK |
| `geolocation` | 738,327 | one lat/lng point | **not unique by zip** — see issue G1 |
| `product_category_translation` | 71 | one category | `product_category_name` PK |

### Relationship map

```
product_category_translation
        │ product_category_name
        ▼
     products ──┐
                │ product_id
   sellers ─────┤ seller_id
                ▼
customers ──► orders ──► order_items
 customer_id  order_id ├─► order_payments
                       └─► order_reviews
```

**The `customer_id` trap.** `customers.customer_id` is unique per *order*, not per person. 99,441 `customer_id` values map to 96,096 `customer_unique_id` values. Any retention, repeat-purchase or CLV analysis **must** group by `customer_unique_id`. Getting this wrong is the most common mistake made with this dataset — calling it out explicitly in your report is an easy credibility win.

---

## 3. Data quality issues found (fix these before analysing)

I profiled all nine files. These are real, verified issues — each one is material for the "Challenges faced and solutions applied" section of your report.

### Blockers — your current `Scripts/DDL.sql` will fail without these

| # | Issue | Fix |
|---|---|---|
| **G1** | `geolocation_zip_code_prefix` is declared `PRIMARY KEY` but has 738,327 rows across only 19,015 distinct prefixes. The load will abort. | Load into a staging table, then build a clean `geolocation` with one row per prefix (median lat/lng, modal city). |
| **D1** | Column name typos vs the CSV headers: `product_lenght_cm` (CSV: `product_length_cm`), `golocation_lat`, `order_estimated_delivry_date`, `review_creation_timesatamp` (CSV: `review_answer_timestamp`). | Correct the DDL. Keep `product_name_lenght` / `product_description_lenght` — those typos are genuinely in the source file. |
| **R1** | `olist_order_reviews_dataset.csv` contains embedded newlines inside review comments. Line count is 104,719 but there are only **99,224 records**. A naïve import will silently mangle rows. | Use `COPY ... WITH (FORMAT csv, HEADER true, QUOTE '"')`, then assert `COUNT(*) = 99224`. |
| **F1** | `order_items` references product `a41e356c76fab66334f36de622ecbd3a`, which does not exist in `products`. The FK will reject the row. | Insert a placeholder product row before loading items, or load items without the FK and add it after reconciling. Document either way. |
| **F2** | `products` contains categories `pc_gamer` and `portateis_cozinha_e_preparadores_de_alimentos` that are absent from the translation file. | You already caught this — the `INSERT` at the bottom of your DDL. **Move it above the products load**, or the FK fires first. |

### Cleaning decisions to make and document

| # | Issue | Recommended handling |
|---|---|---|
| N1 | 609 products (1.8%) have NULL `product_category_name` and NULL name/description/photo fields | Map to `'unknown'` rather than dropping — they carry real revenue |
| N2 | 2 products have NULL weight and dimensions | Leave NULL; exclude from any freight-vs-weight analysis |
| N3 | 2,965 orders (3.0%) have no `order_delivered_customer_date` | Expected — these are cancelled/unavailable/in-transit. Filter to `order_status = 'delivered'` for all delivery and revenue analysis |
| N4 | 160 orders have no `order_approved_at` | Exclude from approval-latency analysis only |
| N5 | 1 order has no payment record | Note it; it doesn't move any number |
| N6 | 9 payments have `payment_value = 0`; 3 rows have `payment_type = 'not_defined'` | Recode `'not_defined'` → `'unknown'` via `CASE` |
| N7 | 789 `review_id` values appear more than once; 547 `order_id` values have multiple reviews | Your composite PK `(review_id, order_id)` handles this correctly. For per-order scores, aggregate with `AVG(review_score)` |
| **N8** | **Date tail truncation.** 2016-12 has 1 order; 2018-09 has 16; 2018-10 has 4 | **Restrict all trend analysis to 2017-01-01 → 2018-08-31.** Include the full range once, as a chart, to justify the cut — this is a strong "depth of exploration" signal |
| N9 | 278 customer zip prefixes absent from geolocation | Use `LEFT JOIN` for geo enrichment; never `INNER` |

### Load order (FK-safe)

```
product_category_translation  →  sellers  →  products  →  customers
      →  geolocation_staging  →  geolocation  →  orders
      →  order_items  →  order_payments  →  order_reviews
```

---

## 4. Research questions

Eight questions, mapped to the three acts. Each has a required SQL technique attached, so answering them satisfies the rubric automatically.

**QI — Is growth real, and where does it come from?**

1. How has monthly revenue and order volume moved from Jan 2017 to Aug 2018, and what is the running cumulative total? *(window function — `SUM() OVER (ORDER BY month)`)*
2. Which product categories drive revenue, and which are growing fastest year over year? *(CTE + `LAG()` + `RANK()`)*
3. How concentrated is revenue across states and sellers? *(aggregation + window `PERCENT_RANK()` / cumulative share)*

**QII — What is breaking the customer experience?**

4. What is the relationship between delivery time and review score? *(`CASE` bucketing + join across orders/reviews)*
5. What share of orders arrive after the estimated delivery date, and which states and sellers are worst? *(date arithmetic + `HAVING` to filter to sellers with enough volume)*
6. Which categories underperform on satisfaction relative to the platform average? *(subquery / correlated comparison to global mean)*

**QIII — Does the business compound?**

7. What share of customers order more than once, and what is repeat-customer value? *(`customer_unique_id` grouping + `COUNT DISTINCT`)*
8. How does payment method and installment count relate to order value? *(aggregation + `CASE` bucketing)*

---

## 5. SQL rubric coverage


| Category | Where it appears | Count |
|---|---|---|
| Data exploration | Row counts / min-max / null audit per table; date-range profile | 6+ |
| Filtering & sorting | Top 10 categories by revenue; top 10 sellers; worst-rated categories | 4 |
| Aggregation (`GROUP BY` / `HAVING`) | Revenue by month, by state, by category; sellers with 50+ orders `HAVING` late rate > 10% | 5 |
| Joins | orders↔customers↔items↔products↔translation (Q2); orders↔reviews (Q4); items↔sellers (Q5) | 5+ |
| Subqueries / CTEs | Above-average category performers (Q6); YoY growth CTE (Q2); cohort CTE (Q7) | 4+ |
| Window functions | Running revenue total (Q1); `RANK()` category by month (Q2); `LAG()` YoY (Q2); cumulative seller share (Q3) | 4+ |
| `CASE` statements | Delivery-time buckets (Q4); installment buckets (Q8); payment-type recode (N6) | 3 |

---

## 6. File structure

```
SQL Capstone/
├── Kaggle Brazilian E-commerce Public Dataset/   (source CSVs — never edit)
├── Scripts/
│   ├── 01_ddl.sql              corrected schema + constraints
│   ├── 02_load.sql             COPY statements, FK-safe order
│   ├── 03_cleaning.sql         staging → clean, dedup, recode, validation asserts
│   └── 04_analysis.sql         the 8 research questions, commented
├── Outputs/                    query results as CSV, feeding Excel
├── Dashboard/                  Olist_Dashboard.xlsx
├── Report/                     Capstone_Report.docx
├── Presentation/               Capstone_Deck.pptx
└── PROJECT_PLAN.md
```


---

## 7. Schedule — Mon 10 Aug → Sun 17 Aug

| Day | Work | Done when |
|---|---|---|
| **Mon 10** | Fix DDL (G1, D1, F1, F2). Write `01_ddl.sql` + `02_load.sql`. Load all 9 files. | Every table row count matches the profile table in §2 |
| **Tue 11** | `03_cleaning.sql` — staging→clean geolocation, null handling, recodes, dedup checks, validation queries | All N-issues in §3 handled and commented |
| **Wed 12** | `04_analysis.sql` Act I + Act II (Q1–Q5) | Queries run; results exported to `Outputs/` |
| **Thu 13** | `04_analysis.sql` Act III (Q6–Q8). Cross-check every number against §8 below | Rubric coverage table in §5 fully ticked |
| **Fri 14** | Excel dashboard — pivot tables, slicers by state/category/month, 5–6 charts | Dashboard is interactive, not static images |
| **Sat 15** | Written report (docx) | All six required sections present, SQL appendix attached |
| **Sun 16** | PowerPoint deck; rehearse the 3-act narrative out loud | Deck under ~12 slides, one message per slide |
| **Mon 17** | Verification pass, commit, submit | Every figure in report and deck traces to a query |

If you have the full two weeks, spread days 12–14 across four days and add a seller-cohort analysis.

---

## 8. Expected findings (verified against the raw data)



**Scale (delivered orders only, full date range)**
- 96,478 delivered orders · 110,197 item lines · R$13,221,498 product revenue · R$2,198,276 freight · AOV **R$137.04**

**Growth**
- Jan–Aug 2017: R$2,993,456 → Jan–Aug 2018: R$7,218,125 = **+141.1%**
- Monthly revenue peaks Nov 2017 (R$987,765 — Black Friday) then plateaus around R$850–975k through 2018

**Delivery and satisfaction**
- Average delivery: **12.56 days** purchase → doorstep
- **8.0%** of delivered orders arrive after the estimated date
- Avg review score: on-time **4.29** vs late **2.57**
- By delivery time: 0–3d → 4.48 · 4–7d → 4.40 · 8–14d → 4.31 · 15–30d → 3.97 · **30d+ → 2.25** (62.9% rated 1–2 stars)

**Concentration**
- Top 10 categories = **62.4%** of revenue (of 72 categories)
- SP + RJ + MG = **63.4%** of revenue (SP alone 38.3%)
- Top 10% of sellers = **67.1%** of revenue; top 1% = 25.5%

**Retention**
- 93,358 unique customers among delivered orders; **only 3.00% ever order twice**

**Payments**
- Credit card **78.5%** of value, boleto 18.0%, voucher 2.2%, debit 1.4%
- 66.8% of credit-card orders use installments
- AOV rises steeply with installments: 1x R$95.60 → 2–3x R$133.63 → 4–6x R$180.48 → **7–12x R$330.41**

---

## 9. Recommendations the analysis will support



1. **Attack the long tail of delivery.** The 4.6% of orders taking 30+ days generate the majority of 1-star reviews. Cap promised delivery windows by route and escalate any order past day 20.
2. **Set seller-level SLAs.** Late-delivery rate varies widely by seller; publish it and gate marketplace visibility on it.
3. **Build a repeat-purchase motive.** At 3% repeat rate, a single point of improvement is worth more than a point of acquisition. Start with post-delivery follow-up on the categories that already score well.
4. **Promote installments on mid-value baskets.** Installment use tracks a 3.5× higher average order value; the causality runs both ways, but offering them earlier in checkout is cheap to test.
5. **Diversify beyond the Southeast.** 63% of revenue in three states is a concentration risk and freight cost outside them is the barrier worth quantifying.

---

## 10. Rubric self-check before submitting

- [ ] 4+ related tables, main table 5+ columns — *8 tables, orders has 8 columns*
- [ ] Relationships documented with FKs — *ERD in §2 and in the report*
- [ ] Missing data, duplicates, formatting all handled and **documented**
- [ ] 2+ examples of each of the 6 SQL categories — *§5 table*
- [ ] `CASE`, CTEs and subqueries all used
- [ ] Research questions address trends, performance and actionable insight
- [ ] Commented SQL script
- [ ] Interactive Excel dashboard (slicers, not static charts)
- [ ] Report covers: overview · questions & methodology · findings · recommendations · challenges · SQL appendix
- [ ] Polished PowerPoint with visuals and recommendations
- [ ] Every number in the report traces to a query
