// Approach 2: read one JSON document and parse it client-side.
//
// SQL counterpart: sql/postgresql/03_fn_dashboard_json.sql
//
// One query returns every logical result set, which removes the session
// affinity and the follow-up queries required by the temporary-table contract.
// In exchange, PostgreSQL builds the complete JSON value before returning it and
// the client materializes another representation while parsing it. Keep payloads
// bounded and test memory consumption with peak production inputs.

using System.Text.Json;
using Npgsql;
using NpgsqlTypes;

namespace DashboardExamples;

public static class JsonDashboard
{
    public static async Task<JsonDocument> GetDashboardJsonAsync(
        string connectionString,
        DateOnly startDate,
        DateOnly endDate,
        CancellationToken ct = default)
    {
        await using var conn = new NpgsqlConnection(connectionString);
        await conn.OpenAsync(ct);

        await using var cmd = new NpgsqlCommand(
            "SELECT fn_dashboard_json($1, $2)", conn);
        cmd.Parameters.Add(new NpgsqlParameter
            { NpgsqlDbType = NpgsqlDbType.Date, Value = startDate });
        cmd.Parameters.Add(new NpgsqlParameter
            { NpgsqlDbType = NpgsqlDbType.Date, Value = endDate });

        // Npgsql returns jsonb as a string by default; parse with System.Text.Json.
        var raw = (string)(await cmd.ExecuteScalarAsync(ct))!;
        return JsonDocument.Parse(raw);
    }
}
