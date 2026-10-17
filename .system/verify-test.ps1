# verify-test.ps1
#
# THE INVARIANT UNDER TEST:
#     `verify` is a WITNESS, not a second opinion. It must:
#       1. read the note from DISK, never from anything the caller supplies;
#       2. refuse every argument that could state an outcome;
#       3. fail CLOSED -- an exception, a missing file, an unrunnable probe or
#          a timeout is `failed`, never a pass;
#       4. run a CANARY CONTROL that must fail, so a probe matching everything
#          cannot certify anything;
#       5. leave the note byte-identical (the checker must not change the
#          object whose state it attests to);
#       6. write evidence only to the append-only log under `.system/`, which
#          every write verb is blocked from.
#
# WHY THIS EXISTS (2026-10-17, Claude + Meta, independently):
#     Claude's test: "replace the caller with a rock. If verify returns the
#     same result no matter what the caller says, it is a witness. If any
#     caller-supplied text influences the outcome, it is a second opinion in a
#     lab coat."
#
#     Meta: "refuse to trust basis. Never auto-promote external-model to
#     observed because content 'looks right'... refuse to pass when checks were
#     not run."
#
#     Both landed on the same design: the probe spec is frozen at create time,
#     the caller names a note and nothing else, and the result is structured --
#     never prose.
#
# ISOLATION: every scenario builds its own git repo under %TEMP% carrying a
#     .vault-test-root sentinel and passes it to the adapter child via
#     OBSIDIAN_VAULT_ROOT. The library ignores that variable unless BOTH the
#     %TEMP% prefix and the sentinel are present, so the real vault cannot be
#     reached. This file never writes to the live vault.
#
# Run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .system/verify-test.ps1
#
# Exit 0 = every assertion passed.

# The harness runs with EAP=Continue on purpose (see native-stderr-test.ps1,
# lines 39-43). The adapter CHILD still sets $ErrorActionPreference='Stop'.
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$adapter = Join-Path $PSScriptRoot 'vault-adapter.ps1'
if (-not (Test-Path -LiteralPath $adapter)) {
    Write-Output ("FATAL: adapter not found at {0}" -f $adapter)
    exit 2
}

$results = @()
function T([string]$Name, [bool]$Pass, $Detail = '') {
    $script:results += [pscustomobject]@{ Name = $Name; Pass = $Pass }
    $d = if ($Detail) { " -- $Detail" } else { '' }
    Write-Output ("{0}  {1}{2}" -f $(if ($Pass) { 'PASS' } else { 'FAIL' }), $Name, $d)
}

function New-ScratchVault {
    param([switch]$WithSystem)
    $root = Join-Path $env:TEMP ('vault-verify-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    foreach ($d in @('inbox', 'entities', 'decisions', 'lessons')) {
        New-Item -ItemType Directory -Path (Join-Path $root $d) -Force | Out-Null
    }
    # .gitattributes pins *.md to LF. Without it git warns on stderr about
    # LF->CRLF and the whole native-stderr regression reappears -- that defect
    # is the reason this suite exists, so the fixture must not reintroduce it.
    [System.IO.File]::WriteAllText((Join-Path $root '.gitattributes'),
        "*.md text eol=lf`n", (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $root '.vault-test-root'),
        "verify test`n", (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $root 'CORE.md'),
        "---`nname: CORE`n---`n`n# CORE`n`nScratch repo.`n", (New-Object System.Text.UTF8Encoding($false)))

    if ($WithSystem) {
        # The `suite` probe runs a real test file by ID, so that file has to
        # exist inside the scratch root. Copying .system is what makes the
        # allowlist honest rather than special-cased.
        #
        # The destination directory is created FIRST. `Copy-Item src\* -Dest
        # newdir -Recurse` against a non-existent destination silently lands
        # only part of the tree -- it created the folder and reported success
        # while smoke-test.mjs was missing, which surfaced as a probe failure
        # that looked like a broken allowlist rather than a broken fixture.
        $dstSys = Join-Path $root '.system'
        New-Item -ItemType Directory -Path $dstSys -Force | Out-Null
        Copy-Item -Path (Join-Path $PSScriptRoot '*') -Destination $dstSys -Recurse -Force
    }

    $git = 'git'
    & $git -C $root init -q 2>$null | Out-Null
    & $git -C $root config user.name  'verify-test' 2>$null | Out-Null
    & $git -C $root config user.email 'verify-test@example.invalid' 2>$null | Out-Null
    & $git -C $root config core.autocrlf false 2>$null | Out-Null
    return $root
}

