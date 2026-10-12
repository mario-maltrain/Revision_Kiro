# CP09A / GeoAI Pipeline - P1/P2 Refactor Notes (OPTION 3 / FEAT-003)

This note documents the four debt-reduction refactors applied to the CP09A/GeoAI
PowerShell family. All existing conventions were preserved: `Set-StrictMode -Version
Latest`, `$ErrorActionPreference='Stop'`, staging->promote, no-overwrite throws,
SHA256 validation, self-install guarded by `Test-ScriptSyntax`, AuditOnly modes,
versioned headers, and timestamped RunId.

Validation note: `pwsh` is not available in this environment, so scripts were NOT
executed or AST-parsed with the real parser. Validation was STATIC: balanced
braces/parentheses/brackets (code-only paren balance confirmed; residual raw-count
mismatches are comment artifacts such as the `1)` `2)` `3)` list markers), consistent
variable names, no use-before-definition, and preserved control flow.

---

## (a) P1 - Externalize the hardcoded ExpectedZipSHA256

File: `Run_CP09A_GeoAI_Consolidation_v1_0_1.ps1`

Previously the expected ZIP hash was only a hardcoded `param()` default, so a new
export ZIP broke preflight until someone edited the script body.

Change:
- Added a new optional parameter `-ExpectedZipSHA256Path` (sidecar hash file path).
- Captured the shipped literal as `$DefaultExpectedZipSHA256` so an explicit override
  can be distinguished from the default.
- Added `Resolve-ExpectedZipSHA256` which applies the resolution order and
  `Test-ExpectedHashFormat` which reuses the 64-char hex guard on the resolved value.
- The sidecar reader accepts a bare hash or a `sha256sum`-style line
  (`<hash> *<file>` / `<hash>  <file>`), taking the first whitespace token and
  trimming a leading `*`.

Resolution order (highest priority first):
1. **Explicit param** - `-ExpectedZipSHA256` whenever it was explicitly bound on the
   command line (keyed off `$PSBoundParameters.ContainsKey('ExpectedZipSHA256')`, so an
   explicitly passed hash wins even if it happens to equal the shipped default).
2. **Sidecar file** - `-ExpectedZipSHA256Path`, or `'<ZipPath>.sha256'` when that param is empty, if the file exists.
3. **Literal default** - the shipped `$DefaultExpectedZipSHA256` fallback (backward compatible).

> Review remediation (issue 5): the explicit-param branch originally fired only when the
> passed value *differed* from the shipped default, which let a sidecar silently win when an
> operator explicitly passed a hash equal to the default. It is now keyed off
> `$PSBoundParameters.ContainsKey('ExpectedZipSHA256')` so "explicit param wins" is literally
> honoured. Behaviour is unchanged whenever the values match.

Preserved: the 64-char hex validation (now via `Test-ExpectedHashFormat`), the ZIP
SHA256 mismatch-throw, and the staging->promote / no-overwrite flow are unchanged.
A new ZIP plus a matching `<ZipPath>.sha256` sidecar now passes preflight without
editing the script body. The resolved source is logged and recorded in Summary as
`ExpectedZipSHA256Source`.

---

## (b) P2 - Unify the #requires directives

Policy chosen: **the entire family standardizes on `#Requires -Version 7.4`** (capital
`R`, uniform casing). 7.4 is the highest requirement already present (the
governance/compare engines need it), and any host that can run the 7.4 scripts can run
the former 5.1 scripts.

Per-file decision:

| Script | Before | After | Registered? | Register action |
|---|---|---|---|---|
| Application_Governance_Controls_v1_2_1.ps1 | `#Requires -Version 7.4` | unchanged (banner added, see (d)) | No | none |
| Application_Governance_Controls_v1_2_2.ps1 | `#Requires -Version 7.4` | unchanged | **Yes** | no byte change -> no update |
| Cross_Export_Comparison_Engine_v1_0_1.ps1 | `#Requires -Version 7.4` | unchanged | **Yes** | no byte change -> no update |
| Cross_Export_Comparison_Engine_v1_0_2.ps1 | `#Requires -Version 7.4` | unchanged | No | none |
| Composite_CP09A_GeoAI_1m_3m_6m_v1_0_0.ps1 | `#requires -Version 5.1` | `#Requires -Version 7.4` | No | none |
| Convert_CP09A_LAS_to_CSV_v1_0_0.ps1 | `#requires -Version 5.1` | `#Requires -Version 7.4` | No | none |
| CP09A_AutoLith_Duplicate_Audit_Cleanup_v1_0_0.ps1 | `#requires -Version 5.1` | `#Requires -Version 7.4` | No | none |
| GeoAI_CP09A_Repository_Inventory_v1_3_0.ps1 | `#requires -Version 5.1` | `#Requires -Version 7.4` | No | none |
| Normalize_CP09A_CSV_Delimiter_v1_0_0.ps1 | `#requires -Version 5.1` | `#Requires -Version 7.4` | No | none |
| Run_CP09A_GeoAI_Consolidation_v1_0_1.ps1 | `#requires -Version 5.1` | `#Requires -Version 7.4` | No | none |
| Orchestrate_CP09A_GeoAI_Pipeline_v1_0_0.ps1 | `#requires -Version 7.4` | `#Requires -Version 7.4` (casing only) | No | none |

