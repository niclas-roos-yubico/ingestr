# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

gong is a Go-based data ingestion CLI tool that transfers data between various databases and formats. It's a reimplementation of the Python-based ingestr tool, focusing on performance and portability. The project uses Apache Arrow for efficient in-memory data representation and ADBC (Arrow Database Connectivity) for database interactions.

## Build and Test Commands

```bash
# Build the application
make build                    # Builds to bin/gong

# Run tests
make test                     # Run all unit tests with race detection
go test -short ./...          # Run unit tests only (skip integration tests)

# Run integration tests
go test -v ./tests/integration/...  # Run all integration tests
go test -v -run TestPostgresToPostgres ./tests/integration/...  # Run specific test

# Clean build artifacts
make clean

# Build and run
make run ARGS="ingest --source-uri=postgres://... --dest-uri=sqlite://... --source-table=users"

# Direct execution
go run . ingest --source-uri=<uri> --dest-uri=<uri> --source-table=<table>
```

## Architecture Overview

### Core Components

1. **Pipeline** (`pkg/pipeline/pipeline.go`): Orchestrates the complete ingestion workflow
   - Connects to source and destination using URI registry
   - Fetches schema from source
   - Auto-detects primary keys if not provided
   - Selects and validates ingestion strategy
   - Executes the strategy with an IngestionJob

2. **URI Registry** (`internal/uri/registry.go`): Central registry pattern for source/destination discovery
   - Maps URI schemes (postgres, duckdb, bigquery, etc.) to constructor functions
   - Provides `GetSource(uri)` and `GetDestination(uri)` methods
   - DefaultRegistry is initialized at package init time with all supported connectors

3. **Sources** (`pkg/source/`): Data extraction layer
   - All sources implement `Source` interface with `Connect`, `GetSchema`, `Read`, `Close`
   - Return data as `<-chan RecordBatchResult` streaming Arrow record batches
   - Two main patterns:
     - **ADBC-based**: Generic ADBC source with pluggable Dialect interface (DuckDB, Snowflake, BigQuery)
     - **Native driver**: Direct database driver usage (Postgres via pgx, MySQL, MSSQL)

4. **Destinations** (`pkg/destination/`): Data loading layer
   - All destinations implement `Destination` interface
   - Key methods: `PrepareTable`, `Write`, `WriteParallel`, `SwapTable`
   - Support transaction handling via `Transaction` interface
   - Consume Arrow record batches from sources

5. **Strategies** (`pkg/strategy/`): Write pattern implementations
   - Registry-based pattern with `Register()` and `Get()` functions
   - Each strategy implements `WriteStrategy` interface
   - Current strategies: `replace` (drop/recreate), `merge` (upsert by primary key)
   - Strategy validation occurs after primary key auto-detection

6. **Schema** (`pkg/schema/schema.go`): Internal type system and Arrow conversion
   - Defines `TableSchema` with columns, primary keys, schema name
   - `Column` type with DataType enum, precision, scale, nullability
   - Converts between database types, internal types, and Arrow types

### ADBC Dialect System

The ADBC source uses a Dialect interface to abstract database-specific behavior:

- **Dialect**: Base interface for driver management, SQL templates, type mapping
- **DatasetAwareDialect**: For databases like BigQuery that embed schema in query paths
- **DatasetConnector**: For databases requiring dataset_id in connection string (BigQuery)
- **SchemaProvider**: Optional interface for native API schema fetching (faster than SQL)

Located in `pkg/source/adbc/`:
- `source.go`: Generic ADBC source implementation
- `dialect.go`: Dialect interface definitions
- `driver.go`: ADBC driver management and dbc tool integration
- `query.go`: SQL query builder with column filtering and incremental logic
- `batch.go`: Arrow record batch conversion from sql.Rows

Database-specific dialects in `pkg/source/{database}/dialect.go`:
- `duckdb/dialect.go`
- `snowflake/dialect.go`, `snowflake/mapper.go`
- `bigquery/dialect.go`, `bigquery/mapper.go`
- Each also has `mapper.go` for database-specific type mapping logic

### Key Patterns

**Configuration Flow**:
1. CLI flags parsed in `cmd/ingest.go`
2. Config struct (`internal/config/config.go`) populated with defaults and user input
3. Config validation (required fields, strategy validation)
4. Pipeline created with config and executed

