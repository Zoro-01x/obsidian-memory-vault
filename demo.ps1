#requires -Version 5.1
<#
demo.ps1 -- the LIVE demo. One command, everything runs now.

WHY THIS EXISTS
    A transcript proves nothing: anyone can paste green output. This script
    builds a FRESH CLONE of the pushed commit into %TEMP% and runs every suite
    against that clone, live, in front of whoever is watching. Nothing in the
    working directory is special; nothing is pre-computed. If a suite would
    fail on a clean clone, it fails here, on screen.

    The last phase is the one that matters most: it REINTRODUCES THE REAL
    DEFECT this project originally shipped (a case-insensitive vocabulary
    guard), shows the suite going RED with named assertions, then restores the
    file and shows GREEN again. That is the difference between a test suite
    and a rubber stamp, demonstrated instead of claimed.

WHAT IT TOUCHES
    A throwaway clone under %TEMP% and throwaway scratch vaults under %TEMP%,
    which the suites create and remove themselves. The real vault is never a
    write target: every suite compares the clone against itself, and the
    adversarial demo asserts its vault's HEAD is unchanged. Nothing is pushed.

USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File demo.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File demo.ps1 -Quick
    powershell -NoProfile -ExecutionPolicy Bypass -File demo.ps1 -Keep

    -Quick   skips the five supporting suites; runs registry + adversarial
             + with/without + the sabotage phase (~2-3 min instead of ~6).
    -Keep    leaves the clone in %TEMP% so a watcher can inspect it.
    -Source  clone from a different URL (defaults to the GitHub repo).

HONESTY NOTES
    - The default clone source is the GITHUB repo, so the demo tests exactly
      the pushed commit, independent of anything on this disk. If GitHub is
      unreachable, it falls back to the local repo -- LOUDLY, with the clone
      source printed, never as a silent substitution.
    - The pre-push secret scanner is NOT part of this demo; run it separately
      (.system/pre-push-scan.ps1) to see its verdict. It is called out in the
      demo output rather than hidden.
    - Exit code 0 means every phase behaved as EXPECTED, including the
      sabotage being caught. A suite that stayed green after the guard was
      broken is a demo FAILURE, loudly.
#>
param(
    [switch]$Quick,
    [switch]$Keep,
    [string]$Source = ''
)

$ErrorActionPreference = 'Continue'
$d0        = Get-Date
$failures  = New-Object System.Collections.Generic.List[string]
$gitExe    = 'git'
$cloneRoot = Join-Path $env:TEMP ('vault-demo-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Banner([string]$Title) {
    Write-Host ''
    Write-Host ('=' * 78)
    Write-Host "  $Title"
    Write-Host ('=' * 78)
}
function Note([string]$Text) { Write-Host "    $Text" }
function Fail([string]$Text) {
    $failures.Add($Text)
    Write-Host "    [DEMO FAILURE] $Text" -ForegroundColor Red
}

# --- phase 0: preflight ------------------------------------------------------
Banner 'PHASE 0 -- PREFLIGHT'
$repoRoot = & $gitExe -C $PSScriptRoot rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0 -or -not $repoRoot) {
    Fail 'this script must live inside a git checkout (could not resolve repo root)'
    Write-Host 'Cannot continue without a repository to clone.'; exit 1
}
$githubUrl = 'https://github.com/Zoro-01x/obsidian-memory-vault.git'
if (-not $Source) { $Source = $githubUrl }
$originMain = (& $gitExe -C $repoRoot rev-parse origin/main 2>$null | Select-Object -First 1)
Note ("local repo    : $repoRoot")
Note ("origin/main   : $originMain  (last fetch/push view)")
Note ''
Note 'CLONE SOURCE, in order of preference:'
Note "  1. $Source"
Note '     Cloning from GitHub live is the strongest receipt: the demo then'
Note '     tests EXACTLY the pushed commit, independent of anything on this disk.'
if ($Source -eq $githubUrl) {
    Note '  2. fallback: the local repo path (used only if GitHub is unreachable;'
    Note '     the output says LOUDLY which source was used -- no silent substitution).'
}
$nodeOk = $null -ne (Get-Command node -ErrorAction SilentlyContinue)
Note ''
Note ("node          : $(if ($nodeOk) { 'found' } else { 'MISSING -- node suites will fail' })")
Note ("mode          : $(if ($Quick) { 'quick (registry + story + claim + sabotage)' } else { 'full (all 7 suites + story + claim + sabotage)' })")
Note ''
Note 'Nothing below is pre-computed. Every command runs now against a fresh clone.'

