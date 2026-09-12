# Migrate SQL Server multi-result-set procedures to PostgreSQL

Companion code for the AWS Database Blog post *Migrate SQL Server
multi-result-set procedures to PostgreSQL*.

> [!IMPORTANT]
> **This is sample code, for non-production usage. You should work with your
> security and legal teams to meet your organizational security, regulatory and
> compliance requirements before deployment.**
>
> This repository exists to demonstrate the concepts discussed in the blog post.
> It is intentionally minimal so each pattern can be read end to end, and it
> omits things production systems require: input validation and authorization,
> error handling and retry logic, observability, secrets management, resource
> limits, schema qualification and migration tooling, and hardening of the
> provisioning scripts. The SQL creates and drops unqualified objects and the AWS
> scripts create billable resources and delete them without final snapshots. Run
> it only in a disposable database and a non-production AWS account. Treat the
> patterns as a reference to adapt — not as code to deploy as-is.

A SQL Server stored procedure can return multiple result sets from a single
call — a pattern commonly used to populate a BI dashboard. Every `SELECT` that
returns rows to the caller produces a separate result set on the TDS wire
protocol, and the application walks them with `SqlDataReader.NextResult()`.

PostgreSQL does not stream multiple independent result sets from a single call
the same way. It can expose multiple query results through `refcursor` output
parameters, but the application must fetch each cursor separately within the same
transaction. This repository implements two alternatives to refcursors, converts
the same source procedure with both, and benchmarks them against a refcursor
baseline:

| Approach | Result shape | Application flow |
|---|---|---|
| **Temporary tables** | Separate relational tables | One `CALL`, then one query per table on the same connection and transaction |
| **JSON aggregation** | One document with a named array per logical result set | One function query, then client-side JSON parsing |

Prefer temporary tables when results can be large, the client streams rows, or
follow-up filtering and indexing are useful; the trade-off is session affinity
and additional queries. Prefer JSON aggregation when results are bounded, one
response is desirable, and the client already handles JSON efficiently; the
trade-off is that the server and client both materialize the complete payload in
memory.

## Repository layout

```
.
├── sql/
│   ├── sqlserver/
│   │   └── 00_usp_get_sales_dashboard.sql   # T-SQL source: 3 result sets in one call
│   └── postgresql/
│       ├── 01_schema_and_data.sql           # sales table + 1M synthetic rows
│       ├── 02_sp_dashboard_temp.sql         # Approach 1: temporary tables
│       ├── 03_fn_dashboard_json.sql         # Approach 2: JSON aggregation
│       ├── 04_validate_equivalence.sql      # Compare both contracts, check empty results
│       └── 99_cleanup.sql                   # Drop the sample objects
├── src/DashboardExamples/                   # .NET 8 / Npgsql client for both approaches
├── benchmark/
│   ├── sql/
│   │   ├── 10_benchmark_routines.sql        # 15-result-set variants of all three patterns
│   │   └── 11_server_side_baseline.sql      # Query cost with no rows returned to the client
│   └── src/                                 # .NET 8 / Npgsql benchmark client
├── scripts/
│   ├── provision-aurora.sh                  # Optional disposable Aurora + EC2 client
│   └── cleanup-aurora.sh                    # Tear the walkthrough resources down
└── docs/benchmark-results.md                # Published results and how to reproduce them
```

## Prerequisites

- PostgreSQL 15 or later. The SQL uses PostgreSQL procedures (PostgreSQL 11+) and
  `jsonb` functions available in earlier releases. It runs on Amazon Aurora
  PostgreSQL-Compatible Edition, Amazon RDS for PostgreSQL, or self-managed
  PostgreSQL.
- .NET 8 SDK or later, and Npgsql 8 or later (restored automatically).
- `psql` for loading the SQL, and the AWS CLI only if you use the provisioning
  scripts.
- SQL Server 2016 SP1 or later to run the source procedure as written
  (`CREATE OR ALTER PROCEDURE`). On an earlier supported release, use
  `ALTER PROCEDURE`.

