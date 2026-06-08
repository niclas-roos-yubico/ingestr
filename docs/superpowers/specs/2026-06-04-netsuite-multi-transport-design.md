# Multi-transport NetSuite source (ODBC baseline + optional JDBC) — design

- **Date:** 2026-06-04
- **kata:** epic `ingestr#3svm` (re-scoped to multi-transport), design `ingestr#yej2` (this brainstorm)
- **Status:** design approved; awaiting spec review before planning.
- **Supersedes direction:** the JDBC-only re-platform
  (`docs/superpowers/specs/2026-06-03-netsuite-jdbc-extractor-design.md`,
  spike `ingestr#eqkh` ✅). That work is reused — JDBC becomes an opt-in transport
  rather than the sole one.

## Summary

Refactor `pkg/source/netsuite` so the SuiteAnalytics Connect access method sits
behind a small **transport seam** with two implementations:

- **ODBC — the default baseline.** `database/sql` + `alexbrainman/odbc` (cgo),
  gated to Linux/Windows. This is the existing, production-proven path.
- **JDBC — a runtime opt-in.** A Java sidecar process streaming Arrow IPC, used
  only when a user supplies a NetSuite JDBC jar and brings their own JVM.

**Hard constraint (maintainer):** *no Java dependency in the normal dev/build/run
flow.* The JDBC path — including the `go:embed` of the Java helper jar — sits
behind the `//go:build netsuite_jdbc` build tag, and the prebuilt helper jar is
**committed** to the repo. So the default `make build` needs no JDK, ships no
jar, and never invokes Java. A JDK is required only to *regenerate* the jar
(`make java-helper`).

Transport is selected by **URI scheme**: `netsuite://` and `netsuite+odbc://` →
ODBC; `netsuite+jdbc://` → JDBC.

## Motivation

The epic originally decided to retire ODBC for JDBC-only, on two grounds: a
wide-text `SIGSEGV` in the ODBC driver's native chunked-fetch path
(`netsuite_crash_findings.md`) and the lack of a macOS/ARM ODBC driver. The
maintainer has since set a stronger priority: **keep Java out of dev, build, and
the default runtime.** That reverses the conclusion:

- ODBC returns as the **default**. The `SIGSEGV` is mitigated in practice by the
  existing `oa_columns` projection + `wide_text` knobs (keep/truncate/exclude),
  which keep wide columns off the crashing chunked path.
- JDBC is preserved as the **portability / robustness escape hatch** — the only
  option on macOS/ARM, and crash-free by construction — but it is opt-in and must
  not impose Java on anyone who does not choose it.

## Decision record

