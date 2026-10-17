# native-stderr-test.ps1
#
# THE INVARIANT UNDER TEST:
#     If a verb reports REFUSED (or any failure), NOTHING may have changed on
#     disk or in the git index. If a verb reports success, the write must
#     actually be committed.
#
# WHY THIS EXISTS (found 2026-10-16 by demo-with-without.mjs):
#     `create` returned
#         REFUSED: warning: in the working copy of '...', LF will be replaced by CRLF
#     while the note was ALREADY WRITTEN and STAGED, with zero commits. The
#     caller was told nothing changed; something had.
#
#     Cause: vault-adapter.ps1 sets $ErrorActionPreference = 'Stop'. In Windows
#     PowerShell 5.1 a native command's STDERR becomes a terminating error under
#     that preference -- regardless of the process exit code, which was 0 here.
#     git warns on stderr about LF->CRLF when core.autocrlf is true and no
#     .gitattributes pins the eol. New-VaultNote writes the file FIRST (line 708)
#     and only then calls Save-VaultCommit, so the throw lands after the mutation.
#
#     The live vault hides this twice over: its .git/config sets autocrlf=false,
#     AND .gitattributes pins *.md to eol=lf. A scratch repo has neither. That is
#     precisely why write-validation-test.ps1 sets `core.autocrlf false` itself --
#     documented at its lines 99-105 -- so the existing 33/33 measured a cleaner
#     environment than any reviewer's machine. This file tests the dirty one.
#
# ISOLATION: every scenario builds its own git repo under %TEMP% carrying a
#     .vault-test-root sentinel and is passed to the adapter child via
#     OBSIDIAN_VAULT_ROOT. The library ignores that variable unless BOTH the
#     %TEMP% prefix and the sentinel are present, so the real vault cannot be
#     reached. This script never dot-sources the library and never writes to the
#     live vault.
#
# Run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .system/native-stderr-test.ps1
#
# Exit 0 = every assertion passed.

# The TEST HARNESS runs with EAP=Continue on purpose: this file makes its own
# raw git calls (log on an empty repo prints "fatal" to stderr and exits 1), and
# under Stop those would abort the harness itself -- which is the very trap under
# test. The adapter CHILD process still sets $ErrorActionPreference='Stop' inside
# vault-adapter.ps1, so the reproduction remains faithful.
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$adapter  = Join-Path $PSScriptRoot 'vault-adapter.ps1'
$gitExe   = $null
foreach ($c in @('C:\Users\Home\tools\git\cmd\git.exe',
                 "$env:ProgramFiles\Git\cmd\git.exe",
                 "${env:ProgramFiles(x86)}\Git\cmd\git.exe")) {
    if (-not $gitExe -and (Test-Path -LiteralPath $c)) { $gitExe = $c }
}
if (-not $gitExe) { $gitExe = 'git' }
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
    param([string]$Autocrlf = 'true', [switch]$GitAttributes, [switch]$FailingHook)
    $root = Join-Path $env:TEMP ('vault-stderr-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    foreach ($d in @('inbox', 'entities', 'decisions', 'lessons')) {
        New-Item -ItemType Directory -Path (Join-Path $root $d) -Force | Out-Null
    }
    & $gitExe -C $root init -q 2>$null | Out-Null
    & $gitExe -C $root config user.name  'stderr-test'
    & $gitExe -C $root config user.email 'stderr-test@example.invalid'
    # Mimic a FRESH CLONE: .git/config is not copied on clone, so the clone
    # inherits the system-level value. Here the system value is autocrlf=true.
    & $gitExe -C $root config core.autocrlf $Autocrlf 2>$null | Out-Null
    if ($GitAttributes) {
        [System.IO.File]::WriteAllText((Join-Path $root '.gitattributes'),
            "*.md text eol=lf`n", (New-Object System.Text.UTF8Encoding($false)))
    }
    if ($FailingHook) {
        $hook = Join-Path $root '.git\hooks\pre-commit'
        New-Item -ItemType Directory -Path (Split-Path $hook) -Force | Out-Null
        # A REAL post-write failure. git for Windows executes hooks via sh, so
        # this must be a POSIX script (a .cmd-style hook yields "cannot spawn",
        # which is a different, earlier failure). It prints to stderr and exits 1
        # AFTER the note is already written and staged.
        [System.IO.File]::WriteAllText($hook,
            "#!/bin/sh`necho 'hook says no' >&2`nexit 1`n", (New-Object System.Text.ASCIIEncoding))
    }
    [System.IO.File]::WriteAllText((Join-Path $root '.vault-test-root'),
        "native-stderr test`n", (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $root 'CORE.md'),
        "---`nname: CORE`n---`n`n# CORE`n`nScratch repo.`n", (New-Object System.Text.UTF8Encoding($false)))
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
    $null = $p.WaitForExit(60000)
    $parsed = $null
    try { $parsed = $out.Trim() | ConvertFrom-Json } catch { }
    return [pscustomobject]@{
        Raw     = $out
        StdErr  = $err
        Parsed  = $parsed
        Ok      = if ($parsed) { [bool]$parsed.ok } else { $false }
        Error   = if ($parsed -and $parsed.PSObject.Properties['error']) { [string]$parsed.error } else { '' }
        Partial = if ($parsed -and $parsed.PSObject.Properties['partial']) { [bool]$parsed.partial } else { $false }
        Path    = if ($parsed -and $parsed.PSObject.Properties['path'])    { [string]$parsed.path }    else { '' }
        ReportsRefused = ($out -match 'REFUSED')
        # The invariant keys off reported FAILURE, not the literal 'REFUSED'
        # string. The 'REFUSED:' prefix is added one layer up, in vault-mcp.mjs
        # (lines ~353-357), which rewrites the adapter's error. At the adapter
        # boundary the lie surfaces as ok=false while the disk already changed.
        ReportsFailure = (-not ([bool]$parsed -and [bool]$parsed.ok))
    }
}