The published benchmark results were collected on Aurora PostgreSQL 17.7. AWS
provisioning, monitoring, and cleanup steps apply only to the AWS managed-service
walkthrough. Verify that your engine version and instance class are available in
your Region before provisioning.

Shell commands throughout assume a POSIX shell (Linux, macOS, or WSL). The .NET
code itself is platform-neutral — no runtime identifier, no OS-specific APIs — so
it builds and runs on Windows too, but you will need to translate the commands
(`$env:PGCONNSTR = "…"` rather than `export PGCONNSTR="…"`), and the two
provisioning scripts require bash.

### Setting up a fresh benchmark client

`scripts/provision-aurora.sh` launches a bare instance and installs nothing. On
Amazon Linux 2023 (`aarch64`, matching the `c7g.large` used for the published
results):

```bash
sudo dnf install -y dotnet-sdk-8.0 postgresql17
curl -o global-bundle.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
```

Match the `postgresql` package to your server's major version. Note that
Amazon Linux repositories are served from S3, so `dnf` succeeds behind an S3
gateway VPC endpoint with no NAT gateway — that does *not* mean NuGet is
reachable. Check before relying on `dotnet run`, which restores packages:

```bash
curl -sS -m 5 -o /dev/null -w '%{http_code}\n' https://api.nuget.org/v3/index.json
```

Without NuGet access, publish a self-contained binary elsewhere and copy it over
instead — it needs no SDK, no restore, and no ICU on the client:

```bash
dotnet publish benchmark/src -c Release -r linux-arm64 --self-contained true -o ./bench
```

## Quick start

Point `psql` and Npgsql at your database. Keep credentials out of source
control — the sample apps read the connection string from `PGCONNSTR`, and the
provisioning script stores the master password in AWS Secrets Manager.

Use full TLS verification. In Npgsql, `SSL Mode=Require` encrypts the session but
does **not** authenticate the server, so it gives no protection against an
on-path attacker; `VerifyFull` checks both the certificate chain and the hostname.
Download the Amazon RDS CA bundle first:

```bash
curl -o global-bundle.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem

CA="$PWD/global-bundle.pem"
PW='YOUR_PASSWORD'          # single quotes — see the note below

export PGPASSWORD="$PW"
export PSQL_CONN="host=YOUR_ENDPOINT dbname=postgres user=dbadmin sslmode=verify-full sslrootcert=$CA"
export PGCONNSTR="Host=YOUR_ENDPOINT;Database=postgres;Username=dbadmin;Password=${PW};SSL Mode=VerifyFull;Root Certificate=${CA}"
```

Assign the password in **single quotes**, then reference it as `${PW}`. RDS
generates passwords containing shell metacharacters, and `!` triggers bash
history expansion *inside double quotes as well as unquoted* — a pasted password
containing one fails with `event not found` and silently corrupts the line. Only
single quotes and backslashes suppress it; `set +H` disables it for the session.
The same applies to the `rds!cluster-...` secret ARN. Better still, never paste
the literal at all — resolve it from Secrets Manager, as
`scripts/provision-aurora.sh` prints:

```bash
PGPASSWORD=$(aws secretsmanager get-secret-value --region YOUR_REGION \
    --secret-id "$SECRET_ARN" --query SecretString --output text \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')
```

`psql` reads `PGPASSWORD` from the environment, so it never needs the password in
the conninfo string. Npgsql connection strings are `;`-delimited with `=`
separators: if a password contains either character, quote the value
(`Password='...'`) or Npgsql truncates it at the first `;`.

Set `rds.force_ssl=1` in your DB parameter group to reject unencrypted
connections server-side as well. For a self-managed PostgreSQL server, point
`Root Certificate` at the CA that issued your server certificate.

Load the schema and both PostgreSQL contracts:

```bash
psql "$PSQL_CONN" -v ON_ERROR_STOP=1 -f sql/postgresql/01_schema_and_data.sql
psql "$PSQL_CONN" -v ON_ERROR_STOP=1 -f sql/postgresql/02_sp_dashboard_temp.sql
psql "$PSQL_CONN" -v ON_ERROR_STOP=1 -f sql/postgresql/03_fn_dashboard_json.sql
```

