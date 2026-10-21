#!/usr/bin/env powershell
# pre-push-guard.ps1 -- what git actually runs before a push
# (invoked by .githooks/pre-push; stdin ref list arrives via -RefFile).
#
# WHY: the scanner (.system/pre-push-scan.ps1) existed but no hook called
# it. Discipline was the only gate, and on 2026-10-21 the scanner was found
# RED on history that had already been pushed. This wires the scanner into
# the push path and adds the checks content scanning cannot cover, because
# the scanner reads words, not intent:
#
#   1. scanner        -- every commit, every detector, self-tested (hard gate)
#   2. baseline anchor -- a committed baseline change blocks the next push
#      until the owner appends a dated reason via audit-baseline.ps1.
#      Accepting findings must leave a trail; that is the whole point of
#      the agent-edit deny on the baseline file.
#   3. provenance     -- any `basis:` value changed inside the pushed range
#      is printed old -> new and recorded. Reported, not blocked: the gate's
#      job is to make owner edits visible, not to stop ordinary note work.
#   4. shadow notes   -- .md files inside the vault that git ignores; they
#      are invisible to `git status` and to every gate reading tracked files.
#   5. index drift    -- CORE.md wikilinks pointing at notes that do not exist.
#   6. gate digests   -- SHA-256 of the gate scripts rides in each audit
#      entry, so editing the grader later shows up as a diff in history.
#
# Honest ceiling: this makes silent skips and quiet edits EVIDENT, not
# impossible. The audit log is committed, so erasing an entry means
# rewriting pushed history -- which the whole-history scanner also sees.
#
# Exit 0 = push may proceed. Nonzero = push blocked. No bypass switch.

[CmdletBinding()]
param(
    [string]$RefFile = '',
    [switch]$NoAudit
)

$ErrorActionPreference = 'Continue'
$root    = Split-Path -Parent $PSScriptRoot
$audit   = Join-Path $root '.system\push-audit.jsonl'
$blocked = @()

function Write-Section([string]$t) { Write-Output ''; Write-Output "--- $t ---" }

Write-Output '=== pre-push guard ==='

# --- 1. scanner: whole history, self-tested ---------------------------------
Write-Section 'scanner: every commit, every detector'
$scan = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\.system\pre-push-scan.ps1'))
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scan
$scanRc = $LASTEXITCODE
if ($scanRc -ne 0) {
    $blocked += "scanner exit $scanRc -- findings or scanner-broken (details above)"
}

# --- 2. baseline anchor: accepted findings need a dated reason --------------
Write-Section 'baseline anchor: accepting findings must leave a trail'

function Read-AuditLog {
    # The whole log must parse. A damaged evidence log is a block, never a skip.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ Ok = $false; Error = 'missing'; Lines = @() }
    }
    $lines = @(); $n = 0
    foreach ($l in @(Get-Content -LiteralPath $Path)) {
        $n++
        if ([string]::IsNullOrWhiteSpace($l)) { continue }
        try   { $lines += [pscustomobject]@{ N = $n; Obj = ($l | ConvertFrom-Json) } }
        catch { return @{ Ok = $false; Error = "line $n does not parse"; Lines = @() } }
    }
    return @{ Ok = $true; Error = ''; Lines = $lines }
}

$anchorCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File .\audit-baseline.ps1 -Reason 'why accepting this change is right'"
$auditState = Read-AuditLog -Path $audit
$anchor = $null
if ($auditState.Ok) {
    foreach ($l in $auditState.Lines) {
        if ($l.Obj.kind -eq 'baseline-anchor') { $anchor = $l.Obj }
    }
}

$blob = & git -C $root rev-parse 'HEAD:.system/pre-push-baseline.json' 2>$null
if ($LASTEXITCODE -ne 0 -or -not $blob) {
    $blocked += 'cannot read the committed baseline blob -- broken repo?'
    $blob = ''
}
$blCount = -1
try {
    $blRaw = @(& git -C $root show 'HEAD:.system/pre-push-baseline.json' 2>$null) -join "`n"
    $blCount = @(($blRaw | ConvertFrom-Json).entries).Count
} catch { }
# The scanner reads the WORKING-TREE baseline; a push publishes the committed
# one. With a local edit the two counts differ -- show both, or the numbers in
# this report contradict the scanner's for no visible reason.
$wtCount = -1
$wtPath  = Join-Path $root '.system\pre-push-baseline.json'
if (Test-Path -LiteralPath $wtPath) {
    try { $wtCount = @(((Get-Content -LiteralPath $wtPath -Raw -ErrorAction Stop) | ConvertFrom-Json).entries).Count } catch { }
}

