#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$ZipPath = 'C:\Python\GeoAi\00_Base_Datos\GeoAi\03_Original_Data_Exports\00_Export\Exports_2026-09-28.zip',
    [string]$ConsolidationRoot = 'C:\Python\GeoAi\00_Base_Datos\GeoAi\00_Consolidacion_BD_GeoAI',
    [string]$ApplicationRoot = 'C:\Python\GeoAi\01_Aplicacion\CP09A_Release_v2.1',
    # ExpectedZipSHA256 resolution order (highest priority first):
    #   1) explicit -ExpectedZipSHA256 bound on the command line (overrides everything, even when
    #      the passed value equals the shipped default; keyed off $PSBoundParameters.ContainsKey),
    #   2) sidecar hash file resolved from -ExpectedZipSHA256Path (or '<ZipPath>.sha256' when that param is empty),
    #   3) the literal default below (last-resort backward-compatible fallback).
    # A new ZIP + matching '<ZipPath>.sha256' sidecar therefore passes preflight without editing this script body.
    [string]$ExpectedZipSHA256 = '5EB627FAB47257294C89289757C36E62276D76E20CB3818E7DE57EB0D8B5FF08',
    [string]$ExpectedZipSHA256Path = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'Continue'

$Version = '1.0.1'
$RunId = 'CP09A-GEOAI-CONSOLIDATION-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
# Shipped literal default used as the last-resort fallback in the hash resolution order.
$DefaultExpectedZipSHA256 = '5EB627FAB47257294C89289757C36E62276D76E20CB3818E7DE57EB0D8B5FF08'
$FinalRunFolder = Join-Path $ConsolidationRoot $RunId
$StagingFolder = Join-Path $ConsolidationRoot ('.staging-' + $RunId)
$InstalledFolder = Join-Path $ApplicationRoot '00_Script\GeoAI_Consolidation'
$InstalledPath = Join-Path $InstalledFolder 'Run_CP09A_GeoAI_Consolidation_v1_0_1.ps1'
$SourceScriptPath = $MyInvocation.MyCommand.Path
$LogPath = Join-Path $StagingFolder 'Execution.log'
$ReportFolder = Join-Path $StagingFolder '_Consolidation_Record'

