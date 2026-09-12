// 15-result-set retrieval benchmark: refcursor baseline vs temporary tables vs
// JSON aggregation.
//
// SAMPLE CODE — NOT FOR PRODUCTION USE. This harness exists to reproduce the
// measurements in the accompanying AWS Database Blog post. See README.md.
//
// Methodology, matching the results published with this sample:
//   * One connection stays open for a whole data point (one pattern at one
//     rows-per-result-set value).
//   * Warm-up iterations populate the buffer cache and stabilize connection and
//     JIT state; they are discarded.
//   * Measured iterations are timed end to end with Stopwatch: routine
//     invocation, retrieval of all 15 result sets, and payload consumption.
//   * Only the rows-per-result-set parameter changes between data points.
//
// Usage:
//   export PGCONNSTR="Host=...;Database=...;Username=...;Password=...;SSL Mode=VerifyFull;Root Certificate=/path/to/global-bundle.pem"
//   dotnet run -c Release --project benchmark/src -- --rows 100,1000,10000
//
// Run this on a client close to the database — ideally in the same Availability
// Zone — so that the numbers are not dominated by network round-trip time.

using System.Diagnostics;
using System.Globalization;
using System.Text;
using MultiResultSetBenchmark;
using MultiResultSetBenchmark.Runners;
using Npgsql;

var parsed = BenchmarkOptions.Parse(args, Console.Error);
if (parsed.Outcome == ParseOutcome.HelpRequested)
    return 0;
if (parsed.Outcome != ParseOutcome.Success || parsed.Options is null)
    return 1;

var options = parsed.Options;

using var cts = new CancellationTokenSource();
Console.CancelKeyPress += (_, eventArgs) =>
{
    eventArgs.Cancel = true;      // Let the current iteration unwind cleanly.
    cts.Cancel();
};
var ct = cts.Token;

var runners = options.Patterns
    .Select(pattern => (PatternRunner)(pattern switch
    {
        "temp"      => new TempTableRunner(),
        "json"      => new JsonRunner(options.JsonDeepConsume),
        "refcursor" => new RefcursorRunner(),
        _           => throw new InvalidOperationException($"Unhandled pattern '{pattern}'."),
    }))
    .ToArray();

await PrintEnvironmentAsync(options.ConnectionString, ct);

Console.WriteLine();
Console.WriteLine($"Result sets per call : {PatternRunner.ResultSetCount}");
Console.WriteLine($"Rows per result set  : {string.Join(", ", options.RowCounts)}");
Console.WriteLine($"Warm-up iterations   : {options.WarmupIterations} (discarded)");
Console.WriteLine($"Measured iterations  : {options.MeasuredIterations}");
foreach (var runner in runners)
    Console.WriteLine($"Pattern '{runner.Name}' : {runner.Description}");

var measurements = new List<Measurement>();
var csv = new StringBuilder("pattern,rows_per_result_set,iteration,elapsed_ms,rows_consumed\n");

try
{
    foreach (var runner in runners)
    {
        foreach (var rows in options.RowCounts)
        {
            Console.WriteLine();
            Console.WriteLine($"--- {runner.Name} @ {rows:N0} rows/result set ---");

            await using var conn = new NpgsqlConnection(options.ConnectionString);
            await conn.OpenAsync(ct);

            for (var i = 0; i < options.WarmupIterations; i++)
            {
                ct.ThrowIfCancellationRequested();
                await runner.RunIterationAsync(conn, rows, ct);
            }

            var samples = new double[options.MeasuredIterations];
            long consumedTotal = 0;
            var stopwatch = new Stopwatch();

            for (var i = 0; i < options.MeasuredIterations; i++)
            {
                ct.ThrowIfCancellationRequested();

                stopwatch.Restart();
                var consumed = await runner.RunIterationAsync(conn, rows, ct);
                stopwatch.Stop();

                samples[i] = stopwatch.Elapsed.TotalMilliseconds;
                consumedTotal += consumed;

                csv.Append(CultureInfo.InvariantCulture,
                    $"{runner.Name},{rows},{i + 1},{samples[i]:F3},{consumed}\n");
            }

            var stats = LatencyStats.From(samples);
            var rowsPerIteration = consumedTotal / options.MeasuredIterations;
            measurements.Add(new Measurement(runner.Name, rows, stats, rowsPerIteration));

            Console.WriteLine(
                $"p50 {stats.P50Ms,9:F1} ms   p95 {stats.P95Ms,9:F1} ms   " +
                $"min {stats.MinMs,9:F1} ms   max {stats.MaxMs,9:F1} ms   " +
                $"rows/iteration {rowsPerIteration:N0}");
        }
    }
}
catch (OperationCanceledException)
{
    Console.Error.WriteLine("\nCancelled. Reporting the data points completed so far.");
}