Run both retrieval patterns from .NET and compare the application-side shape:

```bash
dotnet run --project src/DashboardExamples
```

With no arguments the app reports on the last 30 days. Pass an explicit range as
`dotnet run --project src/DashboardExamples -- <start> <end>` if you want one,
but keep it inside the rolling window `01_schema_and_data.sql` generates — it
loads dates relative to `CURRENT_DATE`, so fixed calendar dates go stale.

Validate that the two conversions agree, and that empty ranges behave as
documented:

```bash
psql "$PSQL_CONN" -v ON_ERROR_STOP=1 -f sql/postgresql/04_validate_equivalence.sql
```

This defaults to the last 90 days; override it with `-v start_date=…
-v end_date=…`. Every `differences` value must be `0` and every `passed` value
must be `t` — including `range_returns_rows`, which fails when the range you
asked for falls outside the generated data. Without that check an empty range
would satisfy every comparison in the script while validating nothing.

Need a disposable database first? `scripts/provision-aurora.sh` creates one. It
creates billable resources and prompts before doing so; read the header for the
environment variables it expects.

## Approach 1: temporary tables

`sp_dashboard_temp` materializes each logical result set in a session-scoped
temporary table. The caller opens an explicit transaction, calls the procedure,
reads each table, and commits.

`ON COMMIT DROP` is deliberate:

- Without the caller's explicit transaction, `CALL` would complete its own
  transaction and drop the tables before the application could query them.
- Without `ON COMMIT DROP`, the tables could survive for the lifetime of a pooled
  physical connection and collide with a later request.

The procedure call and every follow-up query must use the same open connection
and transaction; do not return the connection to the pool in between. Add
explicit `ORDER BY` clauses wherever row order is part of the application
contract. See `src/DashboardExamples/TempTableDashboard.cs`.

## Approach 2: JSON aggregation

`fn_dashboard_json` returns a single `jsonb` document whose top-level properties
are the logical result sets. `COALESCE(jsonb_agg(...), '[]'::jsonb)` returns an
empty array rather than a JSON null when a query matches no rows. An `ORDER BY`
in a subquery does not carry through the surrounding aggregate, so each array
sets its order on the `jsonb_agg` call itself; all three reproduce the ordering
the source procedure guarantees. In `top_customers` the clause appears twice and
does two jobs — it decides *which* ten rows qualify in the subquery, and fixes
the order they are emitted in inside the aggregate.

One query returns everything, which removes session affinity and follow-up
queries. In exchange, PostgreSQL constructs the complete JSON value before
returning it and the client materializes another representation while parsing it.
Keep payloads bounded and test memory consumption with peak production inputs.
See `src/DashboardExamples/JsonDashboard.cs`.

## Benchmark

The benchmark compares the two approaches with a refcursor baseline. Each variant
returns 15 result sets of exactly `p_rows` rows with the same four-column
projection, so the three contracts can be compared at controlled row counts. The
variants exist for benchmarking only — production code should use the patterns in
`sql/postgresql/`.

```bash
psql "$PSQL_CONN" -v ON_ERROR_STOP=1 -f benchmark/sql/10_benchmark_routines.sql

dotnet run -c Release --project benchmark/src -- \
  --rows 100,1000,10000 --warmup 20 --iterations 100 --csv results.csv
```

To separate the query-execution cost shared by all three contracts from the cost
of the contracts themselves, run the server-side baseline. It executes the same
15 queries but discards the rows inside the server, and reports one median per
tested result-set size:

```bash
psql "$PSQL_CONN" -v ON_ERROR_STOP=1 -f benchmark/sql/11_server_side_baseline.sql
```

The medians arrive as `NOTICE` lines; add `2>&1 | grep rows_per_result_set` to
isolate them. Subtract each from the matching row of the end-to-end table to get
the latency attributable to each retrieval contract.

Run the client close to the database — ideally in the same Availability Zone — or
network round-trip time will dominate the measurement. `dotnet run --project
benchmark/src -- --help` lists all options.

