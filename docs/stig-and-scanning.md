# STIG set and scanning

This is a **curated teaching set**, not a complete DISA baseline. IDs are real controls from the RHEL 9 STIG (V2) and the Windows Server 2022 STIG (V2). Official catalog: [https://public.cyber.mil](https://public.cyber.mil).

## RHEL 9 (Ansible role `rhel_stig` + `fips`)

| STIG ID | What the role does |
|---|---|
| RHEL-09-214015 | `gpgcheck=1` in `/etc/dnf/dnf.conf` |
| RHEL-09-214025 | `gpgcheck=1` in every `/etc/yum.repos.d/*.repo` |
| RHEL-09-211020 / RHEL-09-255025 | Legal banner in `/etc/issue` and `/etc/issue.net` |
| RHEL-09-255040 | `PermitEmptyPasswords no` |
| RHEL-09-255045 | `PermitRootLogin no` |
| RHEL-09-255095 / RHEL-09-255100 | `ClientAliveCountMax 1`, `ClientAliveInterval 600` |
| RHEL-09-211045 / RHEL-09-211050 | Disable Ctrl-Alt-Delete burst and mask the target |
| RHEL-09-252010 / RHEL-09-252015 | chrony installed, chronyd enabled |
| RHEL-09-653010 / RHEL-09-653015 | audit installed, auditd enabled |
| RHEL-09-671010 | FIPS mode (`/proc/sys/crypto/fips_enabled == 1`) |
| RHEL-09-215105 | System-wide crypto policy `FIPS` |

The bake then runs OpenSCAP with `xccdf_org.ssgproject.content_profile_stig` against `ssg-rhel9-ds.xml` and fails on remaining CAT I findings (`scripts/scan-rhel-openscap.sh`).

## Windows Server 2022 (PowerShell + Ansible role `windows_stig`)

| STIG ID | What the script/role does |
|---|---|
| WN22-SO-000010 | Disable the built-in Guest account |
| WN22-AC-000010 / 020 / 030 | Lockout duration 15, threshold 3, window 15 |
| WN22-SO-000020 | `LimitBlankPasswordUse = 1` |
| WN22-SO-000080 | `SignSecureChannel = 1` |
| WN22-SO-000130 / 140 | Legal notice text and caption |
| WN22-SO-000250 | `RestrictNullSessAccess = 1` |

`scripts/scan-windows-evaluate-stig.ps1` runs DISA Evaluate-STIG when the tool is installed, and otherwise writes a notes artifact explaining how to obtain it (the tool is not vendored here).
