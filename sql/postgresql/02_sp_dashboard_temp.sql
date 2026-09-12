-- Approach 1: return relational results through session-scoped temporary tables.
--
-- SAMPLE CODE — NOT FOR PRODUCTION USE. This routine demonstrates the concepts
-- in the accompanying AWS Database Blog post. See README.md.
--
-- The procedure materializes each logical result set in its own temporary
-- table. The caller opens an explicit transaction, calls the procedure, reads
-- each table on the SAME connection and transaction, and then commits.
--
-- ON COMMIT DROP is intentional:
--   * Without the caller's explicit transaction, CALL would complete its own
--     transaction and drop the tables before the application could query them.
--   * Without ON COMMIT DROP, the tables could survive for the lifetime of a
--     pooled physical connection and collide with a later request.
--
-- Client-side counterpart: src/DashboardExamples/TempTableDashboard.cs

CREATE OR REPLACE PROCEDURE sp_dashboard_temp(
  p_start_date DATE,
  p_end_date   DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
  -- Result set 1: Sales summary by region
  CREATE TEMP TABLE tmp_sales_by_region ON COMMIT DROP AS
  SELECT region, COUNT(*) AS sale_count, SUM(amount) AS total_amount
  FROM sales
  WHERE sale_date BETWEEN p_start_date AND p_end_date
  GROUP BY region;

  -- Result set 2: Top 10 customers
  -- The tie-break on customer_id matches the source procedure's
  -- ORDER BY total_spend DESC, customer_id. Without it, customers tied at the
  -- tenth position could make PostgreSQL select a different set of ten rows
  -- than SQL Server.
  CREATE TEMP TABLE tmp_top_customers ON COMMIT DROP AS
  SELECT customer_id, SUM(amount) AS total_spend
  FROM sales
  WHERE sale_date BETWEEN p_start_date AND p_end_date
  GROUP BY customer_id
  ORDER BY total_spend DESC, customer_id
  LIMIT 10;

  -- Result set 3: Daily trend
  CREATE TEMP TABLE tmp_daily_trend ON COMMIT DROP AS
  SELECT sale_date, SUM(amount) AS daily_total
  FROM sales
  WHERE sale_date BETWEEN p_start_date AND p_end_date
  GROUP BY sale_date
  ORDER BY sale_date;

  -- Add as many temp tables as you have result sets...
END;
$$;

-- psql demonstration of the required call pattern. Note that the reads happen
-- inside the same transaction as the CALL, and that ORDER BY is explicit on
-- every retrieval query whose row order is part of the application contract.
--
--   BEGIN;
--   CALL sp_dashboard_temp(CURRENT_DATE - 30, CURRENT_DATE);
--   SELECT region, sale_count, total_amount FROM tmp_sales_by_region ORDER BY region;
--   SELECT customer_id, total_spend FROM tmp_top_customers ORDER BY total_spend DESC, customer_id;
--   SELECT sale_date, daily_total FROM tmp_daily_trend ORDER BY sale_date;
--   COMMIT;  -- ON COMMIT DROP removes the temporary tables here.
