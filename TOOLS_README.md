# CP09A / GeoAI Pipeline Tools

Four standalone PowerShell tools added to the CP09A/GeoAI family. Each follows the
established house conventions: `#requires` directive, `[CmdletBinding()]`, `param()`
with Windows absolute-path defaults, `Set-StrictMode -Version Latest`,
`$ErrorActionPreference='Stop'`, `$Version='1.0.0'`, `$Classification`, a timestamped
`$RunId`, staging -> promote with a no-overwrite guard, SHA256 evidence
(`Summary.json`/`Summary.txt`/`SHA256SUMS.txt` plus register CSVs), a self-install block
guarded by `Test-ScriptSyntax` (via `[System.Management.Automation.Language.Parser]::ParseFile`),
and a `[switch]$AuditOnly` mode that analyzes and prints without writing anything.

> Validation note: these scripts were validated **statically** (balanced
> braces/parentheses/quotes, variable coherence, no use-before-definition) because the
> build sandbox has no PowerShell runtime (`pwsh` absent). They assume Windows absolute
> paths and real geological data, so end-to-end execution is not performed here.

---

## TOOL i - Normalize_CP09A_CSV_Delimiter_v1_0_0.ps1

**Purpose.** A robust, multi-line, quote-aware CSV delimiter detector and canonical
normalizer. It is the shared, correct replacement for the fragile inline `Delimiter`
function used in `Cross_Export_Comparison_Engine` (that function reads only the first
line via `Get-Content -TotalCount 1` and miscounts delimiters that appear **inside**
quoted fields).

**How detection works.**
- Samples up to `-SampleLines` physical records (default 50), joining records that span
  multiple physical lines because of an unterminated quoted field (odd quote count).
- For each candidate delimiter (`,`, `;`, tab, `|`) it performs a real quote-aware scan
  (`Split-CsvLine`) that respects double-quote enclosure and the `""` escape, so commas
  (or any delimiter) inside quoted fields are **not** counted as separators.
- Scores each candidate by the consistency of its field count across the sampled records
  (dominant field-count frequency / sampled records) and picks the delimiter with the
  highest consistency, breaking ties by the higher stable field count. Candidates whose
  dominant field count is 1 are rejected.
- The detection is exposed as a reusable function **`Get-CsvDelimiter`** returning the
  delimiter, label, field count, sampled-record count, consistency and a `Confident` flag
  (consistency >= 0.95).

**Requires:** PowerShell 7.4 (unified family directive; see REFACTOR_NOTES.md).

**Key parameters.**
- `-InputPath` - a single CSV file **or** a folder (recursed for `*.csv`).
- `-OutputRoot` - root under which the run folder is promoted.
- `-SampleLines` - sample size for detection (default 50).
- `-AuditOnly` - detect and print the per-file delimiter and column-count consistency; write nothing.

**Outputs (normalize mode).** Under `<OutputRoot>\<RunId>\`:
`CSV\...` (canonical comma-delimited, fully quoted copies written via staging with a
no-overwrite guard), `_Delimiter_Record\Delimiter_Detection.csv`,
`Normalization_Register.csv`, `Summary.json`, `Summary.txt`, `SHA256SUMS.txt`.

**Relationship to Cross_Export.** TOOL i is the shared, standalone robust implementation
(`Get-CsvDelimiter` / `Split-CsvLine`). The equivalent quote-aware, multi-line detection
has ALSO been swapped in-place into `Cross_Export_Comparison_Engine_v1_0_2.ps1`: its
former fragile inline `Delimiter` function (which read only the first line via
`Get-Content -TotalCount 1` and miscounted delimiters inside quoted fields) was replaced
with `Split-CsvLine` + `Read-SampleRecords` + a scoring `Delimiter` detector in the file's
dense one-liner house style, preserving the existing return contract (the raw delimiter
character, `` "`t" `` for TAB) so `Metadata` and `RowCompare` are unchanged. See
`CROSS_EXPORT_v1_0_2_VERIFICATION.md` and the review remediation note for details.
`Cross_Export_Comparison_Engine_v1_0_2.ps1` is NOT a registered component, so no
`INTEGRATION_REGISTER.json` hash update is required; the two registered components remain
byte-for-byte unchanged.

---

## TOOL ii - Verify_CP09A_Integration_Register_v1_0_0.ps1

