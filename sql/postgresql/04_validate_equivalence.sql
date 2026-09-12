-- Validate functional equivalence of the two PostgreSQL contracts.
--
-- SAMPLE CODE — NOT FOR PRODUCTION USE. This script demonstrates the concepts
-- in the accompanying AWS Database Blog post. See README.md.
--
-- This script compares the temporary-table output with the JSON output for the
-- same inputs, then checks empty-result behavior. It runs entirely inside
-- PostgreSQL, so it validates that the two conversions of the same source
-- procedure agree with each other.
--
-- Comparing against the SQL Server source is a separate step that needs a
-- harness able to read both engines. Do it before this script, and canonicalize
-- values first (for example, SQL Server datetime to PostgreSQL timestamp)
-- so that intentional type differences are not reported as mismatches.
--
-- Usage, from the repository root:
--   psql "$PSQL_CONN" -v ON_ERROR_STOP=1 -f sql/postgresql/04_validate_equivalence.sql
--
-- To validate a specific range instead of the default:
--   psql "$PSQL_CONN" -v ON_ERROR_STOP=1 \
--        -v start_date=YYYY-MM-DD -v end_date=YYYY-MM-DD \
--        -f sql/postgresql/04_validate_equivalence.sql
--
-- Both variables are optional. When they are not supplied the script validates
-- the last 90 days, which stays inside the rolling window that
-- 01_schema_and_data.sql generates (CURRENT_DATE - random() * 365). Do not
-- default to fixed calendar dates here: they drift out of the generated data
-- over time, and an empty range makes every comparison below pass vacuously.

-- Defaults when the caller does not supply a range.
\if :{?start_date}
\else
SELECT to_char(CURRENT_DATE - 90, 'YYYY-MM-DD') AS start_date \gset
\endif
\if :{?end_date}
\else
SELECT to_char(CURRENT_DATE, 'YYYY-MM-DD') AS end_date \gset
\endif

-- The CALL and every read must share one transaction: the temporary tables are
-- created ON COMMIT DROP.
BEGIN;

CALL sp_dashboard_temp(:'start_date'::date, :'end_date'::date);

CREATE TEMP TABLE tmp_json_payload ON COMMIT DROP AS
SELECT fn_dashboard_json(:'start_date'::date, :'end_date'::date) AS doc;

-- Guard: the comparisons below are all "no differences found" tests, so an
-- empty range would satisfy every one of them without validating anything.
-- Fail loudly instead. A false here means the requested range falls outside the
-- data that 01_schema_and_data.sql generated, not that the conversions disagree.
SELECT
  'range_returns_rows' AS check_name,
  (SELECT count(*) FROM tmp_sales_by_region) > 0
    AND (SELECT count(*) FROM tmp_top_customers) > 0
    AND (SELECT count(*) FROM tmp_daily_trend)   > 0 AS passed;

-- Row counts per logical result set, from both contracts.
SELECT
  'sales_by_region' AS result_set,
  (SELECT count(*) FROM tmp_sales_by_region) AS temp_table_rows,
  (SELECT jsonb_array_length(doc -> 'sales_by_region') FROM tmp_json_payload) AS json_rows
UNION ALL
SELECT
  'top_customers',
  (SELECT count(*) FROM tmp_top_customers),
  (SELECT jsonb_array_length(doc -> 'top_customers') FROM tmp_json_payload)
UNION ALL
SELECT
  'daily_trend',
  (SELECT count(*) FROM tmp_daily_trend),
  (SELECT jsonb_array_length(doc -> 'daily_trend') FROM tmp_json_payload)
ORDER BY result_set;

