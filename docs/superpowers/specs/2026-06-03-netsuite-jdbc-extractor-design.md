# NetSuite source over JDBC (JVM-based extractor) — design

- **Date:** 2026-06-03
- **kata:** epic `ingestr#3svm`, design `ingestr#9ecz`
- **Status:** proposed (awaiting review)

## Summary

Re-platform the NetSuite source from the proprietary x86-64 SuiteAnalytics
Connect **ODBC** driver onto the cross-platform NetSuite **JDBC** driver. The
JDBC driver is pure Java, so it is run by a small **Java helper process** that
ingestr (Go) spawns; the helper connects via JDBC, runs the windowed query, and
streams **Arrow IPC** back to ingestr over stdout. ingestr feeds that stream into
the `RecordBatchResult` channel it already uses internally.

A **JVM (Java 11+) becomes a hard runtime requirement for the NetSuite source.**
The existing ODBC backend is **removed** (preserved on git branch
`netsuite-connector-client` and the `netsuite-*` improvement branches for
recovery).

## Motivation

The current connector (`pkg/source/netsuite`, branch `netsuite-connector-client`)
uses `alexbrainman/odbc` + the proprietary ODBC `.so`, gated to
`//go:build linux || windows`. Two problems follow:

1. **Portability.** The ODBC `.so` is Linux x86-64 only. On Apple Silicon the
   whole flow runs in an amd64 container under QEMU. There is no macOS ODBC
   driver — JDBC is the only non-Windows/Linux-x86 option NetSuite ships.
2. **Stability.** A `SIGSEGV` lives in the ODBC driver's native chunked
   long-data fetch path (`SQLGetData` of `SQL_C_WCHAR` in 1 KB chunks) for wide
   Unicode text columns, amplified by QEMU emulation. See
   `netsuite_crash_findings.md`.

JDBC + a JVM run **natively on every platform/arch** (macOS, Linux ARM/x86,
Windows). That delivers the broad-portability goal and **eliminates the
wide-text crash by construction** — the ODBC native fetch path is gone entirely;
wide text arrives as ordinary JDBC `VARCHAR`/`CLOB` → Arrow `Utf8`.

## Decision record

- **Bridge mechanism: Java sidecar process streaming Arrow IPC over stdout.**
  Chosen over a cgo/JNI bridge (keeps Go's clean cross-compilation; no `libjvm`
  linking) and over a Flight SQL / ADBC gateway (no server/port lifecycle for a
  single-consumer CLI). Process isolation also means a driver crash kills the
  helper, not ingestr.
- **No DuckDB/Parquet staging middle-man.** Considered (Java → DuckDB Appender →
  ingestr `duckdb://`), rejected as unnecessary weight: the helper streams Arrow
  straight to ingestr.
- **ODBC backend dropped, not kept alongside.** This is pre-production; there are
  no ODBC deployments to regress. One code path is simpler. Recoverable from git.
- **JVM is a documented hard requirement** for the NetSuite source. We do **not**
  bundle a JRE (would break the single-static-binary distribution).

## Verified driver facts (from the supplied package)

The driver package (`netsuite_jdbc_files/`, gitignored — not redistributable) was
inspected directly:

- **Vendor / EULA:** Progress Software DataDirect (OpenAccess). The EULA prohibits
  distribute/sublicense (§1.2.5(c)); redistribution requires an explicit grant we
  do not have. **Confirms the user must supply the jar; we never bundle it.**
- **Jar / version:** `NQjc.jar`, latest in package `8.10.190.0` (built 2026-05-19).
- **JDBC driver class:** `com.netsuite.jdbc.openaccess.OpenAccessDriver`
  (auto-registers via `META-INF/services/java.sql.Driver`).
- **JDBC URL format** (from the bundled examples):
  ```
  jdbc:ns://<host>:<port>;ServerDataSource=NetSuite2.com;encrypted=1;\
    CustomProperties=(AccountID=<id>;RoleID=<role>);NegotiateSSLClose=false
  ```
  host = `<account_id>.connect.api.netsuite.com`, port `1708` — matches the
  constants already in `netsuite.go`.
- **Encryption:** `encrypted=1` (TLS); the package ships a `Certificates/` dir, so
  a truststore may need configuring at runtime.
- **Java floor:** the driver itself runs on **Java SE 8+** (per its readmes). The
  effective floor is set by **Apache Arrow Java (11+)**, not the driver — confirm
  against the exact Arrow version chosen.

> **Auth gap (top risk):** both bundled examples use **password** auth
> (`Login` + interactive password). **TBA / token-based auth is NOT demonstrated
> in the package**, yet the existing connector and the `temporal_server` flow
> default to TBA. How TBA maps onto this JDBC driver's `CustomProperties` (vs the
> ODBC DSN form) must be resolved in the spike before committing. This is the
> single biggest unknown.

## Architecture

```
ingestr (Go)
  pkg/source/netsuite (jdbc backend)
    Connect():  locate java (JAVA_HOME -> PATH), validate NetSuite jar present
    Read():     spawn  java -cp <NQjc.jar>:<netsuite-extractor.jar> \
                          com.bruin.ingestr.NetSuiteExtractor
                  - creds + query params via env (never argv)
                  - read Arrow IPC stream from child stdout
                  - emit source.RecordBatchResult batches
                  - manage lifecycle (see Error handling)

Java helper (netsuite-extractor.jar, pure Java, platform-independent)
    JDBC connect (NetSuite SuiteAnalytics Connect)
    executeQuery(window/incremental SQL)
    arrow-jdbc adapter: ResultSet -> streaming Arrow batches (microsecond ts)
    write Arrow IPC stream to stdout
```

### Components

