-- Sample schema and data for the PostgreSQL side of the walkthrough.
--
-- SAMPLE CODE — NOT FOR PRODUCTION USE. This script demonstrates the concepts
-- in the accompanying AWS Database Blog post. See README.md.
--
-- ============================ READ THIS FIRST =============================
-- This script CREATES an unqualified table named `sales`, and 99_cleanup.sql
-- DROPS it. `sales` is a common name. Run this in a database or schema created
-- solely for this walkthrough, never in one holding data you care about.
--
--   CREATE DATABASE mrs_demo;   -- then connect to mrs_demo and run this script
--
-- The `IF EXISTS` clauses in 99_cleanup.sql are not a safety control; they only
-- suppress errors when an object is absent. They will not stop the script from
-- dropping a pre-existing `sales` table that belongs to someone else.
-- ==========================================================================
--
-- Loads 1,000,000 synthetic rows by default. Adjust the generate_series bound
-- for your test environment; the benchmark numbers published with this sample
-- used 1,000,000 rows. Loading this volume consumes storage and I/O, so keep it
-- off shared and production instances.
--
-- Usage, from the repository root:
--   psql "$PSQL_CONN" -v ON_ERROR_STOP=1 -f sql/postgresql/01_schema_and_data.sql

\timing on

CREATE TABLE sales (
  sale_id      BIGSERIAL PRIMARY KEY,
  customer_id  INT NOT NULL,
  product_id   INT NOT NULL,
  region       TEXT NOT NULL,
  sale_date    DATE NOT NULL,
  amount       NUMERIC(12,2) NOT NULL
);

CREATE INDEX idx_sales_date   ON sales (sale_date);
CREATE INDEX idx_sales_region ON sales (region);

-- Populate with test data (adjust scale as needed)
INSERT INTO sales (customer_id, product_id, region, sale_date, amount)
SELECT
  1 + floor(random() * 10000)::INT,
  1 + floor(random() * 500)::INT,
  (ARRAY['NA','EMEA','APAC','LATAM'])[1 + floor(random() * 4)::INT],
  CURRENT_DATE - floor(random() * 365)::INT,
  (random() * 10000)::NUMERIC(12,2)
FROM generate_series(1, 1000000);

ANALYZE sales;