# --- phase 1: fresh clone ----------------------------------------------------
Banner 'PHASE 1 -- FRESH CLONE (built by git, not by me)'
$t = Get-Date
Note "git clone $Source -> $cloneRoot"
& $gitExe clone $Source $cloneRoot 2>$null | ForEach-Object { Write-Host "    $_" }
$cloneVia = $Source
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $cloneRoot)) {
    Write-Host ''
    Note "GitHub clone FAILED (exit $LASTEXITCODE) -- offline or credentials gone."
    Note 'FALLING BACK to the LOCAL repo. The demo now tests the local HEAD,'
    Note 'not the pushed commit. This substitution is printed, never silent.'
    if (Test-Path -LiteralPath $cloneRoot) { & cmd /c "rmdir /s /q `"$cloneRoot`"" 2>$null }
    & $gitExe clone $repoRoot $cloneRoot 2>$null | ForEach-Object { Write-Host "    $_" }
    $cloneVia = "$repoRoot (LOCAL FALLBACK)"
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $cloneRoot)) {
        Fail 'both clone sources failed'
        Write-Host 'Cannot continue without a clone.'; exit 1
    }
}
Note "cloned via    : $cloneVia"
$cloneHead = (& $gitExe -C $cloneRoot rev-parse HEAD 2>$null | Select-Object -First 1)
Note "clone HEAD    : $cloneHead"
if ($cloneVia -eq $githubUrl) {
    if ($cloneHead -eq $originMain) { Note 'matches origin/main -- this demo tests exactly what is pushed.' }
    else { Fail "clone HEAD ($cloneHead) != origin/main ($originMain) -- pushed view is stale; refetch and rerun." }
} else {
    if ($cloneHead -eq $originMain) { Note 'local HEAD == origin/main, so the local fallback still tests the pushed commit.' }
    else { Note "local HEAD differs from origin/main -- the fallback tests LOCAL HEAD; commits beyond origin/main ARE in this clone." }
}
Note ("took $([int]((Get-Date) - $t).TotalSeconds)s")

# --- helper: run one suite, stream its output live ---------------------------
# Results go into $suiteResults (script scope), never through the pipeline:
# capturing a function's output would also capture the native commands' stdout
# inside it, and the live streaming this demo depends on would be swallowed.
$script:suiteResults = [ordered]@{}
function Invoke-Suite {
    param([string]$Name, [string]$Kind, [string]$RelPath, [string]$SkipIn)
    if ($Quick -and $SkipIn -eq 'quick') { Write-Host "  -- skipped in -Quick: $Name"; $script:suiteResults[$Name] = 'skipped'; return }
    Write-Host ''
    Write-Host "  >> $Name" -ForegroundColor Cyan
    $t = Get-Date
    $file = Join-Path $cloneRoot $RelPath
    if (-not (Test-Path -LiteralPath $file)) { Fail "$Name -- missing script $RelPath in clone"; $script:suiteResults[$Name] = 'missing'; return }
    if ($Kind -eq 'node') { & node $file }
    else                  { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $file }
    $code = $LASTEXITCODE
    $secs = [int]((Get-Date) - $t).TotalSeconds
    if ($code -eq 0) {
        Write-Host "  << $Name -- exit 0 (${secs}s)" -ForegroundColor Green
        $script:suiteResults[$Name] = "ok (${secs}s)"
    } else {
        Fail "$Name exited $code"
        Write-Host "  << $Name -- exit $code (${secs}s)" -ForegroundColor Red
        $script:suiteResults[$Name] = "FAILED exit $code"
    }
}

# --- phase 2: every suite, against the clone ---------------------------------
Banner 'PHASE 2 -- THE SUITES (run against the clone, output streaming live)'
$suites = @(
    @{ n = 'registry-test (97 assertions: closed vocabularies, guards, consumers)'; k = 'ps1';  p = '.system/registry-test.ps1';           q = '' }
    @{ n = 'verify-test (77 assertions: frozen probes, evidence log)'              ; k = 'ps1';  p = '.system/verify-test.ps1';             q = 'quick' }
    @{ n = 'write-validation-test (37 assertions: write-path guards)'              ; k = 'ps1';  p = '.system/write-validation-test.ps1';   q = 'quick' }
    @{ n = 'native-stderr-test (18 assertions: stderr does not become data)'       ; k = 'ps1';  p = '.system/native-stderr-test.ps1';     q = 'quick' }
    @{ n = 'smoke-test (17 assertions: MCP server end-to-end)'                     ; k = 'node'; p = '.system/smoke-test.mjs';             q = 'quick' }
    @{ n = 'cold-start-test (8 assertions: wrapper starts cold)'                    ; k = 'node'; p = '.system/cold-start-test.mjs';        q = 'quick' }
)
foreach ($s in $suites) { Invoke-Suite -Name $s.n -Kind $s.k -RelPath $s.p -SkipIn $s.q }

# --- phase 3: the adversarial story ------------------------------------------
Banner 'PHASE 3 -- ADVERSARIAL DEMO (the story: seed, launder, promote, contradict, supersede)'
Invoke-Suite -Name 'adversarial-demo-test (32 assertions)' -Kind 'ps1' -RelPath '.system/adversarial-demo-test.ps1'

# --- phase 4: the claim ------------------------------------------------------
Banner 'PHASE 4 -- DOES MEMORY CHANGE THE ANSWER? (same task, one variable)'
Invoke-Suite -Name 'demo-with-without (memory present vs absent)' -Kind 'node' -RelPath '.system/demo-with-without.mjs'

# --- phase 5: break it live, watch it get caught -----------------------------
Banner 'PHASE 5 -- SABOTAGE (reintroduce the real historical defect, on purpose)'
$libPath = Join-Path $cloneRoot '.system\vault-lib.ps1'
$anchor  = "-cnotin `$script:ValidStatus"
$broken  = "-notin `$script:ValidStatus"
Note 'The defect: the status guards were once case-INSENSITIVE (-notin), so'
Note "'Status: Active' was accepted and the note silently left every vocabulary."
Note 'Flipping BOTH status guards back in the clone now...'

$libText  = [System.IO.File]::ReadAllText($libPath)
$occ      = 0; $idx = 0
while (($idx = $libText.IndexOf($anchor, $idx)) -ge 0) { $occ++; $idx += $anchor.Length }
if ($occ -ne 2) {
    Fail "sabotage anchor appeared $occ times (expected exactly 2: Test-VaultData + New-VaultNote) -- refusing to guess. Demo cannot prove the catch."
} else {
    [System.IO.File]::WriteAllText($libPath, $libText.Replace($anchor, $broken))
    Note 'guards are now case-insensitive. Re-running registry-test -- it MUST go red:'
    Write-Host ''
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $cloneRoot '.system\registry-test.ps1')
    $redCode = $LASTEXITCODE
    Write-Host ''
    if ($redCode -eq 0) {
        Fail 'registry-test stayed GREEN after the guard was broken -- the suite is a rubber stamp. THIS IS THE WORST OUTCOME AND IT IS REPORTED, NOT HIDDEN.'
    } else {
        Note "registry-test exited $redCode -- the broken guard was CAUGHT, with the failing assertion names above."
        Note 'Restoring the file from the clone git state and re-running:'
        & $gitExe -C $cloneRoot checkout -- '.system/vault-lib.ps1' 2>$null
        if ($LASTEXITCODE -ne 0) { Fail 'git checkout restore failed' }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $cloneRoot '.system\registry-test.ps1')
        $greenCode = $LASTEXITCODE
        Write-Host ''
        if ($greenCode -eq 0) { Note 'GREEN again. Same commit, same machine -- the only variable was the guard.' }
        else { Fail "registry-test exited $greenCode after restore -- expected 0" }
    }
}

