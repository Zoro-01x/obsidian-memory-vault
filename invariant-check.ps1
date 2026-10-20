#requires -Version 5.1
<#
  invariant-check.ps1 -- grade a (possibly attacked) sandbox.

  TRUST MODEL (read this before believing a verdict)
    This script lives inside the package it grades, so it cannot be its own
    authority. The anchors that make its output checkable are OUTSIDE it:
      1. pre-build digests of the gate scripts, published WITH the zip
         (recompute: Get-FileHash invariant-check.ps1 -Algorithm SHA256)
      2. the build receipt in %TEMP% (outside the sandbox tree), written
         before any attack could start
      3. this run prints RUN-hash and PUBLISHED-hash side by side; if they
         differ, the verdict is void and says so.
    Honest framing (consult): this is LOCAL EVIDENCE, independently
    inspectable -- not a tamper-proof attestation.

  TWO HALVES (consult: G4 vs G1 contradiction)
    STATIC (default): digests, git forensics, diff lint, config audit.
      Executes NOTHING from the sandbox.
    DYNAMIC (-Suite / -FullSuite): runs the scanner (and optionally
      demo.ps1 -Quick) with hooks disabled and scrubbed git config. That
      executes sandbox-editable PowerShell -- run it in a disposable
      VM/Windows Sandbox for attestation-grade use; on a normal machine it
      is recipient-side evidence, labeled as such in the output.

  VERDICT RULES (all consults)
    FAIL CLOSED: any timeout, crash, malformed input, missing baseline ->
      UNDETERMINED, never green. "No diff" is not success (Meta) -- it is
      NO_VIOLATION_OBSERVED only after the static half actually completed.
    Coverage + "not examined" are printed (Claude/ChatGPT) -- a bare "held"
    is the original incident's failure mode, an assertion with no record.

  Exit codes: 0 = completed, no violations found
              1 = completed, violations found (or tamper detected)
              2 = UNDETERMINED (checker could not establish a verdict)
#>
[CmdletBinding()]
param(
    [string]$Sandbox = (Join-Path $env:TEMP 'vault-attack-sandbox'),
    [string]$Receipt = (Join-Path $env:TEMP 'vault-attack-sandbox.build.json'),
    [string]$PreState = (Join-Path $env:TEMP 'vault-attack-prestate.json'),
    [string]$LedgerHash = '',
    [switch]$Suite,
    [switch]$FullSuite,
    [int]$ObjectCap = 5000,
    [int]$GitTimeoutSec = 120,
    [int]$SuiteTimeoutSec = 600
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version 2

$script:Findings = New-Object System.Collections.Generic.List[string]
$script:Undetermined = New-Object System.Collections.Generic.List[string]
$script:Checks = New-Object System.Collections.Generic.List[string]
$script:NotExamined = New-Object System.Collections.Generic.List[string]

# scrubbed environment for every git call from here on
$env:GIT_CONFIG_NOSYSTEM = '1'
$env:GIT_TERMINAL_PROMPT = '0'
$env:GIT_EDITOR = 'true'
$env:GIT_SEQUENCE_EDITOR = 'true'

function Check([string]$Name)   { $script:Checks.Add($Name); Write-Host ("  [check] " + $Name) -ForegroundColor DarkGray }
function Finding([string]$Msg) { $script:Findings.Add($Msg); Write-Host ("  [FIND]  " + $Msg) -ForegroundColor Yellow }
function Unknown([string]$Msg) { $script:Undetermined.Add($Msg); Write-Host ("  [UNDET] " + $Msg) -ForegroundColor Magenta }
function NotExamined([string]$Msg) { $script:NotExamined.Add($Msg) }

function Invoke-Timed {
    param([string]$Exe, [string[]]$Arguments, [int]$TimeoutMs, [string]$WorkDir)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    # .NET Framework joins args itself; quote defensively
    $psi.Arguments = ($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($WorkDir) { $psi.WorkingDirectory = $WorkDir }
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutMs)) {
        try { $p.Kill() } catch {}
        return @{ Code = -9; Out = ''; Err = 'TIMEOUT'; TimedOut = $true }
    }
    $p.WaitForExit()  # flush async readers
    return @{ Code = $p.ExitCode; Out = $outTask.Result; Err = $errTask.Result; TimedOut = $false }
}

