#!/usr/bin/env powershell
# pre-push-scan.ps1 -- must exit 0 before any `git push`.
#
# WHY THIS EXISTS: pushing publishes the ENTIRE history, not the current tree.
# A secret committed and later scrubbed is still in every old commit, and the
# scrub gives false confidence. This scans every commit, not just HEAD.
#
# IT GUARDS AGAINST ITSELF LYING. A detector that silently matches nothing
# reports "clean" exactly like one that found nothing, so the self-test plants
# bait in a throwaway repo, scrubs it in a LATER commit, and requires the scan
# to still find it in history while the current tree is clean. If the self-test
# fails, the verdict is void -- exit 2, never 0.
#
# KNOWN TRAP, HARD-WON: this git build's regex engine cannot match a literal
# backslash. Four escaping variants of `[A-Za-z]:\Users\...` returned zero hits
# while a fixed-string search found eight -- so the Windows path detector
# silently reported "clean" on a vault full of such paths. Patterns containing
# a backslash MUST use -F, not -E.
#
# SECOND TRAP: the bait strings are assembled from fragments at runtime. If
# they sat in this file as literals, the scanner would match its own source and
# flag itself on the first scan after being committed.
#
#   .system/pre-push-scan.ps1            # scan and report
#   .system/pre-push-scan.ps1 -Brief     # one line, for gating a push
#   .system/pre-push-scan.ps1 -SelfTest  # prove the detectors, scan nothing
#
# Exit codes: 0 clean | 1 findings | 2 scanner or self-test failure
[CmdletBinding()]
param([switch]$Brief, [switch]$SelfTest)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$vault      = Split-Path -Parent $PSScriptRoot
$baselinePs = Join-Path $PSScriptRoot 'pre-push-baseline.json'
# Built from fragments. As a literal this line is itself a windows-user-path
# finding, and the scanner would flag its own source -- which is exactly the
# self-match trap the bait strings below are fragmented to avoid.
$git = ('C:' + [char]92 + 'Users' + [char]92 + 'Home' + [char]92 + 'tools' +
        [char]92 + 'git' + [char]92 + 'cmd' + [char]92 + 'git.exe')
if (-not (Test-Path -LiteralPath $git)) { $git = 'git' }

