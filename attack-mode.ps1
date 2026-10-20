#requires -Version 5.1
<#
  attack-mode.ps1 -- act two: the recipient breaks it, the gates grade it.

  WHY ACT TWO (three-model consult, this project):
    A scripted break only proves you catch the defect you already knew about.
    When the recipient's own agent picks the attack, he owns the evidence.
    It runs AFTER the scripted demo, because a weak attack looks identical to
    a strong defense unless the viewer has first seen red and green mean
    something.

  THE FLOW (self-serve, offline, inside the shipped package)
    1  BUILD     attack-pack.ps1 -> scrubbed sandbox + published digests
    2  ANCHOR    pre-attack snapshot written OUTSIDE the sandbox tree
    3  CALIBRATE the detector proves it is alive on a KNOWN violation
                 (scored separately -- never counted as a find)
    4  ATTACK    hand the sandbox to your agent: "break its guarantees"
    5  GRADE     invariant-check.ps1 -> diff, guarantees held/broken,
                 tamper attempts, coverage, NOT EXAMINED list, fail-closed

  HONEST FRAMING (do not upgrade these words)
    This produces LOCAL EVIDENCE, independently inspectable -- not a
    tamper-proof attestation. The pre-build digests published WITH the zip
    are the external anchor: if you want to trust the checker you ran,
    Get-FileHash it and compare against the published value.
    A hole your agent finds live is the demo SUCCEEDING: name it, add it as
    a permanent test, fix it red->green. Hiding one is the only way to fail.

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File attack-mode.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File attack-mode.ps1 -SkipCalibration
    powershell -NoProfile -ExecutionPolicy Bypass -File attack-mode.ps1 -NoWait -Suite
    powershell -NoProfile -ExecutionPolicy Bypass -File attack-mode.ps1 -CalibrateOnly
    -SkipCalibration  skip the known-violation detector-alive check
    -CalibrateOnly    run calibration + clean re-check, then stop
    -NoWait           do not pause for the attacker (automation / re-grade)
    -Suite            grade with the dynamic half (scanner) too
    -FullSuite        grade with scanner + demo.ps1 -Quick
    -Sandbox          sandbox location (default %TEMP%\vault-attack-sandbox)
    -LedgerHash       sealed gaps-ledger hash to print with the verdict

  Exit: same as invariant-check (0 clean / 1 violations / 2 undetermined),
        or 2 if calibration itself failed (detector not proven alive).
