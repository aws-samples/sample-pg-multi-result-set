// Runs both PostgreSQL retrieval contracts against the sample schema and prints
// the results, so you can compare the application-side shape of each.
//
// SAMPLE CODE — NOT FOR PRODUCTION USE. This app demonstrates the concepts in
// the accompanying AWS Database Blog post. It has no authorization, structured
// error handling, retries, or observability, and it is not hardened. See
// README.md.
//
// Usage:
//   export PGCONNSTR="Host=...;Database=...;Username=...;Password=...;SSL Mode=VerifyFull;Root Certificate=/path/to/global-bundle.pem"
//   dotnet run --project src/DashboardExamples                    # last 30 days
//   dotnet run --project src/DashboardExamples -- <start> <end>   # explicit range
//
// Keep an explicit range inside the window 01_schema_and_data.sql generates: it
// loads dates relative to CURRENT_DATE, so fixed calendar dates go stale.
//
// The connection string is read from the PGCONNSTR environment variable so that
// credentials are never passed on the command line or committed to source. In
// production, retrieve them from AWS Secrets Manager, or use IAM database
// authentication, instead of a static password.

using System.Text.Json;
using DashboardExamples;

var connectionString = Environment.GetEnvironmentVariable("PGCONNSTR");
if (string.IsNullOrWhiteSpace(connectionString))
{
    Console.Error.WriteLine(
        "PGCONNSTR is not set. Example:\n" +
        "  export PGCONNSTR=\"Host=mycluster.cluster-xxxx.eu-west-1.rds.amazonaws.com;" +
        "Database=postgres;Username=dbadmin;Password=***;SSL Mode=VerifyFull;Root Certificate=/path/to/global-bundle.pem\"");
    return 1;
}

var startDate = args.Length > 0
    ? DateOnly.Parse(args[0])
    : DateOnly.FromDateTime(DateTime.UtcNow).AddDays(-30);
var endDate = args.Length > 1
    ? DateOnly.Parse(args[1])
    : DateOnly.FromDateTime(DateTime.UtcNow);

Console.WriteLine($"Date range: {startDate:yyyy-MM-dd} to {endDate:yyyy-MM-dd}");

// ---------------------------------------------------------------------------
// Approach 1: temporary tables
// ---------------------------------------------------------------------------
Console.WriteLine("\n=== Approach 1: temporary tables ===");
var (salesByRegion, topCustomers, dailyTrend) =
    await TempTableDashboard.GetDashboardAsync(connectionString, startDate, endDate);

Console.WriteLine($"sales_by_region: {salesByRegion.Count} rows");
foreach (var row in salesByRegion)
    Console.WriteLine($"  {row.Region,-6} {row.SaleCount,10:N0} {row.TotalAmount,18:N2}");

Console.WriteLine($"top_customers: {topCustomers.Count} rows");
foreach (var row in topCustomers)
    Console.WriteLine($"  {row.CustomerId,8} {row.TotalSpend,18:N2}");

Console.WriteLine($"daily_trend: {dailyTrend.Count} rows");
foreach (var row in dailyTrend.Take(5))
    Console.WriteLine($"  {row.SaleDate:yyyy-MM-dd} {row.DailyTotal,18:N2}");
if (dailyTrend.Count > 5)
    Console.WriteLine($"  ... {dailyTrend.Count - 5} more rows");

// ---------------------------------------------------------------------------
// Approach 2: JSON aggregation
// ---------------------------------------------------------------------------
Console.WriteLine("\n=== Approach 2: JSON aggregation ===");
using var payload =
    await JsonDashboard.GetDashboardJsonAsync(connectionString, startDate, endDate);

var root = payload.RootElement;
var jsonSalesByRegion = root.GetProperty("sales_by_region");
var jsonTopCustomers  = root.GetProperty("top_customers");
var jsonDailyTrend    = root.GetProperty("daily_trend");

Console.WriteLine($"sales_by_region: {jsonSalesByRegion.GetArrayLength()} elements");
foreach (var element in jsonSalesByRegion.EnumerateArray())
    Console.WriteLine(
        $"  {element.GetProperty("region").GetString(),-6} " +
        $"{element.GetProperty("sale_count").GetInt64(),10:N0} " +
        $"{element.GetProperty("total_amount").GetDecimal(),18:N2}");

Console.WriteLine($"top_customers: {jsonTopCustomers.GetArrayLength()} elements");
foreach (var element in jsonTopCustomers.EnumerateArray())
    Console.WriteLine(
        $"  {element.GetProperty("customer_id").GetInt32(),8} " +
        $"{element.GetProperty("total_spend").GetDecimal(),18:N2}");

Console.WriteLine($"daily_trend: {jsonDailyTrend.GetArrayLength()} elements");
Console.WriteLine("first element: " + FirstElementOrEmpty(jsonDailyTrend));

return 0;

static string FirstElementOrEmpty(JsonElement array) =>
    array.GetArrayLength() == 0 ? "[]" : array[0].GetRawText();