-- Symmetric-difference count per result set. Every row must be 0.
WITH
j_region AS (
  SELECT (e ->> 'region')       AS region,
         (e ->> 'sale_count')::bigint   AS sale_count,
         (e ->> 'total_amount')::numeric AS total_amount
  FROM tmp_json_payload, jsonb_array_elements(doc -> 'sales_by_region') e
),
t_region AS (
  SELECT region, sale_count, total_amount FROM tmp_sales_by_region
),
d_region AS (
  SELECT * FROM ((SELECT * FROM t_region EXCEPT SELECT * FROM j_region)
                 UNION ALL
                 (SELECT * FROM j_region EXCEPT SELECT * FROM t_region)) x
),
j_cust AS (
  SELECT (e ->> 'customer_id')::int     AS customer_id,
         (e ->> 'total_spend')::numeric AS total_spend
  FROM tmp_json_payload, jsonb_array_elements(doc -> 'top_customers') e
),
t_cust AS (
  SELECT customer_id, total_spend FROM tmp_top_customers
),
d_cust AS (
  SELECT * FROM ((SELECT * FROM t_cust EXCEPT SELECT * FROM j_cust)
                 UNION ALL
                 (SELECT * FROM j_cust EXCEPT SELECT * FROM t_cust)) x
),
j_trend AS (
  SELECT (e ->> 'sale_date')::date      AS sale_date,
         (e ->> 'daily_total')::numeric AS daily_total
  FROM tmp_json_payload, jsonb_array_elements(doc -> 'daily_trend') e
),
t_trend AS (
  SELECT sale_date, daily_total FROM tmp_daily_trend
),
d_trend AS (
  SELECT * FROM ((SELECT * FROM t_trend EXCEPT SELECT * FROM j_trend)
                 UNION ALL
                 (SELECT * FROM j_trend EXCEPT SELECT * FROM t_trend)) x
)
SELECT 'sales_by_region' AS result_set, (SELECT count(*) FROM d_region) AS differences
UNION ALL
SELECT 'top_customers',   (SELECT count(*) FROM d_cust)
UNION ALL
SELECT 'daily_trend',     (SELECT count(*) FROM d_trend)
ORDER BY result_set;

-- Ordering checks. All three arrays reproduce an ordering that the source
-- procedure guarantees, so all three are part of the contract. The symmetric
-- difference above is set-based and cannot detect an ordering divergence, so
-- these checks are the only thing covering it.
--
-- COALESCE matters: bool_and() over zero rows returns NULL, so without it an
-- empty array would report a passed value that is neither t nor f.
WITH region_ordered AS (
  SELECT COALESCE(bool_and(region >= prev_region), true) AS passed
  FROM (
    SELECT (e ->> 'region') AS region,
           lag(e ->> 'region') OVER (ORDER BY ord) AS prev_region
    FROM tmp_json_payload,
         jsonb_array_elements(doc -> 'sales_by_region') WITH ORDINALITY AS a(e, ord)
  ) s
),
customers_ordered AS (
  SELECT COALESCE(bool_and(total_spend <= prev_total_spend), true) AS passed
  FROM (
    SELECT (e ->> 'total_spend')::numeric AS total_spend,
           lag((e ->> 'total_spend')::numeric)
             OVER (ORDER BY ord) AS prev_total_spend
    FROM tmp_json_payload,
         jsonb_array_elements(doc -> 'top_customers') WITH ORDINALITY AS a(e, ord)
  ) s
),
trend_ordered AS (
  SELECT COALESCE(bool_and(sale_date >= prev_sale_date), true) AS passed
  FROM (
    SELECT (e ->> 'sale_date')::date AS sale_date,
           lag((e ->> 'sale_date')::date) OVER (ORDER BY ord) AS prev_sale_date
    FROM tmp_json_payload,
         jsonb_array_elements(doc -> 'daily_trend') WITH ORDINALITY AS a(e, ord)
  ) s
)
SELECT 'sales_by_region_is_ordered' AS check_name, passed FROM region_ordered
UNION ALL
SELECT 'top_customers_is_ordered',   passed FROM customers_ordered
UNION ALL
SELECT 'daily_trend_is_ordered',     passed FROM trend_ordered
ORDER BY check_name;

COMMIT;

-- Empty-result behavior. The JSON contract returns []; the temporary-table
-- contract returns a table with zero rows.
SELECT
  'json_empty_range_returns_empty_arrays' AS check_name,
  doc -> 'sales_by_region' = '[]'::jsonb
    AND doc -> 'top_customers'   = '[]'::jsonb
    AND doc -> 'daily_trend'     = '[]'::jsonb AS passed
FROM (
  SELECT fn_dashboard_json(DATE '1900-01-01', DATE '1900-01-02') AS doc
) s;

BEGIN;
CALL sp_dashboard_temp(DATE '1900-01-01', DATE '1900-01-02');
SELECT
  'temp_tables_empty_range_return_zero_rows' AS check_name,
  (SELECT count(*) FROM tmp_sales_by_region) = 0
    AND (SELECT count(*) FROM tmp_top_customers) = 0
    AND (SELECT count(*) FROM tmp_daily_trend)   = 0 AS passed;
COMMIT;