**Data Flow**:
1. Source.Read() returns `<-chan RecordBatchResult` with Arrow record batches
2. Strategy executes its pattern (e.g., staging table, merge, swap)
3. Destination.Write() or WriteParallel() consumes the channel
4. Arrow format enables zero-copy transfer where possible

**Primary Key Handling**:
- Sources attempt to detect PKs during GetSchema()
- Pipeline auto-populates config.PrimaryKeys if empty and source provides them
- Strategy validation checks for required PKs after auto-detection
- This allows merge strategy to work without explicit PK specification

## Important Notes

### Code Standards
Do NOT write comments everywhere. If the code is self-explanatory, do not write comments.

### Type Mapping
Each source must map its native types to `schema.DataType` enum. The ADBC dialect system delegates this via `MapDataType(dbType string)`. Native sources implement mapping directly (e.g., `pkg/source/postgres/mapper.go`).

### Timestamp Convention
All timestamps in the Arrow layer use **microseconds** as the standard unit. This is enforced throughout the codebase:

- **Schema layer** (`pkg/schema/schema.go`): `TypeTimestamp` and `TypeTimestampTZ` map to `arrow.TimestampType{Unit: arrow.Microsecond}`
- **Sources**: Must convert native timestamp values to microseconds using `time.Time.UnixMicro()` or equivalent
- **Schema inference** (`pkg/schemainfer/merge.go`): Merges timestamp types to microseconds
- **Destinations**: Can assume incoming timestamps are in microseconds

When implementing a new source with timestamps:
```go
// Correct: convert to microseconds
case time.Time:
    b.Append(arrow.Timestamp(v.UnixMicro()))

// Correct: convert milliseconds to microseconds
case primitive.DateTime: // MongoDB stores as milliseconds
    b.Append(arrow.Timestamp(int64(v) * 1000))
```

This convention exists because:
1. Most databases use microseconds internally (PostgreSQL, BigQuery)
2. Sufficient precision for virtually all use cases
3. BigQuery's Storage Write API expects microseconds regardless of Arrow schema unit metadata

### ADBC Driver Management
ADBC drivers are installed via the native `github.com/columnar-tech/dbc` client. The `pkg/source/adbc` package handles this automatically. Drivers are cached and only installed once.

### Integration Tests
Located in `tests/integration/integration_test.go`. Tests use testcontainers for PostgreSQL and create temporary files for SQLite/DuckDB. Integration tests are skipped in short mode (`go test -short`).

### Error Handling
- Config validation returns `*ValidationError` with field name and message
- Pipeline wraps errors with context (e.g., "failed to connect to source: ...")
- ADBC source provides debug logging via `config.Debug()` when `--debug` flag is set
- Always use `fmt.Errorf` with `%w` for error wrapping to preserve error chains

### URI Formats
The tool accepts various URI schemes:
- PostgreSQL: `postgres://`, `postgresql://`, `postgresql+psycopg2://`
- MySQL: `mysql://`, `mysql+pymysql://`, `mariadb://`
- MSSQL: `mssql://`, `sqlserver://`, `mssql+pyodbc://`
- MongoDB: `mongodb://`, `mongodb+srv://`
- DuckDB: `duckdb:///path/to/db.db`
- Snowflake: `snowflake://user:pass@account/database/schema`
- BigQuery: `bigquery://project/dataset`
- SQLite: `sqlite:///path/to/db.db`
- CSV: `csv://path/to/file.csv`
- Parquet: `parquet://path/to/file.parquet`

### Adding New Sources
1. Implement the `Source` interface or create an ADBC Dialect
2. Register in `internal/uri/registry.go` init() with URI schemes
3. If using ADBC: implement Dialect with SQL templates and type mapper
4. If native driver: handle connection, schema fetching, and batch reading directly

**Schema-less sources** (like MongoDB): Implement `HasKnownSchema() bool` returning `false`. The pipeline will automatically use schema inference (`pkg/schemainfer/`) to derive the schema from the first batch of data. The source should still emit proper Arrow types - use `pkg/schema.JSONArrowType` for nested documents and arrays.

### Adding New Strategies
1. Implement `WriteStrategy` interface in `pkg/strategy/`
2. Register in `pkg/strategy/strategy.go` init() function
3. Implement validation for required config (e.g., primary keys for merge)
4. Execute pattern using IngestionJob (has source, destination, schema, config)