function Write-RunLog {
    param([string]$Message,[ValidateSet('INFO','PASS','WARN','ERROR')][string]$Level='INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Message
    Write-Host $line
    if (Test-Path -LiteralPath $StagingFolder -PathType Container) {
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    }
}

function Get-NormalizedFullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Test-ExpectedHashFormat {
    param([string]$Value)
    # Reusable 64-char hex guard applied to whatever value the resolution order yields.
    return (-not [string]::IsNullOrWhiteSpace($Value) -and $Value.Length -eq 64 -and $Value -match '^[0-9A-Fa-f]{64}$')
}

function Resolve-ExpectedZipSHA256 {
    # Resolution order (highest priority first):
    #   1) explicit -ExpectedZipSHA256 bound on the command line (operator override),
    #   2) sidecar hash file (-ExpectedZipSHA256Path, or '<ZipPath>.sha256' when that param is empty),
    #   3) the literal default (last-resort backward-compatible fallback).
    # The returned value is still subject to the 64-char hex guard by the caller.
    param(
        [string]$ParamValue,
        [string]$DefaultValue,
        [string]$SidecarPathParam,
        [string]$ZipPathForSidecar,
        [bool]$ParamWasBound
    )
    # 1) explicit param override: honoured whenever -ExpectedZipSHA256 was explicitly bound
    #    on the command line (keyed off $PSBoundParameters so an explicitly passed hash wins
    #    even when it happens to equal the shipped default). The former "differs from default"
    #    test let a sidecar silently win when an operator explicitly passed the default value.
    if ($ParamWasBound -and -not [string]::IsNullOrWhiteSpace($ParamValue)) {
        return [pscustomobject]@{ Value = $ParamValue.Trim(); Source = 'ExplicitParam' }
    }
    # 2) sidecar file: explicit path wins, otherwise the conventional '<ZipPath>.sha256'.
    $sidecar = if (-not [string]::IsNullOrWhiteSpace($SidecarPathParam)) { $SidecarPathParam } else { ($ZipPathForSidecar + '.sha256') }
    if (-not [string]::IsNullOrWhiteSpace($sidecar) -and (Test-Path -LiteralPath $sidecar -PathType Leaf)) {
        $raw = (Get-Content -LiteralPath $sidecar -Raw -ErrorAction Stop)
        # Accept bare hashes and 'sha256sum'-style lines ('<hash> *<file>' / '<hash>  <file>').
        $token = ($raw -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
        if ($null -ne $token) { $token = $token.TrimStart('*').Trim() }
        return [pscustomobject]@{ Value = $token; Source = ('SidecarFile:' + $sidecar) }
    }
    # 3) literal default fallback.
    return [pscustomobject]@{ Value = $DefaultValue; Source = 'LiteralDefault' }
}

function Test-ScriptSyntax {
    param([string]$Path)
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$parseErrors)
    return ($null -eq $parseErrors -or $parseErrors.Count -eq 0)
}

function Test-SafeEntryName {
    param([string]$EntryName,[string]$DestinationRoot)
    if ([string]::IsNullOrWhiteSpace($EntryName)) { return $false }
    $cleanName = $EntryName.Replace('/','\')
    if ([System.IO.Path]::IsPathRooted($cleanName)) { return $false }
    if ($cleanName -match '(^|\\)\.\.(\\|$)') { return $false }
    if ($cleanName.IndexOf([char]0) -ge 0) { return $false }
    $target = [System.IO.Path]::GetFullPath((Join-Path $DestinationRoot $cleanName))
    $root = (Get-NormalizedFullPath $DestinationRoot) + '\'
    return $target.StartsWith($root,[System.StringComparison]::OrdinalIgnoreCase)
}

function Install-CurrentScript {
    if ([string]::IsNullOrWhiteSpace($SourceScriptPath) -or -not (Test-Path -LiteralPath $SourceScriptPath -PathType Leaf)) {
        throw 'Current script path could not be resolved.'
    }
    if (-not (Test-ScriptSyntax $SourceScriptPath)) { throw 'Current script failed parser validation.' }
    New-Item -ItemType Directory -Path $InstalledFolder -Force | Out-Null
    if (-not ((Get-NormalizedFullPath $SourceScriptPath).Equals((Get-NormalizedFullPath $InstalledPath),[System.StringComparison]::OrdinalIgnoreCase))) {
        Copy-Item -LiteralPath $SourceScriptPath -Destination $InstalledPath -Force
    }
    if (-not (Test-ScriptSyntax $InstalledPath)) { throw 'Installed script failed parser validation.' }
}

try {
    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) { throw "ZIP not found: $ZipPath" }
    if ([System.IO.Path]::GetExtension($ZipPath) -ne '.zip') { throw "Input is not a ZIP file: $ZipPath" }
    if (Test-Path -LiteralPath $FinalRunFolder) { throw "Final run folder already exists: $FinalRunFolder" }
    if (Test-Path -LiteralPath $StagingFolder) { throw "Staging folder already exists: $StagingFolder" }

    New-Item -ItemType Directory -Path $StagingFolder -Force | Out-Null
    New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null
    Write-RunLog "BHP INVENT | CP09A GeoAI Consolidation | Version $Version | Classification $Classification"
    Write-RunLog "RUN_ID: $RunId"
    Write-RunLog "SOURCE ZIP: $ZipPath"
    Write-RunLog "OUTPUT: $FinalRunFolder"

    Write-Progress -Id 1 -Activity 'CP09A GeoAI consolidation' -Status 'Installing and validating script' -PercentComplete 3
    Install-CurrentScript
    Write-RunLog "Installed script: $InstalledPath" 'PASS'

    # Resolve the expected ZIP hash: explicit param > sidecar file > literal default.
    $expectedHashResolution = Resolve-ExpectedZipSHA256 -ParamValue $ExpectedZipSHA256 -DefaultValue $DefaultExpectedZipSHA256 -SidecarPathParam $ExpectedZipSHA256Path -ZipPathForSidecar $ZipPath -ParamWasBound $PSBoundParameters.ContainsKey('ExpectedZipSHA256')
    $ExpectedZipSHA256 = $expectedHashResolution.Value
    Write-RunLog ("Expected ZIP SHA256 source: {0}" -f $expectedHashResolution.Source)

    # Single evaluation of the four static preflight conditions (previously re-checked 500x
    # with no added coverage). Failures still aggregate into $validationFailures, still throw
    # with the aggregated count, and still write Preflight_Failures.txt.
    Write-Progress -Id 1 -Activity 'CP09A GeoAI consolidation' -Status 'Preflight validation (single pass)' -PercentComplete 15
    $validationFailures = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) { [void]$validationFailures.Add('ZIP missing') }
    if (-not (Test-ScriptSyntax $InstalledPath)) { [void]$validationFailures.Add('parser failure') }
    if (Test-Path -LiteralPath $FinalRunFolder) { [void]$validationFailures.Add('final folder collision') }
    if (-not (Test-ExpectedHashFormat $ExpectedZipSHA256)) { [void]$validationFailures.Add('invalid expected SHA256') }
    if ($validationFailures.Count -gt 0) {
        $validationFailures | Set-Content -LiteralPath (Join-Path $ReportFolder 'Preflight_Failures.txt') -Encoding UTF8
        throw "$($validationFailures.Count) preflight validation failures detected."
    }
    Write-RunLog 'preflight validation: PASS' 'PASS'

    Write-Progress -Id 1 -Activity 'CP09A GeoAI consolidation' -Status 'Validating ZIP hash and structure' -PercentComplete 18
    $zipItem = Get-Item -LiteralPath $ZipPath
    if ($zipItem.Length -le 0) { throw 'ZIP is empty.' }
    $actualZipHash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actualZipHash -ne $ExpectedZipSHA256.ToUpperInvariant()) {
        throw "ZIP SHA256 mismatch. Expected: $ExpectedZipSHA256 Actual: $actualZipHash"
    }
    Write-RunLog "ZIP SHA256: $actualZipHash" 'PASS'

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entries = @($archive.Entries)
        if ($entries.Count -eq 0) { throw 'ZIP contains no entries.' }
        $unsafeEntries = New-Object System.Collections.ArrayList
        $duplicateEntryNames = @($entries | Group-Object { $_.FullName.Replace('/','\').ToLowerInvariant() } | Where-Object { $_.Count -gt 1 })
        foreach ($entry in $entries) {
            if (-not (Test-SafeEntryName $entry.FullName $StagingFolder)) { [void]$unsafeEntries.Add($entry.FullName) }
        }
        if ($unsafeEntries.Count -gt 0) {
            $unsafeEntries | Set-Content -LiteralPath (Join-Path $ReportFolder 'Unsafe_ZIP_Entries.txt') -Encoding UTF8
            throw "$($unsafeEntries.Count) unsafe ZIP entries detected."
        }
        if ($duplicateEntryNames.Count -gt 0) {
            $duplicateEntryNames | ForEach-Object { $_.Name } | Set-Content -LiteralPath (Join-Path $ReportFolder 'Duplicate_ZIP_Entry_Names.txt') -Encoding UTF8
            throw "$($duplicateEntryNames.Count) duplicate ZIP entry names detected."
        }

        $entryInventory = New-Object System.Collections.ArrayList
        $fileEntries = @($entries | Where-Object { -not [string]::IsNullOrEmpty($_.Name) })
        $totalFiles = $fileEntries.Count
        $extractedFiles = 0
        $extractedBytes = [int64]0

        foreach ($entry in $entries) {
            $relativeName = $entry.FullName.Replace('/','\')
            $destinationPath = [System.IO.Path]::GetFullPath((Join-Path $StagingFolder $relativeName))
            if ([string]::IsNullOrEmpty($entry.Name)) {
                New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
                continue
            }
            $extractedFiles++
            $percent = 20 + [int](55 * ($extractedFiles / [double][math]::Max(1,$totalFiles)))
            Write-Progress -Id 1 -Activity 'CP09A GeoAI consolidation' -Status 'Secure extraction without overwrite' -CurrentOperation ("File {0} of {1}: {2}" -f $extractedFiles,$totalFiles,$entry.FullName) -PercentComplete $percent
            $parent = Split-Path -Path $destinationPath -Parent
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
            if (Test-Path -LiteralPath $destinationPath) { throw "No-overwrite safety block: $destinationPath" }
            $inputStream = $entry.Open()
            try {
                $outputStream = New-Object System.IO.FileStream($destinationPath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
                try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose() }
            } finally { $inputStream.Dispose() }
            $actualLength = (Get-Item -LiteralPath $destinationPath).Length
            if ($actualLength -ne $entry.Length) { throw "Extracted length mismatch: $destinationPath" }
            $extractedBytes += [int64]$actualLength
            [void]$entryInventory.Add([pscustomobject]@{Entry=$entry.FullName;OutputPath=$destinationPath;ExpectedBytes=[int64]$entry.Length;ActualBytes=[int64]$actualLength;Status='PASS'})
        }
    } finally { if ($null -ne $archive) { $archive.Dispose() } }

    Write-Progress -Id 1 -Activity 'CP09A GeoAI consolidation' -Status 'Reviewing extracted result' -PercentComplete 80
    $entryInventory | Export-Csv -LiteralPath (Join-Path $ReportFolder 'Extraction_Register.csv') -NoTypeInformation -Encoding UTF8
    $actualExtractedFiles = @(Get-ChildItem -LiteralPath $StagingFolder -File -Recurse | Where-Object { $_.FullName -notlike "$ReportFolder*" -and $_.FullName -ne $LogPath })
    if ($actualExtractedFiles.Count -ne $totalFiles) { throw "Extracted file count mismatch. Expected: $totalFiles Actual: $($actualExtractedFiles.Count)" }

    $extensionSummary = @($actualExtractedFiles | Group-Object Extension | ForEach-Object {
        $items = @($_.Group)
        $bytes = ($items | Measure-Object Length -Sum).Sum
        [pscustomobject]@{Extension=if([string]::IsNullOrWhiteSpace($_.Name)){'[NO_EXTENSION]'}else{$_.Name.ToLowerInvariant()};FileCount=$items.Count;TotalBytes=[int64]$bytes;TotalMB=[math]::Round($bytes/1MB,3)}
    } | Sort-Object FileCount -Descending)
    $extensionSummary | Export-Csv -LiteralPath (Join-Path $ReportFolder 'Extension_Summary.csv') -NoTypeInformation -Encoding UTF8

    $csvReview = New-Object System.Collections.ArrayList
    $csvFiles = @($actualExtractedFiles | Where-Object Extension -eq '.csv')
    for ($i=0; $i -lt $csvFiles.Count; $i++) {
        $csv = $csvFiles[$i]
        $percent = 82 + [int](8 * (($i+1)/[double][math]::Max(1,$csvFiles.Count)))
        Write-Progress -Id 1 -Activity 'CP09A GeoAI consolidation' -Status 'Reviewing CSV outputs' -CurrentOperation $csv.FullName -PercentComplete $percent
        $firstLine = Get-Content -LiteralPath $csv.FullName -TotalCount 1 -Encoding UTF8
        $lineCount = 0
        $reader = [System.IO.File]::OpenText($csv.FullName)
        try { while ($null -ne $reader.ReadLine()) { $lineCount++ } } finally { $reader.Dispose() }
        [void]$csvReview.Add([pscustomobject]@{File=$csv.FullName;SizeBytes=[int64]$csv.Length;LineCount=$lineCount;Header=$firstLine;Status=if($lineCount -ge 1 -and -not [string]::IsNullOrWhiteSpace($firstLine)){'PASS'}else{'FAIL'}})
    }
    $csvReview | Export-Csv -LiteralPath (Join-Path $ReportFolder 'CSV_Review.csv') -NoTypeInformation -Encoding UTF8
    if (@($csvReview | Where-Object Status -ne 'PASS').Count -gt 0) { throw 'One or more CSV files failed review.' }

    Write-Progress -Id 1 -Activity 'CP09A GeoAI consolidation' -Status 'Generating final evidence' -PercentComplete 92
    $outputHashes = foreach ($file in $actualExtractedFiles) {
        $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
        [pscustomobject]@{RelativePath=$file.FullName.Substring($StagingFolder.Length).TrimStart('\');SizeBytes=[int64]$file.Length;SHA256=$hash.Hash}
    }
    $outputHashes | Export-Csv -LiteralPath (Join-Path $ReportFolder 'Extracted_Files_SHA256.csv') -NoTypeInformation -Encoding UTF8

    $summary = [ordered]@{
        Title='BHP INVENT | CP09A GeoAI Consolidation';Classification=$Classification;Version=$Version;RunId=$RunId
        SourceZip=$ZipPath;SourceZipBytes=[int64]$zipItem.Length;SourceZipSHA256=$actualZipHash
        OutputFolder=$FinalRunFolder;ZipEntryCount=$entries.Count;ExtractedFileCount=$actualExtractedFiles.Count
        ExtractedBytes=[int64](($actualExtractedFiles | Measure-Object Length -Sum).Sum);CSVFileCount=$csvFiles.Count
        UnsafeEntryCount=0;OverwriteCount=0;PreflightValidationMode='SINGLE_PASS';PreflightValidationPassed=$true;PreflightValidationFailures=0;ExpectedZipSHA256Source=$expectedHashResolution.Source
        Status='PASS_REAL_TEST'
    }
    $summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ReportFolder 'Summary.json') -Encoding UTF8
    $summary.GetEnumerator() | ForEach-Object { '{0}: {1}' -f $_.Key,$_.Value } | Set-Content -LiteralPath (Join-Path $ReportFolder 'Summary.txt') -Encoding UTF8

    $recordFiles = @(Get-ChildItem -LiteralPath $ReportFolder -File | Where-Object Name -ne 'SHA256SUMS.txt')
    $manifest = foreach ($file in $recordFiles) { $h=Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256; '{0} *{1}' -f $h.Hash,$file.Name }
    $manifest | Set-Content -LiteralPath (Join-Path $ReportFolder 'SHA256SUMS.txt') -Encoding ASCII

    Write-RunLog 'RESULT REVIEW: PASS_REAL_TEST' 'PASS'
    Write-RunLog "EXTRACTED FILES: $($actualExtractedFiles.Count)" 'PASS'
    Write-RunLog 'OVERWRITES: 0' 'PASS'
    Write-RunLog 'UNSAFE ZIP ENTRIES: 0' 'PASS'

    Write-Progress -Id 1 -Activity 'CP09A GeoAI consolidation' -Status 'Promoting completed run' -PercentComplete 98
    Move-Item -LiteralPath $StagingFolder -Destination $FinalRunFolder
    if (-not (Test-Path -LiteralPath $FinalRunFolder -PathType Container)) { throw 'Final run promotion failed.' }
    Write-Progress -Id 1 -Activity 'CP09A GeoAI consolidation' -Completed

    Write-Host ''
    Write-Host 'CONSOLIDATION: PASS_REAL_TEST' -ForegroundColor Green
    Write-Host 'OVERWRITES: 0' -ForegroundColor Green
    Write-Host "OUTPUT: $FinalRunFolder" -ForegroundColor Cyan
    Write-Host ''
    exit 0
}
catch {
    try {
        if (-not (Test-Path -LiteralPath $StagingFolder -PathType Container)) { New-Item -ItemType Directory -Path $StagingFolder -Force | Out-Null }
        if (-not (Test-Path -LiteralPath $ReportFolder -PathType Container)) { New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null }
        Write-RunLog $_.Exception.Message 'ERROR'
        @('MESSAGE: '+$_.Exception.Message,'SCRIPT: '+$_.InvocationInfo.ScriptName,'LINE: '+$_.InvocationInfo.ScriptLineNumber,'POSITION: '+$_.InvocationInfo.PositionMessage,'',($_ | Out-String)) | Set-Content -LiteralPath (Join-Path $ReportFolder 'Fatal_Error.txt') -Encoding UTF8
    } catch { Write-Host ('FATAL: '+$_.Exception.Message) -ForegroundColor Red }
    Write-Progress -Id 1 -Activity 'CP09A GeoAI consolidation' -Completed
    exit 1
}
