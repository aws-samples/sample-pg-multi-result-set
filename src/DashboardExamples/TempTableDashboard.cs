// Approach 1: read relational results from session-scoped temporary tables.
//
// SQL counterpart: sql/postgresql/02_sp_dashboard_temp.sql
//
// The procedure call and every follow-up query must use the same open
// connection and transaction. Do not return the connection to the pool between
// those operations. Put explicit ORDER BY clauses on the retrieval queries when
// row order is part of the application contract.

using Npgsql;
using NpgsqlTypes;

namespace DashboardExamples;

public record SalesByRegionRow(string Region, long SaleCount, decimal TotalAmount);
public record TopCustomerRow(int CustomerId, decimal TotalSpend);
public record DailyTrendRow(DateOnly SaleDate, decimal DailyTotal);

public static class TempTableDashboard
{
    public static async Task<(
        List<SalesByRegionRow> SalesByRegion,
        List<TopCustomerRow>   TopCustomers,
        List<DailyTrendRow>    DailyTrend)>
    GetDashboardAsync(
        string connectionString,
        DateOnly startDate,
        DateOnly endDate,
        CancellationToken ct = default)
    {
        await using var conn = new NpgsqlConnection(connectionString);
        await conn.OpenAsync(ct);

        // Explicit transaction: temp tables created in the CALL must be visible
        // to subsequent SELECTs on the SAME connection/transaction.
        await using var tx = await conn.BeginTransactionAsync(ct);

        // 1) Invoke the stored procedure that populates the temp tables.
        await using (var call = new NpgsqlCommand(
                         "CALL sp_dashboard_temp($1, $2)", conn, tx))
        {
            call.Parameters.Add(new NpgsqlParameter
                { NpgsqlDbType = NpgsqlDbType.Date, Value = startDate });
            call.Parameters.Add(new NpgsqlParameter
                { NpgsqlDbType = NpgsqlDbType.Date, Value = endDate });
            await call.ExecuteNonQueryAsync(ct);
        }

        // 2) Read each temp table sequentially on the same connection/transaction.
        var salesByRegion = await ReadAsync(conn, tx,
            "SELECT region, sale_count, total_amount FROM tmp_sales_by_region ORDER BY region",
            r => new SalesByRegionRow(
                r.GetString(0), r.GetInt64(1), r.GetDecimal(2)),
            ct);

        var topCustomers = await ReadAsync(conn, tx,
            "SELECT customer_id, total_spend FROM tmp_top_customers ORDER BY total_spend DESC, customer_id",
            r => new TopCustomerRow(r.GetInt32(0), r.GetDecimal(1)),
            ct);

        var dailyTrend = await ReadAsync(conn, tx,
            "SELECT sale_date, daily_total FROM tmp_daily_trend ORDER BY sale_date",
            r => new DailyTrendRow(
                DateOnly.FromDateTime(r.GetDateTime(0)), r.GetDecimal(1)),
            ct);

        await tx.CommitAsync(ct);   // ON COMMIT DROP cleans up the temp tables here.
        return (salesByRegion, topCustomers, dailyTrend);
    }

    private static async Task<List<T>> ReadAsync<T>(
        NpgsqlConnection conn,
        NpgsqlTransaction tx,
        string sql,
        Func<NpgsqlDataReader, T> map,
        CancellationToken ct)
    {
        var rows = new List<T>();
        await using var cmd = new NpgsqlCommand(sql, conn, tx);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
            rows.Add(map(reader));
        return rows;
    }
}