function Get-GitState {
    param([string]$Root, [string]$RelPath)
    $exists  = Test-Path -LiteralPath (Join-Path $Root $RelPath)
    $status  = (& $gitExe -C $Root status --porcelain 2>$null) -join "`n"
    $commits = (& $gitExe -C $Root log --oneline -- $RelPath 2>$null) -join "`n"
    [pscustomobject]@{
        Exists    = $exists
        Staged    = ($status -match [regex]::Escape(($RelPath -replace '\\','/')))
        HasCommit = (-not [string]::IsNullOrWhiteSpace($commits))
        Status    = $status
    }
}

$noteArgs = @{
    folder      = 'decisions'
    name        = 'Harbor API port decision'
    description = 'Harbor API binds 3001'
    body        = "The Harbor API runs on **3001**, never 3000.`n`nPort 3000 belongs to the dashboard."
    aliases     = @('api port')
    basis       = 'observed'
    scope       = 'harbor'
    verified    = '2026-10-17'
    status      = 'active'
    author      = 'stderr-test'
}
$rel = 'decisions\Harbor API port decision.md'

Write-Output '=== native stderr vs. write honesty (Windows PowerShell 5.1) ==='
Write-Output ('PS {0} | git {1} | adapter {2}' -f
    $PSVersionTable.PSVersion, (& $gitExe --version), (Split-Path $adapter -Leaf))
Write-Output ''

# ---------------------------------------------------------------------------
# S1: the environment the demo actually hit. No .gitattributes, autocrlf=true.
# ---------------------------------------------------------------------------
Write-Output '--- S1: default-config scratch (autocrlf=true, NO .gitattributes) ---'
$root1 = New-ScratchVault -Autocrlf 'true'
$r1 = Invoke-VaultAdapter -Root $root1 -Verb 'create' -Arguments $noteArgs
$s1 = Get-GitState -Root $root1 -RelPath $rel

T 'S1: adapter reports success' $r1.Ok ($r1.Error.Substring(0, [Math]::Min(160, $r1.Error.Length)))
T 'S1: the note exists on disk' $s1.Exists
T 'S1: the note was committed' $s1.HasCommit ("status=[" + ($s1.Status -replace "`n", '; ') + "]")
T 'S1: a git warning is NOT reported as a failure' (-not $r1.ReportsFailure) `
    $(if ($r1.ReportsFailure) { 'ok=false on a git WARNING (exit 0) -- ' + $r1.Error.Substring(0, [Math]::Min(120, $r1.Error.Length)) } else { '' })

# ---------------------------------------------------------------------------
# S2: THE INVARIANT -- a reported failure must imply nothing changed.
# ---------------------------------------------------------------------------
Write-Output ''
Write-Output '--- S2: reported-failure-implies-nothing-changed invariant ---'
$failedAndTouched = ($r1.ReportsFailure -and ($s1.Exists -or $s1.Staged -or $s1.HasCommit))
T 'S2: if the verb reports failure, nothing changed on disk' (-not $failedAndTouched) `
    $(if ($failedAndTouched) { 'FAILURE reported BUT file exists/staged/committed -- caller was told nothing happened; it did' } else { 'held' })

# ---------------------------------------------------------------------------
# S3: clone shape -- .gitattributes pins the eol, so git stays silent.
# ---------------------------------------------------------------------------
Write-Output ''
Write-Output '--- S3: clone-shaped repo (.gitattributes present, autocrlf=true) ---'
$root3 = New-ScratchVault -Autocrlf 'true' -GitAttributes
$r3 = Invoke-VaultAdapter -Root $root3 -Verb 'create' -Arguments $noteArgs
$s3 = Get-GitState -Root $root3 -RelPath $rel
T 'S3: adapter reports success' $r3.Ok ($r3.Error.Substring(0, [Math]::Min(160, $r3.Error.Length)))
T 'S3: note committed' ($s3.Exists -and $s3.HasCommit)