function Invoke-VaultAdapter {
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
    $err = $p.StandardError.ReadToEnd()
    $null = $p.WaitForExit(180000)
    $parsed = $null
    try { $parsed = $out.Trim() | ConvertFrom-Json } catch { }
    return [pscustomobject]@{
        Raw    = $out
        StdErr = $err
        Parsed = $parsed
        Ok     = if ($parsed) { [bool]$parsed.ok } else { $false }
        Error  = if ($parsed -and $parsed.PSObject.Properties['error']) { [string]$parsed.error } else { '' }
        Result = if ($parsed -and $parsed.PSObject.Properties['result']) { $parsed.result } else { $null }
    }
}

function New-Note {
    param([string]$Root, [string]$Name, [hashtable]$Extra = @{})
    $a = @{
        folder      = 'entities'
        name        = $Name
        description = "verify test fixture $Name"
        body        = "Test body for $Name. Contains the token VAULTSENTINEL for symbol_present probes."
        scope       = 'verify-test'
        basis       = 'observed'
    }
    foreach ($k in $Extra.Keys) { $a[$k] = $Extra[$k] }
    return Invoke-VaultAdapter -Root $Root -Verb create -Arguments $a
}

function Get-FileSha([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash([System.IO.File]::ReadAllBytes($Path)) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}

Write-Output "=== scenario 1: a note with no probe is UNVERIFIABLE, never a default pass ==="
$root = New-ScratchVault
$c = New-Note -Root $root -Name 'NoProbeNote'
T 'note without a probe is created' $c.Ok $c.Error
$v = Invoke-VaultAdapter -Root $root -Verb verify -Arguments @{ path = 'entities\NoProbeNote.md' }
T 'verify succeeds as an operation' $v.Ok $v.Error
T 'outcome is UNVERIFIABLE (not verified)' ($v.Result.outcome -eq 'unverifiable') "outcome=$($v.Result.outcome)"
T 'the failing check is named probe' (@($v.Result.checks | Where-Object { $_.check -eq 'probe' -and -not $_.ok }).Count -eq 1)
T 'schema check PASSED on the same note' (@($v.Result.checks | Where-Object { $_.check -eq 'schema' -and $_.ok }).Count -eq 1)

Write-Output "=== scenario 2: path_exists on a file that exists -> verified ==="
$root = New-ScratchVault
$c = New-Note -Root $root -Name 'GoodPathProbe' -Extra @{
    probeKind = 'path_exists'; probeTarget = 'CORE.md'
}
T 'note with a path_exists probe is created' $c.Ok $c.Error
$v = Invoke-VaultAdapter -Root $root -Verb verify -Arguments @{ path = 'entities\GoodPathProbe.md' }
T 'outcome is VERIFIED' ($v.Result.outcome -eq 'verified') "outcome=$($v.Result.outcome) err=$($v.Error)"
$pc = @($v.Result.checks | Where-Object { $_.check -like 'probe:*' })
T 'the probe check ran and passed' ($pc.Count -eq 1 -and $pc[0].ok) ($pc | ConvertTo-Json -Compress)

Write-Output "=== scenario 3: path_exists on a file that does NOT exist -> FAILED ==="
$root = New-ScratchVault
$c = New-Note -Root $root -Name 'BadPathProbe' -Extra @{
    probeKind = 'path_exists'; probeTarget = 'entities\does-not-exist.md'
}
T 'note with a failing probe is still created (declared, not yet run)' $c.Ok $c.Error
$v = Invoke-VaultAdapter -Root $root -Verb verify -Arguments @{ path = 'entities\BadPathProbe.md' }
T 'verify operation itself is ok' $v.Ok $v.Error
T 'outcome is FAILED (fail closed)' ($v.Result.outcome -eq 'failed') "outcome=$($v.Result.outcome)"
T 'the probe check reports not-ok' (@($v.Result.checks | Where-Object { $_.check -like 'probe:*' -and -not $_.ok }).Count -eq 1)

Write-Output "=== scenario 4: symbol_present finds a real symbol -> verified, with line evidence ==="
$root = New-ScratchVault
$c = New-Note -Root $root -Name 'SymbolProbe' -Extra @{
    probeKind = 'symbol_present'; probeTarget = 'CORE.md'; probePattern = 'Scratch'
}
T 'note with a symbol_present probe is created' $c.Ok $c.Error
$v = Invoke-VaultAdapter -Root $root -Verb verify -Arguments @{ path = 'entities\SymbolProbe.md' }
T 'outcome is VERIFIED' ($v.Result.outcome -eq 'verified') "outcome=$($v.Result.outcome)"
$ev = @($v.Result.checks | Where-Object { $_.check -eq 'probe-evidence' })
# Match a line NUMBER, not literally line 1 -- "Scratch repo." sits at the
# bottom of the fixture CORE.md, and hard-coding '1:' would make this assert
# the fixture's layout rather than that evidence carries a locator.
T 'evidence carries the matched line' ($ev.Count -eq 1 -and $ev[0].detail -match '\d+:') ($ev | ConvertTo-Json -Compress)

Write-Output "=== scenario 5: schema rejections -- a probe that cannot run is refused at CREATE ==="
$root = New-ScratchVault
foreach ($case in @(
    @{ n = 'AbsTarget';   e = @{ probeKind = 'path_exists'; probeTarget = 'C:\Windows\win.ini' }; why = 'absolute target' },
    @{ n = 'Traversal';   e = @{ probeKind = 'path_exists'; probeTarget = '..\..\..\Windows\win.ini' }; why = 'path traversal' },
    @{ n = 'BadKind';     e = @{ probeKind = 'rm_rf_everything'; probeTarget = 'CORE.md' }; why = 'unknown probe_kind' },
    @{ n = 'NoTarget';    e = @{ probeKind = 'file_hash' }; why = 'file_hash with no target' },
    @{ n = 'TrivialPat';  e = @{ probeKind = 'symbol_present'; probeTarget = 'CORE.md'; probePattern = '.*' }; why = 'pattern matching everything' },
    @{ n = 'ShortPat';    e = @{ probeKind = 'symbol_present'; probeTarget = 'CORE.md'; probePattern = 'abc' }; why = 'pattern below minimum length' },
    @{ n = 'NoPattern';   e = @{ probeKind = 'symbol_present'; probeTarget = 'CORE.md' }; why = 'symbol_present with no pattern' },
    @{ n = 'BadSuite';    e = @{ probeKind = 'suite'; probeSuite = 'rm -rf /' }; why = 'suite is not allowlisted / is a command string' },
    @{ n = 'SuiteNoName'; e = @{ probeKind = 'suite' }; why = 'suite with no name' }
)) {
    $r = New-Note -Root $root -Name $case.n -Extra $case.e
    T "create REFUSES: $($case.why)" (-not $r.Ok -and $r.Error -match 'probe') $r.Error
}
Write-Output "--- and the failed creates left nothing behind ---"
$leftover = @(Get-ChildItem (Join-Path $root 'entities') -Filter '*.md' -File -ErrorAction SilentlyContinue)
T 'no note was written by any refused create' ($leftover.Count -eq 0) (($leftover | ForEach-Object Name) -join ',')

Write-Output "=== scenario 6: the CANARY CONTROL downgrades a bad probe to FAILED ==="
$root = New-ScratchVault
$c = New-Note -Root $root -Name 'CanaryNote' -Extra @{
    probeKind = 'path_exists'; probeTarget = 'entities\CanaryNote.md'
}
T 'note created' $c.Ok $c.Error
# Plant the canary sentinel. The control requires it to be ABSENT; with it
# present the probe's own answer must be DISCARDED, not upgraded to a pass.
$canaryDir = Join-Path $root '.system'
New-Item -ItemType Directory -Path $canaryDir -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $canaryDir '__vault_probe_canary__.md'), "planted`n",
    (New-Object System.Text.UTF8Encoding($false)))