Compatibility review before raising the former 5.1 scripts: none use a Windows
PowerShell 5.1-only construct. They use `Add-Type -AssemblyName System.IO.Compression*`,
`[System.Management.Automation.Language.Parser]::ParseFile`, `Get-FileHash`,
`Export-Csv`/`ConvertTo-Json`, and an embedded `& python` heredoc - all available on 7.4.
No `Get-WmiObject`, COM, or WinPS-only module usage was found.

> Review remediation (issue 3): raising the formerly-5.1 scripts
> (Consolidation, LAS-to-CSV, Composite, Inventory, Duplicate-Audit, and the new
> Normalize tool) to `#Requires -Version 7.4` means a host with **only** Windows
> PowerShell 5.1 can no longer run them. This is an **accepted, deliberate trade-off**:
> the compare/governance/orchestrator stages already mandate 7.4, the whole CP09A/GeoAI
> family is intended to run on a single PowerShell 7.4 host, and a mixed-floor family
> (some stages 5.1, some 7.4) is exactly the version split-brain the unification removes.
> No target host in this pipeline is 5.1-only. If a 5.1-only host must ever be supported,
> the former 5.1 scripts use no 7.4-only language construct (see the compatibility review
> above), so their directive could be lowered again without code changes - but the
> **supported, shipped baseline is 7.4 across the family**.

---

## (c) P2 - Collapse the 500-cycle preflight loop

File: `Run_CP09A_GeoAI_Consolidation_v1_0_1.ps1`

The `for ($cycle=1; $cycle -le 500; $cycle++)` loop re-checked the same four STATIC
conditions 500 times with no added coverage and 500 `Write-Progress` increments.

Change: replaced with a single evaluation of the four conditions:
1. ZIP present (`Test-Path` leaf),
2. installed script parser-valid (`Test-ScriptSyntax`),
3. no final-folder collision (`Test-Path`),
4. expected hash is valid 64-char hex (`Test-ExpectedHashFormat`).

Preserved behavior: failures still aggregate into `$validationFailures`; on any failure
the script still writes `Preflight_Failures.txt` and still throws with the aggregated
failure count; on success it logs `preflight validation: PASS`. `Write-Progress` is now a
single preflight step.

Summary schema impact (kept coherent):
- Removed `PreflightValidationCycles=500`.
- Added `PreflightValidationMode='SINGLE_PASS'` and `PreflightValidationPassed=$true`.
- Kept `PreflightValidationFailures=0`.
- Added `ExpectedZipSHA256Source` (records which resolution branch supplied the hash).

---

## (d) P2 - Consolidate the two Application_Governance_Controls versions

- `Application_Governance_Controls_v1_2_2.ps1` is designated the ACTIVE, registered
  control script (matches `INTEGRATION_REGISTER.json`). **Its bytes were NOT modified.**
- `Application_Governance_Controls_v1_2_1.ps1` is marked SUPERSEDED via a header banner
  (`SUPERSEDED - RETAINED FOR HISTORICAL REFERENCE ONLY. DO NOT USE.`) that cites v1_2_2
  and the register as source of truth. It is NOT deleted (non-destructive, matching the
  Composite failure register's `DO_NOT_USE`/superseded precedent).
- Added `GOVERNANCE_CONTROLS_VERSIONS.md` documenting the designation and rationale.

v1_2_1 is NOT a registered component, so no register update is required for its byte
change.

---

## Register reconciliation table

Recomputed `sha256sum` (uppercased) after all refactors:

| Component | Registered? | SHA256 | Register action |
|---|---|---|---|
| Application_Governance_Controls_v1_2_2.ps1 | Yes | C5242E7E1C6892505EDD69C5F79C37E3BDFD2E9B679337884A0D03D2A2AEEBDA | unchanged - matches |
| Cross_Export_Comparison_Engine_v1_0_1.ps1 | Yes | F27F46FFC08D4733C595753E6A921CED87AD901685D93FAFDE4B09F1E6B3BBD4 | unchanged - matches |

Result: every component in `INTEGRATION_REGISTER.json` has a registered SHA256 that
matches its file after the refactors. No new desynchronization was introduced.