- **Transport seam, fine-grained + optional projection capability** (§"The
  transport seam"). Chosen over a coarse per-transport `ReadTable` (which would
  duplicate the shared SQL builder below the seam) and over a pure `RunQuery`
  seam (which leaves ODBC's connection-dependent introspection homeless).
- **ODBC is the default; selection is by URI scheme.** `netsuite://` ≡
  `netsuite+odbc://`. `netsuite+jdbc://` selects JDBC. No `?driver=` query knob.
- **JDBC behind `//go:build netsuite_jdbc` + committed prebuilt jar.** Default and
  dev builds carry zero Java; an opt-in/release build adds `-tags netsuite_jdbc`
  and embeds the committed jar with **no JDK in CI**. (Alternatives — always-embed
  with no tag, or building the jar in release CI — were considered and rejected
  for, respectively, shipping a fat jar in every binary and reintroducing a JDK
  into the pipeline.) **This single tradeoff — a committed binary jar blob in git
  — is pending maintainer confirmation; see Open questions.**
- **TBA is shared, unchanged.** The token-password recipe in `tba.go` is
  identical for both transports (`CustomProperties` is forwarded opaquely by the
  server; verified for JDBC in spike `ingestr#eqkh`).
- **rzv4 (duplicate rows) is out of scope here.** This refactor only guarantees
  the dedup/ordering fix has a home **above** the transport seam; the fix itself
  is a separate task on top of this seam.

## Architecture

```
pkg/source/netsuite
  ── ABOVE THE SEAM (shared, transport-agnostic) ──
  NetSuiteSource          Connect() parses URI, picks transport by scheme,
                          connects; GetTable()/DynamicSourceTable (schema-less)
  buildSuiteAnalyticsQuery / suiteAnalyticsTimestampLiteral   (SQL builder)
  tba.go                  TBA token-password (identical for both transports)
  uri parse (base)        account/role/host/port/sdsn/encrypted/custom_properties

  ── THE SEAM ──
  type Transport interface {
      Connect(ctx) error
      RunQuery(ctx, sql string, opts source.ReadOptions) (<-chan source.RecordBatchResult, error)
      Close(ctx) error
  }
  type ColumnProjector interface {        // optional; implemented by ODBC only
      ProjectColumns(ctx, table string, opts source.ReadOptions) ([]string, error)
  }

  ── BELOW THE SEAM ──
  transport_odbc.go       //go:build linux || windows
      *sql.DB pool; oa_columns introspection + wide_text; rows->map->arrowconv
  transport_odbc_stub.go  //go:build !(linux || windows)   -> actionable error
  transport_jdbc.go       //go:build netsuite_jdbc
      spawn java helper, read Arrow IPC, ms->us rescale; go:embed committed jar
  transport_jdbc_stub.go  //go:build !netsuite_jdbc        -> "rebuild with -tags netsuite_jdbc"
```

### The transport seam

ODBC must run a live `oa_columns` query to build an explicit projection — both to
dodge the `SELECT *` crash on wide tables and to apply `wide_text`. JDBC issues
`SELECT *` directly (Arrow-jdbc handles wide text safely). The seam therefore is:

- **`Transport.RunQuery(sql, opts)`** — execute an already-built SuiteAnalytics
  SQL string and stream Arrow record batches. Both transports implement it.
- **`ColumnProjector` (optional)** — implemented by ODBC only. The shared read
  flow checks for it:

  ```
  readTable(table, opts):
      if t, ok := transport.(ColumnProjector); ok:
          columns = t.ProjectColumns(table, opts)   # ODBC: oa_columns + wide_text
      else:
          columns = nil                              # JDBC: SELECT *
      sql = buildSuiteAnalyticsQuery(table, columns, opts)   # ABOVE the seam
      return transport.RunQuery(sql, opts)
  ```

Custom queries (`source.IsCustomQuery`) bypass projection and call `RunQuery`
directly. This keeps the SQL builder and incremental/limit logic shared and above
the seam, while isolating ODBC's introspection as a capability JDBC simply does
not advertise.

### Above the seam (shared)

- `NetSuiteSource.Connect()` — parse URI, resolve the base config + TBA, select
  the transport from the scheme, construct it (real or stub per build/platform),
  and `Connect()` it.
- `GetTable()` / `source.DynamicSourceTable` — schema-less
  (`KnownSchema: false`), so the pipeline runs schema inference on the first
  batch. Default PK `id`, default strategy `replace`. (Unchanged from both
  current impls — they are already identical here.)
- `buildSuiteAnalyticsQuery` + `suiteAnalyticsTimestampLiteral` — the
  SQL-Server-style `TOP`, interval predicates, no `ORDER BY` (see rzv4 note).
- `tba.go` — verbatim from the current impls (the two copies are identical).
- Base URI parsing — `account_id`/`role_id`/`host`/`port`/`server_data_source`/
  `encrypted`/`custom_properties`/`static_schema`/`uppercase`, plus
  `accountIDFromURI`, `defaultConnectHost`, `firstNonEmpty`, `parseBool`.

### ODBC transport (default baseline)

`transport_odbc.go` (`//go:build linux || windows`) holds today's ODBC code from
branch `netsuite-tba-odbc-improvements`, reorganized:

- Owns the `*sql.DB` connection pool and the ODBC connection-string assembly
  (DSN / driver / raw `odbc_connect_string` variants, `tbaConnector`).
- Implements `ColumnProjector`: `oa_columns` introspection, `isNonBindable`
  classification, the `wide_text` keep/truncate/exclude projection, ordering
  non-bindable columns last.
- `RunQuery`: `db.QueryContext` → `streamRows` → `arrowconv.ItemsToArrowRecordWithSchema`
  (Go-side type inference; values normalized via `normalizeSQLValue`).

`transport_odbc_stub.go` (`//go:build !(linux || windows)`) returns:
*"the netsuite ODBC transport is unavailable on this platform; use
`netsuite+jdbc://` with a JDBC-enabled build (`-tags netsuite_jdbc`)."*

### JDBC transport (opt-in)

`transport_jdbc.go` (`//go:build netsuite_jdbc`) holds the worktree sidecar
(`worktree-netsuite-jdbc`), reorganized behind the seam:

- `Connect`: locate Java (`JAVA_HOME/bin/java` → PATH), validate the user-supplied
  `NQjc.jar` exists, ensure the embedded helper jar extracts (not a placeholder).
  No persistent connection — each `RunQuery` spawns a fresh helper.
- `RunQuery`: build the helper spec (JDBC URL + env contract; secrets via env, not
  argv; fresh TBA token per call), spawn the Java process (own process group,
  SIGTERM→SIGKILL on cancel, stderr tail), read Arrow IPC from stdout into the
  `RecordBatchResult` channel, **rescaling millisecond timestamps → microseconds**
  (arrow-jdbc emits millis; project convention is micros).
- Does **not** implement `ColumnProjector` (so JDBC uses `SELECT *`).
- `go:embed` of the committed helper jar lives in this file (or a sibling under
  the same build tag), so the embed directive is absent from untagged builds.

`transport_jdbc_stub.go` (`//go:build !netsuite_jdbc`) returns:
*"this ingestr build was compiled without JDBC support; rebuild with
`-tags netsuite_jdbc` to use `netsuite+jdbc://`."*

### Selection, registration, and build-tag interaction

A single source is registered for all three schemes:

```go
registry.RegisterSource(
    []string{"netsuite", "netsuite+odbc", "netsuite+jdbc"},
    func() interface{} { return NewNetSuiteSource() },
)
```

`Connect()` maps the scheme to a transport constructor. Because each constructor
is real or stub depending on build tag / platform, **scheme discovery always
works** and an unavailable transport yields an actionable error rather than an
"unknown scheme." Resulting matrix:

| Build / platform                     | `netsuite+odbc://` | `netsuite+jdbc://` |
|--------------------------------------|--------------------|--------------------|
| Linux/Windows, default (no tag)      | ✅ ODBC            | ❌ friendly error  |
| Linux/Windows, `-tags netsuite_jdbc` | ✅ ODBC            | ✅ JDBC            |
| macOS/ARM, default (no tag)          | ❌ friendly error  | ❌ friendly error  |
| macOS/ARM, `-tags netsuite_jdbc`     | ❌ friendly error  | ✅ JDBC            |

The bottom-left cell is the accepted consequence of the constraint: a default
macOS/ARM build has no working NetSuite transport; that user opts into JDBC.

## Build & release changes

- `make java-helper` — the only target that needs a JDK; builds the fat helper
  jar (our code + `arrow-jdbc` + deps) and writes it to the committed jar path.
  Run rarely (e.g. when bumping arrow-jdbc).
- The committed jar is embedded only under `-tags netsuite_jdbc`. Default
  `make build` is unchanged and Java-free.
- A reproducibility check (CI, in the JDBC matrix leg) may rebuild the jar and
  diff it against the committed copy to guard provenance.
- Reconcile the experimental `Dockerfile.netsuite*`, `run-netsuite.sh`,
  `netsuite_entrypoint.sh` left in the tree: default image keeps the ODBC base
  (unixODBC + proprietary `.so`, no Java); a JDBC variant adds a JRE + a mount
  point for the user's `NQjc.jar`, built `-tags netsuite_jdbc`.

## Testing

- **ODBC (unit):** connection-string assembly (DSN/driver/raw, TBA), `oa_columns`
  projection + `isNonBindable` + `wide_text` modes, `streamRows`/arrowconv.
- **JDBC (unit, `-tags netsuite_jdbc`):** stub helper emitting a known Arrow IPC
  stream via the `execCommand` indirection — assert batches/schema, ms→µs
  rescale, and lifecycle (context cancel → child killed, stderr surfaced on
  non-zero exit). Placeholder-jar guard error.
- **Shared:** `buildSuiteAnalyticsQuery` (TOP/interval/limit/custom), TBA
  known-answer vector (byte-for-byte, already exists), URI parsing/scheme
  selection including the stub-error paths.
- **Integration (manual, gated):** real NetSuite `transaction` incremental load
  — ODBC on Linux, JDBC on macOS/ARM (native, no QEMU).

## Out of scope (related work, on top of this seam)

- **rzv4 — duplicate rows.** The SuiteAnalytics cursor re-emits rows on large
  unordered result sets. The fix (dedup-by-PK in the replace path, and/or an
  optional deterministic `ORDER BY` — noting `ORDER BY` itself risks the ODBC
  wide-table crash) lives **above** the transport seam and applies to both
  transports. Tracked as `ingestr#rzv4`; implemented separately.
- **temporal_server NetSuite worker image.** Stays ODBC by default; any JRE/JDBC
  variant is a cross-repo change linked from `ingestr#3svm`.
- **Packaging/CI image matrix** beyond the make/embed wiring above.

## Open questions

- **Committed jar blob — maintainer confirmation pending.** "Build tag +
  committed prebuilt jar" commits a ~10–20 MB fat jar to git (behind the tag, not
  shipped in default binaries). Confirm this is acceptable vs. building the jar in
  release CI (a JDK in that one pipeline) before planning the build wiring.
- **Implementation base branch.** ODBC lives on `netsuite-tba-odbc-improvements`;
  JDBC lives on `worktree-netsuite-jdbc`; neither is on the current working
  branch. The plan must establish a base that folds both — start from the ODBC
  branch (most complete baseline) and graft the JDBC transport.
- **arrow-jdbc version & DECIMAL handling** carry over from the JDBC design
  (`2026-06-03-netsuite-jdbc-extractor-design.md` Open questions): target Arrow
  Java 19.0, confirm DECIMAL/NUMERIC mapping, pin a tested `NQjc.jar` range.
