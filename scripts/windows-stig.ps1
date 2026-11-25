# Apply the same curated Windows Server 2022 STIG settings as the
# windows_stig Ansible role. Used by Packer over SSH/SSM so the bake
# does not depend on inbound WinRM.
#
# STIG IDs (DISA Windows Server 2022 STIG V2):
#   WN22-SO-000010  Guest account disabled
#   WN22-AC-000010  Lockout duration >= 15 minutes
#   WN22-AC-000020  Lockout threshold <= 3
#   WN22-AC-000030  Lockout window >= 15 minutes
#   WN22-SO-000020  LimitBlankPasswordUse
#   WN22-SO-000080  SignSecureChannel
#   WN22-SO-000130  LegalNoticeText
#   WN22-SO-000140  LegalNoticeCaption
#   WN22-SO-000250  RestrictNullSessAccess
[CmdletBinding()]
param(
    [string]$BannerTitle = "DoD Notice and Consent Banner",
    [string]$BannerText = "This is a U.S. Government system. Unauthorized access is prohibited. Use of this system constitutes consent to monitoring."
)

$ErrorActionPreference = "Stop"

try {
    Disable-LocalUser -Name "Guest" -ErrorAction SilentlyContinue
} catch { }

net accounts /lockoutthreshold:3 | Out-Null
net accounts /lockoutduration:15 | Out-Null
net accounts /lockoutwindow:15 | Out-Null

function Set-Dword([string]$Path, [string]$Name, [int]$Value) {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}
function Set-String([string]$Path, [string]$Name, [string]$Value) {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType String -Force | Out-Null
}

Set-Dword "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" "LimitBlankPasswordUse" 1
Set-Dword "HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters" "SignSecureChannel" 1
Set-Dword "HKLM:\SYSTEM\CurrentControlSet\Services\LanManServer\Parameters" "RestrictNullSessAccess" 1
Set-String "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "LegalNoticeCaption" $BannerTitle
Set-String "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "LegalNoticeText" $BannerText

Write-Host "windows-stig.ps1 applied curated WS2022 STIG settings."