if (measurements.Count == 0)
{
    Console.Error.WriteLine("No data points completed.");
    return 1;
}

PrintSummary(measurements);

if (options.CsvPath is { } csvPath)
{
    await File.WriteAllTextAsync(csvPath, csv.ToString(), ct);
    Console.WriteLine($"\nPer-iteration timings written to {csvPath}");
}

// Referencing the sink keeps the row and field reads from being optimized away.
if (RowConsumer.Sink == long.MinValue)
    Console.WriteLine("unreachable");

return 0;

static async Task PrintEnvironmentAsync(string connectionString, CancellationToken ct)
{
    await using var conn = new NpgsqlConnection(connectionString);
    await conn.OpenAsync(ct);

    await using var cmd = new NpgsqlCommand(
        """
        SELECT version(),
               current_setting('shared_buffers'),
               current_setting('work_mem'),
               current_setting('temp_buffers'),
               (SELECT count(*) FROM sales)
        """, conn);

    await using var reader = await cmd.ExecuteReaderAsync(ct);
    if (!await reader.ReadAsync(ct))
        return;

    Console.WriteLine($"Server               : {reader.GetString(0)}");
    Console.WriteLine($"shared_buffers       : {reader.GetString(1)}");
    Console.WriteLine($"work_mem             : {reader.GetString(2)}");
    Console.WriteLine($"temp_buffers         : {reader.GetString(3)}");
    Console.WriteLine($"sales rows           : {reader.GetInt64(4):N0}");
    Console.WriteLine($"Client               : .NET {Environment.Version}, " +
                      $"Npgsql {typeof(NpgsqlConnection).Assembly.GetName().Version}");
}

static void PrintSummary(List<Measurement> measurements)
{
    Console.WriteLine();
    Console.WriteLine("=== Summary: end-to-end latency (ms) ===");
    Console.WriteLine(
        $"{"pattern",-10} {"rows/set",10} {"p50",10} {"p95",10} {"p99",10} {"mean",10}");

    foreach (var m in measurements.OrderBy(m => m.RowsPerResultSet).ThenBy(m => m.Pattern))
    {
        Console.WriteLine(
            $"{m.Pattern,-10} {m.RowsPerResultSet,10:N0} {m.Stats.P50Ms,10:F1} " +
            $"{m.Stats.P95Ms,10:F1} {m.Stats.P99Ms,10:F1} {m.Stats.MeanMs,10:F1}");
    }

    // Relative p50 comparison per row count, against the slowest pattern.
    Console.WriteLine();
    Console.WriteLine("=== Relative p50 by rows per result set (1.00 = fastest) ===");
    foreach (var group in measurements.GroupBy(m => m.RowsPerResultSet)
                                      .OrderBy(g => g.Key))
    {
        var fastest = group.Min(m => m.Stats.P50Ms);
        var parts = group.OrderBy(m => m.Stats.P50Ms)
                         .Select(m => $"{m.Pattern} {m.Stats.P50Ms / fastest:F2}x");
        Console.WriteLine($"{group.Key,10:N0}   {string.Join("   ", parts)}");
    }

    Console.WriteLine();
    Console.WriteLine(
        "Results vary with row width, query plans, instance class, concurrency,");
    Console.WriteLine(
        "network topology, data distribution, and client parsing. Benchmark with");
    Console.WriteLine(
        "representative production inputs and concurrency before choosing a contract.");
}

internal readonly record struct Measurement(
    string Pattern,
    int RowsPerResultSet,
    LatencyStats Stats,
    long RowsPerIteration);