$v = Invoke-VaultAdapter -Root $root -Verb verify -Arguments @{ path = 'entities\CanaryNote.md' }
T 'a probe whose control fails is NOT reported as verified' ($v.Result.outcome -ne 'verified') "outcome=$($v.Result.outcome)"
$pc = @($v.Result.checks | Where-Object { $_.check -like 'probe:*' })
T 'the check names the canary control' ($pc.Count -eq 1 -and $pc[0].detail -match 'CANARY CONTROL FAILED') ($pc | ConvertTo-Json -Compress)

Write-Output "=== scenario 7: verify NEVER modifies the note it checks ==="
$root = New-ScratchVault
$c = New-Note -Root $root -Name 'ImmutableNote' -Extra @{
    probeKind = 'path_exists'; probeTarget = 'CORE.md'
}
$notePath = Join-Path $root 'entities\ImmutableNote.md'
$before = Get-FileSha $notePath
$v = Invoke-VaultAdapter -Root $root -Verb verify -Arguments @{ path = 'entities\ImmutableNote.md' }
$after = Get-FileSha $notePath
T 'note is byte-identical after verify' ($before -eq $after) "before=$($before.Substring(0,12)) after=$($after.Substring(0,12))"
T 'verify still reported VERIFIED' ($v.Result.outcome -eq 'verified') "outcome=$($v.Result.outcome)"
T 'the note gained no verified_by / evidence frontmatter' (-not ((Get-Content $notePath -Raw) -match 'verified_by')) 'no new frontmatter'

