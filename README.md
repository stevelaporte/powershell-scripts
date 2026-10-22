# powershell-scripts

PowerShell scripts for Active Directory and Windows administration. Each script has comment-based help (`Get-Help .\<script>.ps1 -Full`) and a more detailed write-up on my website. Links below.

## Scripts

| Script | Description | Write-up |
|---|---|---|
| [Backup-ADUserAttributes.ps1](Backup-ADUserAttributes.ps1) | Read-only point-in-time snapshot of AD user attributes, CN, OU and enabled state, keyed on `objectGUID`. | [Link](https://stevelaporte.net/scripts/backup-ad-attributes/) |
| [Restore-ADUserAttributes.ps1](Restore-ADUserAttributes.ps1) | Diffs current AD users against a snapshot and optionally restores attributes, CN, OU and enabled state. Report-only unless `-Apply` is used. | [Link](https://stevelaporte.net/scripts/restore-ad-attributes/) |

## Requirements

- PowerShell 5.1+
- ActiveDirectory module (RSAT, or run on a DC/management server)

## Quick start

```powershell
# Snapshot
.\Backup-ADUserAttributes.ps1 -SearchBase "OU=Staff,DC=corp,DC=example,DC=com" -OutDir C:\ADBackups

# Diff against the snapshot (changes nothing)
.\Restore-ADUserAttributes.ps1 -SnapshotPath C:\ADBackups\ad-snapshot-<timestamp>.clixml
```

## Warnings

- Snapshot and report files contain PII. Store them securely and don't commit them (the included `.gitignore` excludes them).
- Test in a lab before running against production. Read the report before using `-Apply`.

## License

[GPL-3.0-or-later](LICENSE). Copyright (C) 2026 Steve LaPorte.