`benchmark/sql/10_benchmark_routines.sql` creates the `tsm_system_rows`
extension, and `benchmark/sql/11_server_side_baseline.sql` does the same so it
can run standalone. `tsm_system_rows` is the only extension used anywhere in this
repository, and only for the benchmark's `TABLESAMPLE` variant — one of the 15
result sets; the walkthrough patterns need no extensions. It is a trusted
extension, so any role with `CREATE` on the database can install it and
`rds_superuser` is not required.

Published results are in [docs/benchmark-results.md](docs/benchmark-results.md).
In summary: JSON aggregation had the lowest p50 latency at 100 rows per result
set and was close to tied with temporary tables at 1,000 rows; at 10,000 rows,
temporary tables had 31.1% lower p50 latency. Temporary tables beat the refcursor
baseline at every tested size. Treat that as a workload-dependent trade-off, not
a universal row-count threshold.

## Migrating your own procedure

1. **Inventory the result sets.** Identify every `SELECT` in the T-SQL body that
   returns rows to the caller rather than assigning to a variable. Record the
   columns, the ordering the caller expects, and the largest payload the
   procedure returns.
2. **Classify by size.** Bounded result sets are JSON candidates; large ones lean
   toward temporary tables. A single procedure can use a hybrid contract, with
   JSON for small summaries and temporary tables for large detail results.
3. **Convert the body to PL/pgSQL.** Most of this is mechanical:
   `SET @x =` becomes `v_x :=`, `ISNULL` becomes `COALESCE`, `GETDATE()` becomes
   `now()`. AWS DMS Schema Conversion can accelerate the schema-object work.
4. **Update the application.** For temporary tables, replace the
   `NextResult()` loop with N sequential queries inside one transaction. For JSON,
   replace it with a single query plus client-side parsing.
5. **Validate functional equivalence.** Compare column names, types, nullability,
   row counts, and — where it is part of the contract — ordering, for normal,
   boundary, empty, and high-volume inputs. Canonicalize values before hashing so
   that intentional type differences are not reported as mismatches. Exercise
   error paths to confirm transactions roll back and pooled connections are
   returned clean.
6. **Then tune and benchmark.** Use `EXPLAIN (ANALYZE, BUFFERS)` and
   `pg_stat_statements` to find expensive scans, sorts, and repeated work, and
   load test with production-like concurrency before cutover.

## Considerations and limitations

**Scope of this sample.** Everything here is written to illustrate the blog
post's two conversion patterns, not to be deployed. In particular it does not
include: authentication or authorization around the routines, input validation
beyond what the examples need, structured error handling and retries, logging,
metrics or tracing, connection-pool tuning, rate or payload limits, schema
qualification and `search_path` hardening, idempotent migration tooling, or
least-privilege database roles. The provisioning scripts optimize for a quick
disposable walkthrough rather than a secure baseline. Before using any of this in
a real system, re-implement it inside your own application's conventions and
threat-model it against your own environment.

**Transactions, pooling, and failure handling.** The temporary-table approach
needs one physical connection for the whole operation: begin the transaction
before `CALL`, commit only after all reads succeed, and roll back on failure.
`ON COMMIT DROP` removes the tables on commit or rollback. Use unique temporary
table names, or prevent repeated calls in the same transaction, if the procedure
can be invoked more than once per transaction.

**Payload size.** The JSON approach has no session-affinity requirement once the
function returns, but a very large document increases server memory, network
payload size, client allocation, and garbage-collection pressure. Set input limits
or paginate detail results instead of returning one unbounded document.

**Ordering, types, and contract versioning.** Neither a SQL table nor a JSON array
should rely on incidental query order. Validate mappings for numerics, dates,
timestamps, nulls, and large integers, because JSON parsers and relational data
readers can expose them differently. Treat top-level JSON property names and
temporary-table column definitions as an API contract, and version them when
making incompatible changes.

