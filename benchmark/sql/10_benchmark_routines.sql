-- Benchmark routines: 15 result sets, parameterized by rows per result set.
--
-- SAMPLE CODE — NOT FOR PRODUCTION USE. These routines exist to reproduce the
-- measurements in the accompanying AWS Database Blog post. See README.md.
--
-- These are benchmark variants, not production patterns. The production
-- procedures in ../../sql/postgresql/ aggregate aggressively (GROUP BY region,
-- LIMIT 10, GROUP BY sale_date), so each result set is bounded by the data
-- shape rather than by a workload parameter. To compare the three retrieval
-- contracts at controlled row counts, each variant below returns 15 result sets
-- of exactly p_rows rows with the same narrow four-column projection.
--
-- Production code should use the patterns in ../../sql/postgresql/.
--
-- Usage, from the repository root:
--   psql "$PSQL_CONN" -v ON_ERROR_STOP=1 -f benchmark/sql/10_benchmark_routines.sql

-- Required once per database for the SYSTEM_ROWS sampling method.
-- This is the only extension used and it is solely for benchmarking
-- (not for the production patterns).
CREATE EXTENSION IF NOT EXISTS tsm_system_rows;


-- Benchmark variant 1: temp tables, 15 result sets, parameterised by p_rows
CREATE OR REPLACE PROCEDURE sp_dashboard_temp_bench(p_rows INT)
LANGUAGE plpgsql
AS $$
BEGIN
  CREATE TEMP TABLE tmp_rs01 ON COMMIT DROP AS SELECT sale_id, region, sale_date, amount FROM sales ORDER BY sale_id LIMIT p_rows;
  CREATE TEMP TABLE tmp_rs02 ON COMMIT DROP AS SELECT sale_id, region, sale_date, amount FROM sales ORDER BY sale_id DESC LIMIT p_rows;
  CREATE TEMP TABLE tmp_rs03 ON COMMIT DROP AS SELECT sale_id, region, sale_date, amount FROM sales ORDER BY sale_date LIMIT p_rows;
  CREATE TEMP TABLE tmp_rs04 ON COMMIT DROP AS SELECT sale_id, region, sale_date, amount FROM sales ORDER BY sale_date DESC LIMIT p_rows;
  CREATE TEMP TABLE tmp_rs05 ON COMMIT DROP AS SELECT sale_id, region, sale_date, amount FROM sales ORDER BY amount LIMIT p_rows;
  CREATE TEMP TABLE tmp_rs06 ON COMMIT DROP AS SELECT sale_id, region, sale_date, amount FROM sales ORDER BY amount DESC LIMIT p_rows;
  CREATE TEMP TABLE tmp_rs07 ON COMMIT DROP AS SELECT sale_id, region, sale_date, amount FROM sales ORDER BY customer_id LIMIT p_rows;
  CREATE TEMP TABLE tmp_rs08 ON COMMIT DROP AS SELECT sale_id, region, sale_date, amount FROM sales ORDER BY customer_id DESC LIMIT p_rows;
  CREATE TEMP TABLE tmp_rs09 ON COMMIT DROP AS SELECT sale_id, region, sale_date, amount FROM sales ORDER BY product_id LIMIT p_rows;
  CREATE TEMP TABLE tmp_rs10 ON COMMIT DROP AS SELECT sale_id, region, sale_date, amount FROM sales ORDER BY product_id DESC LIMIT p_rows;
  CREATE TEMP TABLE tmp_rs11 ON COMMIT DROP AS SELECT sale_id, region, sale_date, amount FROM sales WHERE region = 'NA' ORDER BY sale_id LIMIT p_rows;
  CREATE TEMP TABLE tmp_rs12 ON COMMIT DROP AS SELECT sale_id, region, sale_date, amount FROM sales WHERE region = 'EMEA' ORDER BY sale_id LIMIT p_rows;
  CREATE TEMP TABLE tmp_rs13 ON COMMIT DROP AS SELECT sale_id, region, sale_date, amount FROM sales WHERE region = 'APAC' ORDER BY sale_id LIMIT p_rows;
  CREATE TEMP TABLE tmp_rs14 ON COMMIT DROP AS SELECT sale_id, region, sale_date, amount FROM sales WHERE region = 'LATAM' ORDER BY sale_id LIMIT p_rows;
  CREATE TEMP TABLE tmp_rs15 ON COMMIT DROP AS SELECT sale_id, region, sale_date, amount FROM sales TABLESAMPLE SYSTEM_ROWS(p_rows);
END;
$$;