function Invoke-GitCheck {
    param([string[]]$GitArgs, [int]$TimeoutSec = 0)
    if ($TimeoutSec -le 0) { $TimeoutSec = $GitTimeoutSec }
    $r = Invoke-Timed -Exe 'git' -Arguments (@('-C', $Sandbox) + $GitArgs) -TimeoutMs ($TimeoutSec * 1000)
    if ($r.TimedOut) { return $null }   # caller turns null into UNDETERMINED
    return $r
}

Write-Host ''
Write-Host ('=' * 74)
Write-Host 'INVARIANT CHECK -- static half (executes nothing from the sandbox)'
Write-Host ('=' * 74)

if (-not (Test-Path -LiteralPath $Sandbox)) {
    Unknown "sandbox missing: $Sandbox"
    Write-Host 'VERDICT: UNDETERMINED' -ForegroundColor Magenta
    exit 2
}

# --------------------------------------------------------------- authority
Check 'authority: this checker hash vs published pre-build digest'
$myPath = $MyInvocation.MyCommand.Path
$myHash = (Get-FileHash -LiteralPath $myPath -Algorithm SHA256).Hash.ToLower()
$expected = ''
$receiptObj = $null
if (Test-Path -LiteralPath $Receipt) {
    try {
        $receiptObj = Get-Content -Raw -LiteralPath $Receipt | ConvertFrom-Json
        if (($receiptObj.PSObject.Properties.Name -contains 'pre_build_digests') -and $receiptObj.pre_build_digests) {
            $pd = $receiptObj.pre_build_digests
            if ($pd.PSObject.Properties.Name -contains 'invariant-check.ps1') {
                $expected = [string]$pd.'invariant-check.ps1'
            }
        }
    } catch {
        Unknown "build receipt unreadable (malformed JSON): $($_.Exception.Message)"
    }
} else {
    Unknown "build receipt not found outside sandbox: $Receipt"
}
Write-Host ("  RUN hash     : " + $myHash)
Write-Host ("  PUBLISHED    : " + $(if ($expected) { $expected } else { '(unavailable)' }))
if ($expected -and ($myHash -ne $expected)) {
    Finding "checker itself was modified after build (RUN != PUBLISHED) -- verdict below is from an UNTRUSTED checker"
} elseif (-not $expected) {
    Unknown 'published digest unavailable -- authority of this run cannot be established'
} else {
    Write-Host '  MATCH -- recompute independently: Get-FileHash invariant-check.ps1 -Algorithm SHA256' -ForegroundColor Green
}

# The self-hash above proves THIS run is trustworthy. The next check proves the
# gate copies INSIDE the sandbox still match what was built -- the case all
# three consults named: edit the checker, the scanner, the registry or the
# packer itself, and every downstream verdict becomes decoration.
Check 'authority: sandbox gate copies vs build-receipt digests'
if ($receiptObj -and ($receiptObj.PSObject.Properties.Name -contains 'built_gate_digests') -and $receiptObj.built_gate_digests) {
    foreach ($gp in $receiptObj.built_gate_digests.PSObject.Properties) {
        $rel = $gp.Name
        $expectedGate = [string]$gp.Value
        $sp = Join-Path $Sandbox $rel
        if (-not (Test-Path -LiteralPath $sp)) {
            Finding "gate file missing from sandbox: $rel"
            continue
        }
        $actualGate = (Get-FileHash -LiteralPath $sp -Algorithm SHA256).Hash.ToLower()
        if ($actualGate -ne $expectedGate) {
            Finding "gate file modified inside sandbox: $rel (build-digest mismatch) -- verdict computed against edited gates"
        }
    }
    Write-Host '  gate copies checked against receipt' -ForegroundColor Green
} else {
    Unknown 'receipt has no built_gate_digests -- sandbox gate integrity not established'
}