# --- phase 6: verdict --------------------------------------------------------
Banner 'PHASE 6 -- VERDICT'
$cloneHeadAfter = (& $gitExe -C $cloneRoot rev-parse HEAD 2>$null | Select-Object -First 1)
Note ("clone HEAD before/after demo : $cloneHead / $cloneHeadAfter $(if ($cloneHeadAfter -eq $cloneHead) { '(unchanged -- sabotage was working-tree only, never committed)' } else { '(CHANGED)' })")
Note ("real vault HEAD              : $((& $gitExe -C $repoRoot rev-parse HEAD 2>$null | Select-Object -First 1)) (read-only throughout)")
Note ''
Note 'NOT part of this demo: the pre-push secret scanner. Run it yourself --'
Note '.system/pre-push-scan.ps1 -- for its verdict on this exact history.'
Note ''
$elapsed = [int]((Get-Date) - $d0).TotalSeconds
if ($failures.Count -eq 0) {
    Write-Host "  EVERY PHASE BEHAVED AS EXPECTED in ${elapsed}s." -ForegroundColor Green
    Write-Host '  The suite catches a broken guard; memory changes what a cold session knows;'
    Write-Host '  the clone was built by git from the pushed commit, live.'
    if ($Keep) { Note "clone kept at $cloneRoot" }
    else       { & cmd /c "rmdir /s /q `"$cloneRoot`"" 2>$null; Note 'clone removed (-Keep to inspect instead)' }
    exit 0
}
Write-Host "  $($failures.Count) UNEXPECTED OUTCOME(S) in ${elapsed}s:" -ForegroundColor Red
$failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
Note "clone kept at $cloneRoot for inspection"
exit 1