-- Benchmark variant 2: JSON aggregation, 15 result sets, parameterised by p_rows
CREATE OR REPLACE FUNCTION fn_dashboard_json_bench(p_rows INT)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN jsonb_build_object(
    'rs01', (SELECT COALESCE(jsonb_agg(t), '[]'::jsonb) FROM (SELECT sale_id, region, sale_date, amount FROM sales ORDER BY sale_id LIMIT p_rows) t),
    'rs02', (SELECT COALESCE(jsonb_agg(t), '[]'::jsonb) FROM (SELECT sale_id, region, sale_date, amount FROM sales ORDER BY sale_id DESC LIMIT p_rows) t),
    'rs03', (SELECT COALESCE(jsonb_agg(t), '[]'::jsonb) FROM (SELECT sale_id, region, sale_date, amount FROM sales ORDER BY sale_date LIMIT p_rows) t),
    'rs04', (SELECT COALESCE(jsonb_agg(t), '[]'::jsonb) FROM (SELECT sale_id, region, sale_date, amount FROM sales ORDER BY sale_date DESC LIMIT p_rows) t),
    'rs05', (SELECT COALESCE(jsonb_agg(t), '[]'::jsonb) FROM (SELECT sale_id, region, sale_date, amount FROM sales ORDER BY amount LIMIT p_rows) t),
    'rs06', (SELECT COALESCE(jsonb_agg(t), '[]'::jsonb) FROM (SELECT sale_id, region, sale_date, amount FROM sales ORDER BY amount DESC LIMIT p_rows) t),
    'rs07', (SELECT COALESCE(jsonb_agg(t), '[]'::jsonb) FROM (SELECT sale_id, region, sale_date, amount FROM sales ORDER BY customer_id LIMIT p_rows) t),
    'rs08', (SELECT COALESCE(jsonb_agg(t), '[]'::jsonb) FROM (SELECT sale_id, region, sale_date, amount FROM sales ORDER BY customer_id DESC LIMIT p_rows) t),
    'rs09', (SELECT COALESCE(jsonb_agg(t), '[]'::jsonb) FROM (SELECT sale_id, region, sale_date, amount FROM sales ORDER BY product_id LIMIT p_rows) t),
    'rs10', (SELECT COALESCE(jsonb_agg(t), '[]'::jsonb) FROM (SELECT sale_id, region, sale_date, amount FROM sales ORDER BY product_id DESC LIMIT p_rows) t),
    'rs11', (SELECT COALESCE(jsonb_agg(t), '[]'::jsonb) FROM (SELECT sale_id, region, sale_date, amount FROM sales WHERE region = 'NA' ORDER BY sale_id LIMIT p_rows) t),
    'rs12', (SELECT COALESCE(jsonb_agg(t), '[]'::jsonb) FROM (SELECT sale_id, region, sale_date, amount FROM sales WHERE region = 'EMEA' ORDER BY sale_id LIMIT p_rows) t),
    'rs13', (SELECT COALESCE(jsonb_agg(t), '[]'::jsonb) FROM (SELECT sale_id, region, sale_date, amount FROM sales WHERE region = 'APAC' ORDER BY sale_id LIMIT p_rows) t),
    'rs14', (SELECT COALESCE(jsonb_agg(t), '[]'::jsonb) FROM (SELECT sale_id, region, sale_date, amount FROM sales WHERE region = 'LATAM' ORDER BY sale_id LIMIT p_rows) t),
    'rs15', (SELECT COALESCE(jsonb_agg(t), '[]'::jsonb) FROM (SELECT sale_id, region, sale_date, amount FROM sales TABLESAMPLE SYSTEM_ROWS(p_rows)) t)
  );
END;
$$;


-- Benchmark variant 3: refcursor baseline, 15 result sets, parameterised by p_rows
CREATE OR REPLACE PROCEDURE sp_dashboard_refcursor_bench(
  p_rows INT,
  INOUT c01 REFCURSOR,
  INOUT c02 REFCURSOR,
  INOUT c03 REFCURSOR,
  INOUT c04 REFCURSOR,
  INOUT c05 REFCURSOR,
  INOUT c06 REFCURSOR,
  INOUT c07 REFCURSOR,
  INOUT c08 REFCURSOR,
  INOUT c09 REFCURSOR,
  INOUT c10 REFCURSOR,
  INOUT c11 REFCURSOR,
  INOUT c12 REFCURSOR,
  INOUT c13 REFCURSOR,
  INOUT c14 REFCURSOR,
  INOUT c15 REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN
  OPEN c01 FOR SELECT sale_id, region, sale_date, amount FROM sales ORDER BY sale_id LIMIT p_rows;
  OPEN c02 FOR SELECT sale_id, region, sale_date, amount FROM sales ORDER BY sale_id DESC LIMIT p_rows;
  OPEN c03 FOR SELECT sale_id, region, sale_date, amount FROM sales ORDER BY sale_date LIMIT p_rows;
  OPEN c04 FOR SELECT sale_id, region, sale_date, amount FROM sales ORDER BY sale_date DESC LIMIT p_rows;
  OPEN c05 FOR SELECT sale_id, region, sale_date, amount FROM sales ORDER BY amount LIMIT p_rows;
  OPEN c06 FOR SELECT sale_id, region, sale_date, amount FROM sales ORDER BY amount DESC LIMIT p_rows;
  OPEN c07 FOR SELECT sale_id, region, sale_date, amount FROM sales ORDER BY customer_id LIMIT p_rows;
  OPEN c08 FOR SELECT sale_id, region, sale_date, amount FROM sales ORDER BY customer_id DESC LIMIT p_rows;
  OPEN c09 FOR SELECT sale_id, region, sale_date, amount FROM sales ORDER BY product_id LIMIT p_rows;
  OPEN c10 FOR SELECT sale_id, region, sale_date, amount FROM sales ORDER BY product_id DESC LIMIT p_rows;
  OPEN c11 FOR SELECT sale_id, region, sale_date, amount FROM sales WHERE region = 'NA' ORDER BY sale_id LIMIT p_rows;
  OPEN c12 FOR SELECT sale_id, region, sale_date, amount FROM sales WHERE region = 'EMEA' ORDER BY sale_id LIMIT p_rows;
  OPEN c13 FOR SELECT sale_id, region, sale_date, amount FROM sales WHERE region = 'APAC' ORDER BY sale_id LIMIT p_rows;
  OPEN c14 FOR SELECT sale_id, region, sale_date, amount FROM sales WHERE region = 'LATAM' ORDER BY sale_id LIMIT p_rows;
  OPEN c15 FOR SELECT sale_id, region, sale_date, amount FROM sales TABLESAMPLE SYSTEM_ROWS(p_rows);
END;
$$;
