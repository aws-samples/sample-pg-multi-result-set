using Npgsql;

namespace MultiResultSetBenchmark.Runners;

/// <summary>
/// One retrieval contract under test. A runner executes a complete end-to-end
/// operation: invoke the routine, retrieve all 15 result sets, and consume the
/// payload. The caller times the whole call.
/// </summary>
public abstract class PatternRunner
{
    /// <summary>Number of logical result sets each routine returns.</summary>
    public const int ResultSetCount = 15;

    public abstract string Name { get; }

    /// <summary>Short description printed in the results header.</summary>
    public abstract string Description { get; }

    /// <summary>
    /// Runs one complete iteration and returns the number of rows (or JSON
    /// elements) consumed. The return value is accumulated by the caller so that
    /// the reads cannot be optimized away, and is reported as a sanity check.
    /// </summary>
    public abstract Task<long> RunIterationAsync(
        NpgsqlConnection conn,
        int rowsPerResultSet,
        CancellationToken ct);

    /// <summary>Result-set identifiers rs01..rs15, matching the SQL routines.</summary>
    protected static string[] ResultSetSuffixes { get; } =
        Enumerable.Range(1, ResultSetCount).Select(i => i.ToString("00")).ToArray();
}
