#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$InputPath = 'C:\Python\GeoAi\00_Base_Datos\GeoAi\01_LAS_to_CSV',
    [string]$OutputRoot = 'C:\Python\GeoAi\00_Base_Datos\GeoAi\15_Schema_Name_Normalization',
    [string]$ApplicationRoot = 'C:\Python\GeoAi\01_Aplicacion\CP09A_Release_v2.1',
    # Family convention switch. When supplied, forces audit-only behavior.
    [switch]$AuditOnly,
    # Explicit execute switch. The WRITE path is gated behind this switch so that
    # audit-only is the DEFAULT: with NO switches, or with -AuditOnly, the tool
    # scans and reports but writes nothing. Only -Apply performs staging->promote.
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'Continue'

$Version = '1.0.0'
# NEUTRAL classification. This tool deliberately carries no client/organisation
# name anywhere in its titles or output.
$Classification = 'Internal'
$RunId = 'CP09A-SCHEMA-NAMES-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$StagingRoot = Join-Path $OutputRoot ('.staging-' + $RunId)
$FinalRoot = Join-Path $OutputRoot $RunId
$DataRoot = Join-Path $StagingRoot 'CSV'
$RecordRoot = Join-Path $StagingRoot '_Schema_Record'
$LogPath = Join-Path $RecordRoot 'Execution.log'
$InstalledFolder = Join-Path $ApplicationRoot '00_Script\Schema_Names'
$InstalledPath = Join-Path $InstalledFolder 'Normalize_CP09A_Schema_Names_v1_0_0.ps1'
$SourceScriptPath = $MyInvocation.MyCommand.Path

# Audit-only is the DEFAULT. The write path requires an explicit -Apply.
# Supplying -AuditOnly (or supplying nothing) keeps the tool in read-only mode.
$ExecuteMode = ($Apply.IsPresent -and -not $AuditOnly.IsPresent)

# =====================================================================================
# CONFIGURABLE / EXPANDABLE RULE TABLES
# -------------------------------------------------------------------------------------
# All normalization rules live here, isolated at the top of the script, so the tool is
# the base for future expansion. Normalization is by EXACT WHOLE-VALUE match only:
# a file/folder name, a complete column name, or a complete cell value must match a
# rule exactly. The tool NEVER performs a partial/substring replacement inside free
# text, which is the safeguard against altering data that must not change.
# =====================================================================================

# -------------------------------------------------------------------------------------
# TABLE A - $FileRenameMap (LEVEL 1): exact old file/folder name -> new name.
# Keys and values are compared as EXACT whole leaf names (case-insensitive match,
# canonical casing emitted from the table). Append further exact pairs as needed.
# -------------------------------------------------------------------------------------
$FileRenameMap = [ordered]@{
    '04LITHOLOGY_DET.csv' = '04A_LITHOLOGY_DET.csv'
    # Add additional exact file/folder rename pairs below, e.g.
    # 'OLDNAME.csv' = 'NEWNAME.csv'
}

# -------------------------------------------------------------------------------------
# TABLE B - $TermMap (LEVELS 2 & 3): exact UPPERCASE term -> canonical American term.
# Recognises British spellings and normalizes toward the American (Z/F) spelling.
# Matching is case-insensitive on the WHOLE value; the canonical casing emitted is the
# American value exactly as stored here. Expand this table with further whole-value
# geological terms as the schema vocabulary grows.
# -------------------------------------------------------------------------------------
$TermMap = [ordered]@{
    'MINERALISATION'  = 'MINERALIZATION'
    'MINERALISED'     = 'MINERALIZED'
    'MINERALISE'      = 'MINERALIZE'
    'SULPHIDE'        = 'SULFIDE'
    'SULPHATE'        = 'SULFATE'
    'SULPHUR'         = 'SULFUR'
    'OXIDISED'        = 'OXIDIZED'
    'OXIDISATION'     = 'OXIDIZATION'
    'SERICITISATION'  = 'SERICITIZATION'
    'CARBONATISATION' = 'CARBONATIZATION'
    'ARGILLISATION'   = 'ARGILLIZATION'
    'CHLORITISATION'  = 'CHLORITIZATION'
    'SILICISED'       = 'SILICIFIED'
    'COLOUR'          = 'COLOR'
    'GREY'            = 'GRAY'
    'ANALYSE'         = 'ANALYZE'
    'CATALOGUE'       = 'CATALOG'
}