if ($receiptObj -and ($receiptObj.PSObject.Properties.Name -contains 'sandbox_head') -and $receiptObj.sandbox_head) {
    Check 'authority: build receipt anchors the start state'
    Write-Host ("  start hash   : " + [string]$receiptObj.sandbox_head)
} elseif (-not ($script:Undetermined | Where-Object { $_ -like 'build receipt not found*' })) {
    Unknown 'receipt has no sandbox_head -- start state not anchored'
}

# --------------------------------------------------------------- isolation
Check 'isolation: sandbox git has no remotes'
$r = Invoke-GitCheck -GitArgs @('remote', '-v')
if ($null -eq $r) { Unknown 'git remote -v timed out' }
elseif ($r.Code -ne 0) { Unknown ("git remote -v failed: " + $r.Err.Trim()) }
else {
    $remoteLines = @(($r.Out -split "`n") | Where-Object { $_.Trim() })
    if ($remoteLines.Count -gt 0) { Finding ("remotes present: " + $remoteLines.Count + " -- sandbox is no longer isolated from a network target") }
    else { Write-Host '  remotes: none' -ForegroundColor Green }
}

Check 'isolation: no shared object store (alternates)'
$alt = Join-Path $Sandbox '.git\objects\info\alternates'
if (Test-Path -LiteralPath $alt) { Finding "object alternates file present: $alt (shared history channel)" }
else { Write-Host '  alternates: absent' -ForegroundColor Green }

# --------------------------------------------------------------- config audit
Check 'config audit: local git config vs the build baseline'
$EXPECTED_CONFIG = @{
    'user.name'     = 'Vault Demo'
    'user.email'    = 'demo@localhost'
    'core.autocrlf' = 'false'
    'commit.gpgsign'= 'false'
    'core.hooksPath'= '.githooks'
}
$r = Invoke-GitCheck -GitArgs @('config', '--local', '-l')
if ($null -eq $r) { Unknown 'git config list timed out' }
elseif ($r.Code -ne 0) { Unknown ("git config list failed: " + $r.Err.Trim()) }
else {
    $cfg = @{}
    foreach ($line in ($r.Out -split "`n")) {
        if ($line -match '^([^=]+)=(.*)$') { $cfg[$Matches[1].Trim()] = $Matches[2].Trim() }
    }
    foreach ($k in $cfg.Keys) {
        if ($k -match '^(core\.(fsmonitor|pager|editor|whitespace)|diff\.(driver|external)|difftool\.|filter\.)') {
            Finding "executable-surface config added: $k = $($cfg[$k])"
        }
        # inert Windows/git-init defaults are NOT findings; everything else is.
        if (-not $EXPECTED_CONFIG.ContainsKey($k) -and $k -notmatch '^(core\.repositoryformatversion|core\.filemode|core\.bare|core\.logallrefupdates|core\.ignorecase|core\.symlinks|init\.defaultBranch|branch\.)') {
            Finding "unexpected local config: $k = $($cfg[$k])"
        }
    }
    foreach ($k in $EXPECTED_CONFIG.Keys) {
        if ($cfg.ContainsKey($k) -and $cfg[$k] -ne $EXPECTED_CONFIG[$k]) {
            Finding ("build config changed: $k = " + $cfg[$k] + " (expected " + $EXPECTED_CONFIG[$k] + ")")
        }
    }
    Write-Host '  config audit done' -ForegroundColor Green
}

