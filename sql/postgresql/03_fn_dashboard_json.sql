-- Approach 2: return one document through JSON aggregation.
--
-- SAMPLE CODE — NOT FOR PRODUCTION USE. This routine demonstrates the concepts
-- in the accompanying AWS Database Blog post. See README.md.
--
-- Each top-level property is one logical result set; each value is an array of
-- rows. The caller issues a single query and parses the document client-side.
--
-- COALESCE returns an empty array instead of a JSON null when a query returns
-- no rows. An ORDER BY in a subquery does not carry through the surrounding
-- aggregate, so every array that has an ordering contract sets its order on the
-- jsonb_agg call itself. All three arrays here reproduce the ordering the source
-- procedure guarantees.
--
-- In top_customers the ordering appears twice and the two clauses do different
-- jobs: ORDER BY total_spend DESC, customer_id in the subquery decides *which*
-- ten rows qualify, and the same clause inside jsonb_agg fixes the order they
-- are emitted in. The customer_id tie-break matches the source procedure;
-- without it, customers tied at the tenth position could make PostgreSQL select
-- a different set of ten rows than SQL Server.
--
-- Client-side counterpart: src/DashboardExamples/JsonDashboard.cs

CREATE OR REPLACE FUNCTION fn_dashboard_json(
  p_start_date DATE,
  p_end_date   DATE
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'sales_by_region', (
      SELECT COALESCE(jsonb_agg(t ORDER BY region), '[]'::jsonb)
      FROM (
        SELECT region, COUNT(*) AS sale_count, SUM(amount) AS total_amount
        FROM sales
        WHERE sale_date BETWEEN p_start_date AND p_end_date
        GROUP BY region
      ) t
    ),
    'top_customers', (
      SELECT COALESCE(jsonb_agg(t ORDER BY total_spend DESC, customer_id), '[]'::jsonb)
      FROM (
        SELECT customer_id, SUM(amount) AS total_spend
        FROM sales
        WHERE sale_date BETWEEN p_start_date AND p_end_date
        GROUP BY customer_id
        ORDER BY total_spend DESC, customer_id
        LIMIT 10
      ) t
    ),
    'daily_trend', (
      SELECT COALESCE(jsonb_agg(t ORDER BY sale_date), '[]'::jsonb)
      FROM (
        SELECT sale_date, SUM(amount) AS daily_total
        FROM sales
        WHERE sale_date BETWEEN p_start_date AND p_end_date
        GROUP BY sale_date
      ) t
    )
  ) INTO v_result;

  RETURN v_result;
END;
$$;

-- psql demonstration:
--
--   SELECT jsonb_pretty(fn_dashboard_json(CURRENT_DATE - 30, CURRENT_DATE));
--
-- jsonb is generally preferable when PostgreSQL must inspect or manipulate the
-- document. If the function only builds the value and returns it immediately,
-- benchmark json against jsonb for your workload.