# -------------------------------------------------------------------------------------
# TABLE C - $SuffixDenyList (LEVELS 2 & 3 gate): CONFIGURABLE / EXPANDABLE.
# The generic whole-value suffix rules (-ISATION -> -IZATION, -ISED -> -IZED) exist so
# that genuine British->American geological morphology is still normalized even for
# terms not yet enumerated in $TermMap. But those endings also occur in ordinary English
# words (RAISED, REVISED, ADVISED, ...) that must NOT be mangled (RAIZED/REVIZED/...),
# which would defeat the exact-whole-value safeguard. To keep the generic rule useful
# without corrupting plain English, the suffix transform is GATED by this deny-list:
# if the uppercased whole value is listed here, the suffix rules are skipped and the
# value is returned unchanged. Entries are stored UPPERCASE and matched case-insensitively
# on the WHOLE value. Expand this list as more common English -ISED/-ISATION words are
# encountered in the corpus. (Explicit $TermMap entries such as SILICISED->SILICIFIED are
# resolved BEFORE this gate and are unaffected by it.)
# -------------------------------------------------------------------------------------
$SuffixDenyList = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($denyWord in @(
    # Common English -ISED words (and their inflections) that are NOT geological terms.
    'RAISED','REVISED','ADVISED','DEVISED','SUPERVISED','COMPROMISED','IMPROVISED',
    'EXERCISED','DISGUISED','SURPRISED','SUMMARISED','APPRAISED','PARAPHRASED',
    'FRANCHISED','MERCHANDISED','ENTERPRISED',
    # Common English -ISATION / -ISE related nouns that are NOT geological terms.
    'ORGANISATION','AUTHORISATION','RECOGNISATION','CIVILISATION','PRIVATISATION',
    'STANDARDISATION','CHARACTERISATION','OPTIMISATION','UTILISATION','REALISATION',
    'LOCALISATION','VISUALISATION','SYNCHRONISATION','CATEGORISATION','PRIORITISATION'
)) { [void]$SuffixDenyList.Add($denyWord) }

# =====================================================================================
# HELPER FUNCTIONS (all defined before their call sites in the main body)
# =====================================================================================

function Write-RunLog {
    param([string]$Message,[ValidateSet('INFO','PASS','WARN','ERROR')][string]$Level='INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Message
    Write-Host $line
    if (Test-Path -LiteralPath $RecordRoot -PathType Container) { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 }
}

function Test-ScriptSyntax {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    return ($null -eq $errors -or $errors.Count -eq 0)
}

# Quote-aware field split for a single physical CSV record line.
# Respects RFC 4180 double-quote enclosure and the "" escape sequence.
# Returns the array of field values with surrounding enclosure quotes removed.
function Split-CsvLine {
    param([string]$Line,[string]$Delimiter)
    $fields = New-Object System.Collections.Generic.List[string]
    $current = New-Object System.Text.StringBuilder
    $inQuotes = $false
    $i = 0
    $length = $Line.Length
    while ($i -lt $length) {
        $char = $Line[$i]
        if ($inQuotes) {
            if ($char -eq '"') {
                if ($i + 1 -lt $length -and $Line[$i + 1] -eq '"') {
                    [void]$current.Append('"')
                    $i += 2
                    continue
                }
                $inQuotes = $false
                $i++
                continue
            }
            [void]$current.Append($char)
            $i++
            continue
        }
        if ($char -eq '"') {
            $inQuotes = $true
            $i++
            continue
        }
        if ($char -eq $Delimiter) {
            [void]$fields.Add($current.ToString())
            $current = New-Object System.Text.StringBuilder
            $i++
            continue
        }
        [void]$current.Append($char)
        $i++
    }
    [void]$fields.Add($current.ToString())
    return ,$fields.ToArray()
}

function Get-SafeCsvField {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return '""' }
    return '"' + $Value.Replace('"','""') + '"'
}