Write-Output "=== scenario 8: evidence lands ONLY in the append-only log under .system/ ==="
$logPath = Join-Path $root '.system\verify-log.ndjson'
T 'evidence log exists after a verify' (Test-Path -LiteralPath $logPath) $logPath
if (Test-Path -LiteralPath $logPath) {
    $lines = @((Get-Content $logPath) | Where-Object { $_ })
    T 'the log holds one record' ($lines.Count -eq 1) "count=$($lines.Count)"
    $rec = $lines[0] | ConvertFrom-Json
    T 'record carries a content hash' ($rec.content_hash -match '^[0-9a-f]{64}$') $rec.content_hash
    T 'record carries a timestamp' ([bool]$rec.ts)
    T 'record names the probe' ($rec.probe -eq 'path_exists') "probe=$($rec.probe)"
    T 'record lists its checks' (@($rec.checks).Count -gt 0) "checks=$(@($rec.checks).Count)"
}
$fmAfter = @{}
$raw = Get-Content (Join-Path $root 'entities\ImmutableNote.md') -Raw
T 'the log is OUTSIDE the note' ($raw -notmatch 'content_hash') 'note body has no log content'

Write-Output "=== scenario 9: DRIFT -- a note edited after verification is caught ==="
$root = New-ScratchVault
$c = New-Note -Root $root -Name 'DriftNote' -Extra @{
    probeKind = 'symbol_present'; probeTarget = 'entities\DriftNote.md'; probePattern = 'VAULTSENTINEL'
}
$v1 = Invoke-VaultAdapter -Root $root -Verb verify -Arguments @{ path = 'entities\DriftNote.md' }
T 'first verify is VERIFIED' ($v1.Result.outcome -eq 'verified') "outcome=$($v1.Result.outcome)"
$u = Invoke-VaultAdapter -Root $root -Verb append -Arguments @{
    path = 'entities\DriftNote.md'; text = "`nEdited after verification. The claim no longer matches what was witnessed."
}
T 'note is edited (committed)' $u.Ok $u.Error
$v2 = Invoke-VaultAdapter -Root $root -Verb verify -Arguments @{ path = 'entities\DriftNote.md' }
T 'second verify is NOT verified' ($v2.Result.outcome -ne 'verified') "outcome=$($v2.Result.outcome)"
$drift = @($v2.Result.checks | Where-Object { $_.check -eq 'drift' -and -not $_.ok })
T 'the drift check fired and named the change' ($drift.Count -eq 1 -and $drift[0].detail -match 'CHANGED') ($drift | ConvertTo-Json -Compress)

