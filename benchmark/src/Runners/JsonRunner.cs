using System.Text.Json;
using Npgsql;

namespace MultiResultSetBenchmark.Runners;

/// <summary>
/// JSON aggregation contract: one query returns a single jsonb document holding
/// all 15 result sets, which the client parses.
/// </summary>
/// <remarks>
/// By default the runner parses the complete document and accesses every
/// top-level array, which is the methodology published with this sample. With
/// <see cref="BenchmarkOptions.JsonDeepConsume"/>, it also reads every field of
/// every element, matching how the relational runners consume rows.
/// </remarks>
public sealed class JsonRunner(bool deepConsume) : PatternRunner
{
    public override string Name => "json";

    public override string Description => deepConsume
        ? "SELECT fn_dashboard_json_bench + parse + read every field"
        : "SELECT fn_dashboard_json_bench + parse + access every top-level array";

    private static readonly string[] PropertyNames = ResultSetSuffixes
        .Select(s => $"rs{s}")
        .ToArray();

    public override async Task<long> RunIterationAsync(
        NpgsqlConnection conn,
        int rowsPerResultSet,
        CancellationToken ct)
    {
        await using var cmd = new NpgsqlCommand("SELECT fn_dashboard_json_bench($1)", conn);
        cmd.Parameters.AddWithValue(rowsPerResultSet);

        // Npgsql returns jsonb as a string by default; parse with System.Text.Json.
        var raw = (string)(await cmd.ExecuteScalarAsync(ct))!;
        using var document = JsonDocument.Parse(raw);

        long consumed = 0;
        long sink = 0;
        var root = document.RootElement;

        foreach (var propertyName in PropertyNames)
        {
            var array = root.GetProperty(propertyName);
            consumed += array.GetArrayLength();

            if (!deepConsume)
                continue;

            foreach (var element in array.EnumerateArray())
            {
                sink += element.GetProperty("sale_id").GetInt64()
                      + element.GetProperty("region").GetString()!.Length
                      + DateOnly.Parse(element.GetProperty("sale_date").GetString()!).DayNumber
                      + (long)element.GetProperty("amount").GetDecimal();
            }
        }

        RowConsumer.Sink += sink + consumed;
        return consumed;
    }
}