# -------------------------------------------------------------------------------------
# Get-CanonicalTerm (LEVELS 2 & 3): normalizes a WHOLE value only.
# Resolution order:
#   (a) exact uppercased whole-value lookup in $TermMap -> canonical table value;
#   (b) else, UNLESS the whole value is in $SuffixDenyList, WHOLE-value suffix rules:
#       -ISATION -> -IZATION, -ISED -> -IZED (gated so ordinary English words such as
#       RAISED/REVISED/ORGANISATION are left untouched);
#   (c) else return the original value unchanged.
# Casing rule: the input is matched case-INsensitively on the WHOLE value and, when a
# rule fires, the emitted value uses the canonical casing (the American spelling from
# the table for (a); for (b) the whole value is upper-cased so the canonical suffix is
# consistent with the table style). Never a partial/substring replacement.
# Returns a PSCustomObject: Changed (bool), New (string), Reason (string).
# -------------------------------------------------------------------------------------
function Get-CanonicalTerm {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) {
        return [pscustomobject]@{ Changed=$false; New=$Value; Reason='' }
    }
    $upper = $Value.ToUpperInvariant()
    if ($TermMap.Contains($upper)) {
        $canonical = [string]$TermMap[$upper]
        if ($canonical -cne $Value) {
            return [pscustomobject]@{ Changed=$true; New=$canonical; Reason='TermMap exact match' }
        }
        return [pscustomobject]@{ Changed=$false; New=$Value; Reason='' }
    }
    # Gate the generic suffix rules: skip them for common English words in the
    # deny-list so only genuine geological morphology is normalized.
    if (-not $SuffixDenyList.Contains($upper)) {
        if ($upper.EndsWith('ISATION')) {
            $canonical = $upper.Substring(0,$upper.Length - 'ISATION'.Length) + 'IZATION'
            if ($canonical -cne $Value) {
                return [pscustomobject]@{ Changed=$true; New=$canonical; Reason='Suffix rule -ISATION->-IZATION' }
            }
        }
        if ($upper.EndsWith('ISED')) {
            $canonical = $upper.Substring(0,$upper.Length - 'ISED'.Length) + 'IZED'
            if ($canonical -cne $Value) {
                return [pscustomobject]@{ Changed=$true; New=$canonical; Reason='Suffix rule -ISED->-IZED' }
            }
        }
    }
    return [pscustomobject]@{ Changed=$false; New=$Value; Reason='' }
}

# LEVEL 1: resolve an exact leaf-name rename against $FileRenameMap (case-insensitive).
# Returns a PSCustomObject: Changed (bool), New (string), Reason (string).
function Get-CanonicalName {
    param([string]$Name)
    foreach ($key in $FileRenameMap.Keys) {
        if ($Name -ieq $key) {
            $canonical = [string]$FileRenameMap[$key]
            return [pscustomobject]@{ Changed=($canonical -cne $Name); New=$canonical; Reason='FileRenameMap exact match' }
        }
    }
    return [pscustomobject]@{ Changed=$false; New=$Name; Reason='' }
}