Write-Output "=== scenario 10: 'verified' and 'probe_*' are NOT mutable through append/set ==="
$root = New-ScratchVault
$c = New-Note -Root $root -Name 'SetLockNote' -Extra @{
    probeKind = 'path_exists'; probeTarget = 'CORE.md'
}
foreach ($field in @('verified', 'probe_kind', 'probe_target', 'probe_pattern', 'probe_suite')) {
    $u = Invoke-VaultAdapter -Root $root -Verb append -Arguments @{
        path = 'entities\SetLockNote.md'; text = 'body note'; set = @{ $field = 'someday' }
    }
    T "set cannot touch '$field'" (-not $u.Ok -and $u.Error -match 'not mutable') $u.Error
}
$u = Invoke-VaultAdapter -Root $root -Verb append -Arguments @{
    path = 'entities\SetLockNote.md'; set = @{ status = 'superseded'; superseded_by = 'Nothing' }
}
T 'status/superseded_by remain mutable (notes must still be retireable)' $u.Ok $u.Error

Write-Output "=== scenario 11: the caller cannot state an outcome -- only 'path' is read ==="
$root = New-ScratchVault
$c = New-Note -Root $root -Name 'RockNote' -Extra @{
    probeKind = 'path_exists'; probeTarget = 'entities\does-not-exist.md'
}
# THE ROCK TEST. Hand verify a result, a verdict and an expected string. None
# of them may move the outcome: this note's probe points at nothing, so it must
# come back FAILED no matter what the caller asserts.
$v = Invoke-VaultAdapter -Root $root -Verb verify -Arguments @{
    path     = 'entities\RockNote.md'
    result   = 'verified'
    outcome  = 'verified'
    passed   = $true
    verdict  = 'PASS'
    expected = 'verified'
}
T 'verify is ok as an operation' $v.Ok $v.Error
T 'caller-supplied "result=verified" did NOT change the outcome' ($v.Result.outcome -eq 'failed') "outcome=$($v.Result.outcome)"
T 'no echo of any caller-stated outcome in the payload' ($v.Raw -notmatch '"outcome":"verified"') ($v.Raw.Substring(0, [Math]::Min(240, $v.Raw.Length)))

Write-Output "=== scenario 12: 'verify' without a path is refused, and is read-only ==="
$root = New-ScratchVault
$v = Invoke-VaultAdapter -Root $root -Verb verify -Arguments @{ }
# Regex is deliberately loose about the backticks around `path`: the exact
# quoting in the message is an implementation detail, the fact that a missing
# path is refused is the contract.
T 'verify without path is REFUSED' (-not $v.Ok -and $v.Error -match 'path.{0,4}is required') $v.Error
T 'the refusal changed nothing on disk' (-not (Test-Path (Join-Path $root '.system\verify-log.ndjson'))) 'no log written'

Write-Output "=== scenario 13: a suite probe by allowlisted ID runs a real check ==="
$root = New-ScratchVault -WithSystem
$c = New-Note -Root $root -Name 'SuiteNote' -Extra @{ probeKind = 'suite'; probeSuite = 'smoke' }
T 'note with a suite probe is created' $c.Ok $c.Error
$v = Invoke-VaultAdapter -Root $root -Verb verify -Arguments @{ path = 'entities\SuiteNote.md' }
$pc = @($v.Result.checks | Where-Object { $_.check -like 'probe:*' })
T 'the suite probe ran' ($pc.Count -eq 1 -and $pc[0].detail -match 'exit=') ($pc | ConvertTo-Json -Compress)
T 'suite outcome agrees with its exit code' (($v.Result.outcome -eq 'verified') -eq ($pc.Count -eq 1 -and $pc[0].detail -match 'exit=0')) "outcome=$($v.Result.outcome)"
# The suite ran against the scratch root, which is its own repo.
T 'the scratch vault gained no stray notes' (@(Get-ChildItem (Join-Path $root 'entities') -Filter '*.md').Count -eq 1)