**Temporary files and Aurora Optimized Reads.** Temporary tables are not the same
as PostgreSQL temporary files. Small temporary tables can stay in memory through
`temp_buffers`, while sorts, hashes, and similar operations spill to temporary
files when they exceed available working memory. To spot spilling, use
`EXPLAIN (ANALYZE, BUFFERS)`, check `temp_blks_read` and `temp_blks_written` in
`pg_stat_statements`, and monitor the `TempStorageIOPS` and
`TempStorageThroughput` CloudWatch metrics where available. For Aurora workloads
with significant temporary-file I/O, Aurora Optimized Reads places temporary
files on local NVMe storage for supported instance classes (`db.r6gd`,
`db.r8gd`, `db.r6id`). On those classes `temp_tablespaces` points at
`aurora_temp_tablespace`, so temporary tables that outgrow `temp_buffers` are
placed on NVMe as well — which makes this relevant to Approach 1, not only to
sorts and hashes. It does not help temporary operations that stay in memory, and
the benchmark in this repository does not exercise it.

## Cleanup

```bash
psql "$PSQL_CONN" -v ON_ERROR_STOP=1 -f sql/postgresql/99_cleanup.sql
```

If you used the provisioning script, tear the AWS resources down with
`scripts/cleanup-aurora.sh`. It skips final snapshots and permanently deletes the
sample database, so use it only for disposable test resources.

## Security

This sample exists to illustrate two conversion patterns, not to be deployed
as-is. Threat-model your own adaptation of it before it reaches a real
environment.

The sample apps read credentials from the `PGCONNSTR` environment variable and
never log them. In production, retrieve database credentials from AWS Secrets
Manager or use IAM database authentication, restrict inbound port 5432 to your
application tier, and require TLS with full verification (`SSL Mode=VerifyFull`
for Npgsql, `sslmode=verify-full` for `psql`) — `Require` alone does not
authenticate the server.

`scripts/provision-aurora.sh` creates the cluster with `--storage-encrypted`, so
the sample volume is encrypted at rest with the AWS managed key for RDS. Pass
`--kms-key-id` instead if you need control over the key policy or rotation.
Encryption at rest can only be set at creation time: enabling it on an existing
cluster requires a snapshot and restore.

### Database privileges

The walkthrough connects as the Aurora master user (`dbadmin`) because it creates
the schema, the routines, and the benchmark extension in a throwaway database.
Do not carry that over. An application calling these routines needs far less:

```sql
CREATE ROLE dashboard_app LOGIN PASSWORD 'use-a-secret-manager-value';

GRANT CONNECT ON DATABASE mrs_demo TO dashboard_app;
GRANT USAGE ON SCHEMA public TO dashboard_app;

-- Approach 1 also needs the right to create session-scoped temporary tables.
GRANT TEMPORARY ON DATABASE mrs_demo TO dashboard_app;

GRANT SELECT ON sales TO dashboard_app;
GRANT EXECUTE ON PROCEDURE sp_dashboard_temp(date, date) TO dashboard_app;
GRANT EXECUTE ON FUNCTION  fn_dashboard_json(date, date) TO dashboard_app;
```

Note that the temporary-table contract requires `TEMPORARY` on the database,
which the JSON contract does not — one more consideration when choosing between
them. Neither routine needs `rds_superuser`, table ownership, or DDL rights.

Two hazards are worth reading before you run anything:

- The scripts in `sql/postgresql/` create and drop an unqualified table named
  `sales`. Run them in a throwaway database or schema.
- `scripts/cleanup-aurora.sh` permanently deletes a cluster with no final
  snapshot.

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for reporting
security issues — do not open a public GitHub issue.

## Further reading

- [PL/pgSQL — SQL Procedural Language](https://www.postgresql.org/docs/current/plpgsql.html)
- [Improving query performance for Aurora PostgreSQL with Aurora Optimized Reads](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/AuroraPostgreSQL.optimized.reads.html)
- [SQL Server to Aurora PostgreSQL migration playbook](https://docs.aws.amazon.com/dms/latest/sql-server-to-aurora-postgresql-migration-playbook/)
- [AWS DMS Schema Conversion](https://docs.aws.amazon.com/dms/latest/userguide/CHAP_SchemaConversion.html)

## License

This library is licensed under the MIT-0 License. See the [LICENSE](LICENSE) file.
