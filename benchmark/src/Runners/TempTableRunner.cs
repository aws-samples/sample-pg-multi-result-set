using Npgsql;

namespace MultiResultSetBenchmark.Runners;

/// <summary>
/// Temporary-table contract: one CALL that materializes 15 temporary tables,
/// followed by one SELECT per table on the same connection and transaction.
/// Committing drops the tables (ON COMMIT DROP).
/// </summary>
public sealed class TempTableRunner : PatternRunner
{
    public override string Name => "temp";

    public override string Description =>
        "CALL sp_dashboard_temp_bench + 15 SELECTs in one transaction";

    private static readonly string[] SelectStatements = ResultSetSuffixes
        .Select(s => $"SELECT sale_id, region, sale_date, amount FROM tmp_rs{s}")
        .ToArray();

    public override async Task<long> RunIterationAsync(
        NpgsqlConnection conn,
        int rowsPerResultSet,
        CancellationToken ct)
    {
        long consumed = 0;

        // The temporary tables live only inside this transaction.
        await using var tx = await conn.BeginTransactionAsync(ct);

        await using (var call = new NpgsqlCommand(
                         "CALL sp_dashboard_temp_bench($1)", conn, tx))
        {
            call.Parameters.AddWithValue(rowsPerResultSet);
            await call.ExecuteNonQueryAsync(ct);
        }

        foreach (var sql in SelectStatements)
        {
            await using var cmd = new NpgsqlCommand(sql, conn, tx);
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            consumed += await RowConsumer.ConsumeAsync(reader, ct);
        }

        await tx.CommitAsync(ct);
        return consumed;
    }
}