Write-Output "=== scenario 15: the three axes stay separate, and the verdict is a pure AND ==="
$root = New-ScratchVault
$c = New-Note -Root $root -Name 'AxisNote' -Extra @{
    probeKind = 'symbol_present'; probeTarget = 'entities\AxisNote.md'; probePattern = 'VAULTSENTINEL'
}
$v1 = Invoke-VaultAdapter -Root $root -Verb verify -Arguments @{ path = 'entities\AxisNote.md' }
T 'axes: probe_ok true, drift UNRECORDED (no prior record), spec unknown' `
    ($v1.Result.probe_ok -eq $true -and $v1.Result.drift -eq 'unrecorded' -and $v1.Result.spec_drift -eq 'unknown') `
    "probe_ok=$($v1.Result.probe_ok) drift=$($v1.Result.drift) spec=$($v1.Result.spec_drift)"
T 'a FIRST verify is VERIFIED (unrecorded is clean -- nothing to have drifted from)' ($v1.Result.outcome -eq 'verified') "outcome=$($v1.Result.outcome)"

# Second verify, nothing changed: drift must now be `unchanged`.
$v2 = Invoke-VaultAdapter -Root $root -Verb verify -Arguments @{ path = 'entities\AxisNote.md' }
T 're-verify with no edit: drift becomes UNCHANGED' ($v2.Result.drift -eq 'unchanged') "drift=$($v2.Result.drift)"
T 're-verify with no edit: outcome VERIFIED' ($v2.Result.outcome -eq 'verified') "outcome=$($v2.Result.outcome)"
T 'the record carries the prior hash for time-travel' ([bool]$v2.Result.prior_hash) $v2.Result.prior_hash

# Edit the note. probe still passes (symbol still there), but content moved.
$null = Invoke-VaultAdapter -Root $root -Verb append -Arguments @{
    path = 'entities\AxisNote.md'; text = "`nA benign-looking edit after verification."
}
$v3 = Invoke-VaultAdapter -Root $root -Verb verify -Arguments @{ path = 'entities\AxisNote.md' }
T 'after an edit: probe_ok STILL true (symbol survived)' ($v3.Result.probe_ok -eq $true) "probe_ok=$($v3.Result.probe_ok)"
T 'after an edit: drift is CHANGED' ($v3.Result.drift -eq 'changed') "drift=$($v3.Result.drift)"
T 'after an edit: outcome is still FAILED (drift can only LOWER the verdict)' ($v3.Result.outcome -eq 'failed') "outcome=$($v3.Result.outcome)"
T 'the drift check names both hashes' (@($v3.Result.checks | Where-Object { $_.check -eq 'drift' -and $_.detail -match 'was .{16}\.\.\..*now .{16}\.\.\.' }).Count -eq 1)
T 'spec_drift stayed UNCHANGED (body edited, spec not)' ($v3.Result.spec_drift -eq 'unchanged') "spec=$($v3.Result.spec_drift)"

Write-Output "=== scenario 16: SPEC drift is an integrity violation, reported apart ==="
$root = New-ScratchVault
$c = New-Note -Root $root -Name 'SpecNote' -Extra @{
    probeKind = 'path_exists'; probeTarget = 'CORE.md'
}
$v1 = Invoke-VaultAdapter -Root $root -Verb verify -Arguments @{ path = 'entities\SpecNote.md' }
T 'baseline verify is VERIFIED' ($v1.Result.outcome -eq 'verified') "outcome=$($v1.Result.outcome)"
T 'baseline spec_drift is unknown on first record' ($v1.Result.spec_drift -eq 'unknown') "spec=$($v1.Result.spec_drift)"

