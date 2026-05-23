# stud-finder — Technical Requirements Document

## Overview

`stud-finder` is a Ruby gem CLI that analyzes a Rails codebase and outputs a ranked file risk list. It combines three signals (Phase 1) or four signals (Phase 3) into a composite risk score per file.

**Repo:** `bazfer/stud-finder`  
**Current phase:** 1 — fan_in + complexity + churn (no coverage, no JS)

**Signals and default weights:**

| Signal | Default weight | Source |
|--------|---------------|--------|
| fan_in | 0.35 | rubocop-ast static analysis |
| complexity | 0.25 | rubocop Metrics/CyclomaticComplexity |
| churn | 0.25 | git log commit frequency |
| coverage | 0.15 | SimpleCov/lcov report (Phase 3) |

**Formula:**
```
risk_score = w_fan_in × fan_in_pct + w_complexity × complexity_pct + w_churn × churn_pct [+ w_coverage × (1 − coverage_fraction)]
```

All percentile inputs are normalized to [0.0, 1.0]. Result: [0.0, 1.0].

---

## CLI Interface

```
stud-finder [PATH] [OPTIONS]
```

**Arguments:**
- `PATH` — path to the repository root. Defaults to `.` (current directory).

**Options:**

```
--output table|json|markdown
    Output format. Default: table.

--churn-days N
    Commit lookback window in days. Default: 90.

--weights fan_in:F,complexity:C,churn:H,coverage:V
    Override all four weights. Values are floats in [0.0, 1.0].
    All four keys must be present. Values must sum to 1.0 (±0.001 tolerance).
    In Phase 1 (no coverage), specifying coverage: any non-zero value is a
    validation error — exit 1 with message:
      "Error: coverage weight must be 0.0 in Phase 1 (no coverage data available)."
    If coverage: 0.0, the remaining three values must sum to 1.0 (±0.001).
    Example (Phase 1): --weights fan_in:0.5,complexity:0.3,churn:0.2,coverage:0.0
    Example (Phase 3): --weights fan_in:0.4,complexity:0.2,churn:0.2,coverage:0.2

--trunk-threshold N
    fan_in percentile cutoff for trunk classification (integer, 0–99).
    Default: 85 (top 15% by fan_in = trunk). Internal: trunk_pct = N / 100.0.

--branch-threshold N
    fan_in percentile cutoff for branch classification (integer, 0–99).
    Default: 50. Must be strictly less than trunk-threshold — exit 1 if violated.

--exclude PATTERN
    File glob pattern. Repeatable. Evaluated via File.fnmatch against each file's
    path relative to PATH (with File::FNM_PATHNAME | File::FNM_DOTMATCH flags).
    Examples:
      --exclude "app/admin/**"        all files under app/admin/
      --exclude "**/*_generated.rb"   files ending in _generated.rb anywhere
      --exclude "db/schema.rb"        exact file

--min-files N
    Minimum file count before advisory warning. Default: 20.

--top N
    Emit only the top N results. Default: all.

--verbose
    Print suppressed per-file warnings to stderr.

--version
    Print gem version and exit.

--help
    Print help and exit.
```

**Default excludes (always applied, cannot be disabled):**
- `db/schema.rb`
- `db/migrate/**`
- `vendor/**`
- `**/node_modules/**`
- `**/*.min.js`
- `tmp/**`
- `log/**`
- Files whose first non-blank line matches `/\A\s*#\s*This file is auto-generated/i`

---

## Scoring Pipeline

### Step 1 — File Discovery

Walk `PATH` recursively. Collect all `.rb` files. Apply default excludes, then `--exclude` patterns. Store result as `files[]`.

Glob matching: `File.fnmatch(pattern, relative_path, File::FNM_PATHNAME | File::FNM_DOTMATCH)`. `relative_path` is the file's path relative to `PATH` with no leading `./`.

**Post-collection checks:**
- `files.length < 5` → exit 1: `"Error: only N .rb files found after excludes. Too few for meaningful analysis."`
- `files.length < min_files` → print to stderr and continue:
  `"Warning: only N files found. Percentile ranks are unreliable at this scale. Results are advisory only."`

**Phase 1 note:** Only `.rb` files are collected. JavaScript files are not analyzed. Cross-language dependencies (JS → Rails API) are not tracked. This is a known limitation noted in output footers.

### Step 2 — fan_in via rubocop-ast

**Goal:** for each file, count how many other files in `files[]` reference the constant it owns.

#### 2a. Constant ownership

Each file owns one constant — its **primary constant**. Determination order:

1. **AST scan first:** parse the file with `rubocop-ast`. Walk the AST. Find the first `class` or `module` node at the top level of the file — i.e., not nested inside another `class` or `module` node. Use its resolved constant name (e.g., `Billing::Invoice`).

2. **Zeitwerk fallback:** if no top-level class or module node is found (constants-only file, DSL-only file, etc.), derive the constant from the file path using Zeitwerk rules (see below).

3. **No ownership:** if the file does not reside under `app/`, `lib/`, or `test/` (relative to `PATH`), skip constant mapping and assign `fan_in = 0`.

#### 2b. Zeitwerk path-to-constant mapping

Given a file path relative to `PATH`:

1. Strip the leading path segment up to and including the first `app/`, `lib/`, or `test/` directory component.  
   Example: `app/models/concerns/auditable.rb` → `models/concerns/auditable.rb`

2. **Strip the `concerns` segment** if present anywhere in the remaining path. Remove only the segment named `concerns` — not its parent.  
   Examples:
   - `models/concerns/auditable.rb` → `models/auditable.rb` → constant `Auditable`
   - `controllers/concerns/authenticatable.rb` → `controllers/authenticatable.rb` → constant `Authenticatable`
   - `concerns/shared_behavior.rb` → `shared_behavior.rb` → constant `SharedBehavior`

3. Strip the `.rb` extension.

4. Split on `/`. CamelCase each segment (`booking_payment_service` → `BookingPaymentService`).

5. Join with `::`.

#### 2c. Reference scanning

For each file in `files[]`, parse with `rubocop-ast`. Walk all `const` nodes. For each `const` node, resolve the full qualified name by following `cbase` (scope resolution) nodes upward. Build:

```
references[file] = Set<String>   # all fully-qualified constant names referenced
```

#### 2d. fan_in computation

```
fan_in[file] = count of files f in files[] where f != file AND constant_for[file] ∈ references[f]
```

Files with no ownership (step 2a rule 3) get `fan_in = 0` and are not counted as reference sources for those constants.

**Known limitation (document in README and output footer):** dynamic references (`Object.const_get`, string interpolation, metaprogramming via `send`) are not detected. fan_in is undercounted for files with heavy metaprogramming.

### Step 3 — Complexity via RuboCop

Run as subprocess:

```bash
rubocop --no-config --only Metrics/CyclomaticComplexity --format json <PATH>
```

`--no-config` is mandatory. Without it, the target repo's `.rubocop.yml` may disable `Metrics/CyclomaticComplexity`, override thresholds, or exclude files — all of which would corrupt stud-finder's scores.

**Aggregation:** RuboCop reports complexity per method. Sum all method scores per file. Files with no methods (config files, constant definitions, etc.) get `complexity = 0`.

**Parse errors:** if RuboCop reports a parse error for a file, skip that file (remove from `files[]`), emit to stderr, continue. Count skipped files and report in footer.

**Subprocess failure:** if `rubocop` is not found in PATH, exit 1:
```
Error: rubocop not found. Install it: gem install rubocop
```

### Step 4 — Churn via git log

Run as subprocess:

```bash
git -C <PATH> log \
  --since="<N> days ago" \
  --diff-filter=ACDMR \
  --name-only \
  --format=tformat: \
  -z
```

Flags explained:
- `--diff-filter=ACDMR` — include Added, Copied, Deleted, Modified, Renamed; exclude Unmerged/Unknown. Prevents double-counting: without this, a rename appears as both the old path and the new path under `--name-only`.
- `--format=tformat:` — empty format string; suppresses commit header lines entirely (no blank separators between commits).
- `-z` — NUL-delimit filenames instead of newline-delimiting. Required for correct parsing of filenames containing spaces, tabs, or other special characters.

**Parsing:** split output on NUL bytes (`\0`). Discard empty strings. Each remaining token is a filename. Build frequency count:

```ruby
churn = Hash.new(0)
tokens.each { |f| churn[f] += 1 }
```

**Path normalization:** normalize each path to a path relative to `PATH`. Discard entries that don't correspond to a file currently in `files[]` (deleted files, out-of-scope files).

**Zero-inflation check:** if `files.count { |f| churn[f] == 0 } > files.length * 0.5`, print warning to stderr:
```
Warning: X% of files have zero churn in the last N days. Churn signal is weak. Consider --churn-days to widen the window.
```

**Subprocess failures:**
- `git` not in PATH → exit 1: `"Error: git not found in PATH."`
- `PATH` is not a git repository → exit 1: `"Error: <PATH> is not a git repository."`