## Issue Tracking with kata

This repo uses [kata](https://go.kenn.io/kata) as the shared issue ledger. The
workspace is bound to the kata project **`ingestr`** via `.kata.toml`.

**Always scope kata commands to this project with `--project ingestr`.** This
workspace contains more than one repo, and commands are not reliably run from
this repo's directory — the explicit flag prevents issues landing in the wrong
project.

```bash
kata search --project ingestr "query" --agent          # search before creating
kata create --project ingestr "title" --body "..." --agent
kata ready  --project ingestr --agent                  # find unblocked work
kata show   --project ingestr <ref> --agent
kata close  --project ingestr <ref> --done \
  --message "what was done + how it was verified" --commit <sha>
```

Rules:
- Search before creating; prefer updating an existing issue over making duplicates.
- Close an issue only when its work is verified complete. If not done, add a
  `needs-review` label and a comment describing what remains instead of closing.
- Use `--agent` for concise output; use `--json` only when piping into a tool.
- If the `kata` binary is not on `PATH`, invoke it via `$(go env GOPATH)/bin/kata`.

Run `kata quickstart` for the full agent guide.

### Work hierarchy

kata work is organized as a tree so any issue traces up to the design that
justified it. Structural roles carry labels; leaf tasks don't (they're
identified as children of a `plan`):

```
Epic (spec / initiative)        label: epic
├── Design & exploration        label: design  — the brainstorm → spec work
│   └── Spike: <investigation>  label: spike   — substantial investigations
├── Plan A (parent)             label: plan
│   ├── Task A1                 (no label; child of a plan)
│   └── Task A2
└── Plan B (parent)            ← a spec may spawn more than one plan
```

Only mirror non-trivial work into kata; trivial one-off changes don't need issues.

### Specs, epics & exploration

When a brainstorm/design session starts on something non-trivial:

1. **Create the epic early** — as soon as the topic is nameable, before you know
   whether it will yield a spec. Exploration knowledge is worth keeping even when
   no spec results.

   ```bash
   kata create --project ingestr "<initiative title>" \
     --body "Goal: <what we're exploring and why>" \
     --label epic --idempotency-key "<topic-slug>" --agent      # -> epic ref
   ```

2. **Create a "Design & exploration" child**, claim it, and capture findings as
   you go (comments). Spin off `spike` children for substantial investigations:

   ```bash
   kata create --project ingestr "Design & exploration: <topic>" \
     --parent <epic-ref> --label design \
     --idempotency-key "<topic-slug>-design" --agent
   kata claim <design-ref> --project ingestr
   kata create --project ingestr "Spike: <question>" --parent <epic-ref> \
     --label spike --idempotency-key "<topic-slug>-spike-01" --agent
   ```