**Purpose.** Loads `INTEGRATION_REGISTER.json` and verifies every registered component
against the files that actually exist, detecting both **hash** and **version**
desynchronization.

**How it works.**
- Resolves each component against a configurable `-RepositoryRoot`: the exact registered
  `C:\...` path first, then (since those paths will not exist on other hosts) by the
  **leaf file name** under the repository root.
- Recomputes SHA256 and reports `HASH_MATCH` / `HASH_MISMATCH` / `FILE_NOT_FOUND`.
- Detects `VERSION_MISMATCH` by comparing the `_vX_Y_Z` token parsed from the file name
  against the in-file `$Version` / `$ScriptVersion` declaration.
- Emits a GO/REVIEW/NO_GO-style **decision**:
  - `NO_GO` - at least one resolved file has a confirmed hash mismatch.
  - `REVIEW_REQUIRED` - any missing/ambiguous file or any version drift.
  - `PASS` - every component resolved, hashes match, versions consistent.

**Requires:** PowerShell 7.4 (to match the register/governance family).

**Key parameters.**
- `-RegisterPath` - path to `INTEGRATION_REGISTER.json`.
- `-RepositoryRoot` - root to resolve components against (default the application root).
- `-OutputRoot` - root under which the run folder is promoted.
- `-AuditOnly` - report the per-component status table and decision; write nothing.

**Outputs.** Under `<OutputRoot>\<RunId>\`: `Register_Verification.csv`,
`Summary.json`, `Summary.txt`, `SHA256SUMS.txt`.

---

## TOOL iii - Orchestrate_CP09A_GeoAI_Pipeline_v1_0_0.ps1

**Purpose.** Master orchestrator that chains the pipeline stages under one shared
pipeline RUN_ID with fail-fast behavior:

`Consolidation` -> `LAS->CSV` -> `Composite` -> `Compare`

**How it works.**
- `-MasterRunId` defaults to `CP09A-GEOAI-PIPELINE-<timestamp>` and tags the master
  evidence record.
- Locates each stage script under a configurable `-ScriptRoot` (recursive glob). The
  Compare stage **prefers `Cross_Export_Comparison_Engine_v1_0_2.ps1`** and falls back to
  any available version.
- Invokes each stage in a child `pwsh -NoProfile -File` process (so a stage's terminal
  `exit` cannot kill the orchestrator), checks `$LASTEXITCODE` after each stage, and
  **stops the chain on the first non-zero exit (fail-fast)**, recording a per-stage status row.
- `-AuditOnly` is a dry run: it prints the resolved script paths and the full invocation
  chain **without executing any stage**.

**RUN_ID coupling.** The downstream stage scripts do not accept a `RunId` parameter. The
shared `MasterRunId` tags the orchestrator's own evidence; the stages couple through
**folder discovery**. In particular, Composite auto-discovers the latest LAS-to-CSV run
via its `Resolve-InputRoot` (newest `CP09A-LAS-TO-CSV-*` folder under `LasCsvRoot`), so
running LAS-to-CSV then Composite in sequence links them without a direct parameter. The
Compare stage reads a pre-existing processed-exports pipeline run (`-ProcessedRoot` /
`-ComparePipelineRunId`).

**Runtime choice.** `#requires -Version 7.4` is deliberate so the single host can run the
7.4 Compare stage; the upstream 5.1 stages are forward compatible with a 7.4 host, which
avoids a runtime split-brain across the chain.

**Requires:** PowerShell 7.4.

**Key parameters.**
- `-ScriptRoot` - root to locate the four stage scripts.
- `-OutputRoot` - root under which the master run folder is promoted.
- Per-stage roots: `-ZipPath`, `-ConsolidationRoot`, `-LasInputRoot`, `-LasCsvRoot`,
  `-CompositeOutputRoot`, `-ProcessedRoot`, `-ComparePipelineRunId`,
  `-BaselineExportId`, `-CandidateExportId`.
- `-AuditOnly` - print the resolved invocation chain; execute nothing.