### Step 5 — Normalization

For each signal `s` in `{fan_in, complexity, churn}`:

1. Collect raw values across all files in `files[]` → `values[]`
2. For each file, compute percentile rank using the **lower-bound formula**:
   ```
   pct[file] = count(v in values where v < raw[file]) / (|files| - 1)
   ```
   - Files with the same raw value receive the same percentile rank (lower bound of their tied group).
   - Result is in [0.0, 1.0].

**Edge cases:**
- `|files| == 1` → `pct = 0.0` (denominator is 0; clamp).
- All files share the same raw value → `pct = 0.0` for all (numerator is always 0).

**Coverage (Phase 3 only):** not percentile-ranked. Used directly as `(1.0 - coverage_fraction)`. Coverage fraction is in [0.0, 1.0]; uncovered files contribute 1.0 to the coverage term.

### Step 6 — Composite Score

**Phase 1 (no coverage):** the coverage term is dropped. The three active weights are renormalized so they sum to 1.0:

```
total = w_fan_in + w_complexity + w_churn   # = 0.85 with defaults
w′_fan_in     = w_fan_in     / total        # ≈ 0.4118
w′_complexity = w_complexity / total        # ≈ 0.2941
w′_churn      = w_churn      / total        # ≈ 0.2941
```

Print once to stderr (and include in JSON warnings):
```
Note: coverage data not available. Score uses 3-factor formula (fan_in 0.41, complexity 0.29, churn 0.29).
```

**Score formula:**
```
risk_score = w′_fan_in × fan_in_pct + w′_complexity × complexity_pct + w′_churn × churn_pct
```

Result: [0.0, 1.0], rounded to 4 decimal places in output.

**Custom weights in Phase 1:** if user passes `--weights` with `coverage:0.0`, renormalization applies to the three non-zero weights as above. The three non-coverage values must still sum to 1.0 (±0.001) after coverage is excluded — if not, exit 1 with validation error showing the actual sum.

### Step 7 — Classification

Classification is based on `fan_in_pct` only (not composite score):

```
fan_in_pct >= trunk_threshold / 100.0   → trunk
fan_in_pct >= branch_threshold / 100.0  → branch
otherwise                                → leaf
```

Defaults: trunk_threshold = 85, branch_threshold = 50.

### Step 8 — Sort and Emit

Sort `files[]` by `risk_score` descending (stable sort — ties preserve file discovery order). Apply `--top N` slice if specified. Pass to reporter.

---

## Output Formats

### Table (default)

```
stud-finder — /path/to/my-rails-app (90-day churn, 3-factor score)
Note: coverage data not available. Score uses fan_in 0.41, complexity 0.29, churn 0.29.
Note: JavaScript files not analyzed (Phase 1). Cross-language dependencies not tracked.

 rank  file                                score   class   fan_in  complexity  churn
    1  app/models/user.rb                  0.8734  trunk       42          28     19
    2  lib/auth/token_verifier.rb          0.8112  trunk       38          31     12
    3  app/services/booking_service.rb     0.7401  branch      18          44     22
    4  app/models/booking.rb               0.7103  trunk       31          19      8

135 files analyzed. 2 files skipped (parse errors — run --verbose to see). 3 files excluded by default rules.
fan_in is a static approximation — dynamic references (const_get, send, metaprogramming) not counted.
```

Columns: `rank`, `file` (relative path), `score` (4 decimal places), `class`, `fan_in` (raw count), `complexity` (raw sum), `churn` (raw count).

### JSON

**Schema (normative — all field names, types, and null semantics are binding):**

```json
{
  "meta": {
    "repo": "<string — absolute path to analyzed repo>",
    "analyzed_at": "<string — ISO 8601 UTC, e.g. 2026-05-23T22:00:00Z>",
    "churn_days": "<integer>",
    "file_count": "<integer — files in final output after excludes and skips>",
    "files_skipped": "<integer — files dropped due to parse errors>",
    "formula": "<string — '3-factor (no coverage)' | '4-factor'>",
    "weights": {
      "fan_in": "<float>",
      "complexity": "<float>",
      "churn": "<float>",
      "coverage": "<float | null — null when coverage excluded>"
    },
    "warnings": ["<string — machine-readable warning codes, see below>"]
  },
  "files": [
    {
      "rank": "<integer — 1-indexed>",
      "path": "<string — relative to repo root, no leading ./>",
      "score": "<float — 4 decimal places>",
      "class": "<string — 'trunk' | 'branch' | 'leaf'>",
      "fan_in": "<integer — raw count>",
      "fan_in_pct": "<float — percentile rank [0.0, 1.0], 4 decimal places>",
      "complexity": "<integer — summed cyclomatic complexity>",
      "complexity_pct": "<float — 4 decimal places>",
      "churn": "<integer — commit count in window>",
      "churn_pct": "<float — 4 decimal places>",
      "coverage": "<float | null — fraction [0.0, 1.0]; null if unavailable>"
    }
  ]
}
```

