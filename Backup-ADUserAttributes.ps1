<#
.SYNOPSIS
    Point-in-time snapshot of AD user attributes, CN, OU and enabled state, keyed on objectGUID,
    for use with Restore-ADUserAttributes.ps1. Read-only.

.DESCRIPTION
    Captures a configurable set of attributes for every user under the given OU(s) and writes:
      ad-snapshot-<timestamp>.clixml   Restore source (types preserved, multi-valued kept as arrays)
      ad-snapshot-<timestamp>.csv      Human-readable copy for diffing
      ad-snapshot-<timestamp>.txt      Metadata (DC, OUs, attribute list, counts)
    Attributes that don't exist in the forest's schema are skipped with a warning.
    Manager is stored as a GUID as well as a DN, so a renamed or moved manager doesn't break a restore.
    Nothing in AD is modified. The output files contain PII - store them accordingly.

.PARAMETER SearchBase
    One or more OU/container distinguished names to capture (subtree search),
    e.g. "OU=Staff,DC=corp,DC=example,DC=com".

.PARAMETER ExtraAttributes
    Additional LDAP attribute names to capture, e.g. custom schema attributes or anything your
    provisioning/sync tooling writes that isn't in the default list.

.PARAMETER Server
    DC to read from. Also accepts a mounted AD snapshot, e.g. localhost:51389 (dsamain).

.PARAMETER OutDir
    Output directory (created if missing). Default: current directory.

.EXAMPLE
    .\Backup-ADUserAttributes.ps1 -SearchBase "OU=Staff,DC=corp,DC=example,DC=com" -OutDir C:\ADBackups

.EXAMPLE
    .\Backup-ADUserAttributes.ps1 -SearchBase "OU=Staff,DC=corp,DC=example,DC=com","OU=Contractors,DC=corp,DC=example,DC=com" -ExtraAttributes msDS-cloudExtensionAttribute1 -Server dc01.corp.example.com

.NOTES
    Author:   Steve LaPorte (stevelaporte.net | github.com/tmfc666)
    Requires: PowerShell 5.1+, ActiveDirectory module (RSAT), read access to the target OUs
    License:  GPL-3.0-or-later
              Copyright (C) 2026 Steve LaPorte
              This program is free software: you can redistribute it and/or modify it under the
              terms of the GNU General Public License as published by the Free Software Foundation,
              either version 3 of the License, or (at your option) any later version.
              This program is distributed in the hope that it will be useful, but WITHOUT ANY
              WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
              PARTICULAR PURPOSE. See the GNU General Public License for more details.
              You should have received a copy of the GNU General Public License along with this
              program. If not, see <https://www.gnu.org/licenses/>.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$SearchBase,
    [string[]]$ExtraAttributes = @(),
    [string]$Server,
    [string]$OutDir = "."
)

$ErrorActionPreference = 'Stop'   # a bad OU or DC fails the run instead of producing a partial snapshot
Import-Module ActiveDirectory
$common = @{}
if ($Server) { $common.Server = $Server }

foreach ($ou in $SearchBase) {
    try { Get-ADObject @common -Identity $ou | Out-Null }
    catch { throw "SearchBase not found: $ou" }
}
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$default = @(
    'givenName','sn','initials','middleName','displayName','description',
    'title','department','division','company','manager',
    'employeeID','employeeNumber','employeeType',
    'physicalDeliveryOfficeName','streetAddress','l','st','postalCode','c','co','countryCode',
    'telephoneNumber','mobile','ipPhone','facsimileTelephoneNumber','homePhone','otherTelephone',
    'info','wWWHomePage','mail','proxyAddresses','userPrincipalName','sAMAccountName'
) + (1..15 | ForEach-Object { "extensionAttribute$_" })

# Drop anything not in this forest's schema (Get-ADUser errors on unknown attributes)
$schemaNC = (Get-ADRootDSE @common).schemaNamingContext
$Attributes = foreach ($a in ($default + $ExtraAttributes | Select-Object -Unique)) {
    if (Get-ADObject @common -SearchBase $schemaNC -Filter "lDAPDisplayName -eq '$a'") { $a }
    else { Write-Warning "Attribute '$a' not in schema - skipped." }
}

$users = foreach ($ou in $SearchBase) {
    Get-ADUser @common -Filter * -SearchBase $ou -SearchScope Subtree -Properties ($Attributes + 'cn')
}
$users = $users | Sort-Object ObjectGUID -Unique

# Manager is a DN; store the manager's GUID too so a rename/move can't break the restore
$dnToGuid = @{}
foreach ($u in $users) { $dnToGuid[$u.DistinguishedName] = $u.ObjectGUID }

function Get-ParentDN([string]$dn) { $dn -replace '^CN=.+?(?<!\\),', '' }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$snapshot = foreach ($u in $users) {
    $attrs = @{}
    foreach ($a in $Attributes) {
        $v = $u.$a
        if ($null -eq $v) { $attrs[$a] = $null }
        elseif ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) {
            $arr = [string[]]@($v | ForEach-Object { "$_" })
            $attrs[$a] = if ($arr.Count) { ,$arr } else { $null }
        }
        else { $attrs[$a] = $v }
    }
    $mgrGuid = $null
    if ($u.manager) {
        $mgrGuid = $dnToGuid[$u.manager]
        if (-not $mgrGuid) {
            try { $mgrGuid = (Get-ADUser @common -Identity $u.manager).ObjectGUID }
            catch { Write-Warning "Can't resolve manager for $($u.SamAccountName): $($u.manager)" }
        }
    }
    [pscustomobject]@{
        ObjectGUID        = $u.ObjectGUID
        SamAccountName    = $u.SamAccountName
        DistinguishedName = $u.DistinguishedName
        ParentDN          = Get-ParentDN $u.DistinguishedName
        CN                = $u.cn
        Enabled           = $u.Enabled
        ManagerGuid       = $mgrGuid
        Attributes        = $attrs
        SnapshotTime      = $stamp
    }
}

$base = Join-Path $OutDir "ad-snapshot-$stamp"
$snapshot | Export-Clixml "$base.clixml" -Depth 5

$snapshot | ForEach-Object {
    $row = [ordered]@{
        ObjectGUID = $_.ObjectGUID; SamAccountName = $_.SamAccountName; CN = $_.CN
        ParentDN = $_.ParentDN; Enabled = $_.Enabled
    }
    foreach ($a in $Attributes) {
        $v = $_.Attributes[$a]
        $row[$a] = if ($v -is [array]) { $v -join ' | ' } else { $v }
    }
    [pscustomobject]$row
} | Export-Csv "$base.csv" -NoTypeInformation

@"
Snapshot:   $stamp
Server:     $(if ($Server) { $Server } else { '(default DC)' })
SearchBase: $($SearchBase -join '; ')
Users:      $(@($snapshot).Count)
Attributes: $($Attributes -join ', ')
"@ | Set-Content "$base.txt"

Write-Host "Captured $(@($snapshot).Count) users -> $base.clixml"
