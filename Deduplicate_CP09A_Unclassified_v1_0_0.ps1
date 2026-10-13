#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$RepositoryRoot = 'C:\Python\GeoAi',
    [string]$QuarantineRoot = 'C:\Python\GeoAi\00_Base_Datos\GeoAi\16_Unclassified_Dedup_Quarantine',
    [string]$ApplicationRoot = 'C:\Python\GeoAi\01_Aplicacion\CP09A_Release_v2.1',
    # Family convention switch. When supplied, forces audit-only behavior.
    [switch]$AuditOnly,
    # Explicit execute switch. The WRITE path is gated behind this switch so that
    # audit-only is the DEFAULT: with NO switches, or with -AuditOnly, the tool
    # scans and reports but writes nothing. Only -Apply performs the quarantine
    # move via staging->promote.
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'Continue'

$Version = '1.0.0'
# NEUTRAL classification. This tool deliberately carries no client/organisation
# name anywhere in its titles or output.
$Classification = 'Internal'
$RunId = 'CP09A-DEDUP-UNCLASSIFIED-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$StagingRoot = Join-Path $QuarantineRoot ('.staging-' + $RunId)
$FinalRoot = Join-Path $QuarantineRoot $RunId
$QuarantineDataRoot = Join-Path $StagingRoot 'Quarantine'
$RecordRoot = Join-Path $StagingRoot '_Dedup_Record'
$LogPath = Join-Path $RecordRoot 'Execution.log'
$InstalledFolder = Join-Path $ApplicationRoot '00_Script\Unclassified_Dedup'
$InstalledPath = Join-Path $InstalledFolder 'Deduplicate_CP09A_Unclassified_v1_0_0.ps1'
$SourceScriptPath = $MyInvocation.MyCommand.Path

# Audit-only is the DEFAULT. The write path requires an explicit -Apply.
# Supplying -AuditOnly (or supplying nothing) keeps the tool in read-only mode.
$ExecuteMode = ($Apply.IsPresent -and -not $AuditOnly.IsPresent)

# =====================================================================================
# SCAN EXCLUSIONS (modelled on GeoAI_CP09A_Repository_Inventory). Directories and files
# that must never be scanned for duplicate content. The QuarantineRoot itself is also
# excluded at scan time (see the main body) so prior quarantine runs are never
# re-scanned and re-flagged as duplicates.
# =====================================================================================
$ExcludedDirectoryNames = @(
    '.git','.svn','.hg','.venv','venv','env','__pycache__','node_modules',
    'tmp','temp','.tmp','.temp','cache','.cache',
    '$RECYCLE.BIN','System Volume Information'
)
$ExcludedFilePatterns = @(
    '~$*','*.tmp','*.temp','*.bak','*.swp','*.swo','*.part','*.lock','*.pyc','*.pyo'
)

# The exact folder name that defines the dedup scope. A duplicate group is only
# processed when at least one copy's relative path has a segment EXACTLY equal to
# this value (case-insensitive). ASCII only, no client name anywhere.
$UnclassifiedSegment = '99_UNCLASSIFIED'

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

function Get-NormalizedPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