if (-not $auditState.Ok) {
    $blocked += "push-audit log $($auditState.Error) -- restore it (git checkout -- .system/push-audit.jsonl) or create it: $anchorCmd"
} elseif (-not $anchor) {
    $blocked += "no baseline anchor recorded yet -- owner runs: $anchorCmd"
} elseif ([string]$anchor.blob -ne [string]$blob) {
    $why = ''
    if ($anchor.PSObject.Properties['reason']) { $why = " (last anchor reason: '$($anchor.reason)')" }
    $blocked += "committed baseline changed since the anchor$why -- owner runs: $anchorCmd"
}
if ($anchor) {
    Write-Output "committed baseline : blob $blob, $blCount entries (what a push publishes)"
    Write-Output "working tree       : $wtCount entries (what the scanner reads now)"
    Write-Output "anchor on record   : blob $($anchor.blob), $($anchor.entries) entries, $($anchor.time)"
    if ($anchor.PSObject.Properties['reason']) { Write-Output "anchor reason      : $($anchor.reason)" }
} else {
    Write-Output 'anchor on record   : NONE'
}
if ($wtCount -ge 0 -and $blCount -ge 0 -and $wtCount -ne $blCount) {
    Write-Output "NOTE: the working-tree baseline differs from the committed one ($wtCount vs $blCount) -- commit or discard the local edit before trusting either count."
}

# --- 3. provenance: basis: changes inside the pushed range ------------------
Write-Section 'provenance: basis: changes in the pushed commits'
$flips = @()
$range = $null; $rangeSrc = ''
if ($RefFile -and (Test-Path -LiteralPath $RefFile)) {
    foreach ($line in @(Get-Content -LiteralPath $RefFile)) {
        $p = $line -split ' '
        if ($p.Count -ge 4) {
            $local = $p[1]; $remote = $p[3]
            if ($remote -match '^0+$') {
                # First push of this ref: no previous tip. Start from git's
                # empty tree -- additions only, so a flip still needs both
                # sides of a change to exist before it is reported.
                $range = '4b825dc642cb6eb9a060e54bf8d69288fbee4904..' + $local
                $rangeSrc = 'first push (empty remote)'
            } else {
                $range = "$remote..$local"
                $rangeSrc = 'ref list from git'
            }
            break
        }
    }
}
if (-not $range) {
    $up = & git -C $root rev-parse --abbrev-ref '@{upstream}' 2>$null
    if ($LASTEXITCODE -eq 0 -and $up) { $range = "$up..HEAD"; $rangeSrc = 'upstream fallback' }
}
if ($range) {
    Write-Output "range: $range ($rangeSrc)"
    $patch = @()
    $patch = @(& git -C $root log -p --format= -U0 $range -- '*.md' 2>$null)
    if ($LASTEXITCODE -ne 0) {
        Write-Output 'range not resolvable -- provenance report skipped for this push (visible, not silent).'
        $patch = @()
    }
    $cur = ''; $minus = @{}; $plus = @{}
    foreach ($l in $patch) {
        if ($l -match '^diff --git a/.+ b/(.+)$') {
            $cur = $Matches[1]
            if (-not $minus.ContainsKey($cur)) { $minus[$cur] = @(); $plus[$cur] = @() }
        } elseif ($cur -and $l -match '^-basis:[ \t]*(.+)$') {
            $minus[$cur] += $Matches[1].Trim()
        } elseif ($cur -and $l -match '^\+basis:[ \t]*(.+)$') {
            $plus[$cur] += $Matches[1].Trim()
        }
    }
    foreach ($f in @($minus.Keys)) {
        $old = @($minus[$f]); $new = @($plus[$f])
        if ($old.Count -and $new.Count) {
            $changed = $false
            foreach ($o in $old) { foreach ($n in $new) { if ($o -ne $n) { $changed = $true } } }
            if ($changed) { $flips += "$f : $($old -join ', ') -> $($new -join ', ')" }
        }
    }
} else {
    Write-Output 'no push range available -- provenance report skipped for this push (visible, not silent).'
}
if ($flips.Count) {
    Write-Output "CHANGED provenance in this push -- $($flips.Count):"
    $flips | ForEach-Object { Write-Output "  $_" }
    Write-Output 'Recorded in the audit entry. Owner: each flip above was yours to make -- confirm it was deliberate.'
} else {
    Write-Output 'no basis: value changed in the pushed range.'
}

