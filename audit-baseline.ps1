#!/usr/bin/env powershell
# audit-baseline.ps1 -- the sanctioned way to anchor a baseline change.
#
# WHY: the push baseline (.system/pre-push-baseline.json) decides which
# findings are "accepted". Editing it without a recorded reason is exactly
# the rubber stamp the agent-edit deny exists to stop. This script never
# edits the baseline -- it appends the committed baseline's identity plus
# YOUR reason to the append-only .system/push-audit.jsonl. The pre-push
# guard blocks any push whose committed baseline has no matching anchor.
#
# Order of operations: edit the baseline, commit it, run this, push.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\audit-baseline.ps1 `
#       -Reason "why accepting these findings is correct"
#
# Honest ceiling: a reason can be written lazily -- evidence, not
# invincibility. What cannot happen silently is the ABSENCE of one: every
# anchor records a timestamp, the exact baseline blob it blesses, and the
# words you gave.

#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Reason
)

$ErrorActionPreference = 'Continue'
$Reason = $Reason.Trim()
if ($Reason.Length -lt 8) {
    Write-Output 'REASON too short -- say WHY accepting this change is right (8+ characters).'
    exit 1
}

$root   = $PSScriptRoot
$audit  = Join-Path $root '.system\push-audit.jsonl'
$blRel  = '.system/pre-push-baseline.json'

$blob = & git -C $root rev-parse "HEAD:$blRel" 2>$null
if ($LASTEXITCODE -ne 0 -or -not $blob) {
    Write-Output 'ERROR: cannot read the committed baseline blob -- run this inside the vault repo.'
    exit 2
}

# The committed baseline must parse; anchoring garbage would read as an
# acceptance of anything.
$raw = @(& git -C $root show "HEAD:$blRel" 2>$null) -join "`n"
$entries = -1
try {
    $doc = $raw | ConvertFrom-Json
    if ($doc.version -ne 1) { throw "version $($doc.version)" }
    if ($null -eq $doc.entries) { throw 'no entries array' }
    $entries = @($doc.entries).Count
} catch {
    Write-Output "REJECTED: committed baseline does not parse ($($_.Exception.Message))."
    Write-Output 'A broken baseline must never read as accepted -- fix it first.'
    exit 2
}

$lastBlob = $null; $lastReason = ''; $lastEntries = $null; $corrupt = ''
if (Test-Path -LiteralPath $audit) {
    $n = 0
    foreach ($l in @(Get-Content -LiteralPath $audit)) {
        $n++
        if ([string]::IsNullOrWhiteSpace($l)) { continue }
        try   { $o = $l | ConvertFrom-Json }
        catch { $corrupt = "line $n"; break }
        if ($o.kind -eq 'baseline-anchor') {
            $lastBlob    = [string]$o.blob
            $lastReason  = [string]$o.reason
            $lastEntries = $o.entries
        }
    }
}
if ($corrupt) {
    Write-Output "REJECTED: push-audit log damaged at $corrupt -- restore it (git checkout -- .system/push-audit.jsonl) before anchoring."
    exit 2
}

if ($lastBlob -eq $blob) {
    Write-Output "already anchored: baseline blob $blob ($entries entries)."
    Write-Output "anchor reason: $lastReason"
    exit 0
}

$delta = ''
if ($null -ne $lastEntries) {
    $d = $entries - [int]$lastEntries
    if     ($d -gt 0) { $delta = " (+$d vs last anchor)" }
    elseif ($d -lt 0) { $delta = " ($d vs last anchor)" }
    else              { $delta = ' (same entry count as last anchor)' }
}

# An uncommitted baseline edit is not what the push will publish -- say so.
& git -C $root diff --quiet HEAD -- $blRel 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Output 'NOTE: the working-tree baseline differs from HEAD -- commit your edit first, then anchor, so the anchor matches what will be pushed.'
}

$head = [string](& git -C $root rev-parse --short=12 HEAD 2>$null)
$time = (Get-Date).ToString("yyyy-MM-dd'T'HH:mm:sszzz")
$entry = [ordered]@{
    kind    = 'baseline-anchor'
    time    = $time
    head    = $head
    blob    = [string]$blob
    entries = $entries
    reason  = $Reason
}
$json = $entry | ConvertTo-Json -Compress -Depth 3
[IO.File]::AppendAllText($audit, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))

Write-Output 'anchored:'
Write-Output "  blob    $blob"
Write-Output "  entries $entries$delta"
Write-Output "  head    $head"
Write-Output "  reason  $Reason"
Write-Output 'recorded in .system/push-audit.jsonl -- the baseline gate will pass this state now.'
exit 0