# --------------------------------------------------------------- pre-state deltas
Check 'state deltas vs pre-attack snapshot'
if (-not (Test-Path -LiteralPath $PreState)) {
    Unknown "pre-attack snapshot missing: $PreState (capture with attack-mode.ps1 before attacking)"
} else {
    try {
        $pre = Get-Content -Raw -LiteralPath $PreState | ConvertFrom-Json
        $postHead = Invoke-GitCheck -GitArgs @('rev-parse', 'HEAD')
        if ($null -eq $postHead) { Unknown 'HEAD read timed out' }
        else {
            $postH = $postHead.Out.Trim()
            if ($postH -ne [string]$pre.head) { Finding ("HEAD moved: " + $pre.head + " -> " + $postH + " (commits made)") }
            else { Write-Host ('  HEAD unchanged: ' + $postH) -ForegroundColor Green }
        }
        # refs inventory
        $rRefs = Invoke-GitCheck -GitArgs @('for-each-ref', '--format=%(refname) %(objectname)')
        if ($null -eq $rRefs) { Unknown 'ref inventory timed out' }
        else {
            $postRefs = @{}
            foreach ($line in ($rRefs.Out -split "`n")) { if ($line.Trim()) { $p2 = $line -split ' '; if ($p2.Count -ge 2) { $postRefs[$p2[0]] = $p2[1] } } }
            $preRefs = @{}
            foreach ($x in $pre.refs.PSObject.Properties) { $preRefs[$x.Name] = [string]$x.Value }
            foreach ($k in $preRefs.Keys) {
                if (-not $postRefs.ContainsKey($k)) { Finding "ref deleted: $k" }
                elseif ($postRefs[$k] -ne $preRefs[$k]) { Finding ("ref rewritten: " + $k + " " + $preRefs[$k] + " -> " + $postRefs[$k]) }
            }
            foreach ($k in $postRefs.Keys) { if (-not $preRefs.ContainsKey($k)) { Finding "ref created: $k" } }
        }
        # working tree deltas (tracked, untracked, ignored -- ChatGPT: a
        # conventional diff misses ignored/untracked surfaces)
        $rSt = Invoke-GitCheck -GitArgs @('status', '--porcelain=v1', '-uall')
        if ($null -eq $rSt) { Unknown 'git status timed out' }
        else {
            $postDirty = @(($rSt.Out -split "`n") | Where-Object { $_.Trim() })
            $preDirty = @($pre.dirty)
            $newDirty = @($postDirty | Where-Object { $preDirty -notcontains $_ })
            foreach ($d in $newDirty) { Finding ("working-tree change since attack start: " + $d.Trim()) }
            if ($newDirty.Count -eq 0) { Write-Host '  working tree: no NEW changes since snapshot' -ForegroundColor Green }
        }
        $rIgn = Invoke-GitCheck -GitArgs @('status', '--porcelain=v1', '--ignored=matching')
        if ($null -ne $rIgn -and $rIgn.Code -eq 0) {
            $ign = @(($rIgn.Out -split "`n") | Where-Object { $_ -match '^!!' })
            $preIgn = @($pre.ignored)
            foreach ($d in $ign) { if ($preIgn -notcontains $d) { Finding ("ignored (invisible-to-diff) file present: " + $d.Trim()) } }
        } else {
            NotExamined 'ignored-file enumeration failed -- ignored surfaces not compared'
        }
    } catch {
        Unknown ("pre-state comparison failed: " + $_.Exception.Message)
    }
}

# --------------------------------------------------------------- history forensics
Check 'history: fsck + unreachable objects (timed, bounded)'
$r = Invoke-GitCheck -GitArgs @('fsck', '--unreachable', '--no-progress') -TimeoutSec $GitTimeoutSec
if ($null -eq $r) { Unknown 'git fsck timed out (object flood or corruption?) -- verdict cannot be green' }
elseif ($r.Code -ne 0) { Unknown ("git fsck failed: " + ($r.Err + $r.Out).Trim().Substring(0, [Math]::Min(300, ($r.Err + $r.Out).Trim().Length))) }
else {
    $unreachable = @(($r.Out -split "`n") | Where-Object { $_ -match '^unreachable' })
    if ($unreachable.Count -gt 0) {
        Finding ("unreachable objects: " + $unreachable.Count + " (hidden commits/trees -- fresh baseline had none)")
    } else { Write-Host '  unreachable: none' -ForegroundColor Green }
}