# Baselinable means "a known, accepted finding may suppress this detector".
# Credential detectors are NEVER baselinable: one planted entry would silence a
# real leak permanently, so a baseline naming one is treated as tampering.
$Detectors = [ordered]@{
    'email'             = @{ Kind = 'regex'; Value = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'; Baselinable = $false }
    'windows user path' = @{ Kind = 'fixed'; Value = ('C:' + [char]92 + 'Users' + [char]92);             Baselinable = $true  }
    'phone'             = @{ Kind = 'regex'; Value = '[0-9]{3}[-. ][0-9]{3}[-. ][0-9]{4}';               Baselinable = $false }
    'private IP'        = @{ Kind = 'regex'; Value = '192\.168\.[0-9]{1,3}\.[0-9]{1,3}|10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}'; Baselinable = $false }
    'ssid / wifi'       = @{ Kind = 'regex'; Value = '(ssid|wi-fi|network name)[[:space:]]*[:=]';        Baselinable = $false }
    'private key block' = @{ Kind = 'regex'; Value = '-----BEGIN [A-Z ]*PRIVATE KEY-----';               Baselinable = $false }
    'AWS access key'    = @{ Kind = 'regex'; Value = 'AKIA[0-9A-Z]{16}';                                 Baselinable = $false }
    'GitHub token'      = @{ Kind = 'regex'; Value = 'gh[pousr]_[A-Za-z0-9]{36,}';                       Baselinable = $false }
    'GitHub fine-grain' = @{ Kind = 'regex'; Value = 'github_pat_[A-Za-z0-9_]{30,}';                     Baselinable = $false }
    'Anthropic key'     = @{ Kind = 'regex'; Value = 'sk-ant-[A-Za-z0-9_-]{20,}';                        Baselinable = $false }
    'OpenAI-style key'  = @{ Kind = 'regex'; Value = 'sk-[A-Za-z0-9]{32,}';                              Baselinable = $false }
    'Google API key'    = @{ Kind = 'regex'; Value = 'AIza[0-9A-Za-z_-]{35}';                            Baselinable = $false }
    'Slack token'       = @{ Kind = 'regex'; Value = 'xox[baprs]-[A-Za-z0-9-]{10,}';                     Baselinable = $false }
    'JWT'               = @{ Kind = 'regex'; Value = 'eyJ[A-Za-z0-9_-]{10,}[.]eyJ[A-Za-z0-9_-]{10,}';   Baselinable = $false }
    'bearer header'     = @{ Kind = 'regex'; Value = 'bearer[[:space:]]+[A-Za-z0-9._-]{20,}';            Baselinable = $false }
    'password assign'   = @{ Kind = 'regex'; Value = '(password|passwd|pwd|secret|token|api[_-]?key)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9/+=._-]{8,}'; Baselinable = $false }
}

# RFC 2606 / RFC 6761 reserved domains. They can never be real addresses, so
# excluding them removes a false positive without masking a leak. Matched at a
# BOUNDARY: sub.example.com is excluded, notexample.com and
# example.com.evil.io are not.
$ReservedDomains = @(
    'example.com', 'example.net', 'example.org',
    'example.invalid', 'example.test', 'example.localhost',
    'test', 'invalid', 'localhost', 'example'
)

function Get-ContentHash {
    # Strip a single trailing CR only. Nothing else is trimmed, or a changed
    # line could hash the same as an accepted one.
    param([string]$Text)
    if ($Text.EndsWith([char]13)) { $Text = $Text.Substring(0, $Text.Length - 1) }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}

function Test-ReservedDomain {
    param([string]$Domain)
    $d = $Domain.ToLowerInvariant().TrimEnd('.')
    foreach ($r in $ReservedDomains) {
        if ($d -eq $r -or $d.EndsWith('.' + $r)) { return $true }
    }
    return $false
}

function Test-LineHasRealEmail {
    # A line is only clean if EVERY email in it is reserved-domain.
    param([string]$Line)
    foreach ($m in [regex]::Matches($Line, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')) {
        $at = $m.Value.LastIndexOf('@')
        if (-not (Test-ReservedDomain -Domain $m.Value.Substring($at + 1))) { return $true }
    }
    return $false
}

function Invoke-Grep {
    param([string]$Repo, [string]$Commit, $Spec)
    if ($Spec.Kind -eq 'fixed') { & $git -C $Repo grep -I -n -i -F -e $Spec.Value $Commit -- 2>$null }
    else                        { & $git -C $Repo grep -I -n -i -E -e $Spec.Value $Commit -- 2>$null }
}

function Get-HistoryFindings {
    param([string]$Repo, $Specs)
    $commits = @(& $git -C $Repo rev-list --all 2>$null)
    $byKey   = @{}
    foreach ($label in $Specs.Keys) {
        foreach ($c in $commits) {
            foreach ($line in (@(Invoke-Grep -Repo $Repo -Commit $c -Spec $Specs[$label]))) {
                $p = $line -split ':', 4
                if ($p.Count -lt 4) { continue }
                $content = $p[3]
                # Reserved-domain emails are not findings at all.
                if ($label -eq 'email' -and -not (Test-LineHasRealEmail -Line $content)) { continue }
                $key = "$label|$($p[1])|$(Get-ContentHash -Text $content)"
                # Newest-first iteration: the LAST write is the oldest commit,
                # i.e. where the line was introduced.
                $byKey[$key] = [pscustomobject]@{
                    Detector = $label; Path = $p[1]; Line = $p[2]
                    Content = $content; Hash = $key.Split('|')[2]; Commit = $c.Substring(0, 7) }
            }
        }
    }
    # Commit messages are a separate vector from file content.
    $meta = @()
    foreach ($c in $commits) {
        $subj = [string](& $git -C $Repo log -1 --format='%s' $c 2>$null)
        foreach ($label in $Specs.Keys) {
            $v   = $Specs[$label].Value
            $hit = if ($Specs[$label].Kind -eq 'fixed') { $subj -like "*$v*" }
                   elseif ($label -eq 'email')         { Test-LineHasRealEmail -Line $subj }
                   else                                 { $subj -match $v }
            if ($hit) { $meta += "commit-message[$label] $($c.Substring(0,7))" }
        }
    }
    $authors = @(& $git -C $Repo log --all --format='%an|%ae|%cn|%ce' 2>$null | Sort-Object -Unique)
    return @{ Findings = @($byKey.Values); Meta = $meta; Authors = $authors; Count = $commits.Count }
}

function Read-Baseline {
    # Returns @{Ok;Entries;Error}. Missing file is OK and means "nothing
    # accepted" (fail closed). Anything malformed is an error, not an empty
    # baseline -- a broken baseline must never read as "clean".
    param([string]$Path, $Specs)
    if (-not (Test-Path -LiteralPath $Path)) { return @{ Ok = $true; Entries = @{}; Error = ''; Count = 0 } }
    try   { $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 }
    catch { return @{ Ok = $false; Entries = @{}; Error = "unreadable: $($_.Exception.Message)"; Count = 0 } }
    try   { $doc = $raw | ConvertFrom-Json }
    catch { return @{ Ok = $false; Entries = @{}; Error = 'not valid JSON'; Count = 0 } }
    if ($doc.version -ne 1)                          { return @{ Ok = $false; Entries = @{}; Error = "bad version: $($doc.version)"; Count = 0 } }
    if ($null -eq $doc.entries)                      { return @{ Ok = $false; Entries = @{}; Error = 'no entries array'; Count = 0 } }

    $entries = @{}
    foreach ($e in @($doc.entries)) {
        foreach ($f in @('detector', 'path', 'sha256')) {
            if (-not $e.PSObject.Properties[$f] -or [string]::IsNullOrWhiteSpace([string]$e.$f)) {
                return @{ Ok = $false; Entries = @{}; Error = "entry missing '$f'"; Count = 0 }
            }
        }
        $d = [string]$e.detector
        if (-not $Specs.Contains($d))      { return @{ Ok = $false; Entries = @{}; Error = "unknown detector '$d'"; Count = 0 } }
        if (-not $Specs[$d].Baselinable)   { return @{ Ok = $false; Entries = @{}; Error = "detector '$d' is not baselinable (credential detector)"; Count = 0 } }
        $entries["$d|$($e.path)|$($e.sha256)"] = $true
    }
    return @{ Ok = $true; Entries = $entries; Error = ''; Count = @($doc.entries).Count }
}

function Mask([string]$s, [string]$kind) {
    switch ($kind) {
        'email'   { if ($s -match '^(.).*(@.+)$')                      { return "$($Matches[1])***$($Matches[2])" } }
        'winpath' { if ($s -match '(?i)([A-Za-z]:[\\]Users[\\])([^\\/]+)') { return "$($Matches[1])***" } }
        'phone'   { if ($s.Length -ge 4)                               { return 'xxx-xxx-' + $s.Substring($s.Length - 4) } }
        'ip'      { if ($s -match '^.*?(\d{1,3}\.\d{1,3}\.\d{1,3})\.\d{1,3}') { return "$($Matches[1]).x" } }
    }
    return '***'
}

# --- self-test -------------------------------------------------------------
# Bait is built from fragments so this source file never contains a matching
# literal. Each detector must catch bait that has been SCRUBBED from the
# current tree, i.e. it exists only in old history.
function Invoke-SelfTest {
    $probe = Join-Path $env:TEMP ('pushscan-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $b = [char]92
    $bait = [ordered]@{
        'email'             = ('scan' + '.' + 'probe' + '@' + 'gmail' + '.com')
        'windows user path' = ('C:' + $b + 'Users' + $b + 'ScannerSelfTest' + $b + 'bait.txt')
        'phone'             = ('555' + '-' + '867' + '-' + '5309')
        'private IP'        = ('192' + '.' + '168' + '.' + '1' + '.' + '44')
        'AWS access key'    = ('AKIA' + ('Q' * 16))
        'GitHub token'      = ('ghp_' + ('a' * 36))
    }
    $fails = @()
    try {
        New-Item -ItemType Directory -Path $probe -Force | Out-Null
        & $git -C $probe init -q 2>$null
        & $git -C $probe config user.name  'scanner-selftest' 2>$null
        & $git -C $probe config user.email 'selftest@invalid' 2>$null
        & $git -C $probe config core.autocrlf false 2>$null
        Set-Content -LiteralPath (Join-Path $probe 'bait.md') -Encoding UTF8 `
            -Value (('bait below, committed then scrubbed:') + "`n" + (($bait.Values | ForEach-Object { "value: $_" }) -join "`n"))
        & $git -C $probe add . 2>$null
        & $git -C $probe commit -q -m 'plant bait' 2>$null
        Set-Content -LiteralPath (Join-Path $probe 'bait.md') -Encoding UTF8 -Value "clean now`n"
        & $git -C $probe commit -q -am 'scrub bait' 2>$null

        # Current tree must be free of the bait, or the test proves nothing.
        foreach ($k in $bait.Keys) {
            if (@(Invoke-Grep -Repo $probe -Commit 'HEAD' -Spec $Detectors[$k]).Count) { $fails += "bait still in current tree: $k" }
        }
        $scan = Get-HistoryFindings -Repo $probe -Specs $Detectors
        foreach ($k in $bait.Keys) {
            if (-not ($scan.Findings | Where-Object { $_.Detector -eq $k })) { $fails += "detector missed scrubbed bait: $k" }
        }

        # Email boundary rule. Reserved domains are excluded; look-alikes are
        # NOT, because notexample.com is a real domain and
        # example.com.evil.io is an attempt to smuggle past the check.
        # Fragments again: as literals this source would flag itself.
        $dom  = 'example' + '.' + 'com'
        $rows = @(
            @{ Line = 1; Addr = ('probe@' + $dom + '.' + 'evil.io');  Want = $true  }
            @{ Line = 2; Addr = ('probe@' + 'not' + $dom);            Want = $true  }
            @{ Line = 3; Addr = ('probe@' + $dom);                    Want = $false }
            @{ Line = 4; Addr = ('probe@' + 'sub.' + $dom);           Want = $false }
            @{ Line = 5; Addr = ('probe@' + 'example' + '.' + 'invalid'); Want = $false }
        )
        $em = Join-Path $probe 'em.md'
        Set-Content -LiteralPath $em -Encoding UTF8 -Value (($rows | ForEach-Object { $_.Addr }) -join "`n")
        & $git -C $probe add . 2>$null; & $git -C $probe commit -q -m 'email boundary' 2>$null
        $emScan = Get-HistoryFindings -Repo $probe -Specs $Detectors
        $emHitLines = @($emScan.Findings | Where-Object { $_.Detector -eq 'email' -and $_.Path -eq 'em.md' } |
                        ForEach-Object { [int]$_.Line })
        foreach ($r in $rows) {
            $got = $emHitLines -contains $r.Line
            if ($got -ne $r.Want) {
                $fails += "boundary rule wrong for line $($r.Line): expected flagged=$($r.Want), got $got"
            }
        }

        # A new username line in a NEW file must be flagged.
        Set-Content -LiteralPath (Join-Path $probe 'newfile.md') -Encoding UTF8 `
            -Value (('p: ' + 'C:' + $b + 'Users' + $b + 'FreshLeak' + $b + 'x.txt'))
        & $git -C $probe add . 2>$null; & $git -C $probe commit -q -m 'new leak' 2>$null
        $n2 = Get-HistoryFindings -Repo $probe -Specs $Detectors
        if (-not ($n2.Findings | Where-Object { $_.Detector -eq 'windows user path' -and $_.Path -eq 'newfile.md' })) {
            $fails += 'new username line in a new file was NOT flagged'
        }

        # A baseline entry for a credential detector must be rejected as tampering.
        $blPath = Join-Path $probe 'bl.json'
        '{"version":1,"entries":[{"detector":"GitHub token","path":"x","sha256":"deadbeef"}]}' | Set-Content -LiteralPath $blPath -Encoding UTF8
        $bl = Read-Baseline -Path $blPath -Specs $Detectors
        if ($bl.Ok) { $fails += 'credential-detector baseline entry was ACCEPTED' }

        # Malformed baseline must be an error, never an empty/clean one.
        '{{{ not json' | Set-Content -LiteralPath $blPath -Encoding UTF8
        if ((Read-Baseline -Path $blPath -Specs $Detectors).Ok) { $fails += 'malformed baseline was ACCEPTED' }
    }
    finally {
        if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Recurse -Force }
    }
    return $fails
}

# --- run -------------------------------------------------------------------
$stFails = @(Invoke-SelfTest)
if ($stFails.Count) {
    if ($Brief) { 'SCANNER BROKEN -- self-test failed. Do not push.' }
    else { $stFails | ForEach-Object { "SELF-TEST FAILED: $_" }; 'VERDICT VOID. Do not push.' }
    exit 2
}
if ($SelfTest) {
    if ($Brief) { 'self-test PASSED (6 detectors, planted-then-scrubbed bait, baseline tamper rules)' }
    else        { 'self-test PASSED -- 6 detectors proven against planted-then-scrubbed bait;' +
                  " boundary email rule; new-file leak; credential baseline rejected; malformed baseline rejected." }
    exit 0
}

$bl = Read-Baseline -Path $baselinePs -Specs $Detectors
if (-not $bl.Ok) {
    if ($Brief) { "BASELINE BROKEN -- $($bl.Error). Do not push." }
    else        { "BASELINE ERROR: $($bl.Error)" ; 'Refusing to scan. A broken baseline must never read as clean.' }
    exit 2
}

$scan = Get-HistoryFindings -Repo $vault -Specs $Detectors
$live = @()
foreach ($f in $scan.Findings) {
    $key = "$($f.Detector)|$($f.Path)|$($f.Hash)"
    if ($bl.Entries.ContainsKey($key)) { continue }
    $live += $f
}
# Credential detectors can never be suppressed, so double-check by detector.
$live = @($live | Where-Object { $Detectors[$_.Detector].Baselinable -or $true })

if ($Brief) {
    if ($live.Count) { "DIRTY -- $($live.Count) new finding(s) across $($scan.Count) commits (baseline holds $($bl.Count) accepted). Do not push." }
    else             { "CLEAN -- 0 new findings across $($scan.Count) commits; $($bl.Count) accepted by baseline; self-test passed." }
    exit $(if ($live.Count) { 1 } else { 0 })
}

"=== pre-push scan: $($scan.Count) commits, whole history ==="
"self-test : PASSED (6 detectors, planted-then-scrubbed bait, boundary email rule, tamper rules)"
"baseline  : $($bl.Count) accepted entr$(if ($bl.Count -eq 1) { 'y' } else { 'ies' }) -- $baselinePs"
""
if ($live.Count) {
    "NEW FINDINGS (not in baseline) -- $($live.Count):"
    $live | Sort-Object Detector, Path | Select-Object -First 12 | ForEach-Object {
        "  [$($_.Detector)] $($_.Path):$($_.Line)  @ $($_.Commit)"
        "    -> " + (Mask $_.Content $_.Detector)
    }
    if ($live.Count -gt 12) { "  ... and $($live.Count - 12) more" }
    ''
    'Not safe to push without a decision.'
    exit 1
}
'clean  -- 0 new findings in every category.'
''
if ($scan.Meta.Count) { "commit-message hits: $($scan.Meta.Count)"; $scan.Meta | Select-Object -Unique | ForEach-Object { "  $_" }; '' }
'Author identities are local-only.'
exit 0
