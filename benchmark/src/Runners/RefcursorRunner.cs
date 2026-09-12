using Npgsql;

namespace MultiResultSetBenchmark.Runners;

/// <summary>
/// Refcursor baseline: one CALL opens 15 server-side cursors, and the client
/// fetches each one separately inside the same transaction.
/// </summary>
/// <remarks>
/// The cursor names are supplied as literals so that each portal has a
/// predictable name to FETCH from. PostgreSQL would otherwise generate names
/// such as &lt;unnamed portal 1&gt;, which the client would have to read back from
/// the procedure's INOUT parameters. Committing closes the non-holdable cursors.
/// </remarks>
public sealed class RefcursorRunner : PatternRunner
{
    public override string Name => "refcursor";

    public override string Description =>
        "CALL sp_dashboard_refcursor_bench + 15 FETCH ALL in one transaction";

    // Generated in code, not taken from user input, so string interpolation into
    // the statements below cannot introduce injection.
    private static readonly string[] CursorNames = ResultSetSuffixes
        .Select(s => $"bc{s}")
        .ToArray();

    private static readonly string CallSql =
        "CALL sp_dashboard_refcursor_bench($1, " +
        string.Join(", ", CursorNames.Select(name => $"'{name}'::refcursor")) +
        ")";

    private static readonly string[] FetchStatements = CursorNames
        .Select(name => $"FETCH ALL FROM {name}")
        .ToArray();

    public override async Task<long> RunIterationAsync(
        NpgsqlConnection conn,
        int rowsPerResultSet,
        CancellationToken ct)
    {
        long consumed = 0;

        // Refcursors are only valid inside the transaction that opened them.
        await using var tx = await conn.BeginTransactionAsync(ct);

        await using (var call = new NpgsqlCommand(CallSql, conn, tx))
        {
            call.Parameters.AddWithValue(rowsPerResultSet);
            await call.ExecuteNonQueryAsync(ct);
        }

        foreach (var sql in FetchStatements)
        {
            await using var cmd = new NpgsqlCommand(sql, conn, tx);
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            consumed += await RowConsumer.ConsumeAsync(reader, ct);
        }

        await tx.CommitAsync(ct);   // Closes the cursors.
        return consumed;
    }
}