# Returns $true when the normalized Path is strictly under the normalized Root
# (case-insensitive). Used as the quarantine-root safeguard before every move,
# exactly like CP09A_AutoLith_Duplicate_Audit_Cleanup.
function Test-IsUnderRoot {
    param([string]$Path,[string]$Root)
    $normalizedPath = Get-NormalizedPath $Path
    $normalizedRoot = Get-NormalizedPath $Root
    return $normalizedPath.StartsWith($normalizedRoot + '\',[System.StringComparison]::OrdinalIgnoreCase)
}

function Test-ExcludedFile {
    param([System.IO.FileInfo]$File)
    foreach ($pattern in $ExcludedFilePatterns) {
        if ($File.Name -like $pattern) { return $true }
    }
    return $false
}

# A relative path is "in unclassified" when ANY of its path segments is EXACTLY
# equal to the 99_UNCLASSIFIED folder name (case-insensitive). Split on both path
# separators so the test is independent of the separator in the stored path.
function Test-InUnclassified {
    param([string]$RelativePath)
    foreach ($segment in @($RelativePath -split '[\\/]+')) {
        if ($segment -ieq $UnclassifiedSegment) { return $true }
    }
    return $false
}

function Install-CurrentScript {
    if (-not (Test-Path -LiteralPath $SourceScriptPath -PathType Leaf)) { throw 'Current script path could not be resolved.' }
    if (-not (Test-ScriptSyntax $SourceScriptPath)) { throw 'Current script failed parser validation.' }
    New-Item -ItemType Directory -Path $InstalledFolder -Force | Out-Null
    Copy-Item -LiteralPath $SourceScriptPath -Destination $InstalledPath -Force
    if (-not (Test-ScriptSyntax $InstalledPath)) { throw 'Installed script failed parser validation.' }
}

# -------------------------------------------------------------------------------------
# Select-CanonicalCopy: choose the single copy to KEEP within a duplicate group, in the
# EXACT priority order required:
#   (1) PREFER a copy OUTSIDE any 99_UNCLASSIFIED folder (the good location). If exactly
#       one copy is outside, it is canonical. If several are outside, restrict the
#       candidate set to those outside and continue to the tie-breakers. If NONE are
#       outside, the candidate set is all copies (all in-unclassified).
#   (2) Tie-break by MOST RECENT LastWriteTime (newest wins).
#   (3) Final tie-break by SHORTEST path length.
# If, after all three steps, two or more candidates remain genuinely indistinguishable
# (same out/in status, identical LastWriteTime, identical path length), Ambiguous=$true,
# which drives a REVIEW_REQUIRED decision for that group.
# Returns a PSCustomObject { Canonical=<record>; Reason=<string>; Ambiguous=<bool> }.
# -------------------------------------------------------------------------------------
function Select-CanonicalCopy {
    param([object[]]$Records)

    $outside = @($Records | Where-Object { -not $_.InUnclassified })
    if ($outside.Count -eq 1) {
        return [pscustomobject]@{ Canonical=$outside[0]; Reason='Only copy outside 99_UNCLASSIFIED'; Ambiguous=$false }
    }

    if ($outside.Count -gt 1) {
        $candidates = $outside
        $reasonBase = 'Preferred copy outside 99_UNCLASSIFIED'
    } else {
        $candidates = @($Records)
        $reasonBase = 'All copies in 99_UNCLASSIFIED'
    }

    # Tie-break 1: most recent LastWriteTime.
    $newest = ($candidates | Measure-Object -Property LastWriteTime -Maximum).Maximum
    $byTime = @($candidates | Where-Object { $_.LastWriteTime -eq $newest })
    if ($byTime.Count -eq 1) {
        return [pscustomobject]@{ Canonical=$byTime[0]; Reason=($reasonBase + '; newest LastWriteTime'); Ambiguous=$false }
    }

    # Tie-break 2: shortest path length.
    $minLength = ($byTime | Measure-Object -Property { $_.FullPath.Length } -Minimum).Minimum
    $byLength = @($byTime | Where-Object { $_.FullPath.Length -eq $minLength })
    if ($byLength.Count -eq 1) {
        return [pscustomobject]@{ Canonical=$byLength[0]; Reason=($reasonBase + '; newest LastWriteTime; shortest path'); Ambiguous=$false }
    }

    # Still indistinguishable: pick a deterministic first copy but flag Ambiguous so the
    # group decision becomes REVIEW_REQUIRED.
    $deterministic = @($byLength | Sort-Object FullPath)[0]
    return [pscustomobject]@{ Canonical=$deterministic; Reason=($reasonBase + '; AMBIGUOUS - indistinguishable copies'); Ambiguous=$true }
}

try {
    if (-not (Test-Path -LiteralPath $RepositoryRoot -PathType Container)) { throw ('Repository root not found: {0}' -f $RepositoryRoot) }

    $repositoryRootFull = Get-NormalizedPath $RepositoryRoot

    Write-Host ''
    Write-Host ('{0} | CP09A UNCLASSIFIED DUPLICATE DEDUP v{1}' -f $Classification,$Version) -ForegroundColor Cyan
    Write-Host ('RUN_ID: {0}' -f $RunId)
    Write-Host ('REPOSITORY ROOT: {0}' -f $RepositoryRoot)
    Write-Host ('QUARANTINE ROOT: {0}' -f $QuarantineRoot)
    Write-Host ('MODE: {0}' -f $(if ($ExecuteMode) { 'EXECUTE (-Apply)' } else { 'AUDIT_ONLY (default)' }))

    # -------------------------------------------------------------------------------
    # RECURSIVE SCAN + HASHING (runs in BOTH audit and execute modes).
    # Skips excluded directory names (any segment), excluded file patterns, and
    # anything under the QuarantineRoot so previous quarantine runs are not re-scanned.
    # -------------------------------------------------------------------------------
    # Normalize the quarantine root up front so the scan can exclude it (whether or
    # not it exists yet) and prior quarantine runs are never re-scanned.
    $quarantineRootFull = Get-NormalizedPath $QuarantineRoot

    $fileRecords = New-Object System.Collections.ArrayList
    $allFiles = @(Get-ChildItem -LiteralPath $RepositoryRoot -Recurse -File -Force -ErrorAction SilentlyContinue)
    foreach ($file in $allFiles) {
        $fullNorm = Get-NormalizedPath $file.FullName
        # Exclude anything inside the quarantine root (or the root itself).
        if ($fullNorm.Equals($quarantineRootFull,[System.StringComparison]::OrdinalIgnoreCase) -or
            $fullNorm.StartsWith($quarantineRootFull + '\',[System.StringComparison]::OrdinalIgnoreCase)) { continue }
        # Compute the relative path against the repository root.
        $relative = $fullNorm.Substring($repositoryRootFull.Length).TrimStart('\','/')
        # Exclude by directory segment name.
        $excludedByDir = $false
        foreach ($segment in @(($relative -split '[\\/]+'))) {
            if ($ExcludedDirectoryNames -contains $segment) { $excludedByDir = $true; break }
        }
        if ($excludedByDir) { continue }
        # Exclude by file pattern.
        if (Test-ExcludedFile -File $file) { continue }

        $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
        [void]$fileRecords.Add([pscustomobject]@{
            FullPath=$file.FullName
            RelativePath=$relative
            SizeBytes=[int64]$file.Length
            LastWriteTime=$file.LastWriteTime
            SHA256=$hash.Hash
            InUnclassified=(Test-InUnclassified -RelativePath $relative)
        })
    }

    $filesScanned = $fileRecords.Count
    Write-Host ('FILES SCANNED: {0}' -f $filesScanned)

    # -------------------------------------------------------------------------------
    # GROUP BY SHA256 -> keep duplicate groups (Count>1) -> keep only groups with at
    # least one 99_UNCLASSIFIED copy. Groups with no unclassified copy are IGNORED.
    # -------------------------------------------------------------------------------
    $duplicateGroups = @($fileRecords | Where-Object { -not [string]::IsNullOrWhiteSpace($_.SHA256) } | Group-Object SHA256 | Where-Object { $_.Count -gt 1 })

    $duplicateGroupRows = New-Object System.Collections.ArrayList
    $duplicateFileRows = New-Object System.Collections.ArrayList
    $quarantinePlan = New-Object System.Collections.ArrayList
    $groupId = 0
    $recoverableTotal = [int64]0
    $anyAmbiguous = $false
    $unclassifiedGroupCount = 0

    foreach ($group in $duplicateGroups) {
        $items = @($group.Group)
        $hasUnclassified = @($items | Where-Object { $_.InUnclassified }).Count -gt 0
        if (-not $hasUnclassified) { continue }
        $unclassifiedGroupCount++
        $groupId++

        $size = [int64]$items[0].SizeBytes
        $recoverable = [int64]($size * ($items.Count - 1))
        $recoverableTotal += $recoverable

        $selection = Select-CanonicalCopy -Records $items
        if ($selection.Ambiguous) { $anyAmbiguous = $true }
        $groupDecision = if ($selection.Ambiguous) { 'REVIEW_REQUIRED' } else { 'PASS' }

        [void]$duplicateGroupRows.Add([pscustomobject]@{
            GroupId=$groupId
            SHA256=$group.Name
            Copies=$items.Count
            SizeEachBytes=$size
            RecoverableBytes=$recoverable
            RecoverableMB=[math]::Round($recoverable/1MB,3)
            CanonicalPath=$selection.Canonical.FullPath
            CanonicalReason=$selection.Reason
            Decision=$groupDecision
        })

        foreach ($item in $items) {
            $isCanonical = $item.FullPath.Equals($selection.Canonical.FullPath,[System.StringComparison]::OrdinalIgnoreCase)
            $role = if ($isCanonical) { 'CANONICAL' } else { 'DUPLICATE' }
            [void]$duplicateFileRows.Add([pscustomobject]@{
                GroupId=$groupId
                SHA256=$group.Name
                Role=$role
                InUnclassified=$(if ($item.InUnclassified) { 'true' } else { 'false' })
                SizeBytes=[int64]$item.SizeBytes
                LastWriteTime=$item.LastWriteTime
                FullPath=$item.FullPath
                RelativePath=$item.RelativePath
            })
            if (-not $isCanonical) {
                [void]$quarantinePlan.Add([pscustomobject]@{
                    GroupId=$groupId
                    SHA256=$group.Name
                    Role=$role
                    SourceFullPath=$item.FullPath
                    RelativePath=$item.RelativePath
                    SourceSHA256=$item.SHA256
                })
            }
        }
    }

    $decision = if ($anyAmbiguous) { 'REVIEW_REQUIRED' } else { 'PASS' }

    Write-Host ''
    Write-Host 'UNCLASSIFIED DUPLICATE REPORT' -ForegroundColor Cyan
    Write-Host ('  DUPLICATE GROUPS (all)              : {0}' -f $duplicateGroups.Count)
    Write-Host ('  UNCLASSIFIED DUPLICATE GROUPS       : {0}' -f $unclassifiedGroupCount)
    Write-Host ('  NON-CANONICAL DUPLICATES            : {0}' -f $quarantinePlan.Count)
    Write-Host ('  TOTAL RECOVERABLE BYTES             : {0}' -f $recoverableTotal)
    Write-Host ('  TOTAL RECOVERABLE MB                : {0}' -f [math]::Round($recoverableTotal/1MB,3))
    Write-Host ('  DECISION                            : {0}' -f $decision)

    if ($duplicateGroupRows.Count -gt 0) {
        Write-Host ''
        Write-Host 'DUPLICATE_GROUPS' -ForegroundColor Cyan
        @($duplicateGroupRows | Sort-Object RecoverableBytes -Descending) | Format-Table GroupId,SHA256,Copies,SizeEachBytes,RecoverableBytes,CanonicalReason,Decision -AutoSize
        Write-Host 'DUPLICATE_FILES' -ForegroundColor Cyan
        @($duplicateFileRows | Sort-Object GroupId,FullPath) | Format-Table GroupId,Role,InUnclassified,SizeBytes,LastWriteTime,RelativePath -AutoSize
    }

    # -------------------------------------------------------------------------------
    # AUDIT MODE (default): write NOTHING and exit before creating any directory.
    # -------------------------------------------------------------------------------
    if (-not $ExecuteMode) {
        Write-Host ('TOTAL RECOVERABLE BYTES: {0}' -f $recoverableTotal) -ForegroundColor Green
        Write-Host 'AUDITONLY PASS: NO FILES OR FOLDERS CREATED.' -ForegroundColor Green
        exit 0
    }

    # -------------------------------------------------------------------------------
    # EXECUTE MODE (-Apply): staging -> promote with no-overwrite + quarantine-root
    # safeguards. Non-canonical duplicates are MOVED (never deleted); the canonical
    # copy is never moved.
    # -------------------------------------------------------------------------------
    if (Test-Path -LiteralPath $FinalRoot) { throw ('Final output already exists: {0}' -f $FinalRoot) }
    if (Test-Path -LiteralPath $StagingRoot) { throw ('Staging output already exists: {0}' -f $StagingRoot) }
    New-Item -ItemType Directory -Path $QuarantineDataRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $RecordRoot -Force | Out-Null
    Write-RunLog ('CP09A Unclassified Duplicate Dedup | Version {0} | Classification {1}' -f $Version,$Classification)
    Write-RunLog ('RUN_ID: {0}' -f $RunId)

    Install-CurrentScript
    Write-RunLog ('Installed script: {0}' -f $InstalledPath) 'PASS'

    $quarantineDataRootFull = Get-NormalizedPath $QuarantineDataRoot
    $moveMapRows = New-Object System.Collections.ArrayList
    $movedCount = 0

    foreach ($plan in $quarantinePlan) {
        # Never move the canonical: by construction only DUPLICATE rows are in the plan,
        # but assert the invariant explicitly as a defensive safeguard.
        if ($plan.Role -ne 'DUPLICATE') { throw ('Safety block: refusing to move a non-duplicate record: {0}' -f $plan.SourceFullPath) }

        $targetPath = Join-Path $QuarantineDataRoot $plan.RelativePath
        $parent = Split-Path -Path $targetPath -Parent
        New-Item -ItemType Directory -Path $parent -Force | Out-Null

        # No-overwrite guard.
        if (Test-Path -LiteralPath $targetPath) { throw ('No-overwrite safety block: {0}' -f $targetPath) }
        # Quarantine-root safeguard: the resolved parent must be strictly under the
        # quarantine data root before any move takes place.
        $parentFull = Get-NormalizedPath $parent
        $underRoot = $parentFull.Equals($quarantineDataRootFull,[System.StringComparison]::OrdinalIgnoreCase) -or (Test-IsUnderRoot $parent $QuarantineDataRoot)
        if (-not $underRoot) { throw ('Safety block: quarantine target outside quarantine root: {0}' -f $targetPath) }

        Move-Item -LiteralPath $plan.SourceFullPath -Destination $targetPath
        if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) { throw ('Move verification failed: {0}' -f $targetPath) }

        $quarantineHash = Get-FileHash -LiteralPath $targetPath -Algorithm SHA256
        [void]$moveMapRows.Add([pscustomobject]@{
            GroupId=$plan.GroupId
            SHA256=$plan.SHA256
            Role=$plan.Role
            SourceFullPath=$plan.SourceFullPath
            QuarantinePath=$targetPath
            SourceSHA256=$plan.SourceSHA256
            QuarantineSHA256=$quarantineHash.Hash
            Status='MOVED_VERIFIED'
        })
        $movedCount++
        Write-RunLog ('Quarantined: {0} -> {1}' -f $plan.SourceFullPath,$targetPath) 'PASS'
    }

    # -------------------------------------------------------------------------------
    # EVIDENCE
    # -------------------------------------------------------------------------------
    $groupsCsv = Join-Path $RecordRoot 'Duplicate_Groups.csv'
    $filesCsv = Join-Path $RecordRoot 'Duplicate_Files.csv'
    $moveMapCsv = Join-Path $RecordRoot 'Quarantine_Move_Map.csv'

    if ($duplicateGroupRows.Count -gt 0) {
        @($duplicateGroupRows | Sort-Object RecoverableBytes -Descending) | Export-Csv -LiteralPath $groupsCsv -NoTypeInformation -Encoding utf8
    } else {
        'GroupId,SHA256,Copies,SizeEachBytes,RecoverableBytes,RecoverableMB,CanonicalPath,CanonicalReason,Decision' | Set-Content -LiteralPath $groupsCsv -Encoding utf8
    }
    if ($duplicateFileRows.Count -gt 0) {
        @($duplicateFileRows | Sort-Object GroupId,FullPath) | Export-Csv -LiteralPath $filesCsv -NoTypeInformation -Encoding utf8
    } else {
        'GroupId,SHA256,Role,InUnclassified,SizeBytes,LastWriteTime,FullPath,RelativePath' | Set-Content -LiteralPath $filesCsv -Encoding utf8
    }
    if ($moveMapRows.Count -gt 0) {
        @($moveMapRows | Sort-Object GroupId,SourceFullPath) | Export-Csv -LiteralPath $moveMapCsv -NoTypeInformation -Encoding utf8
    } else {
        'GroupId,SHA256,Role,SourceFullPath,QuarantinePath,SourceSHA256,QuarantineSHA256,Status' | Set-Content -LiteralPath $moveMapCsv -Encoding utf8
    }

    $summary = [ordered]@{
        Title='Internal | CP09A Unclassified Duplicate Dedup'
        Classification=$Classification
        Version=$Version
        RunId=$RunId
        Mode='EXECUTE'
        RepositoryRoot=$RepositoryRoot
        QuarantineRoot=$FinalRoot
        FilesScanned=$filesScanned
        DuplicateGroupsConsidered=$duplicateGroups.Count
        UnclassifiedDuplicateGroups=$unclassifiedGroupCount
        DuplicateFilesMoved=$movedCount
        RecoverableBytes=$recoverableTotal
        Decision=$decision
    }
    $summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $RecordRoot 'Summary.json') -Encoding UTF8
    $summary.GetEnumerator() | ForEach-Object { '{0}: {1}' -f $_.Key,$_.Value } | Set-Content -LiteralPath (Join-Path $RecordRoot 'Summary.txt') -Encoding UTF8

    # Integrity manifest covering BOTH the evidence record files AND the quarantined
    # data. Record files are listed bare; quarantined data is listed with a
    # 'Quarantine/<relative>' prefix so the two sets never clash.
    $manifestLines = New-Object System.Collections.Generic.List[string]
    $recordFiles = @(Get-ChildItem -LiteralPath $RecordRoot -File | Where-Object Name -ne 'SHA256SUMS.txt' | Sort-Object Name)
    foreach ($file in $recordFiles) {
        $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
        [void]$manifestLines.Add(('{0} *{1}' -f $hash.Hash,$file.Name))
    }
    $quarantinedFiles = @(Get-ChildItem -LiteralPath $QuarantineDataRoot -Recurse -File | Sort-Object FullName)
    foreach ($file in $quarantinedFiles) {
        $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
        $dataRel = $file.FullName.Substring($quarantineDataRootFull.Length).TrimStart('\','/') -replace '\\','/'
        [void]$manifestLines.Add(('{0} *Quarantine/{1}' -f $hash.Hash,$dataRel))
    }
    $manifestLines | Set-Content -LiteralPath (Join-Path $RecordRoot 'SHA256SUMS.txt') -Encoding ASCII

    # -------------------------------------------------------------------------------
    # PROMOTE
    # -------------------------------------------------------------------------------
    Move-Item -LiteralPath $StagingRoot -Destination $FinalRoot
    if (-not (Test-Path -LiteralPath $FinalRoot -PathType Container)) { throw 'Final promotion failed.' }

    Write-Host ''
    Write-Host ('UNCLASSIFIED DUPLICATE DEDUP: {0}' -f $decision) -ForegroundColor Green
    Write-Host ('FILES MOVED: {0}' -f $movedCount) -ForegroundColor Green
    Write-Host ('RECOVERABLE BYTES: {0}' -f $recoverableTotal) -ForegroundColor Green
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
