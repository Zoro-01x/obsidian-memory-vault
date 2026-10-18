# adversarial-demo-test.ps1
#
# MOVE 2 -- the adversarial demo: can an unverified claim launder itself into
# memory? This is the demo meant for external review, so it prints a narrative
# with receipts, not just a pass count.
#
# The story it tells, all inside one throwaway vault under %TEMP%:
#
#   1. SEED        an external-model claim enters through `propose` -- staged,
#                  unverified, basis: external-model.
#   2. RETRIEVE    a COLD session (every adapter call is a fresh process)
#                  recalls it. The claim is available AND its unverified
#                  status is visible in the same breath.
#   3. LAUNDER     two attempts to promote it without evidence:
#                    a. create a permanent note claiming `basis: observed`
#                       with no verified date -> must REFUSE, nothing written
#                    b. stamp `verified` onto the inbox item via `set`
#                       -> must REFUSE, note bytes byte-identical after
#   4. EVIDENCE    promote properly: a separate evidence note (the observed
#                  experiment) plus a claim note whose frozen probe points at
#                  that evidence. `verify` executes the probe and logs it.
#   5. CONTRADICT  a second external account claims the opposite, staged
#                  through propose (an unchecked contradiction is exactly an
#                  unverified claim -- it must not be promoted either).
#                  recall shows BOTH: the observed note and the contradiction,
#                  each with its provenance, and the verified note outranks
#                  the unchecked one. Surfaced, never silently resolved.
#   6. SUPERSEDE   the inbox item is retired (status: superseded,
#                  superseded_by: the permanent note). PASS CONDITION, written
#                  here before running: for the claim's query the permanent
#                  note must rank ABOVE the superseded item, and the
#                  superseded item must still be retrievable -- demoted, not
#                  deleted. Memory that forgets defeats the point.
#   7. TRAIL       git log shows every step as its own auditable commit.
#
# Controls (without these the demo proves nothing):
#   - the refusals are pinned to their SPECIFIC wording, not any failure
#   - the refused inbox item is asserted byte-identical (sha256) afterward,
#     so "refused" cannot hide a silent write
#   - a control create with evidence SUCCEEDS, so the refusals cannot be
#     explained by a broken verb refusing everything
#   - the real vault's git state is checked before and after
#
# Run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .system/adversarial-demo-test.ps1
#
# Exit 0 = every assertion passed.

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$adapter = Join-Path $PSScriptRoot 'vault-adapter.ps1'
if (-not (Test-Path -LiteralPath $adapter)) {
    Write-Output ("FATAL: adapter not found at {0}" -f $adapter); exit 2
}

$realVault = Split-Path $PSScriptRoot -Parent
$realHeadBefore = (& git -C $realVault rev-parse HEAD 2>$null)

$results = @()
function T([string]$Name, [bool]$Pass, $Detail = '') {
    $script:results += [pscustomobject]@{ Name = $Name; Pass = $Pass }
    $d = if ($Detail) { " -- $Detail" } else { '' }
    Write-Output ("{0}  {1}{2}" -f $(if ($Pass) { 'PASS' } else { 'FAIL' }), $Name, $d)
}

function New-DemoVault {
    $root = Join-Path $env:TEMP ('vault-demo-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    foreach ($d in @('inbox', 'entities', 'decisions', 'lessons')) {
        New-Item -ItemType Directory -Path (Join-Path $root $d) -Force | Out-Null
    }
    # .gitattributes in the fixture, or git's LF->CRLF stderr warning is a
    # tripwire in the demo itself (the defect native-stderr-test.ps1 covers).
    [System.IO.File]::WriteAllText((Join-Path $root '.gitattributes'),
        "*.md text eol=lf`n", (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $root '.vault-test-root'),
        "adversarial demo`n", (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $root 'CORE.md'),
        "---`nname: CORE`n---`n`n# CORE`n`nDemo scratch repo.`n",
        (New-Object System.Text.UTF8Encoding($false)))
    $git = 'git'
    & $git -C $root init -q 2>$null | Out-Null
    & $git -C $root config user.name  'adversarial-demo' 2>$null | Out-Null
    & $git -C $root config user.email 'demo@example.invalid' 2>$null | Out-Null
    & $git -C $root config core.autocrlf false 2>$null | Out-Null
    return $root
}