**Warning codes (exhaustive):**

| Code | Condition |
|------|-----------|
| `coverage_unavailable` | No coverage data found (Phase 1 always emits this) |
| `zero_churn_majority` | >50% of files have zero churn in window |
| `small_repo` | file_count < min_files |
| `files_skipped` | One or more files dropped due to parse errors |
| `js_not_analyzed` | Phase 1 — JS files absent, cross-language deps not tracked |

**Example:**
```json
{
  "meta": {
    "repo": "/home/user/my-rails-app",
    "analyzed_at": "2026-05-23T22:00:00Z",
    "churn_days": 90,
    "file_count": 135,
    "files_skipped": 2,
    "formula": "3-factor (no coverage)",
    "weights": {
      "fan_in": 0.4118,
      "complexity": 0.2941,
      "churn": 0.2941,
      "coverage": null
    },
    "warnings": ["coverage_unavailable", "js_not_analyzed"]
  },
  "files": [
    {
      "rank": 1,
      "path": "app/models/user.rb",
      "score": 0.8734,
      "class": "trunk",
      "fan_in": 42,
      "fan_in_pct": 0.9778,
      "complexity": 28,
      "complexity_pct": 0.9111,
      "churn": 19,
      "churn_pct": 0.8889,
      "coverage": null
    }
  ]
}
```

### Markdown

```markdown
## stud-finder — 2026-05-23

> 3-factor score (no coverage). Churn window: 90 days. 135 files analyzed.
> JavaScript files not analyzed (Phase 1).

| rank | file | score | class | fan_in | complexity | churn |
|------|------|-------|-------|--------|------------|-------|
| 1 | app/models/user.rb | 0.8734 | trunk | 42 | 28 | 19 |

*fan_in is a static approximation — dynamic references not counted.*
```

---

## Error Handling

| Condition | Exit code | Behavior |
|-----------|-----------|----------|
| `PATH` does not exist | 1 | Clear error message |
| `PATH` is not a git repository | 1 | Clear error message |
| `rubocop` not in PATH | 1 | Error + install instructions |
| `git` not in PATH | 1 | Clear error message |
| File count < 5 (post-exclude) | 1 | "Too few files" error |
| File count < min_files | 0 | Warning to stderr, continue |
| >50% zero-churn files | 0 | Warning to stderr, continue |
| `--weights` values don't sum to 1.0 | 1 | Validation error with actual sum |
| `--weights coverage:N` where N > 0 in Phase 1 | 1 | Validation error |
| `--branch-threshold >= --trunk-threshold` | 1 | Validation error |
| RuboCop parse error on a file | 0 | Skip file, log to stderr, continue |
| AST parse error on a file | 0 | Skip file, log to stderr, continue |
| git subprocess non-zero exit | 1 | Propagate stderr, exit 1 |

---

## Gem Structure

```
stud-finder/
├── bin/
│   └── stud-finder              # Executable entry point
├── lib/
│   └── stud_finder/
│       ├── version.rb
│       ├── cli.rb               # Argument parsing and validation (OptionParser or Thor)
│       ├── file_collector.rb    # File discovery, glob exclude application
│       ├── fan_in.rb            # rubocop-ast constant ownership + reference scanning
│       ├── complexity.rb        # rubocop subprocess, JSON parsing, per-file aggregation
│       ├── churn.rb             # git log subprocess, NUL-delimited parsing, frequency count
│       ├── normalizer.rb        # Percentile rank computation
│       ├── scorer.rb            # Weight application, renormalization, classification
│       └── reporter.rb          # table / json / markdown formatting
├── spec/
│   └── stud_finder/
│       ├── file_collector_spec.rb
│       ├── fan_in_spec.rb
│       ├── complexity_spec.rb
│       ├── churn_spec.rb
│       ├── normalizer_spec.rb
│       ├── scorer_spec.rb
│       └── integration/
│           └── fixture_repo_spec.rb
├── spec/fixtures/
│   └── sample_app/              # Minimal Rails-like directory tree for integration tests
├── stud-finder.gemspec
├── Gemfile
├── README.md
└── TRD.md
```

---