**Outputs.** Under `<OutputRoot>\<MasterRunId>\`:
`_Pipeline_Record\Pipeline_Stage_Register.csv`, `Summary.json`, `Summary.txt`,
`SHA256SUMS.txt`, plus `Execution.log`.

---

## TOOL iv - Normalize_CP09A_Schema_Names_v1_0_0.ps1

**Purpose.** A conservative schema-name normalizer for the CSV family. It harmonizes
file/folder names, column headers and cell values toward a single canonical vocabulary
(including American Z/F spellings) using **exact whole-value matching only**, so free
text and numeric data that must not change are never touched.

**How it works.**
- Scans the input (a single CSV file or a folder recursed for `*.csv`), reading full
  records with a quote-aware, multi-line-safe reader (`Read-CsvRecords` / `Split-CsvLine`
  respecting double-quote enclosure and the `""` escape), then applies three
  normalization levels:
  - **LEVEL 1 - file AND folder names.** Exact whole-name renames resolved against
    `$FileRenameMap` (case-insensitive match, canonical casing emitted from the table).
    Every segment of each relative path is canonicalized independently, so a mapped
    folder name is renamed as well as a mapped file leaf, and the staged target path is
    rebuilt from the canonicalized segments. Level-1 folder renames are recorded in
    `Normalization_Map.csv` too.
  - **LEVEL 2 - column headers.** Each whole header value is normalized via
    `Get-CanonicalTerm`.
  - **LEVEL 3 - cell values.** Every whole cell value (every row after the header) is
    normalized via the same `Get-CanonicalTerm`.
- **Exact whole-value matching semantics.** A file/folder leaf name, a complete column
  name, or a complete cell value must match a rule **exactly** (case-insensitive on the
  whole value). The tool NEVER performs a partial/substring replacement inside free
  text; that is the safeguard against altering data that must not change.
- **Configurable / expandable rule tables.** All rules live isolated at the top of the
  script so the tool is a base for future expansion:
  - `$FileRenameMap` (LEVEL 1): exact old leaf name -> new name; append further exact
    pairs as needed (preloaded: `04LITHOLOGY_DET.csv` -> `04A_LITHOLOGY_DET.csv`).
  - `$TermMap` (LEVELS 2 & 3): exact UPPERCASE term -> canonical American term. For a
    value not found in the table, two whole-value suffix rules then apply:
    `-ISATION -> -IZATION` and `-ISED -> -IZED`; otherwise the value is returned
    unchanged. Expand `$TermMap` with further whole-value terms as the vocabulary grows.
  - `$SuffixDenyList` (LEVELS 2 & 3 gate): the generic suffix rules are GATED by this
    expandable deny-list of common English `-ISED`/`-ISATION` words (e.g. `RAISED`,
    `REVISED`, `ADVISED`, `ORGANISATION`). A whole value listed here is left unchanged
    so ordinary English is never mangled into `RAIZED`/`REVIZED`, while genuine
    geological morphology not yet in `$TermMap` is still normalized. Explicit `$TermMap`
    entries (such as `SILICISED` -> `SILICIFIED`) are resolved before the gate and are
    unaffected by it.
- **Decision.** Emits `PASS`, or `REVIEW_REQUIRED` when a LEVEL 1 rename collision is
  detected on FULL target relative paths: two renames resolving to the same relative
  path, or a rename target that would land on an existing source file not itself being
  renamed away. The per-file no-overwrite guard remains the fail-closed backstop at
  apply time.
- **Audit-only is the DEFAULT.** With no switches (or with `-AuditOnly`) the tool scans,
  prints the planned changes by level and the decision, and writes **nothing**. Only
  `-Apply` performs the write via staging -> promote (with no-overwrite guards and a
  `Test-ScriptSyntax`-guarded self-install); source files are never deleted.

**Requires:** PowerShell 7.4.

**Key parameters.**
- `-InputPath` - a single CSV file **or** a folder (recursed for `*.csv`).
- `-OutputRoot` - root under which the run folder is promoted.
- `-ApplicationRoot` - application root under which the governed script is self-installed.
- `-AuditOnly` - scan and report the planned changes and decision; write nothing. This is
  the default behavior and, when supplied, forces audit-only even if `-Apply` is present.
- `-Apply` - execute switch that performs the staging -> promote write. The write path is
  gated behind this switch so audit-only remains the default.

**Outputs (apply mode).** Under `<OutputRoot>\<RunId>\`: the normalized `CSV\...` copies
plus the evidence record `Normalization_Map.csv`, `Summary.json`, `Summary.txt`,
`SHA256SUMS.txt`. The SHA256 manifest hashes BOTH the evidence record files AND the
normalized `CSV\` data outputs (data outputs are listed with a `CSV/<relative>` prefix).
