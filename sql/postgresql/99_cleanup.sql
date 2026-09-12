-- Remove the sample database objects.
--
-- SAMPLE CODE — NOT FOR PRODUCTION USE. This script demonstrates the concepts
-- in the accompanying AWS Database Blog post. See README.md.
--
-- ============================== DESTRUCTIVE ===============================
-- `DROP TABLE IF EXISTS sales` below is irreversible. `sales` is a common table
-- name, and `IF EXISTS` is not a safety control — it suppresses the error when
-- the object is absent, and silently drops it when it is present, whether or not
-- that object is the one this walkthrough created.
--
-- Confirm you are connected to the throwaway database before running this:
--
--   SELECT current_database(), current_schema();
--
-- If this is a database you intend to keep, drop the routines only and remove
-- the DROP TABLE statement.
-- ==========================================================================
--
-- Session-scoped temporary tables are dropped when their transaction commits or
-- rolls back, or when the connection closes, so they need no explicit cleanup.
--
-- Usage, from the repository root:
--   psql "$PSQL_CONN" -v ON_ERROR_STOP=1 -f sql/postgresql/99_cleanup.sql

-- Production patterns
DROP PROCEDURE IF EXISTS sp_dashboard_temp(date, date);
DROP FUNCTION  IF EXISTS fn_dashboard_json(date, date);

-- Benchmark routines (see ../../benchmark/sql/10_benchmark_routines.sql)
DROP PROCEDURE IF EXISTS sp_dashboard_temp_bench(int);
DROP FUNCTION  IF EXISTS fn_dashboard_json_bench(int);
DROP FUNCTION  IF EXISTS fn_bench_server_side(int);
DROP PROCEDURE IF EXISTS sp_dashboard_refcursor_bench(
  int,
  refcursor, refcursor, refcursor, refcursor, refcursor,
  refcursor, refcursor, refcursor, refcursor, refcursor,
  refcursor, refcursor, refcursor, refcursor, refcursor
);

DROP TABLE IF EXISTS sales;

-- The benchmark sampling extension is left in place because other objects in a
-- shared database may depend on it. Drop it explicitly if this database was
-- created only for the walkthrough:
--   DROP EXTENSION IF EXISTS tsm_system_rows;
