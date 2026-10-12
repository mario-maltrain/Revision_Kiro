# Application Governance Controls - Version Designation


Two copies of the Application Governance control script coexist in this repository.
This note designates the authoritative version and records why both are retained.

## Active version

**`Application_Governance_Controls_v1_2_2.ps1`** is the ACTIVE, deployed control
script. It is the version registered in `INTEGRATION_REGISTER.json`, which is the
authoritative source of truth for the installed component set.

- Registered SHA256: `C5242E7E1C6892505EDD69C5F79C37E3BDFD2E9B679337884A0D03D2A2AEEBDA`
- Style: dense one-liner governance engine (7.4 governance/compare family style).

## Superseded version

**`Application_Governance_Controls_v1_2_1.ps1`** (551-line multi-line formatting)
is SUPERSEDED and retained for historical/audit reference only. It is NOT
registered in `INTEGRATION_REGISTER.json` and is NOT deployed.

A header banner has been added to v1_2_1 marking it `SUPERSEDED - DO NOT USE`
and pointing to v1_2_2 and this note. This follows the repository's existing
governance ethos of marking rather than deleting (the Composite failure register
uses `DO_NOT_USE` / superseded dispositions as precedent).

## Rationale for retention (not deletion)

The pipeline's governance posture is evidence-first and non-destructive: nothing
is silently removed. Keeping v1_2_1 with an explicit superseded banner preserves
lineage and audit traceability while leaving no ambiguity about which script is
active. The register remains the single source of truth; if v1_2_1 is ever
retired, it should be removed in a deliberate, logged change, not silently.
