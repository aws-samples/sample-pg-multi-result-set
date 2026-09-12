/*
 * Source SQL Server procedure — the migration starting point.
 *
 * SAMPLE CODE — NOT FOR PRODUCTION USE. This procedure demonstrates the
 * concepts in the accompanying AWS Database Blog post. See README.md.
 *
 * Returns three result sets from a single call. Each SELECT that returns rows
 * to the caller produces a separate result set on the TDS wire protocol, and
 * the application walks them with SqlDataReader.NextResult().
 *
 * CREATE OR ALTER PROCEDURE requires SQL Server 2016 SP1 or later. On an
 * earlier supported release, use CREATE PROCEDURE / ALTER PROCEDURE instead.
 *
 * Run this against SQL Server only. The PostgreSQL conversions live in
 * ../postgresql/.
 */

-- Sample source table, for reference when reproducing the source side.
IF OBJECT_ID('dbo.sales', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.sales (
        sale_id      BIGINT IDENTITY(1,1) PRIMARY KEY,
        customer_id  INT NOT NULL,
        product_id   INT NOT NULL,
        region       NVARCHAR(20) NOT NULL,
        sale_date    DATE NOT NULL,
        amount       DECIMAL(12,2) NOT NULL
    );

    CREATE INDEX idx_sales_date   ON dbo.sales (sale_date);
    CREATE INDEX idx_sales_region ON dbo.sales (region);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_get_sales_dashboard
    @start_date date,
    @end_date   date
AS
BEGIN
    SET NOCOUNT ON;

    -- Result set 1: sales summary by region
    SELECT
        region,
        COUNT_BIG(*) AS sale_count,
        SUM(amount) AS total_amount
    FROM dbo.sales
    WHERE sale_date BETWEEN @start_date AND @end_date
    GROUP BY region
    ORDER BY region;

    -- Result set 2: top 10 customers
    SELECT TOP (10)
        customer_id,
        SUM(amount) AS total_spend
    FROM dbo.sales
    WHERE sale_date BETWEEN @start_date AND @end_date
    GROUP BY customer_id
    ORDER BY total_spend DESC, customer_id;

    -- Result set 3: daily sales trend
    SELECT
        sale_date,
        SUM(amount) AS daily_total
    FROM dbo.sales
    WHERE sale_date BETWEEN @start_date AND @end_date
    GROUP BY sale_date
    ORDER BY sale_date;
END;
GO