# LEVEL 1 (file AND folder names): canonicalize EVERY segment of a relative path.
# The user requirement covers both file and folder names, so each directory segment
# and the file leaf is independently resolved against $FileRenameMap and the target
# path is rebuilt from the canonicalized segments. Returns a PSCustomObject:
#   Changed  (bool)   - any segment was renamed
#   New      (string) - rebuilt relative path using canonical segments (same separators)
#   Renames  (array)  - per-segment rename records { Old; New; Kind } for the map,
#                       where Kind is 'folder' for a directory segment or 'file' for the leaf.
function Get-CanonicalRelativePath {
    param([string]$RelativePath)
    $segments = $RelativePath -split '[\\/]+'
    $outSegments = New-Object System.Collections.Generic.List[string]
    $renames = New-Object System.Collections.ArrayList
    $changed = $false
    for ($s = 0; $s -lt $segments.Count; $s++) {
        $segment = $segments[$s]
        $isLeaf = ($s -eq ($segments.Count - 1))
        $segResult = Get-CanonicalName -Name $segment
        if ($segResult.Changed) {
            $changed = $true
            [void]$renames.Add([pscustomobject]@{
                Old=$segment; New=$segResult.New; Kind=$(if ($isLeaf) { 'file' } else { 'folder' })
            })
            [void]$outSegments.Add($segResult.New)
        } else {
            [void]$outSegments.Add($segment)
        }
    }
    return [pscustomobject]@{
        Changed=$changed; New=($outSegments -join '\'); Renames=$renames.ToArray()
    }
}

# Reads full CSV records from a file, joining physical lines that span multiple lines
# because of an unterminated (odd-count) quoted field. No naive single-line read.
function Read-CsvRecords {
    param([string]$Path)
    $records = New-Object System.Collections.Generic.List[string]
    $pending = $null
    $reader = [System.IO.File]::OpenText($Path)
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($null -eq $pending) { $pending = $line } else { $pending = $pending + "`n" + $line }
            $quoteCount = ([regex]::Matches($pending,'"')).Count
            if (($quoteCount % 2) -eq 0) {
                [void]$records.Add($pending)
                $pending = $null
            }
        }
    }
    finally {
        $reader.Dispose()
    }
    if ($null -ne $pending) { [void]$records.Add($pending) }
    return ,$records.ToArray()
}

function Install-CurrentScript {
    if (-not (Test-Path -LiteralPath $SourceScriptPath -PathType Leaf)) { throw 'Current script path could not be resolved.' }
    if (-not (Test-ScriptSyntax $SourceScriptPath)) { throw 'Current script failed parser validation.' }
    New-Item -ItemType Directory -Path $InstalledFolder -Force | Out-Null
    Copy-Item -LiteralPath $SourceScriptPath -Destination $InstalledPath -Force
    if (-not (Test-ScriptSyntax $InstalledPath)) { throw 'Installed script failed parser validation.' }
}