# Tamper with the log directly. The probe spec is NOT mutable through the write
# path, so the only way spec_drift can fire is if something bypassed it --
# which is exactly the case this axis exists to surface.
$logPath = Join-Path $root '.system\verify-log.ndjson'
$lines = @((Get-Content $logPath) | Where-Object { $_ })
$tampered = @()
foreach ($l in $lines) {
    $o = $l | ConvertFrom-Json
    $o.probe_target = 'CORE.md'   # was already CORE.md; flip to something else
    $o | Add-Member -NotePropertyName probe_target -NotePropertyValue 'entities\SpecNote.md' -Force
    $tampered += (ConvertTo-Json -InputObject $o -Depth 8 -Compress)
}
[System.IO.File]::WriteAllLines($logPath, $tampered, (New-Object System.Text.UTF8Encoding($false)))

$v2 = Invoke-VaultAdapter -Root $root -Verb verify -Arguments @{ path = 'entities\SpecNote.md' }
T 'spec drift is CHANGED' ($v2.Result.spec_drift -eq 'changed') "spec=$($v2.Result.spec_drift)"
T 'spec drift forces outcome FAILED' ($v2.Result.outcome -eq 'failed') "outcome=$($v2.Result.outcome)"
T 'the spec-drift check explains the bypass' (@($v2.Result.checks | Where-Object { $_.check -eq 'spec-drift' -and $_.detail -match 'bypassed' }).Count -eq 1)

Write-Output "=== scenario 17: unknown drift never reads as clean ==="
$root = New-ScratchVault
$c = New-Note -Root $root -Name 'UnknownNote' -Extra @{
    probeKind = 'path_exists'; probeTarget = 'CORE.md'
}
$null = Invoke-VaultAdapter -Root $root -Verb verify -Arguments @{ path = 'entities\UnknownNote.md' }
# Corrupt the log line so no prior record can be recovered.
$logPath = Join-Path $root '.system\verify-log.ndjson'
[System.IO.File]::WriteAllText($logPath, "{ this is not json`n", (New-Object System.Text.UTF8Encoding($false)))
$v = Invoke-VaultAdapter -Root $root -Verb verify -Arguments @{ path = 'entities\UnknownNote.md' }
T 'an unparseable log leaves drift UNKNOWN, not unrecorded' ($v.Result.drift -eq 'unknown') "drift=$($v.Result.drift)"
# Fail-closed: history that SHOULD be there but cannot be read is not the same
# as history that never existed. Treating unknown as clean would let a corrupt
# or truncated log silently clear an edited note, so the verdict must drop.
T 'unknown drift does NOT yield verified (fail closed)' ($v.Result.outcome -eq 'failed') "outcome=$($v.Result.outcome)"
T 'the probe itself still passes -- the axes stay separate' ($v.Result.probe_ok -eq $true) "probe_ok=$($v.Result.probe_ok)"
T 'the log-parse failure is surfaced as a check' (@($v.Result.checks | Where-Object { $_.check -eq 'log-parse' -and -not $_.ok }).Count -eq 1)

Write-Output "=== scenario 14: the real vault was never touched ==="
$realRoot = 'C:\Users\Home\Documents\ObsidianVault'
$realLog  = Join-Path $realRoot '.system\verify-log.ndjson'
T 'no evidence log appeared in the REAL vault' (-not (Test-Path -LiteralPath $realLog)) $realLog

# --- summary ---------------------------------------------------------------
$pass = @($results | Where-Object Pass).Count
$fail = @($results | Where-Object { -not $_.Pass }).Count
Write-Output ""
Write-Output ("{0}/{1} assertions passed" -f $pass, $results.Count)
if ($fail) {
    Write-Output "FAILED:"
    $results | Where-Object { -not $_.Pass } | ForEach-Object { Write-Output ("  - " + $_.Name) }
}
exit $(if ($fail) { 1 } else { 0 })
