# Benchmark results

> [!IMPORTANT]
> **Sample code — not for production use.** These measurements come from a
> demonstration harness built to illustrate the concepts in the accompanying AWS
> Database Blog post. See [README](../README.md).

These are the published results for the 15-result-set benchmark. They are a
single point of reference, not a threshold to apply to your own workload. Run
`benchmark/src` against your data before choosing a retrieval contract.

## Environment

| Component | Value |
|---|---|
| Database | Aurora PostgreSQL-Compatible Edition 17.7, `db.r6g.large` writer |
| Client | `c7g.large` EC2 instance, .NET 8 / Npgsql 8, same Availability Zone |
| Source data | 1,000,000 rows in `sales` |
| Result sets per call | 15, each with the same four-column projection |
| Rows per result set | 100, 1,000, 10,000 |
| Iterations | 20 discarded warm-up, 100 measured, per data point |
| Connection | one connection held open for the whole data point |

## Methodology

Each pattern ran through the same .NET/Npgsql client. Timing covers the complete
end-to-end operation: invoke the routine, retrieve all 15 result sets, and
consume the payload. For the relational patterns the client read every row and
accessed every field. For JSON it parsed the complete document and accessed every
top-level array. Between data points, only the rows-per-result-set parameter
changed; the cluster, client, source data, projection, and result-set count
stayed constant.

Two properties of the environment matter when reading the numbers:

- The `sales` table fits entirely in `shared_buffers`, so all plans ran fully
  cached and no sort spilled to disk.
- The heavier queries each planned two parallel workers. On a `db.r6g.large`
  (2 vCPUs) that means these figures are single-session latency on a
  deliberately unconstrained instance, not behavior under concurrency.

## End-to-end latency

| Rows per result set | Refcursor p50 / p95 (ms) | Temp tables p50 / p95 (ms) | JSON aggregation p50 / p95 (ms) |
|---:|---:|---:|---:|
| 100 | 1,822.9 / 1,849.7 | 1,066.1 / 1,189.8 | 1,008.7 / 1,083.1 |
| 1,000 | 1,859.6 / 1,888.4 | 1,123.8 / 1,214.2 | 1,111.3 / 1,270.1 |
| 10,000 | 2,233.9 / 2,278.0 | 1,613.6 / 1,732.3 | 2,343.4 / 2,452.1 |

Across this run, p95 was 1.5–14.3% higher than p50.

## Reading the absolute numbers

A substantial portion of the measured latency is query execution shared by all
three implementations. Six of the 15 result sets sort on unindexed columns
(`amount`, `customer_id`, `product_id`) and therefore scan the full
1-million-row table.

`benchmark/sql/11_server_side_baseline.sql` runs the same 15 queries but discards
the rows inside the server, isolating that shared cost. It reports a **separate
median per result-set size**, because the cost is not constant — it grows 42%
across the tested range:

| Rows per result set | Shared server-side cost (ms) |
|---:|---:|
| 100 | 1,010.6 |
| 1,000 | 1,044.7 |
| 10,000 | 1,431.3 |

Subtracting it gives the latency attributable to each retrieval contract:

| Rows per result set | Refcursor | Temp tables | JSON aggregation |
|---:|---:|---:|---:|
| 100 | 812.3 | 55.5 | ~0 |
| 1,000 | 814.9 | 79.1 | 66.6 |
| 10,000 | 802.6 | 182.3 | 912.1 |

Three things stand out:

- **Refcursor overhead is flat at roughly 810 ms** regardless of row count. It is
  dominated by the 16 round trips (one `CALL` plus 15 `FETCH ALL`), not by data
  volume — which is the structural cost of the pattern.
- **JSON adds essentially nothing at 100 rows per result set.** Its end-to-end
  latency is within measurement noise of pure server-side execution.
- **At 10,000 rows, JSON's retrieval overhead is 5.0x that of temporary tables**
  (912.1 ms vs 182.3 ms), even though end-to-end latency differs by only 1.45x.

That last point is why the shared cost matters when reading the table above: it
compresses the reported percentage differences, so the gaps attributable to the
retrieval contract are considerably larger in relative terms than the
end-to-end numbers suggest.

One caveat on subtraction: the baseline uses `PERFORM`, which discards rows inside
the server, so the difference includes server-side materialization (building temp
tables, constructing the `jsonb` document) as well as transfer and client parsing.
It is the cost of the contract, not of the network alone.

## Interpretation

- JSON aggregation had the lowest p50 latency at 100 rows per result set (5.4%
  lower than temporary tables) and was close to tied at 1,000 rows (1.1%
  lower).
- At 10,000 rows per result set, temporary tables had 31.1% lower p50 latency
  than JSON aggregation.
- Temporary tables beat the refcursor baseline at all three tested sizes.
- JSON aggregation beat the refcursor baseline at 100 and 1,000 rows, but was
  4.9% slower at 10,000 rows.
- For this workload the JSON-to-temporary-table crossover falls somewhere between
  1,000 and 10,000 rows per result set.

The takeaway is a workload-dependent trade-off, not a universal row-count
threshold. Results vary with row width, query plans, instance class, concurrency,
network topology, data distribution, and client parsing.

## Reproducing

```bash
psql "$PSQL_CONN" -v ON_ERROR_STOP=1 -f sql/postgresql/01_schema_and_data.sql
psql "$PSQL_CONN" -v ON_ERROR_STOP=1 -f benchmark/sql/10_benchmark_routines.sql

export PGCONNSTR="Host=...;Database=postgres;Username=dbadmin;Password=***;SSL Mode=VerifyFull;Root Certificate=/path/to/global-bundle.pem"
dotnet run -c Release --project benchmark/src -- \
  --rows 100,1000,10000 --warmup 20 --iterations 100 --csv results.csv

# Shared server-side cost, reported as NOTICE lines (one median per size).
psql "$PSQL_CONN" -v ON_ERROR_STOP=1 -f benchmark/sql/11_server_side_baseline.sql \
  2>&1 | grep rows_per_result_set
```

Run all of it from the repository root, and run the client in the writer's
Availability Zone — otherwise network round-trip time dominates the measurement,
and the three contracts differ in how many round trips they make (16 for
refcursor and temporary tables, 1 for JSON).

The `--json-deep` flag makes the JSON runner read every field of every element
rather than only accessing each top-level array. It is not part of the published
methodology; use it to see how much of the JSON cost is deserialization rather
than transfer and parsing.