try {
    if (-not (Test-Path -LiteralPath $InputPath)) { throw ('Input path not found: {0}' -f $InputPath) }

    $inputIsFolder = Test-Path -LiteralPath $InputPath -PathType Container
    if ($inputIsFolder) {
        $csvFiles = @(Get-ChildItem -LiteralPath $InputPath -Recurse -File | Where-Object { $_.Extension -ieq '.csv' } | Sort-Object FullName)
    } else {
        $csvFiles = @(Get-Item -LiteralPath $InputPath)
    }
    if ($csvFiles.Count -eq 0) { throw 'No CSV files found at the input path.' }

    Write-Host ''
    Write-Host ('{0} | CP09A SCHEMA NAME NORMALIZER v{1}' -f $Classification,$Version) -ForegroundColor Cyan
    Write-Host ('RUN_ID: {0}' -f $RunId)
    Write-Host ('INPUT: {0}' -f $InputPath)
    Write-Host ('CSV FILES: {0}' -f $csvFiles.Count)
    Write-Host ('MODE: {0}' -f $(if ($ExecuteMode) { 'EXECUTE (-Apply)' } else { 'AUDIT_ONLY (default)' }))

    # -------------------------------------------------------------------------------
    # SCAN LOGIC (runs in BOTH audit and execute modes). Accumulates planned changes.
    # -------------------------------------------------------------------------------
    $changes = New-Object System.Collections.ArrayList
    $level1Count = 0
    $level2Count = 0
    $level3Count = 0

    $baseFolder = if ($inputIsFolder) { (Get-Item -LiteralPath $InputPath).FullName } else { (Get-Item -LiteralPath $InputPath).DirectoryName }

    # Collision detection operates on FULL target RELATIVE paths (not bare leaf names)
    # so the audit decision matches apply-time reality:
    #   - two renamed targets resolving to the same relative path collide;
    #   - a rename target landing on an EXISTING source file that is NOT itself being
    #     renamed away also collides (the per-file no-overwrite guard is the fail-closed
    #     backstop at apply time; here we surface it as REVIEW_REQUIRED in audit).
    $sourceRelatives = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    $renamedAwaySources = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    $plannedTargetPaths = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    $renameCollision = $false

    # Pre-index every source relative path so we can detect targets that would land on
    # a pre-existing, unmapped source file.
    foreach ($file in $csvFiles) {
        $rel = if ($inputIsFolder) { $file.FullName.Substring($baseFolder.Length).TrimStart('\','/') } else { $file.Name }
        [void]$sourceRelatives.Add(($rel -replace '/','\'))
    }

    foreach ($file in $csvFiles) {
        $relative = if ($inputIsFolder) { $file.FullName.Substring($baseFolder.Length).TrimStart('\','/') } else { $file.Name }
        $relativeNorm = $relative -replace '/','\'

        # LEVEL 1 - exact file AND folder renames across EVERY path segment.
        $pathResult = Get-CanonicalRelativePath -RelativePath $relativeNorm
        if ($pathResult.Changed) {
            [void]$renamedAwaySources.Add($relativeNorm)
            foreach ($rename in $pathResult.Renames) {
                $level1Count++
                [void]$changes.Add([pscustomobject]@{
                    Old=$rename.Old; New=$rename.New; Level=1; Reason=('FileRenameMap exact match (' + $rename.Kind + ')'); File=$relativeNorm; Column=''
                })
            }
            # Collision: another rename already targets this relative path.
            if ($plannedTargetPaths.Contains($pathResult.New)) { $renameCollision = $true }
            [void]$plannedTargetPaths.Add($pathResult.New)
        }

        # Read full records (quote-aware, multi-line safe) for LEVELS 2 & 3.
        $records = @(Read-CsvRecords -Path $file.FullName)
        if ($records.Count -eq 0) { continue }

        # LEVEL 2 - header column names (first non-empty handled as header row).
        $headerFields = Split-CsvLine $records[0] ','
        foreach ($col in $headerFields) {
            $colResult = Get-CanonicalTerm -Value $col
            if ($colResult.Changed) {
                $level2Count++
                [void]$changes.Add([pscustomobject]@{
                    Old=$col; New=$colResult.New; Level=2; Reason=$colResult.Reason; File=$relative; Column=$col
                })
            }
        }

        # LEVEL 3 - data cell values (every row after the header).
        for ($r = 1; $r -lt $records.Count; $r++) {
            $cells = Split-CsvLine $records[$r] ','
            for ($c = 0; $c -lt $cells.Count; $c++) {
                $cellResult = Get-CanonicalTerm -Value $cells[$c]
                if ($cellResult.Changed) {
                    $level3Count++
                    $colName = if ($c -lt $headerFields.Count) { $headerFields[$c] } else { ('COL' + $c) }
                    [void]$changes.Add([pscustomobject]@{
                        Old=$cells[$c]; New=$cellResult.New; Level=3; Reason=$cellResult.Reason; File=$relative; Column=$colName
                    })
                }
            }
        }
    }

    # Second collision class: a rename target that lands on an existing source file
    # which is NOT itself being renamed away (so the source would still occupy that
    # relative path). This matches the per-file no-overwrite throw at apply time.
    foreach ($targetRel in $plannedTargetPaths) {
        if ($sourceRelatives.Contains($targetRel) -and -not $renamedAwaySources.Contains($targetRel)) {
            $renameCollision = $true
        }
    }

    $totalChanges = $changes.Count
    $decision = if ($renameCollision) { 'REVIEW_REQUIRED' } else { 'PASS' }

    Write-Host ''
    Write-Host 'PLANNED CHANGES BY LEVEL' -ForegroundColor Cyan
    Write-Host ('  LEVEL 1 (file/folder names): {0}' -f $level1Count)
    Write-Host ('  LEVEL 2 (column names)     : {0}' -f $level2Count)
    Write-Host ('  LEVEL 3 (cell values)      : {0}' -f $level3Count)
    Write-Host ('  TOTAL                      : {0}' -f $totalChanges)
    Write-Host ('  DECISION                   : {0}' -f $decision)
    if ($totalChanges -gt 0) {
        @($changes | Select-Object Level,File,Column,Old,New,Reason) | Format-Table Level,File,Column,Old,New -AutoSize
    }

    # -------------------------------------------------------------------------------
    # AUDIT MODE (default): write NOTHING and exit.
    # -------------------------------------------------------------------------------
    if (-not $ExecuteMode) {
        Write-Host 'AUDITONLY PASS: NO FILES OR FOLDERS CREATED.' -ForegroundColor Green
        exit 0
    }

    # -------------------------------------------------------------------------------
    # EXECUTE MODE (-Apply): staging -> promote with no-overwrite guards.
    # -------------------------------------------------------------------------------
    if (Test-Path -LiteralPath $FinalRoot) { throw ('Final output already exists: {0}' -f $FinalRoot) }
    if (Test-Path -LiteralPath $StagingRoot) { throw ('Staging output already exists: {0}' -f $StagingRoot) }
    New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $RecordRoot -Force | Out-Null
    Write-RunLog ('CP09A Schema Name Normalizer | Version {0} | Classification {1}' -f $Version,$Classification)
    Write-RunLog ('RUN_ID: {0}' -f $RunId)

    Install-CurrentScript
    Write-RunLog ('Installed script: {0}' -f $InstalledPath) 'PASS'

    # Rewrite each CSV into staging under its (possibly renamed) leaf name, applying
    # LEVEL 2 header and LEVEL 3 cell normalizations. Source files are never deleted;
    # this tool only writes governed copies plus evidence.
    $writtenCount = 0
    foreach ($file in $csvFiles) {
        $relative = if ($inputIsFolder) { $file.FullName.Substring($baseFolder.Length).TrimStart('\','/') } else { $file.Name }
        $relativeNorm = $relative -replace '/','\'
        # LEVEL 1 applies to EVERY path segment (file AND folder names).
        $pathResult = Get-CanonicalRelativePath -RelativePath $relativeNorm
        $targetRelative = if ($pathResult.Changed) { $pathResult.New } else { $relativeNorm }
        $targetPath = Join-Path $DataRoot $targetRelative

        $parent = Split-Path -Path $targetPath -Parent
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        if (Test-Path -LiteralPath $targetPath) { throw ('No-overwrite safety block: {0}' -f $targetPath) }

        $records = @(Read-CsvRecords -Path $file.FullName)
        $utf8 = New-Object System.Text.UTF8Encoding($true)
        $writer = New-Object System.IO.StreamWriter($targetPath,$false,$utf8)
        try {
            for ($r = 0; $r -lt $records.Count; $r++) {
                $fields = Split-CsvLine $records[$r] ','
                $outFields = foreach ($f in $fields) { (Get-CanonicalTerm -Value $f).New }
                $writer.WriteLine((($outFields | ForEach-Object { Get-SafeCsvField $_ }) -join ','))
            }
        }
        finally {
            $writer.Dispose()
        }
        $writtenCount++
    }

    # -------------------------------------------------------------------------------
    # EVIDENCE
    # -------------------------------------------------------------------------------
    $mapPath = Join-Path $RecordRoot 'Normalization_Map.csv'
    if ($changes.Count -gt 0) {
        @($changes | Select-Object Old,New,Level,Reason,File,Column) | Export-Csv -LiteralPath $mapPath -NoTypeInformation -Encoding utf8
    } else {
        # Emit a header-only map so the evidence file always exists.
        'Old,New,Level,Reason,File,Column' | Set-Content -LiteralPath $mapPath -Encoding utf8
    }

    $summary = [ordered]@{
        Title='Internal | CP09A Schema Name Normalization';Classification=$Classification;Version=$Version;RunId=$RunId
        InputPath=$InputPath;OutputRoot=$FinalRoot;CSVFileCount=$csvFiles.Count;NormalizedFileCount=$writtenCount
        Level1Renames=$level1Count;Level2ColumnChanges=$level2Count;Level3CellChanges=$level3Count
        TotalChanges=$totalChanges;Decision=$decision
    }
    $summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $RecordRoot 'Summary.json') -Encoding UTF8
    $summary.GetEnumerator() | ForEach-Object { '{0}: {1}' -f $_.Key,$_.Value } | Set-Content -LiteralPath (Join-Path $RecordRoot 'Summary.txt') -Encoding UTF8

    # Integrity manifest. This is an integrity-focused tool, so SHA256SUMS.txt covers
    # BOTH the evidence record files AND the normalized CSV\ data outputs. Record-file
    # names are listed bare; data outputs are listed with a 'CSV/<relative>' prefix so
    # the two sets never clash and the hash of every produced artifact is captured.
    $manifestLines = New-Object System.Collections.Generic.List[string]
    $recordFiles = @(Get-ChildItem -LiteralPath $RecordRoot -File | Where-Object Name -ne 'SHA256SUMS.txt' | Sort-Object Name)
    foreach ($file in $recordFiles) {
        $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
        [void]$manifestLines.Add(('{0} *{1}' -f $hash.Hash,$file.Name))
    }
    $dataFiles = @(Get-ChildItem -LiteralPath $DataRoot -Recurse -File | Sort-Object FullName)
    foreach ($file in $dataFiles) {
        $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
        $dataRel = $file.FullName.Substring($DataRoot.Length).TrimStart('\','/') -replace '\\','/'
        [void]$manifestLines.Add(('{0} *CSV/{1}' -f $hash.Hash,$dataRel))
    }
    $manifestLines | Set-Content -LiteralPath (Join-Path $RecordRoot 'SHA256SUMS.txt') -Encoding ASCII

    # -------------------------------------------------------------------------------
    # PROMOTE
    # -------------------------------------------------------------------------------
    Move-Item -LiteralPath $StagingRoot -Destination $FinalRoot
    if (-not (Test-Path -LiteralPath $FinalRoot -PathType Container)) { throw 'Final promotion failed.' }

    Write-Host ''
    Write-Host ('SCHEMA NAME NORMALIZATION: {0}' -f $decision) -ForegroundColor Green
    Write-Host ('FILES: {0}/{1}' -f $writtenCount,$csvFiles.Count) -ForegroundColor Green
    Write-Host ('CHANGES: {0} (L1={1} L2={2} L3={3})' -f $totalChanges,$level1Count,$level2Count,$level3Count) -ForegroundColor Green
    Write-Host ('OUTPUT: {0}' -f $FinalRoot) -ForegroundColor Cyan
    Write-Host ''
    exit 0
}
catch {
    try {
        if (-not (Test-Path -LiteralPath $RecordRoot -PathType Container)) { New-Item -ItemType Directory -Path $RecordRoot -Force | Out-Null }
        Write-RunLog $_.Exception.Message 'ERROR'
        @('MESSAGE: '+$_.Exception.Message,'SCRIPT: '+$_.InvocationInfo.ScriptName,'LINE: '+$_.InvocationInfo.ScriptLineNumber,'POSITION: '+$_.InvocationInfo.PositionMessage,'',($_ | Out-String)) | Set-Content -LiteralPath (Join-Path $RecordRoot 'Fatal_Error.txt') -Encoding UTF8
    } catch { Write-Host ('FATAL: '+$_.Exception.Message) -ForegroundColor Red }
    exit 1
}