# ---------------------------------------------------------------------------
# S4: a REAL post-write failure (pre-commit hook exits 1 after the write).
#      Reporting bare REFUSED here is still a lie: the file is on disk.
# ---------------------------------------------------------------------------
Write-Output ''
Write-Output '--- S4: post-write failure (pre-commit hook exits 1) ---'
$root4 = New-ScratchVault -Autocrlf 'false' -FailingHook
$r4 = Invoke-VaultAdapter -Root $root4 -Verb 'create' -Arguments $noteArgs
$s4 = Get-GitState -Root $root4 -RelPath $rel
T 'S4: hook really did fail the commit' (-not $s4.HasCommit)
T 'S4: file is on disk (the mutation happened)' $s4.Exists
$status = if ($r4.Parsed.errorType) { [string]$r4.Parsed.errorType } else { '' }
T 'S4: post-write failure reports a DISTINCT written-not-committed state' `
    ($status -eq 'PartialWrite') `
    ("errorType='$status' (a bare ok=false would be the lie this test was written to catch)")
T 'S4: a post-write failure does not masquerade as a plain refusal' `
    (-not ($r4.ReportsFailure -and $s4.Exists -and -not $r4.Partial)) `
    $(if ($r4.Partial) { 'partial state present -- caller can tell written-from-committed' } else { 'no partial state' })
T 'S4: reports the PARTIAL state, not a clean ok' $r4.Partial `
    $(if ($r4.Partial) { 'partial=true' } else { 'partial flag absent -- caller cannot tell written-from-committed' })
T 'S4: names the on-disk path so the caller can recover' ($r4.Path -match 'decisions|Harbor') `
    $(if ($r4.Path) { $r4.Path } else { '(empty)' })
T 'S4: the failure names the path or state so the caller can recover' `
    ($r4.Error -match 'decisions|commit|partial|written|Harbor') `
    $(if ($r4.Error) { $r4.Error.Substring(0, [Math]::Min(160, $r4.Error.Length)) } else { '(empty)' })

# ---------------------------------------------------------------------------
# S5: a git shim that prints extra warnings on stderr but exits 0.
#      Nonempty stderr is NOT a failure.
# ---------------------------------------------------------------------------
Write-Output ''
Write-Output '--- S5: git shim adds stderr noise, exit code 0 ---'
$shimDir = Join-Path $env:TEMP ('gitshim-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $shimDir -Force | Out-Null
$shim = Join-Path $shimDir 'git.cmd'
[System.IO.File]::WriteAllText($shim,
    "@echo off`r`necho warning: shim noise on stderr 1>&2`r`n`"" + $gitExe + "`" %*`r`n",
    (New-Object System.Text.ASCIIEncoding))

$root5 = New-ScratchVault -Autocrlf 'false'
$psi5 = New-Object System.Diagnostics.ProcessStartInfo
$psi5.FileName               = 'powershell.exe'
$psi5.Arguments              = '-NoProfile -ExecutionPolicy Bypass -File "' + $adapter + '" -Verb create'
$psi5.RedirectStandardInput  = $true
$psi5.RedirectStandardOutput = $true
$psi5.RedirectStandardError  = $true
$psi5.UseShellExecute        = $false
$psi5.CreateNoWindow         = $true
$psi5.EnvironmentVariables['OBSIDIAN_VAULT_ROOT'] = $root5
$psi5.EnvironmentVariables['PATH'] = $shimDir + ';' + $env:PATH
$p5 = [System.Diagnostics.Process]::Start($psi5)
$p5.StandardInput.Write((($noteArgs) | ConvertTo-Json -Depth 8 -Compress))
$p5.StandardInput.Close()
$out5 = $p5.StandardOutput.ReadToEnd()
$null = $p5.StandardError.ReadToEnd()
$null = $p5.WaitForExit(60000)
$parsed5 = $null
try { $parsed5 = $out5.Trim() | ConvertFrom-Json } catch { }
$s5 = Get-GitState -Root $root5 -RelPath $rel
$shimSawWarning = ($out5 -match 'REFUSED')
T 'S5: shim was actually used' (Test-Path -LiteralPath $shim)
T 'S5: create still reports success with extra stderr noise' ($parsed5 -and [bool]$parsed5.ok) `
    $(if ($parsed5) { } else { 'unparseable: ' + $out5.Substring(0, [Math]::Min(160, $out5.Length)) })
T 'S5: note committed under shim' ($s5.Exists -and $s5.HasCommit)
T 'S5: stderr noise not reported as REFUSED' (-not $shimSawWarning) `
    $(if ($shimSawWarning) { $out5.Substring(0, [Math]::Min(160, $out5.Length)) } else { '' })

# ---------------------------------------------------------------------------
Write-Output ''
foreach ($r in @($root1, $root3, $root4, $root5)) {
    if ($r -and (Test-Path -LiteralPath $r)) {
        # Leave staged files behind on purpose? No -- clean up like a good citizen.
        Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue
    }
}
if (Test-Path -LiteralPath $shimDir) { Remove-Item -LiteralPath $shimDir -Recurse -Force -ErrorAction SilentlyContinue }

$failed = @($results | Where-Object { -not $_.Pass })
Write-Output ''
Write-Output ('{0}/{1} passed' -f ($results.Count - $failed.Count), $results.Count)
exit $(if ($failed.Count) { 1 } else { 0 })
