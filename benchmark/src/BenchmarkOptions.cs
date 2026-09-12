using System.Globalization;

namespace MultiResultSetBenchmark;

public sealed class BenchmarkOptions
{
    /// <summary>
    /// Npgsql connection string. Read from the PGCONNSTR environment variable so
    /// that credentials are never passed on the command line.
    /// </summary>
    public string ConnectionString { get; init; } = "";

    /// <summary>Rows returned per result set. Each call returns 15 result sets.</summary>
    public int[] RowCounts { get; init; } = [100, 1_000, 10_000];

    /// <summary>Discarded iterations that warm the buffer cache, connection, and JIT.</summary>
    public int WarmupIterations { get; init; } = 20;

    /// <summary>Timed iterations per data point.</summary>
    public int MeasuredIterations { get; init; } = 100;

    /// <summary>Patterns to measure: temp, json, refcursor.</summary>
    public string[] Patterns { get; init; } = ["refcursor", "temp", "json"];

    /// <summary>Optional path for per-iteration CSV output.</summary>
    public string? CsvPath { get; init; }

    /// <summary>
    /// When false (default), the JSON runner parses the document and accesses
    /// every top-level array, which is the methodology published with this
    /// sample. When true, it also reads every field of every element, matching
    /// how the relational runners consume rows. Use it to see how much of the
    /// JSON cost is deserialization rather than transfer and parsing.
    /// </summary>
    public bool JsonDeepConsume { get; init; }

    public static ParseResult Parse(string[] args, TextWriter error)
    {
        var connectionString = Environment.GetEnvironmentVariable("PGCONNSTR");
        var rowCounts = new[] { 100, 1_000, 10_000 };
        var patterns = new[] { "refcursor", "temp", "json" };
        var warmup = 20;
        var measured = 100;
        string? csvPath = null;
        var jsonDeep = false;

        for (var i = 0; i < args.Length; i++)
        {
            var arg = args[i];
            switch (arg)
            {
                case "--rows":
                {
                    if (!TryTakeValue(args, ref i, out var rowsValue)) return Fail(error, arg);
                    var rowParts = rowsValue.Split(',', StringSplitOptions.RemoveEmptyEntries |
                                                        StringSplitOptions.TrimEntries);
                    var parsedRows = new int[rowParts.Length];
                    for (var r = 0; r < rowParts.Length; r++)
                    {
                        if (!TryParseInt(rowParts[r], out var parsed))
                            return FailValue(error, arg, rowParts[r]);
                        parsedRows[r] = parsed;
                    }
                    rowCounts = parsedRows;
                    break;
                }

                case "--patterns":
                    if (!TryTakeValue(args, ref i, out var patternsValue)) return Fail(error, arg);
                    patterns = patternsValue.Split(',', StringSplitOptions.RemoveEmptyEntries |
                                                        StringSplitOptions.TrimEntries)
                                            .Select(p => p.ToLowerInvariant())
                                            .ToArray();
                    break;

                case "--warmup":
                    if (!TryTakeValue(args, ref i, out var warmupValue)) return Fail(error, arg);
                    if (!TryParseInt(warmupValue, out warmup))
                        return FailValue(error, arg, warmupValue);
                    break;

                case "--iterations":
                    if (!TryTakeValue(args, ref i, out var iterationsValue)) return Fail(error, arg);
                    if (!TryParseInt(iterationsValue, out measured))
                        return FailValue(error, arg, iterationsValue);
                    break;

                case "--csv":
                    if (!TryTakeValue(args, ref i, out var csv)) return Fail(error, arg);
                    csvPath = csv;
                    break;

                case "--json-deep":
                    jsonDeep = true;
                    break;

                case "-h":
                case "--help":
                    PrintUsage(Console.Out);
                    return ParseResult.Help;

                default:
                    error.WriteLine($"Unknown argument: {arg}");
                    PrintUsage(error);
                    return ParseResult.Invalid;
            }
        }

        if (string.IsNullOrWhiteSpace(connectionString))
        {
            error.WriteLine("PGCONNSTR is not set.");
            PrintUsage(error);
            return ParseResult.Invalid;
        }

        var unknownPatterns = patterns.Except(new[] { "temp", "json", "refcursor" }).ToArray();
        if (unknownPatterns.Length > 0)
        {
            error.WriteLine($"Unknown pattern(s): {string.Join(", ", unknownPatterns)}");
            PrintUsage(error);
            return ParseResult.Invalid;
        }

        if (rowCounts.Length == 0 || rowCounts.Any(r => r <= 0))
        {
            error.WriteLine("--rows must be a comma-separated list of positive integers.");
            return ParseResult.Invalid;
        }

        if (measured <= 0 || warmup < 0)
        {
            error.WriteLine("--iterations must be positive and --warmup must not be negative.");
            return ParseResult.Invalid;
        }

        return ParseResult.Ok(new BenchmarkOptions
        {
            ConnectionString   = connectionString,
            RowCounts          = rowCounts,
            Patterns           = patterns,
            WarmupIterations   = warmup,
            MeasuredIterations = measured,
            CsvPath            = csvPath,
            JsonDeepConsume    = jsonDeep,
        });
    }

    private static bool TryTakeValue(string[] args, ref int i, out string value)
    {
        if (i + 1 >= args.Length)
        {
            value = "";
            return false;
        }

        value = args[++i];
        return true;
    }

    /// <summary>
    /// Parses an integer with the invariant culture, so that parsing does not
    /// depend on the host locale. The project sets InvariantGlobalization, and
    /// TryParse also rejects values that overflow Int32 rather than throwing.
    /// </summary>
    private static bool TryParseInt(string value, out int result) =>
        int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out result);

    private static ParseResult Fail(TextWriter error, string arg)
    {
        error.WriteLine($"Missing value for {arg}.");
        PrintUsage(error);
        return ParseResult.Invalid;
    }

    private static ParseResult FailValue(TextWriter error, string arg, string value)
    {
        error.WriteLine($"Invalid integer for {arg}: '{value}'.");
        PrintUsage(error);
        return ParseResult.Invalid;
    }

    public static void PrintUsage(TextWriter writer)
    {
        writer.WriteLine("""
            15-result-set retrieval benchmark for PostgreSQL.

            The connection string is read from the PGCONNSTR environment variable:
              export PGCONNSTR="Host=...;Database=...;Username=...;Password=...;SSL Mode=VerifyFull;Root Certificate=/path/to/global-bundle.pem"

            Usage:
              dotnet run -c Release --project benchmark/src -- [options]

            Options:
              --rows 100,1000,10000     Rows per result set (default: 100,1000,10000)
              --patterns refcursor,temp,json
                                        Patterns to measure (default: all three)
              --warmup 20               Discarded warm-up iterations (default: 20)
              --iterations 100          Measured iterations per data point (default: 100)
              --csv results.csv         Write per-iteration timings to a CSV file
              --json-deep               Also read every field of every JSON element
              -h, --help                Show this help

            Prerequisites:
              psql -f sql/postgresql/01_schema_and_data.sql
              psql -f benchmark/sql/10_benchmark_routines.sql
            """);
    }
}

/// <summary>Outcome of command-line parsing.</summary>
public enum ParseOutcome
{
    Success,
    HelpRequested,
    Invalid,
}

public sealed record ParseResult(ParseOutcome Outcome, BenchmarkOptions? Options)
{
    public static ParseResult Help { get; } = new(ParseOutcome.HelpRequested, null);
    public static ParseResult Invalid { get; } = new(ParseOutcome.Invalid, null);

    public static ParseResult Ok(BenchmarkOptions options) =>
        new(ParseOutcome.Success, options);
}