#>
[CmdletBinding()]
param(
    [switch]$SkipCalibration,
    [switch]$CalibrateOnly,
    [switch]$NoWait,
    [switch]$Suite,
    [switch]$FullSuite,
    [string]$Sandbox = (Join-Path $env:TEMP 'vault-attack-sandbox'),
    [string]$LedgerHash = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$pack = Join-Path $PSScriptRoot '.system\attack-pack.ps1'
$checker = Join-Path $PSScriptRoot 'invariant-check.ps1'
$Receipt = [System.IO.Path]::GetFullPath((Join-Path $Sandbox '..\vault-attack-sandbox.build.json'))
$PreState = [System.IO.Path]::GetFullPath((Join-Path $Sandbox '..\vault-attack-prestate.json'))
$env:GIT_CONFIG_NOSYSTEM = '1'
$env:GIT_TERMINAL_PROMPT = '0'

function Step([string]$T) {
    Write-Host ''
    Write-Host ('>' * 74) -ForegroundColor Cyan
    Write-Host ('> ' + $T) -ForegroundColor Cyan
    Write-Host ('>' * 74) -ForegroundColor Cyan
}
function Die([string]$M) { Write-Host ("ATTACK-MODE FAIL: " + $M) -ForegroundColor Red; exit 2 }

function Invoke-Git([string[]]$GitArgs) {
    # PS 5.1 trap: 2>&1 under EAP=Stop turns git stderr warnings fatal.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & git -C $Sandbox @GitArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    return @{ Code = $code; Out = ($out | Out-String).Trim() }
}

# ================================================================ 1 BUILD
Step 'PHASE 1 -- BUILD the scrubbed sandbox'
if (-not (Test-Path -LiteralPath $pack)) { Die "attack-pack.ps1 missing: $pack" }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $pack -OutDir $Sandbox -Force
$packExit = $LASTEXITCODE
if ($packExit -ne 0) { Die "attack-pack.ps1 exit $packExit -- sandbox not trustworthy, stopping" }

# ================================================================ 2 ANCHOR
Step 'PHASE 2 -- ANCHOR the pre-attack state (outside the sandbox tree)'
$h = Invoke-Git @('rev-parse', 'HEAD')
if ($h.Code -ne 0) { Die "cannot read sandbox HEAD: $($h.Out)" }
$refs = @{}
$rf = Invoke-Git @('for-each-ref', '--format=%(refname) %(objectname)')
if ($rf.Code -eq 0) {
    foreach ($line in ($rf.Out -split "`n")) { if ($line.Trim()) { $p = $line -split ' '; if ($p.Count -ge 2) { $refs[$p[0]] = $p[1] } } }
}
$st = Invoke-Git @('status', '--porcelain=v1', '-uall')
$dirty = @()
if ($st.Code -eq 0) { $dirty = @(($st.Out -split "`n") | Where-Object { $_.Trim() }) }
$ig = Invoke-Git @('status', '--porcelain=v1', '--ignored=matching')
$ignored = @()
if ($ig.Code -eq 0) { $ignored = @(($ig.Out -split "`n") | Where-Object { $_.Trim() }) }

$pre = [ordered]@{
    captured_utc = (Get-Date).ToUniversalTime().ToString('o')
    head = $h.Out.Trim()
    refs = $refs
    dirty = $dirty
    ignored = $ignored
}
$pre | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $PreState -Encoding UTF8
Write-Host ("  HEAD   : " + $pre.head)
Write-Host ("  refs   : " + $refs.Count + "   dirty: " + $dirty.Count + "   ignored: " + $ignored.Count)
Write-Host ("  anchor : " + $PreState)

# ================================================================ 3 CALIBRATE
if (-not $SkipCalibration) {
    Step 'PHASE 3 -- CALIBRATION: prove the detector is alive (scored separately)'
    Write-Host 'A KNOWN violation is planted on purpose: a future-dated verified claim'
    Write-Host 'with no record behind it. The checker MUST go red. If it does not,'
    Write-Host 'every later green is meaningless and this run fails loudly.'

    $trip = Join-Path $Sandbox 'synthetic\Calibration tripwire.md'
    $tripBody = @'
---
title: Calibration tripwire
basis: observed
verified: 2099-12-31
status: active
---
Deliberate KNOWN violation for detector calibration. The verified stamp is
future-dated on purpose; no record backs it. This file is removed at the end
of calibration and its appearance here is never scored as a find.
'@
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($trip, $tripBody, $enc)
    $null = Invoke-Git @('add', '-A')

    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $checker, '-Sandbox', $Sandbox, '-Receipt', $Receipt, '-PreState', $PreState)
    & powershell.exe @args
    $red = $LASTEXITCODE
    if ($red -ne 1) {
        Write-Host ("CALIBRATION FAILED: checker exit " + $red + " (expected 1 = KNOWN violation caught)") -ForegroundColor Red
        Write-Host 'The detector is NOT proven alive. Verdict of this run: UNDETERMINED.' -ForegroundColor Magenta
        exit 2
    }
    Write-Host 'CALIBRATION: RED as expected -- detector is alive (score: KNOWN, not a find)' -ForegroundColor Green

    Remove-Item -LiteralPath $trip -Force
    $null = Invoke-Git @('add', '-A')
    # Staging the tripwire created index-tree/blob objects; removing the file
    # leaves them UNREACHABLE, and the checker correctly scores unreachable
    # objects as hidden history. Calibration must collect after itself -- gc
    # drops the orphans so the clean re-check tests the sandbox, not our mess.
    $null = Invoke-Git @('gc', '--prune=now', '--quiet')
    & powershell.exe @args
    $green = $LASTEXITCODE
    if ($green -ne 0) {
        Write-Host ("CALIBRATION FAILED: clean re-check exit " + $green + " (expected 0)") -ForegroundColor Red
        exit 2
    }
    Write-Host 'CALIBRATION: GREEN restored -- clean baseline verified' -ForegroundColor Green
}
if ($CalibrateOnly) { exit 0 }

# ================================================================ 4 ATTACK
Step 'PHASE 4 -- ATTACK WINDOW'
Write-Host @"
  Sandbox (the ONLY thing your agent may touch):
      $Sandbox

  One instruction for your agent:
      "Break this vault's guarantees. Change what it says, what it stores,
        its history -- your call. When done, stop."

  What your agent gets: raw file + git + shell access to that directory.
  What it does NOT get: your real vault (it is not on this machine's paths),
  and a verdict written by this package -- grade it yourself with the
  published digests if you want an anchor outside the package.

  When your agent is done, press Enter to grade.
"@ -ForegroundColor Cyan
if (-not $NoWait) {
    $null = Read-Host 'Press Enter to run the invariant check'
}

# ================================================================ 5 GRADE
Step 'PHASE 5 -- GRADE'
$checkArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $checker,
               '-Sandbox', $Sandbox, '-Receipt', $Receipt, '-PreState', $PreState)
if ($Suite) { $checkArgs += '-Suite' }
if ($FullSuite) { $checkArgs += '-FullSuite' }
if ($LedgerHash) { $checkArgs += @('-LedgerHash', $LedgerHash) }
& powershell.exe @checkArgs
$code = $LASTEXITCODE

Write-Host ''
Write-Host ('=' * 74)
switch ($code) {
    0 { Write-Host 'ATTACK-MODE RESULT: no violations observed within stated coverage.' -ForegroundColor Green
        Write-Host 'This is NOT "unbreakable". It is "nothing found by the checks printed above".' }
    1 { Write-Host 'ATTACK-MODE RESULT: violations found. THIS IS THE GOOD OUTCOME IF IT IS NOVEL.' -ForegroundColor Yellow
        Write-Host 'Next: name the guarantee broken, add it as a permanent test, fix red->green.' }
    2 { Write-Host 'ATTACK-MODE RESULT: UNDETERMINED (fail closed). Not green, not red.' -ForegroundColor Magenta
        Write-Host 'Fix the checker input (pre-state, receipt) and re-run; never quote this as a pass.' }
}
Write-Host ('=' * 74)
exit $code
