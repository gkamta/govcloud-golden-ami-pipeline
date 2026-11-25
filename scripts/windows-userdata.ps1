<powershell>
# EC2 user data for the Windows Packer builder.
# Installs OpenSSH Server so Packer can reach the instance through
# SSM Session Manager (ssh_interface=session_manager) with no inbound
# security-group rules. The official AWS Windows AMI already includes
# EC2Launch v2 and the SSM Agent.
$ErrorActionPreference = "Stop"
Start-Transcript -Path "C:\Windows\Temp\packer-userdata.log" -Force

# Ensure SSM Agent is running before Packer tries Session Manager.
Set-Service -Name AmazonSSMAgent -StartupType Automatic
Start-Service -Name AmazonSSMAgent

# OpenSSH Server (Windows Server 2022 optional feature).
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue

Set-Service -Name sshd -StartupType Automatic
Start-Service -Name sshd

# Administrative PowerShell default shell makes the provisioners simpler.
New-Item -Path "HKLM:\SOFTWARE\OpenSSH" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell `
    -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -PropertyType String -Force | Out-Null

Stop-Transcript
</powershell>