3. **The deliverable is a spec _or_ recorded knowledge.** Close spikes with their
   findings in the close message. If the session yields no spec, still close the
   design issue with a substantive knowledge summary so nothing is lost, then
   close the epic with a fitting reason (`--done` "explored; chose not to spec
   because…", or `--wontfix` / `--superseded-by <ref>` with rationale).

4. **Drift check before attaching a spec or plans.** When you reach the point of
   writing a spec (or spawning plans) under the epic, confirm what you actually
   explored still matches the epic's goal. If it matches, proceed. **If it
   drifted, pause and ask the user** whether to re-scope the epic (`kata edit
   <epic-ref> --title/--body …`) or split into a new epic (`--related` to the
   original). Never silently attach a mismatched spec.

5. **On a spec:** close the design issue `--done` with the spec doc commit as
   evidence; leave the epic open to host plan parents.

   ```bash
   kata close <design-ref> --project ingestr --done \
     --message "Spec approved: <key decisions>." --commit <spec-doc-sha>
   ```

### Plans → kata

When a multi-task plan is produced (e.g. via the superpowers `writing-plans`,
`executing-plans`, or `subagent-driven-development` skills), mirror it into kata
so the work is durable and visible across sessions and agents. Skip this for
trivial one-off changes — only do it for plans with several real tasks.

**Roles (source of truth):** the plan file + TodoWrite are canonical for *what
the tasks are and how they're executed in-session*. kata is the durable record
of *task existence and status*. Sync them at exactly two moments per task —
**claim when you start, close when verified done** — and don't narrate every
micro-step into kata.

1. **At plan finalization** — create one plan parent (label `plan`) and one child
   per task. When the plan came from an epic, make the plan parent a **child of
   that epic** (`--parent <epic-ref>`). Use idempotency keys so re-running the
   plan never duplicates issues (grab each ref from the `create` output):

   ```bash
   kata create --project ingestr "<plan title>" --label plan \
     --parent <epic-ref> \
     --body "Goal: <plan goal>. Plan file: <path-to-plan-file>." \
     --idempotency-key "<plan-slug>" --agent            # -> plan parent ref
   kata create --project ingestr "<task 1 title>" --parent <plan-ref> \
     --body "$(cat <<'BODY'
   Goal: <1-2 lines: what and why, tied to the parent plan>

   Done when:
   - <checkable acceptance criterion>
   - <checkable acceptance criterion>

   Scope: <in / out, if ambiguous>
   Refs: plan <path>#<section>, files <...>, related <ref>
   BODY
   )" --idempotency-key "<plan-slug>-01" --agent
   kata create --project ingestr "<task 2 title>" --parent <plan-ref> \
     --blocked-by <task1-ref> --idempotency-key "<plan-slug>-02" --agent
   ```

   Mirror ordering with `--blocked-by` / `--blocks` where tasks depend on each other.

   **Each issue body is the task's durable contract** — write it so `kata show`
   alone is intelligible without the plan file open:
   - **Goal** (1–2 lines): what and why, tied to the parent plan.
   - **Done when**: concrete, checkable acceptance criteria. This is what the
     close message is later judged against — don't skip it.
   - **Scope**: what's explicitly in/out (matters most for multi-agent claiming).
   - **Refs**: link the plan file + section and key paths. Don't copy the plan
     (it's canonical and volatile — link it), don't restate implementation steps
     (those live in TodoWrite), and don't pre-write the outcome (that's the
     close message's job).

2. **Before starting a task:** `kata claim <ref> --project ingestr`.

3. **If a task can't be finished:** do NOT close it. Record state instead:
   `kata label add <ref> needs-review --project ingestr` and
   `kata comment <ref> --body "what was attempted, what remains" --project ingestr`.

4. **On verified completion** (only after the verification-before-completion check
   passes) close eagerly, one task at a time, with substantive prose and evidence:

   ```bash
   kata close <ref> --project ingestr --done \
     --message "what was done + how it was verified" --commit <sha>
   ```

   Close each task as it's verified, not in a batch (the daemon throttles >3
   sibling closes in 60s). The parent closes only after all children are closed
   (kata enforces this).

### Ad-hoc & bug issues

Work discovered *outside* a plan (bugs, chores, follow-ups) becomes a standalone
issue — no parent required. Search first, then create with a type label and the
same body contract (Goal / Done when / Refs). Set `--priority` (0 highest .. 4)
only when it's genuinely urgent.

```bash
kata search --project ingestr "<symptom>" --agent          # avoid duplicates
kata create --project ingestr "<bug title>" --label bug \
  --body "Goal: <fix what>. Done when: <criteria>. Refs: <where found>" \
  --idempotency-key "<bug-slug>" --agent
```

### Labels

Use this fixed taxonomy, the same way in both projects, so search/filter stays
consistent:

| Label | Meaning |
|-------|---------|
| `epic` | initiative / spec anchor (top of a tree) |
| `design` | the design & exploration issue under an epic |
| `spike` | a substantial investigation (closed with findings) |
| `plan` | a plan parent (its children are tasks) |
| `bug` | a defect |
| `chore` | maintenance / non-feature work |
| `needs-review` | done-ish but awaiting review; not closeable yet |
| `blocked` | cannot proceed (prefer a real `--blocked-by` link when possible) |

Tasks (plan children) carry no structural label — they're identified as children
of a `plan`.

### Reopen on regression

If a closed issue's work later fails — a test regression, a rejected PR, a revert
— reopen it rather than filing a duplicate, and say why:

```bash
kata reopen <ref> --project ingestr \
  --comment "Reopened: <what regressed and where>."
```

### Cross-repo references

This workspace has two kata projects (`ingestr`, `temporal_server`). When work in
one relates to the other, link them with qualified refs — `ingestr#<ref>` /
`temporal_server#<ref>` — using `--related` for context or `--blocked-by` for true
ordering:

```bash
kata edit <ref> --project ingestr --related temporal_server#<ref>
```
