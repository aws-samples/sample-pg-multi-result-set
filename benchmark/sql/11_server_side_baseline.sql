-- Server-side execution baseline.
--
-- SAMPLE CODE — NOT FOR PRODUCTION USE. This script exists to reproduce the
-- measurements in the accompanying AWS Database Blog post. See README.md.
--
-- Runs the same 15 benchmark queries but discards the rows inside the server,
-- so nothing is returned to the client. The result is the query-execution cost
-- that all three retrieval contracts share. Subtracting it from the end-to-end
-- numbers shows how much of the measured latency is attributable to the
-- retrieval contract itself.
--
-- Six of the 15 queries sort on unindexed columns (amount, customer_id,
-- product_id) and therefore scan the whole sales table, which is why this
-- baseline dominates the end-to-end latency in the published results.
--
-- Usage, from the repository root:
--   psql "$PSQL_CONN" -v ON_ERROR_STOP=1 -f benchmark/sql/11_server_side_baseline.sql
--
-- The medians are emitted as NOTICE lines. To isolate them:
--   ... 2>&1 | grep rows_per_result_set

CREATE EXTENSION IF NOT EXISTS tsm_system_rows;

CREATE OR REPLACE FUNCTION fn_bench_server_side(p_rows INT)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM sale_id, region, sale_date, amount FROM sales ORDER BY sale_id LIMIT p_rows;
  PERFORM sale_id, region, sale_date, amount FROM sales ORDER BY sale_id DESC LIMIT p_rows;
  PERFORM sale_id, region, sale_date, amount FROM sales ORDER BY sale_date LIMIT p_rows;
  PERFORM sale_id, region, sale_date, amount FROM sales ORDER BY sale_date DESC LIMIT p_rows;
  PERFORM sale_id, region, sale_date, amount FROM sales ORDER BY amount LIMIT p_rows;
  PERFORM sale_id, region, sale_date, amount FROM sales ORDER BY amount DESC LIMIT p_rows;
  PERFORM sale_id, region, sale_date, amount FROM sales ORDER BY customer_id LIMIT p_rows;
  PERFORM sale_id, region, sale_date, amount FROM sales ORDER BY customer_id DESC LIMIT p_rows;
  PERFORM sale_id, region, sale_date, amount FROM sales ORDER BY product_id LIMIT p_rows;
  PERFORM sale_id, region, sale_date, amount FROM sales ORDER BY product_id DESC LIMIT p_rows;
  PERFORM sale_id, region, sale_date, amount FROM sales WHERE region = 'NA' ORDER BY sale_id LIMIT p_rows;
  PERFORM sale_id, region, sale_date, amount FROM sales WHERE region = 'EMEA' ORDER BY sale_id LIMIT p_rows;
  PERFORM sale_id, region, sale_date, amount FROM sales WHERE region = 'APAC' ORDER BY sale_id LIMIT p_rows;
  PERFORM sale_id, region, sale_date, amount FROM sales WHERE region = 'LATAM' ORDER BY sale_id LIMIT p_rows;
  PERFORM sale_id, region, sale_date, amount FROM sales TABLESAMPLE SYSTEM_ROWS(p_rows);
END;
$$;

-- Time it: 5 warm-up calls, then report the median of 20 measured calls
-- for each of the three tested result-set sizes.
DO $$
DECLARE
  v_rows    INT;
  v_started TIMESTAMPTZ;
  v_ms      DOUBLE PRECISION;
  v_samples DOUBLE PRECISION[];
  v_median  DOUBLE PRECISION;
BEGIN
  FOREACH v_rows IN ARRAY ARRAY[100, 1000, 10000] LOOP
    FOR i IN 1..5 LOOP
      PERFORM fn_bench_server_side(v_rows);
    END LOOP;

    v_samples := ARRAY[]::DOUBLE PRECISION[];
    FOR i IN 1..20 LOOP
      v_started := clock_timestamp();
      PERFORM fn_bench_server_side(v_rows);
      v_ms := EXTRACT(EPOCH FROM (clock_timestamp() - v_started)) * 1000;
      v_samples := v_samples || v_ms;
    END LOOP;

    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY s)
    INTO v_median
    FROM unnest(v_samples) AS s;

    RAISE NOTICE 'rows_per_result_set=% server_side_median_ms=%',
      v_rows, round(v_median::numeric, 1);
  END LOOP;
END;
$$;

-- Clean up:
--   DROP FUNCTION IF EXISTS fn_bench_server_side(int);