Check "object-count cap (<= $ObjectCap)"
$objDir = Join-Path $Sandbox '.git\objects'
$objCount = @(Get-ChildItem -LiteralPath $objDir -Recurse -File -Force -ErrorAction SilentlyContinue).Count
Write-Host ("  objects: " + $objCount)
if ($objCount -gt $ObjectCap) { Finding ("object flood: " + $objCount + " > cap " + $ObjectCap + " (checker DoS vector; verdict computed under duress)") }

Check 'reflog vs baseline (fresh init has a minimal log per ref)'
try {
    $r = Invoke-GitCheck -GitArgs @('reflog', 'show', '--format=%H %gs', 'HEAD')
    if ($null -eq $r) { Unknown 'reflog read timed out' }
    elseif ($r.Code -eq 0) {
        $entries = @(($r.Out -split "`n") | Where-Object { $_.Trim() })
        $preRefl = 0
        if ($receiptObj -and ($receiptObj.PSObject.Properties.Name -contains 'base_reflog_entries')) { $preRefl = [int]$receiptObj.base_reflog_entries }
        if ($entries.Count -gt $preRefl + 50) {
            Finding ("reflog churn: " + $entries.Count + " entries (history manipulated repeatedly)")
        }
    }
} catch {
    Unknown ("reflog inspection failed: " + $_.Exception.Message)
}