## Dependencies

**Runtime:**
- `rubocop-ast` — AST parsing for fan_in and Zeitwerk fallback
- `rubocop` (gem) — required to ensure the binary is available; also invoked as subprocess

**CLI parsing:** stdlib `OptionParser` preferred over Thor to keep the dependency surface minimal. Use Thor only if sub-command routing is needed (not currently planned).

**Development:**
- `rspec` — test suite
- `rubocop` — gem linting (separate invocation from analysis, uses stud-finder's own `.rubocop.yml`)

**External binaries (must be in PATH at runtime):**
- `git` — always required
- `rubocop` — always required (Phase 1+)
- `npx dependency-cruiser` — Phase 2 only
- `npx eslint` — Phase 2 only

---

## Testing Requirements

### Unit tests

- **`file_collector_spec.rb`** — glob exclude semantics (FNM_PATHNAME | FNM_DOTMATCH), default excludes, auto-generated header detection, file count thresholds
- **`fan_in_spec.rb`** — Zeitwerk path mapping (standard, concerns stripping, nested namespaces), AST primary constant detection (top-level only, not nested), multi-constant files (first top-level wins), fallback ordering, fan_in counting, zero fan_in (no-ownership case), files outside app/lib/test
- **`complexity_spec.rb`** — RuboCop JSON output parsing, per-method sum aggregation, zero-method files, `--no-config` flag presence in subprocess call, parse error handling
- **`churn_spec.rb`** — NUL-delimited git output parsing, filenames with spaces, rename handling (single count per rename event with `--diff-filter=ACDMR`), zero-churn files, window calculation, zero-inflation threshold
- **`normalizer_spec.rb`** — lower-bound percentile formula, tie handling, single-file edge case (clamp to 0.0), all-same-value edge case (all 0.0), zero-inflation detection
- **`scorer_spec.rb`** — Phase 1 weight renormalization (sum 0.85 → 1.0), custom weights validation, `coverage:N > 0` rejection in Phase 1, classification thresholds, `branch >= trunk` rejection

### Integration test

`spec/integration/fixture_repo_spec.rb`: run stud-finder against `spec/fixtures/sample_app/`. Assert:
- Top-ranked file is the one with highest artificial fan_in
- All scores in [0.0, 1.0]
- JSON output is valid and matches schema
- Exit code 0

The fixture repo must be a real git repository (initialized in spec setup or checked in) so churn analysis runs against actual git history.

---

## Phase 2 — JavaScript (future, not in Phase 1)

When Phase 2 is implemented:
- Add `.js`, `.ts`, `.jsx`, `.tsx` file collection
- fan_in via `npx dependency-cruiser --output-type json`
- complexity via `npx eslint` with complexity rule
- Both tools are optional subprocesses: if not found in PATH, degrade gracefully — emit warning, set signal to 0 for affected files, continue. Do not exit 1. Partial results are valid output.

---

## Acceptance Criteria (Phase 1)

- [ ] `stud-finder ./path/to/rails/app` produces a ranked table with correct columns
- [ ] fan_in is non-zero for well-connected files (e.g., User model referenced across the app)
- [ ] complexity scores match summed RuboCop per-method output
- [ ] churn scores reflect git log commit counts for the window
- [ ] filenames with spaces parse correctly (NUL-delimited git output)
- [ ] rename events counted once, not twice (`--diff-filter=ACDMR`)
- [ ] `--no-config` is passed in rubocop subprocess (verified by unit test asserting the subprocess command)
- [ ] `concerns/` segment stripped correctly in Zeitwerk mapping (the segment itself, not its parent)
- [ ] first top-level class/module used as primary constant (nested classes ignored)
- [ ] zero-churn warning fires when >50% of files have zero churn
- [ ] small-repo warning fires at < min_files
- [ ] `rubocop` not in PATH → exit 1 with message
- [ ] `git` not in PATH → exit 1 with message
- [ ] not-a-git-repo → exit 1 with message
- [ ] `--weights` with non-summing values → exit 1 with validation error showing actual sum
- [ ] `--weights coverage:0.15` in Phase 1 → exit 1 with validation error
- [ ] `--branch-threshold >= --trunk-threshold` → exit 1
- [ ] `--output json` produces valid JSON matching the normative schema
- [ ] `--output markdown` produces valid markdown table
- [ ] default excludes filter `db/schema.rb`, `vendor/`, `db/migrate/**`, auto-generated headers
- [ ] JS absence noted in table footer and JSON warning codes
- [ ] all unit tests pass
- [ ] integration test passes against fixture repo
