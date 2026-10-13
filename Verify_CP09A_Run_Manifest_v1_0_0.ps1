#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$RunRoot = "C:\Python\GeoAi\00_Base_Datos\GeoAi\99_Run_To_Verify",
    [string]$ManifestName = "SHA256SUMS.txt",
    [string]$OutputRoot = "C:\Python\GeoAi\00_Base_Datos\GeoAi\15_Manifest_Verification",
    [string]$ApplicationRoot = "C:\Python\GeoAi\01_Aplicacion\CP09A_Release_v2.1",
    [switch]$AuditOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ScriptName = "Verify_CP09A_Run_Manifest"
$Version = "1.0.0"
$Classification = "Internal"
$RunId = "MANIFEST-VERIFY-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss")
$StagingRoot = Join-Path $OutputRoot (".staging-" + $RunId)
$FinalRoot = Join-Path $OutputRoot $RunId
$InstalledFolder = Join-Path $ApplicationRoot "00_Script\Manifest_Verification"
$InstalledPath = Join-Path $InstalledFolder "Verify_CP09A_Run_Manifest_v1_0_0.ps1"
$SourceScriptPath = $MyInvocation.MyCommand.Path
function Assert-PathValue { param([string]$Value,[string]$Name) if([string]::IsNullOrWhiteSpace($Value)){throw ("{0} is empty." -f $Name)} if(-not [IO.Path]::IsPathFullyQualified($Value)){throw ("{0} must be absolute." -f $Name)} }
function Test-ScriptSyntax { param([string]$Path) $tokens=$null;$errors=$null;[void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors);return ($null -eq $errors -or $errors.Count -eq 0) }
# Parses a sha256sum-style line "<64hexhash>  <relative/path>" (one or two spaces, optional leading '*' on the name).
# Returns an object with Hash (uppercased) and RelPath, or $null for blank/comment lines that carry no hash.
function Read-ManifestLine { param([string]$Line) $t=$Line.Trim();if($t.Length -eq 0 -or $t.StartsWith("#")){return $null};$m=[regex]::Match($t,'^(?<hash>[0-9A-Fa-f]{64})\s+\*?(?<name>.+)$');if(-not $m.Success){return [pscustomobject]@{Hash=$null;RelPath=$t;Malformed=$true}};return [pscustomobject]@{Hash=$m.Groups['hash'].Value.ToUpperInvariant();RelPath=$m.Groups['name'].Value.Trim();Malformed=$false} }
# Normalizes a manifest-relative path to the host separator and strips a leading "./".
function ConvertTo-LocalRelPath { param([string]$RelPath) $p=$RelPath -replace '/',[string][IO.Path]::DirectorySeparatorChar;if($p.StartsWith("."+[IO.Path]::DirectorySeparatorChar)){$p=$p.Substring(2)};return $p }
Assert-PathValue $RunRoot "RunRoot"
Assert-PathValue $OutputRoot "OutputRoot"
Assert-PathValue $ApplicationRoot "ApplicationRoot"
if(-not(Test-Path -LiteralPath $RunRoot -PathType Container)){throw ("RunRoot not found: {0}" -f $RunRoot)}
$RunRoot=[IO.Path]::GetFullPath($RunRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
$manifestPath=Join-Path $RunRoot $ManifestName
if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){throw ("Manifest not found in RunRoot: {0}" -f $manifestPath)}
# SOURCE IS READ-ONLY: the audited run is only read; never modified. The manifest itself is excluded from the listed set.
$manifestLines=@(Get-Content -LiteralPath $manifestPath -Encoding utf8)
$listed=@();$malformed=@()
foreach($line in $manifestLines){$parsed=Read-ManifestLine $line;if($null -eq $parsed){continue};if($parsed.Malformed){$malformed+=$parsed.RelPath;continue};$listed+=$parsed}
# Build the set of actual files present under RunRoot (excluding the manifest file itself), keyed by host-relative path.
$actualFiles=@(Get-ChildItem -LiteralPath $RunRoot -File -Recurse -Force|Where-Object{$_.FullName -ine $manifestPath})
$actualRel=@{}
foreach($f in $actualFiles){$rel=$f.FullName.Substring($RunRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar);$actualRel[$rel]=$f.FullName}
$results=@();$seenRel=New-Object System.Collections.Generic.HashSet[string]
foreach($entry in $listed){
    $localRel=ConvertTo-LocalRelPath $entry.RelPath
    [void]$seenRel.Add($localRel)
    $expected=$entry.Hash;$actual=$null;$status="FILE_NOT_FOUND"
    if($actualRel.ContainsKey($localRel)){
        $actual=(Get-FileHash -LiteralPath $actualRel[$localRel] -Algorithm SHA256).Hash.ToUpperInvariant()
        $status=if($actual -eq $expected){"HASH_MATCH"}else{"HASH_MISMATCH"}
    }
    $results+=[pscustomobject]@{RelPath=$localRel;ExpectedSHA256=$expected;ActualSHA256=$actual;Status=$status}
}
# Files present on disk but absent from the manifest are UNLISTED_FILE (evidence drift, not a hard mismatch).
foreach($rel in $actualRel.Keys){if(-not $seenRel.Contains($rel)){$results+=[pscustomobject]@{RelPath=$rel;ExpectedSHA256=$null;ActualSHA256=(Get-FileHash -LiteralPath $actualRel[$rel] -Algorithm SHA256).Hash.ToUpperInvariant();Status="UNLISTED_FILE"}}}
# Decision idiom aligned with the register-verification / governance engines:
#   NO_GO            -> at least one listed file has a confirmed hash mismatch
#   REVIEW_REQUIRED  -> any missing listed file, any unlisted file on disk, or any malformed manifest line
#   PASS             -> every listed file present with a matching hash and no drift
$mismatch=@($results|Where-Object{$_.Status -eq "HASH_MISMATCH"})
$notFound=@($results|Where-Object{$_.Status -eq "FILE_NOT_FOUND"})
$unlisted=@($results|Where-Object{$_.Status -eq "UNLISTED_FILE"})
$decision=if($mismatch.Count -gt 0){"NO_GO"}elseif($notFound.Count -gt 0 -or $unlisted.Count -gt 0 -or $malformed.Count -gt 0){"REVIEW_REQUIRED"}else{"PASS"}
$summary=[ordered]@{Classification=$Classification;Version=$Version;RunId=$RunId;AuditedRunRoot=$RunRoot;ManifestPath=$manifestPath;ListedEntries=$listed.Count;MalformedManifestLines=$malformed.Count;FilesOnDisk=$actualFiles.Count;HashMatches=@($results|Where-Object{$_.Status -eq "HASH_MATCH"}).Count;HashMismatches=$mismatch.Count;FilesNotFound=$notFound.Count;UnlistedFiles=$unlisted.Count;Decision=$decision;CompletedAt=(Get-Date).ToString("o")}
Write-Host "";Write-Host ("{0} | {1} v{2}" -f $Classification,$ScriptName,$Version) -ForegroundColor Cyan;Write-Host ("AUDITED RUN ROOT: {0}" -f $RunRoot);Write-Host ("MANIFEST: {0}" -f $manifestPath);Write-Host ("PROPOSED OUTPUT: {0}" -f $FinalRoot);$results|Format-Table RelPath,Status -AutoSize;Write-Host ("DECISION: {0}" -f $decision)
if($AuditOnly){Write-Host "AUDITONLY PASS: NO FILES OR FOLDERS CREATED." -ForegroundColor Green;exit 0}
if(Test-Path -LiteralPath $FinalRoot){throw ("Final output already exists: {0}" -f $FinalRoot)}
if(Test-Path -LiteralPath $StagingRoot){throw ("Staging output already exists: {0}" -f $StagingRoot)}
if(-not(Test-Path -LiteralPath $SourceScriptPath -PathType Leaf)){throw "Current script path could not be resolved."}
if(-not(Test-ScriptSyntax $SourceScriptPath)){throw "Current script failed parser validation."}
New-Item -ItemType Directory -Path $InstalledFolder -Force|Out-Null;Copy-Item -LiteralPath $SourceScriptPath -Destination $InstalledPath -Force;if(-not(Test-ScriptSyntax $InstalledPath)){throw "Installed script failed parser validation."}
New-Item -ItemType Directory -Path $StagingRoot -ErrorAction Stop|Out-Null
$results|Export-Csv (Join-Path $StagingRoot "Manifest_Verification.csv") -NoTypeInformation -Encoding utf8
$summary|ConvertTo-Json -Depth 10|Set-Content (Join-Path $StagingRoot "Summary.json") -Encoding utf8
$summary.GetEnumerator()|ForEach-Object{"{0}: {1}" -f $_.Key,$_.Value}|Set-Content (Join-Path $StagingRoot "Summary.txt") -Encoding utf8
$lines=@();foreach($f in @(Get-ChildItem -LiteralPath $StagingRoot -File|Sort-Object Name)){$lines+=("{0}  {1}" -f (Get-FileHash $f.FullName -Algorithm SHA256).Hash,$f.Name)};$lines|Set-Content (Join-Path $StagingRoot "SHA256SUMS.txt") -Encoding ascii
Move-Item -LiteralPath $StagingRoot -Destination $FinalRoot;if(-not(Test-Path -LiteralPath $FinalRoot -PathType Container)){throw "Final promotion failed."}
Write-Host ("INSTALLED SCRIPT: {0}" -f $InstalledPath) -ForegroundColor Green;Write-Host ("REPORT ROOT: {0}" -f $FinalRoot) -ForegroundColor Green;Write-Host ("DECISION: {0}" -f $decision);Write-Host "RUN MANIFEST VERIFICATION COMPLETE" -ForegroundColor Green