function Invoke-Vault {
    param([string]$Root, [string]$Verb, [hashtable]$Arguments)
    $json = ''
    if ($Arguments) { $json = ($Arguments | ConvertTo-Json -Depth 8 -Compress) }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = 'powershell.exe'
    $psi.Arguments              = '-NoProfile -ExecutionPolicy Bypass -File "' + $adapter + '" -Verb ' + $Verb
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.EnvironmentVariables['OBSIDIAN_VAULT_ROOT'] = $Root
    $p = [System.Diagnostics.Process]::Start($psi)
    if ($json) { $p.StandardInput.Write($json) }
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd()
    $null = $p.WaitForExit(180000)
    $parsed = $null
    try { $parsed = $out.Trim() | ConvertFrom-Json } catch { }
    return [pscustomobject]@{
        Raw    = $out
        Parsed = $parsed
        Ok     = if ($parsed) { [bool]$parsed.ok } else { $false }
        Error  = if ($parsed -and $parsed.PSObject.Properties['error']) { [string]$parsed.error } else { '' }
        Result = if ($parsed -and $parsed.PSObject.Properties['result']) { $parsed.result } else { $null }
    }
}

function Get-FileSha([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash([System.IO.File]::ReadAllBytes($Path)) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}

$root = New-DemoVault

# ---------------------------------------------------------------- 1. SEED ---
Write-Output "=== 1. SEED: an unverified external-model claim enters through propose ==="
$seed = Invoke-Vault -Root $root -Verb propose -Arguments @{
    title = 'Intel UHD driver installer exits code 7'
    claim = 'The Intel UHD driver installer exits with code 7 on Windows 11; the fix is 7-Zip extract plus pnputil /add-driver.'
    scope = 'machine'
    basis = 'external-model'
}
T 'propose accepts the claim into inbox/' $seed.Ok $seed.Error
$inboxItem = 'inbox\Intel UHD driver installer exits code 7 ('
$inboxFile = Get-ChildItem (Join-Path $root 'inbox') -Filter '*.md' | Select-Object -First 1
T 'exactly one inbox item exists' (@(Get-ChildItem (Join-Path $root 'inbox') -Filter '*.md').Count -eq 1) $inboxFile.Name
$inInbox = Invoke-Vault -Root $root -Verb read -Arguments @{ path = ('inbox\' + $inboxFile.Name) }
T 'it reads back as basis=external-model' ($inInbox.Result.frontmatter.basis -eq 'external-model') "basis=$($inInbox.Result.frontmatter.basis)"
T 'it reads back with NO verified date' (-not $inInbox.Result.frontmatter.verified) "verified=$($inInbox.Result.frontmatter.verified)"

# ------------------------------------------------------------ 2. RETRIEVE ---
Write-Output ""
Write-Output "=== 2. RETRIEVE: a cold session recalls it -- claim and caveat together ==="
$hit = Invoke-Vault -Root $root -Verb recall -Arguments @{ query = 'intel uhd driver installer' }
T 'a cold recall finds the seeded claim' ($hit.Result.count -ge 1) "count=$($hit.Result.count)"
$top = $hit.Result.hits[0]
T 'the top hit exposes basis=external-model (caveat travels with the claim)' ($top.basis -eq 'external-model') "basis=$($top.basis)"
T 'the top hit exposes verified=null (nothing has checked it)' ($null -eq $top.verified -or $top.verified -eq '') "verified=$($top.verified)"

# ------------------------------------------------------------- 3. LAUNDER ---
Write-Output ""
Write-Output "=== 3. LAUNDER: promote without evidence -- both routes must refuse ==="
Write-Output "--- 3a. create a permanent note claiming basis: observed, no verified date ---"
$launderA = Invoke-Vault -Root $root -Verb create -Arguments @{
    folder      = 'entities'
    name        = 'Intel UHD driver install fix'
    description = 'The Intel UHD driver installer exits code 7; fix via 7-Zip extract and pnputil /add-driver'
    body        = 'Claim promoted from inbox. The installer exits code 7.'
    scope       = 'machine'
    basis       = 'observed'
    status      = 'active'
}
T 'create REFUSES the evidence-free promotion' (-not $launderA.Ok) $launderA.Error
T 'refusal is for the SPECIFIC reason: missing verified date' ($launderA.Error -match [regex]::Escape('missing `verified` date')) $launderA.Error
T 'nothing was written to disk (the refusal is not a silent write)' (-not (Test-Path (Join-Path $root 'entities\Intel UHD driver install fix.md')))

Write-Output "--- 3b. stamp `verified` onto the inbox item via set ---"
$shaBefore = Get-FileSha -Path $inboxFile.FullName
$launderB = Invoke-Vault -Root $root -Verb append -Arguments @{
    path = ('inbox\' + $inboxFile.Name)
    text = 'Promotion attempt: stamping a verified date without checking anything.'
    set  = @{ verified = '2026-10-18' }
}
T 'set REFUSES to write verified' (-not $launderB.Ok) $launderB.Error
T 'refusal is for the SPECIFIC reason: not mutable' ($launderB.Error -match 'not mutable through update') $launderB.Error
$shaAfter = Get-FileSha -Path $inboxFile.FullName
T 'the inbox item is byte-identical after the refused set (sha256)' ($shaBefore -eq $shaAfter) "$($shaBefore.Substring(0,12))... vs $($shaAfter.Substring(0,12))..."

# ------------------------------------------------------------- 4. EVIDENCE ---
Write-Output ""
Write-Output "=== 4. EVIDENCE: promote properly -- separate evidence, frozen probe ==="
# The evidence note is the observed experiment itself. The claim note will
# carry a probe pointing AT the evidence, so a later session can re-witness
# the predicate without trusting the claim's own text.
$evidence = Invoke-Vault -Root $root -Verb create -Arguments @{
    folder      = 'entities'
    name        = 'Intel UHD driver experiment 2026-10-18'
    description = 'Observed: Intel UHD driver installer exits code 7; 7-Zip extract plus pnputil /add-driver succeeds'
    body        = "Ran the Intel installer on 2026-10-18: exit code 7.`nExtracted the package with 7-Zip, then pnputil /add-driver succeeded and the driver installed."
    scope       = 'machine'
    basis       = 'observed'
    status      = 'active'
    verified    = '2026-10-18'
}
T 'the evidence note (observed + verified) is created' $evidence.Ok $evidence.Error
$claim = Invoke-Vault -Root $root -Verb create -Arguments @{
    folder      = 'entities'
    name        = 'Intel UHD driver install fix'
    description = 'The Intel UHD driver installer exits code 7; fix via 7-Zip extract and pnputil /add-driver'
    body        = 'Promoted from inbox once evidence existed. The claim is witnessed by its probe, not by this text.'
    scope       = 'machine'
    basis       = 'observed'
    status      = 'active'
    verified    = '2026-10-18'
    probeKind   = 'symbol_present'
    probeTarget = 'entities\Intel UHD driver experiment 2026-10-18.md'
    probePattern = 'exit code 7'
}
T 'the claim note is created WITH a frozen probe' $claim.Ok $claim.Error
$ver = Invoke-Vault -Root $root -Verb verify -Arguments @{ path = 'entities\Intel UHD driver install fix.md' }
T 'verify runs as an operation' $ver.Ok $ver.Error
T 'outcome is VERIFIED (the probe witnessed the evidence)' ($ver.Result.outcome -eq 'verified') "outcome=$($ver.Result.outcome)"
T 'evidence was appended to the scratch verify-log' (Test-Path (Join-Path $root '.system\verify-log.ndjson'))
$verLog = Get-Content (Join-Path $root '.system\verify-log.ndjson') -Raw
T 'the log records this note and its probe' ($verLog -match 'Intel UHD driver install fix' -and $verLog -match 'symbol_present')

# ---------------------------------------------------------- 5. CONTRADICT ---
Write-Output ""
Write-Output "=== 5. CONTRADICT: a second account claims the opposite -- staged, surfaced ==="
# An unchecked contradiction is an unverified claim, so it goes through the
# staging door too -- it must not be promoted either. What matters: recall
# surfaces BOTH with their provenance, and the contradiction does not
# outrank the observed note. Surfaced, never silently resolved.
$contra = Invoke-Vault -Root $root -Verb propose -Arguments @{
    title = 'Intel UHD installer completes normally'
    claim = 'A second account says the Intel UHD driver installer completes normally and needs no 7-Zip or pnputil workaround. Not checked.'
    scope = 'machine'
    basis = 'external-model'
}
T 'the contradictory account is staged, not promoted' $contra.Ok $contra.Error
$both = Invoke-Vault -Root $root -Verb recall -Arguments @{ query = 'intel uhd driver installer' }
$paths = @($both.Result.hits | ForEach-Object { $_.name })
T 'recall surfaces BOTH the claim and its contradiction' (($paths -contains 'Intel UHD driver install fix') -and (@($paths | Where-Object { $_ -like 'Intel UHD installer completes normally*' }).Count -eq 1)) ($paths -join ' | ')
$claimHit5 = $both.Result.hits | Where-Object { $_.name -eq 'Intel UHD driver install fix' } | Select-Object -First 1
$contraHit = $both.Result.hits | Where-Object { $_.name -like 'Intel UHD installer completes normally*' } | Select-Object -First 1
T 'the observed+verified note OUTRANKS the unchecked contradiction' ($claimHit5.score -gt $contraHit.score) "verified=$($claimHit5.score) contradiction=$($contraHit.score)"
T 'the contradiction carries its declared basis (never laundered into observed)' ($contraHit.basis -eq 'external-model') "basis=$($contraHit.basis)"

# ----------------------------------------------------------- 6. SUPERSEDE ---
Write-Output ""
Write-Output "=== 6. SUPERSEDE: retire the inbox item. PASS CONDITION, defined before running:"
Write-Output "      after supersession, the permanent note ranks ABOVE the superseded"
Write-Output "      item for the claim's query -- and the item stays retrievable."
$sup = Invoke-Vault -Root $root -Verb append -Arguments @{
    path = ('inbox\' + $inboxFile.Name)
    text = 'Superseded by the evidence-backed permanent note; promotion happened 2026-10-18.'
    set  = @{ status = 'superseded'; supersededBy = 'Intel UHD driver install fix' }
}
T 'the inbox item is superseded with a pointer' $sup.Ok $sup.Error
$after = Invoke-Vault -Root $root -Verb recall -Arguments @{ query = 'intel uhd driver installer' }
$claimHit = $after.Result.hits | Where-Object { $_.name -eq 'Intel UHD driver install fix' } | Select-Object -First 1
$itemHit  = $after.Result.hits | Where-Object { $_.name -like 'Intel UHD driver installer exits code 7*' } | Select-Object -First 1
T 'the permanent note ranks ABOVE the superseded inbox item' ($claimHit -and $itemHit -and ($claimHit.score -gt $itemHit.score)) "claim=$($claimHit.score) item=$($itemHit.score)"
T 'the superseded item is still retrievable (demoted, not deleted)' ($null -ne $itemHit) "score=$($itemHit.score)"
T 'the superseded item reports status=superseded' ($itemHit.status -eq 'superseded') "status=$($itemHit.status)"
$readBack = Invoke-Vault -Root $root -Verb read -Arguments @{ path = $itemHit.path }
T 'the supersession pointer reads back on the item' ($readBack.Result.frontmatter.supersededBy -eq 'Intel UHD driver install fix' -or $readBack.Result.frontmatter.superseded_by -eq 'Intel UHD driver install fix') "by=$($readBack.Result.frontmatter.supersededBy)"

# ---------------------------------------------------------------- 7. TRAIL --
Write-Output ""
Write-Output "=== 7. TRAIL: every step is its own auditable commit ==="
$git = 'git'
$trail = @(& $git -C $root log --oneline 2>$null)
T 'the seed, refusals, evidence, contradiction and supersession left a git trail' ($trail.Count -ge 5) "$($trail.Count) commits"
$trail | ForEach-Object { Write-Output ("    " + $_) }
$refusedWrites = @(& $git -C $root log --all --name-only --oneline 2>$null | Where-Object { $_ -match 'verified.*inbox|inbox.*verified' })
T 'the refused verified-stamp appears nowhere in history' ($refusedWrites.Count -eq 0)

# ------------------------------------------------------- REAL VAULT SAFETY --
Write-Output ""
Write-Output "=== real vault untouched by this demo ==="
$realHeadAfter = (& git -C $realVault rev-parse HEAD 2>$null)
T 'real vault HEAD is unchanged' ($realHeadBefore -eq $realHeadAfter) "$realHeadBefore"
T 'no evidence log appeared in the REAL vault' (-not (Test-Path (Join-Path $realVault '.system\verify-log.ndjson')))

# ------------------------------------------------------------------ SUMMARY -
Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
$pass = @($results | Where-Object { $_.Pass }).Count
$fail = @($results | Where-Object { -not $_.Pass }).Count
Write-Output ""
Write-Output ("{0} passed, {1} failed" -f $pass, $fail)
if ($fail -gt 0) {
    Write-Output "FAILED assertions:"
    $results | Where-Object { -not $_.Pass } | ForEach-Object { Write-Output ("  - " + $_.Name) }
    exit 1
}
exit 0
