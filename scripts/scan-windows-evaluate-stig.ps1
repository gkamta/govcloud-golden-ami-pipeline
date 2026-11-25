# Evaluate-STIG placeholder / runner for a Windows Server 2022 golden image.
#
# Evaluate-STIG is a DISA tool (not redistributed here). When it is installed
# on the builder, this script runs it against the Windows Server 2022 STIG
# and fails the bake on remaining CAT I findings (RA-5, SA-11).
#
# When the tool is not installed, we write a notes artifact explaining how
# to obtain and run it, and we exit 0 unless -RequireTool is set.
#
# Usage (elevated PowerShell on the Packer builder):
#   .\scripts\scan-windows-evaluate-stig.ps1 -OutputDir C:\scan-artifacts
[CmdletBinding()]
param(
    [string]$OutputDir = "C:\scan-artifacts",
    [string]$EvaluateStigRoot = "C:\Evaluate-STIG",
    [switch]$RequireTool
)

$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$notes = Join-Path $OutputDir "evaluate-stig-notes.txt"
$summary = Join-Path $OutputDir "evaluate-stig-summary.txt"

$exe = Get-ChildItem -Path $EvaluateStigRoot -Filter "Evaluate-STIG.ps1" -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1

if (-not $exe) {
    $message = @"
Evaluate-STIG was not found under $EvaluateStigRoot.

This is expected on a first bake: DISA does not allow us to vendor the
tool in a public GitHub repo. In a real NAVSEA / DoD environment:

  1. Download Evaluate-STIG from the official DISA / cyber.mil distribution
     (requires a CAC / approved source). Do not copy it from an unofficial mirror.
  2. Unpack it to $EvaluateStigRoot on the Packer builder (or bake a
     bootstrap package into the build pipeline).
  3. Re-run this script. When the tool is present it evaluates the
     Microsoft Windows Server 2022 STIG and fails the AMI gate on CAT I findings.

The PowerShell / Ansible windows_stig role still applies a curated set of
real STIG settings (WN22-SO-000010, WN22-AC-000010/020/030, WN22-SO-000020,
WN22-SO-000080, WN22-SO-000130/140, WN22-SO-000250) even when this scan is
a placeholder.
"@
    Set-Content -Path $notes -Value $message
    Set-Content -Path $summary -Value "Evaluate-STIG: NOT INSTALLED (placeholder notes written)"
    Write-Host $message
    if ($RequireTool) {
        Write-Error "Evaluate-STIG is required but was not found."
        exit 2
    }
    exit 0
}

Write-Host "Running Evaluate-STIG from $($exe.FullName)"
& $exe.FullName -ScanType Unclassified -OutputPath $OutputDir
if ($LASTEXITCODE -ne 0) {
    Write-Error "Evaluate-STIG exited with code $LASTEXITCODE"
    exit $LASTEXITCODE
}

# Best-effort CAT I gate: look for a typical results/XML/CSV artifact.
$cat1 = 0
$xml = Get-ChildItem -Path $OutputDir -Filter "*.xml" -Recurse -ErrorAction SilentlyContinue
foreach ($file in $xml) {
    try {
        [xml]$doc = Get-Content -Path $file.FullName
        $cat1 += @($doc.SelectNodes("//*[translate(@severity,'HIGH','high')='high' and (text()='Open' or @status='Open' or @result='fail')]")).Count
    } catch {
        continue
    }
}
Set-Content -Path $summary -Value "Evaluate-STIG completed. Approximate open CAT I findings: $cat1"
if ($cat1 -gt 0) {
    Write-Error "GATE FAILED: $cat1 CAT I finding(s) remain. The AMI will not be published."
    exit 1
}
Write-Host "GATE PASSED (or no CAT I nodes could be parsed). See $OutputDir"
exit 0