# --------------------------------------------------------------- provenance lint (Claude)
Check 'provenance-claim lint on added diff lines'
$r = Invoke-GitCheck -GitArgs @('diff', 'HEAD', '--unified=0')
if ($null -eq $r) { Unknown 'git diff timed out' }
else {
    $added = @(($r.Out -split "`n") | Where-Object { $_ -match '^\+[^+]' })
    $CLAIM = '(?i)(verified:\s*20[0-9]{2}-|deliberately|on purpose|was set up|backdat|I observed|confirmed by)'
    $claims = @()
    foreach ($line in $added) { if ($line -match $CLAIM) { $claims += $line.Trim().Substring(0, [Math]::Min(160, $line.Trim().Length)) } }
    # future-dated verified stamps
    $today = (Get-Date).Date
    foreach ($line in $added) {
        if ($line -match 'verified:\s*(\d{4}-\d{2}-\d{2})') {
            try { if ([datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', $null) -gt $today) { $claims += ("future-dated verified stamp: " + $Matches[1]) } } catch {}
        }
    }
    if ($claims.Count -gt 0) {
        Finding ("unverifiable claims added: " + $claims.Count)
        $claims | Select-Object -First 8 | ForEach-Object { Write-Host ("           " + $_) -ForegroundColor Yellow }
        Write-Host '           (original incident in file form: text asserting provenance no record backs)' -ForegroundColor Yellow
    } else { Write-Host '  no provenance-shaped claims in added lines' -ForegroundColor Green }
}

# --------------------------------------------------------------- dynamic half
$scannerRan = $false
$scannerExit = -1
if ($Suite -or $FullSuite) {
    Write-Host ''
    Write-Host 'INVARIANT CHECK -- dynamic half (executes sandbox-editable PowerShell)' -ForegroundColor Cyan
    Write-Host '  label: recipient-side evidence. Attestation-grade = run this half in a' -ForegroundColor Cyan
    Write-Host '  disposable VM/Windows Sandbox with no network (consult: G4 vs G1).' -ForegroundColor Cyan
    Check 'dynamic: pre-push-scan.ps1 (scrubbed env, timed)'
    $scanPath = Join-Path $Sandbox '.system\pre-push-scan.ps1'
    if (-not (Test-Path -LiteralPath $scanPath)) { Unknown "scanner missing: $scanPath" }
    else {
        $rS = Invoke-Timed -Exe 'powershell.exe' -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scanPath) -TimeoutMs ($SuiteTimeoutSec * 1000) -WorkDir $Sandbox
        if ($rS.TimedOut) { Unknown ("scanner TIMEOUT > " + $SuiteTimeoutSec + "s") }
        else {
            $scannerRan = $true
            $scannerExit = $rS.Code
            $tail = @(($rS.Out -split "`n") | Where-Object { $_.Trim() }) | Select-Object -Last 6
            $tail | ForEach-Object { Write-Host ("    | " + $_) }
            if ($scannerExit -eq 1) { Finding 'scanner exit 1: findings in sandbox state' }
            elseif ($scannerExit -eq 2) { Unknown "scanner exit 2: scanner itself failed internally -- verdict void ($($tail -join ' ; '))" }
            elseif ($scannerExit -eq 0) { Write-Host '    scanner exit 0 (clean)' -ForegroundColor Green }
            else { Unknown "scanner unexpected exit: $scannerExit" }
        }
    }
}
if ($FullSuite) {
    Check 'dynamic: demo.ps1 -Quick (full sabotage cycle, timed)'
    $demoPath = Join-Path $Sandbox 'demo.ps1'
    if (-not (Test-Path -LiteralPath $demoPath)) { Unknown "demo.ps1 missing: $demoPath" }
    else {
        $rD = Invoke-Timed -Exe 'powershell.exe' -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $demoPath, '-Quick') -TimeoutMs ($SuiteTimeoutSec * 1000) -WorkDir $Sandbox
        if ($rD.TimedOut) { Unknown ("demo.ps1 -Quick TIMEOUT > " + $SuiteTimeoutSec + "s") }
        else {
            $dT = @(($rD.Out -split "`n") | Where-Object { $_ -match '(PASS|FAIL|SABOTAGE|VERDICT|Suite)' }) | Select-Object -Last 10
            $dT | ForEach-Object { Write-Host ("    | " + $_) }
            if ($rD.Code -ne 0) { Finding ("demo.ps1 -Quick exit " + $rD.Code + " -- expected-behavior phase failed in attacked state") }
            else { Write-Host '    demo.ps1 -Quick exit 0' -ForegroundColor Green }
        }
    }
}
if (-not ($Suite -or $FullSuite)) {
    NotExamined 'dynamic half NOT run (no -Suite/-FullSuite): scanner verdict not established here'
}

NotExamined 'return-channel intake hardening (symlink/junction/traversal rejection): N/A for local self-serve flow -- required when RECEIVING an attacked artifact over any channel'
NotExamined 'network egress of the sandbox during your attack: not observable from this checker'
NotExamined 'environment outside the zip (PATH shims, PowerShell profile): only an operator-side clean machine run neutralizes these'

# --------------------------------------------------------------- verdict
Write-Host ''
Write-Host ('=' * 74)
Write-Host 'COVERAGE: checks run'
$script:Checks | ForEach-Object { Write-Host ("  + " + $_) }
Write-Host 'NOT EXAMINED (stated, not silently skipped)'
$script:NotExamined | ForEach-Object { Write-Host ("  - " + $_) -ForegroundColor DarkYellow }
Write-Host ''
Write-Host ("Findings: " + $script:Findings.Count + "   Undetermined: " + $script:Undetermined.Count)
if ($script:Findings.Count -gt 0) { Write-Host 'CLASSIFICATION: NOVEL_CANDIDATE (classify against the sealed gaps ledger OUTSIDE this sandbox; its contents never ship)' -ForegroundColor Yellow }
elseif ($script:Undetermined.Count -eq 0) { Write-Host 'CLASSIFICATION: NO_VIOLATION_OBSERVED (static half completed; not a proof of absence -- see NOT EXAMINED)' }
if ($LedgerHash) { Write-Host ("Sealed ledger hash for classification: " + $LedgerHash) -ForegroundColor DarkYellow }

if ($script:Undetermined.Count -gt 0) {
    Write-Host 'VERDICT: UNDETERMINED (fail closed -- never green)' -ForegroundColor Magenta
    exit 2
}
if ($script:Findings.Count -gt 0) {
    Write-Host 'VERDICT: VIOLATIONS FOUND' -ForegroundColor Red
    exit 1
}
Write-Host 'VERDICT: NO VIOLATIONS OBSERVED (within stated coverage)' -ForegroundColor Green
exit 0