1. **Go JDBC backend** (`pkg/source/netsuite`): replaces `odbc_driver.go` and the
   ODBC code path in `netsuite.go`. Owns subprocess spawn, Arrow-IPC read, and
   lifecycle. The `//go:build linux || windows` constraint is removed (builds and
   runs on darwin/arm64). The query builder (`buildSuiteAnalyticsQuery`,
   incremental/limit logic) is reused — it produces SQL, independent of transport.

2. **Java helper module** (`java/netsuite-extractor/`, Maven or Gradle): produces
   a fat jar of *our code + Apache `arrow-jdbc` + deps* — but **not** the
   proprietary NetSuite jar (added to the classpath at runtime). Apache Arrow's
   `arrow-jdbc` adapter (`JdbcToArrow` / `sqlToArrowVectorIterator`) does the
   JDBC-type → Arrow-type mapping and batch streaming, so the helper is thin.
   Configured to emit **microsecond timestamps** to match the project timestamp
   convention (CLAUDE.md).

3. **Embedding**: the helper jar is `go:embed`-ed into the ingestr binary and
   extracted to a temp dir on first use, so the shipped artifact stays a single
   Go binary.

### Data flow

1. Workflow/CLI requests a table over a window (existing path).
2. Go backend builds SuiteAnalytics SQL (existing builder), spawns the helper.
3. Helper queries NetSuite, converts ResultSet → Arrow batches, writes IPC.
4. Go reads IPC → `RecordBatchResult` channel → destination (unchanged).

### Configuration / inputs

| Input | Source | Notes |
|---|---|---|
| JVM (Java 11+) | user-provided | found via `JAVA_HOME/bin/java` then `java` on PATH |
| NetSuite JDBC jar | user-provided | proprietary, not redistributable; `netsuite://?jdbc_jar=…` or `NETSUITE_JDBC_JAR` |
| `netsuite-extractor.jar` | shipped (embedded) | pure Java, platform-independent |
| credentials | env into child | TBA / password, passed via env not argv (existing pattern) |

## Error handling & lifecycle

- **Fail fast in `Connect()`** with an actionable message if no JVM or no JDBC
  jar: e.g. *"the NetSuite source requires a Java runtime (Java 11+); install
  Java or set JAVA_HOME, and provide the JDBC driver via NETSUITE_JDBC_JAR."*
- **Subprocess management** mirrors the proven pattern in
  `temporal_server/ingestr/activity.go`: own process group (`Setpgid`), `SIGTERM`
  on context cancel escalating to `SIGKILL` after a grace period, and a stderr
  tail captured for diagnostics on non-zero exit.
- **Arrow IPC framing** makes partial/failed streams detectable (truncated
  stream → error), distinct from a clean empty result.

## Build & release changes

- New Java build step producing `netsuite-extractor.jar` (CI: set up JDK, build
  the module, place the jar where `go:embed` picks it up).
- `go generate` / embed wiring so the jar is present at Go build time.
- Update `Dockerfile.netsuite`, `run-netsuite.sh`, `netsuite_entrypoint.sh`:
  drop the amd64/QEMU + unixODBC apparatus; the image needs a JRE + the mounted
  JDBC jar and can run native arm64.
- `temporal_server`: the NetSuite worker image no longer needs the amd64 ODBC
  base; it needs a JRE. (Tracked cross-repo — see Open questions.)

## What is removed

- `pkg/source/netsuite/odbc_driver.go` and the ODBC connection path.
- `github.com/alexbrainman/odbc` dependency (if unused elsewhere).
- `exclude_clob_columns` / `wide_text` URI options whose sole purpose was working
  around the ODBC crash (no longer needed). Confirm none are relied upon before
  removing.

## Testing

- **Unit (Go):** backend spawns a stub "helper" that emits a known Arrow IPC
  stream; assert batches/schema/lifecycle (cancel → child killed).
- **Unit (Java):** `arrow-jdbc` conversion against an in-memory JDBC source
  (e.g. H2/SQLite) — type mapping, timestamp unit, batch boundaries.
- **Integration / spike (manual, gated):** real NetSuite `transaction`
  incremental load on macOS arm64, native (no QEMU), via the JDBC path.

## De-risking spike (do first)

Before the full backend swap, prove end-to-end on the dev Mac, natively (no
QEMU): `Java(NetSuite JDBC) → arrow-jdbc → Arrow IPC stdout → ingestr reads →
DuckDB`, one table. Ordered objectives (each gates the next):

1. **TBA auth over JDBC works** — resolve how token-based auth maps onto
   `OpenAccessDriver` `CustomProperties` (the package only shows password auth).
   This is the gating unknown; if TBA can't be made to work, escalate before
   building anything.
2. **TLS/`encrypted=1` connects** — with the shipped `Certificates/` truststore.
3. **`arrow-jdbc` converts a real table** — types correct, **wide-text/CLOB
   columns intact** (the columns that crashed under ODBC), microsecond timestamps.
4. **IPC handoff** — ingestr reads the child's Arrow IPC stream into batches and
   lands them in DuckDB.

Success = a real `transaction` (or smaller wide table) row sample in DuckDB with
correct wide-text values and no crash.

## Open questions

- **TBA over JDBC** — exact `CustomProperties` (consumer key/secret, token
  id/secret) for `OpenAccessDriver`. *(Spike objective 1 — highest priority.)*
- TLS truststore wiring for `encrypted=1` (the bundled `Certificates/` dir).
- Exact `arrow-jdbc` config for NetSuite decimals/timestamps vs the microsecond
  convention, and CLOB handling.
- Pin the `NQjc.jar` version contract (package ships 8.10.190.0) — document the
  supported/tested driver version range.
- `temporal_server` NetSuite worker image change (amd64/ODBC base → JRE) —
  separate kata issue, cross-repo link to `ingestr#3svm`.
