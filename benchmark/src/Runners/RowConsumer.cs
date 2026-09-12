using Npgsql;

namespace MultiResultSetBenchmark.Runners;

/// <summary>
/// Reads every row and accesses every field, so the relational runners pay the
/// full deserialization cost rather than only the transfer cost.
/// </summary>
internal static class RowConsumer
{
    /// <summary>
    /// Accumulates a value derived from every field. It is never read for
    /// correctness, but it prevents the reads from being elided.
    /// </summary>
    internal static long Sink;

    /// <summary>
    /// Consumes a reader over (sale_id bigint, region text, sale_date date,
    /// amount numeric) and returns the row count.
    /// </summary>
    internal static async Task<long> ConsumeAsync(NpgsqlDataReader reader, CancellationToken ct)
    {
        long rows = 0;
        long sink = 0;

        while (await reader.ReadAsync(ct))
        {
            var saleId   = reader.GetInt64(0);
            var region   = reader.GetString(1);
            var saleDate = reader.GetFieldValue<DateOnly>(2);
            var amount   = reader.GetDecimal(3);

            sink += saleId + region.Length + saleDate.DayNumber + (long)amount;
            rows++;
        }

        Sink += sink;
        return rows;
    }
}
