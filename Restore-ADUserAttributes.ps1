<#
.SYNOPSIS
    Compares current AD users to a Backup-ADUserAttributes.ps1 snapshot and optionally restores them.

.DESCRIPTION
    Default is REPORT ONLY: writes a per-attribute diff to CSV and changes nothing.
    Add -Apply to write. Users are matched on objectGUID, so renamed/moved objects are still found.
    Name (CN), OU and enabled state are only compared/restored when the matching switch is used.
    Manager is compared and restored by GUID.

    Before applying, stop whatever caused the change (e.g. a directory sync or identity provider
    provisioning job that writes attributes to AD), or it may overwrite the restored values on its next run.

.PARAMETER SnapshotPath
    Path to the .clixml file produced by Backup-ADUserAttributes.ps1.

.PARAMETER Attributes
    Restore only these attributes. Default: every attribute captured in the snapshot.

.PARAMETER Identity
    Limit to these sAMAccountNames or objectGUIDs.

.PARAMETER RestoreName
    Rename the CN back to the snapshot value (changes the DN).

.PARAMETER RestoreOU
    Move the object back to its original OU.

.PARAMETER RestoreEnabled
    Enable/disable the account to match the snapshot.

.PARAMETER Apply
    Actually write changes. Without it, the script only reports.

.PARAMETER Server
    DC to read from and write to.

.PARAMETER ReportPath
    Output CSV for the diff/results. Default: .\ad-restore-report-<timestamp>.csv

.EXAMPLE
    .\Restore-ADUserAttributes.ps1 -SnapshotPath .\ad-snapshot-20261014-090000.clixml
    Diff only.

.EXAMPLE
    .\Restore-ADUserAttributes.ps1 -SnapshotPath .\snap.clixml -Identity jdoe -RestoreName -Apply
    Restore one user, including CN.

.EXAMPLE
    .\Restore-ADUserAttributes.ps1 -SnapshotPath .\snap.clixml -Attributes title,department,manager -Apply
    Restore only specific attributes for everyone.

.NOTES
    Author:   Steve LaPorte (stevelaporte.net | github.com/tmfc666)
    Requires: PowerShell 5.1+, ActiveDirectory module (RSAT), write access to the target user objects
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
    [Parameter(Mandatory)][string]$SnapshotPath,
    [string[]]$Attributes,          # subset to restore; default = all captured
    [string[]]$Identity,            # limit to these sAMAccountNames or GUIDs
    [switch]$RestoreName,           # rename CN back (changes DN)
    [switch]$RestoreOU,             # move back to original OU
    [switch]$RestoreEnabled,        # re-enable/disable to match snapshot
    [switch]$Apply,
    [string]$Server,
    [string]$ReportPath = ".\ad-restore-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
)

Import-Module ActiveDirectory -ErrorAction Stop
$common = @{}
if ($Server) { $common.Server = $Server }

$snapshot = Import-Clixml $SnapshotPath
if ($Identity) {
    $snapshot = $snapshot | Where-Object { $Identity -contains $_.SamAccountName -or $Identity -contains "$($_.ObjectGUID)" }
}
if (-not $snapshot) { throw "No snapshot entries matched." }
$captured = @(@($snapshot)[0].Attributes.Keys)
# @() forces an array: a single attribute would otherwise be a string, and string + 'cn' concatenates
$toCheck  = @(if ($Attributes) { $Attributes | Where-Object { $captured -contains $_ } } else { $captured })
if (-not $toCheck.Count) { throw "None of the requested attributes are in the snapshot." }
$missingAttrs = $Attributes | Where-Object { $captured -notcontains $_ }
if ($missingAttrs) { Write-Warning "Not in snapshot, ignored: $($missingAttrs -join ', ')" }

function Get-Norm($v) {
    if ($null -eq $v) { return '' }
    if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) {
        return (@($v | ForEach-Object { "$_" }) | Sort-Object) -join "`n"
    }
    "$v"
}
function Get-ParentDN([string]$dn) { $dn -replace '^CN=.+?(?<!\\),', '' }

$report = [System.Collections.Generic.List[object]]::new()
function Add-Row($s, $attr, $snapVal, $curVal, $action, $applied, $err) {
    $row = [pscustomobject]@{
        SamAccountName = $s.SamAccountName
        ObjectGUID     = $s.ObjectGUID
        Attribute      = $attr
        SnapshotValue  = (Get-Norm $snapVal) -replace "`n", ' | '
        CurrentValue   = (Get-Norm $curVal) -replace "`n", ' | '
        Action         = $action
        Applied        = $applied
        Error          = $err
    }
    $report.Add($row)
}

