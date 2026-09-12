namespace MultiResultSetBenchmark;

/// <summary>
/// Percentile summary of one data point (a pattern at one rows-per-result-set
/// value). Percentiles use the nearest-rank method on the sorted samples.
/// </summary>
public sealed record LatencyStats(
    int Count,
    double MinMs,
    double P50Ms,
    double P95Ms,
    double P99Ms,
    double MaxMs,
    double MeanMs)
{
    public static LatencyStats From(IReadOnlyList<double> samplesMs)
    {
        if (samplesMs.Count == 0)
            throw new ArgumentException("No samples to summarize.", nameof(samplesMs));

        var sorted = samplesMs.ToArray();
        Array.Sort(sorted);

        return new LatencyStats(
            Count: sorted.Length,
            MinMs: sorted[0],
            P50Ms: Percentile(sorted, 0.50),
            P95Ms: Percentile(sorted, 0.95),
            P99Ms: Percentile(sorted, 0.99),
            MaxMs: sorted[^1],
            MeanMs: sorted.Average());
    }

    private static double Percentile(double[] sorted, double percentile)
    {
        var rank = (int)Math.Ceiling(percentile * sorted.Length) - 1;
        return sorted[Math.Clamp(rank, 0, sorted.Length - 1)];
    }
}