# --- 4. shadow notes: .md files git ignores ---------------------------------
Write-Section 'shadow notes: md files git ignores'
$shadow = @(& git -C $root ls-files --others --ignored --exclude-standard -- '*.md' 2>$null)
if ($shadow.Count) {
    Write-Output "$($shadow.Count) ignored .md file(s) -- invisible to git status, invisible to gates that read tracked files:"
    $shadow | Select-Object -First 20 | ForEach-Object { Write-Output "  $_" }
    if ($shadow.Count -gt 20) { Write-Output "  ... and $($shadow.Count - 20) more" }
} else {
    Write-Output 'none.'
}

# --- 5. index drift: CORE.md wikilinks vs notes on disk ---------------------
Write-Section 'index drift: CORE.md links vs notes on disk'
$corePath = Join-Path $root 'CORE.md'
if (Test-Path -LiteralPath $corePath) {
    $names = @{}
    Get-ChildItem -LiteralPath $root -Recurse -Filter '*.md' -File |
        Where-Object { $_.FullName -notlike '*\.obsidian\*' -and $_.FullName -notlike '*\.trash\*' } |
        ForEach-Object { if (-not $names.ContainsKey($_.BaseName)) { $names[$_.BaseName] = $true } }
    $coreTxt = Get-Content -LiteralPath $corePath -Raw
    $all = @([regex]::Matches($coreTxt, '\[\[([^\[\]]+)\]\]'))
    $dangling = @()
    foreach ($m in $all) {
        $t = $m.Groups[1].Value
        if ($t -match '[|#]') { $t = ($t -split '[|#]')[0] }
        $t = $t.Trim()
        if ($t -and -not $names.ContainsKey($t)) { $dangling += $t }
    }
    if ($all.Count -eq 0)      { Write-Output 'CORE.md has no wikilinks.' }
    elseif ($dangling.Count)   {
        Write-Output "$($dangling.Count) of $($all.Count) CORE.md wikilinks point at no note:"
        $dangling | Select-Object -Unique | ForEach-Object { Write-Output "  [[$_]]" }
    }
    else                       { Write-Output "$($all.Count) wikilinks, all resolve." }
} else {
    Write-Output 'CORE.md MISSING -- the memory index is gone from the working tree.'
}

# --- 6. gate digests: tamper evidence for the grader itself -----------------
Write-Section 'gate digests (recorded in the audit entry)'
$gates = @('invariant-check.ps1', 'attack-mode.ps1', 'demo.ps1', '.system\pre-push-scan.ps1', '.system\attack-pack.ps1')
$gateMap = [ordered]@{}
foreach ($g in $gates) {
    $p = Join-Path $root $g
    if (Test-Path -LiteralPath $p) {
        $h = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()
        $gateMap[$g] = $h
        Write-Output ('  {0}  {1}' -f $h.Substring(0, 16), $g)
    } else {
        $gateMap[$g] = 'absent'
        Write-Output "  absent  $g"
    }
}

# --- audit entry + verdict ---------------------------------------------------
$verdict = if ($blocked.Count) { 'blocked' } else { 'pass' }
$time = (Get-Date).ToString("yyyy-MM-dd'T'HH:mm:sszzz")
$head = [string](& git -C $root rev-parse --short=12 HEAD 2>$null)

Write-Output ''
if ($NoAudit) {
    Write-Output 'audit entry: NOT written (-NoAudit verification run).'
} elseif (-not $auditState.Ok) {
    Write-Output "audit entry: NOT written -- push-audit log $($auditState.Error); this run left no trail."
} else {
    $entry = [ordered]@{
        kind            = 'run'
        time            = $time
        verdict         = $verdict
        head            = $head
        scannerExit     = $scanRc
        baselineBlob    = [string]$blob
        baselineEntries = $blCount
        anchorBlob      = if ($anchor) { [string]$anchor.blob } else { '' }
        flips           = @($flips)
        shadowMd        = @($shadow).Count
        blocked         = @($blocked)
        gates           = $gateMap
    }
    $json = $entry | ConvertTo-Json -Compress -Depth 4
    [IO.File]::AppendAllText($audit, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
    Write-Output "audit entry: recorded (verdict $verdict) in .system/push-audit.jsonl"
}

Write-Output ''
if ($blocked.Count) {
    Write-Output "VERDICT: BLOCKED -- $($blocked.Count) reason(s):"
    $blocked | ForEach-Object { Write-Output "  - $_" }
    Write-Output 'Push refused. This guard does not get to decide what is acceptable -- the owner does.'
    exit 1
}
Write-Output 'VERDICT: OK -- scanner clean, baseline anchored, reports above recorded.'
exit 0