foreach ($s in $snapshot) {
    try {
        $cur = Get-ADUser @common -Identity $s.ObjectGUID -Properties (@($toCheck) + 'cn')
    } catch {
        $action = if ($_.Exception.GetType().Name -eq 'ADIdentityNotFoundException') { 'MISSING - check AD Recycle Bin' } else { 'READ ERROR - user skipped' }
        Add-Row $s '(object)' $s.DistinguishedName $null $action $false $_.Exception.Message
        continue
    }

    $replace = @{}
    $clear   = [System.Collections.Generic.List[string]]::new()

    foreach ($a in $toCheck) {
        $snapVal = $s.Attributes[$a]
        $curVal  = $cur.$a

        if ($a -eq 'manager') {
            $curMgrGuid = $null
            if ($curVal) { try { $curMgrGuid = (Get-ADUser @common -Identity $curVal).ObjectGUID } catch {} }
            if ("$curMgrGuid" -eq "$($s.ManagerGuid)") { continue }
            if (-not $s.ManagerGuid) { $clear.Add('manager'); Add-Row $s $a $snapVal $curVal 'Clear' $false $null; continue }
            try {
                $replace['manager'] = (Get-ADUser @common -Identity $s.ManagerGuid).DistinguishedName
                Add-Row $s $a $snapVal $curVal 'Replace' $false $null
            } catch { Add-Row $s $a $snapVal $curVal 'Manager object not found' $false $_.Exception.Message }
            continue
        }

        if ((Get-Norm $snapVal) -ceq (Get-Norm $curVal)) { continue }
        if ($null -eq $snapVal -or (Get-Norm $snapVal) -eq '') {
            $clear.Add($a); Add-Row $s $a $snapVal $curVal 'Clear' $false $null
        } else {
            # Clixml returns multi-valued attributes as ArrayList; hand AD a string[]
            if ($snapVal -is [System.Collections.IEnumerable] -and $snapVal -isnot [string]) {
                $replace[$a] = [string[]]@($snapVal | ForEach-Object { "$_" })
            } else {
                $replace[$a] = $snapVal
            }
            Add-Row $s $a $snapVal $curVal 'Replace' $false $null
        }
    }

    $nameChanged = $cur.cn -cne $s.CN
    $ouChanged   = (Get-ParentDN $cur.DistinguishedName) -ne $s.ParentDN
    $enChanged   = $cur.Enabled -ne $s.Enabled
    if ($nameChanged) { Add-Row $s 'cn' $s.CN $cur.cn $(if ($RestoreName) { 'Rename' } else { 'Rename (needs -RestoreName)' }) $false $null }
    if ($ouChanged)   { Add-Row $s 'OU' $s.ParentDN (Get-ParentDN $cur.DistinguishedName) $(if ($RestoreOU) { 'Move' } else { 'Move (needs -RestoreOU)' }) $false $null }
    if ($enChanged)   { Add-Row $s 'Enabled' $s.Enabled $cur.Enabled $(if ($RestoreEnabled) { 'SetEnabled' } else { 'SetEnabled (needs -RestoreEnabled)' }) $false $null }

    if (-not $Apply) { continue }

    $userRows = $report | Where-Object { $_.ObjectGUID -eq $s.ObjectGUID -and $_.Action -notmatch 'needs|MISSING|not found' }
    try {
        $set = @{}
        if ($replace.Count) { $set.Replace = $replace }
        if ($clear.Count)   { $set.Clear   = $clear.ToArray() }
        if ($set.Count)     { Set-ADUser @common -Identity $s.ObjectGUID @set -ErrorAction Stop }
        if ($RestoreName -and $nameChanged) { Rename-ADObject @common -Identity $s.ObjectGUID -NewName $s.CN -ErrorAction Stop }
        if ($RestoreOU -and $ouChanged)     { Move-ADObject   @common -Identity $s.ObjectGUID -TargetPath $s.ParentDN -ErrorAction Stop }
        if ($RestoreEnabled -and $enChanged) {
            if ($s.Enabled) { Enable-ADAccount @common -Identity $s.ObjectGUID -ErrorAction Stop }
            else            { Disable-ADAccount @common -Identity $s.ObjectGUID -ErrorAction Stop }
        }
        $userRows | ForEach-Object { $_.Applied = $true }
    } catch {
        $msg = $_.Exception.Message
        $userRows | ForEach-Object { $_.Error = "$($_.Error)$msg" }
        Write-Warning "$($s.SamAccountName): $msg"
    }
}

$report | Export-Csv $ReportPath -NoTypeInformation
$mode = if ($Apply) { 'APPLIED' } else { 'REPORT ONLY (use -Apply to write)' }
Write-Host "$mode - $(@($report).Count) differences across $(@($report | Select-Object -Unique ObjectGUID).Count) users -> $ReportPath"
$report | Group-Object Attribute | Sort-Object Count -Descending | Format-Table Name, Count -AutoSize
