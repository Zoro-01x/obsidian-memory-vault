# vault-write-guard.ps1
#
# Runs a command and PROVES the real vault was not written to while it ran.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .system\vault-write-guard.ps1 `
#       -Script .system\write-validation-test.ps1
#
# -Script takes a .ps1 or .mjs path and picks powershell.exe or node for you.
# Use -Command/-ArgumentList for anything else.
# This exists because on 2026-10-15 a restore proof ran the write-validation
# test against a clone, and the test hardcoded the live vault path, so it
# committed two `test`-authored commits into live history. Every test in this
# vault is now expected to run under this guard, so the same class of bug
# cannot land quietly again.
#
# The fingerprint covers HEAD, every ref, tracked changes and the untracked
# file list -- enough to notice a commit, a checkout, a dirty edit or a stray
# file. It FAILS LOUDLY and never auto-cleans: an unexpected write is evidence,
# and evidence you silently reverted is evidence you no longer have.
#
# Exit codes:
#   (child's own exit code)  vault untouched
#   3                        vault CHANGED -- the finding, not the cleanup
#   4                        setup failure (vault missing, git missing)
param(
    # Either -Script (the common case: run a .ps1 or .mjs under guard) ...
    [string]$Script = '',
    # ... or -Command/-ArgumentList for anything else.
    [string]$Command = '',
    [string[]]$ArgumentList = @(),
    # Left empty on purpose: $PSScriptRoot is not populated while parameter
    # defaults are bound, so the default is resolved in the body instead.
    [string]$Vault = ''
)

$ErrorActionPreference = 'Stop'

if (-not $PSScriptRoot) { Write-Error 'cannot resolve $PSScriptRoot; run this with -File'; exit 4 }
if (-not $Vault) { $Vault = Split-Path -Parent $PSScriptRoot }
if (-not (Test-Path -LiteralPath $Vault)) { Write-Error "vault not found: $Vault"; exit 4 }

# -Script keeps the child invocation in-process, so nothing round-trips through
# Windows command-line parsing and splits on commas or quotes.
if ($Script) {
    if (-not (Test-Path -LiteralPath $Script)) { Write-Error "script not found: $Script"; exit 4 }
    $Command = if ($Script -match '\.mjs$') { 'node' } else { 'powershell.exe' }
    $ArgumentList = if ($Command -eq 'node') { @($Script) }
                    else { @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Script) }
} elseif (-not $Command) {
    Write-Error 'pass either -Script <path> or -Command <exe>'; exit 4
}
. (Join-Path $PSScriptRoot 'vault-lib.ps1')
$git = Get-VaultGit
if (-not $git) { Write-Error 'git not found; cannot fingerprint the vault'; exit 4 }

function Get-VaultWriteFingerprint([string]$Repo) {
    # Child-process stderr is DATA, not an error: under EAP=Stop a native
    # command's warning promoted through a redirect becomes terminating.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $head = & $git -C $Repo rev-parse HEAD 2>$null
    $refs = @(& $git -C $Repo for-each-ref 2>$null)
    $porc = @(& $git -C $Repo status --porcelain --untracked-files=all 2>$null)
    $ErrorActionPreference = $prev
    return (@($head) + @($refs) + @($porc)) -join "`n"
}

$realRoot = [System.IO.Path]::GetFullPath((Get-VaultRoot))
$before   = Get-VaultWriteFingerprint -Repo $realRoot

& $Command @ArgumentList
$childExit = $LASTEXITCODE

$after = Get-VaultWriteFingerprint -Repo $realRoot

if ($before -ne $after) {
    ""
    "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    "!!! VAULT WRITE DETECTED DURING A TEST RUN"
    "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    "  vault   : $realRoot"
    "  command : $Command $($ArgumentList -join ' ')"
    ""
    "  BEFORE fingerprint:"
    $before -split "`n" | ForEach-Object { "    $_" }
    "  AFTER fingerprint:"
    $after  -split "`n" | ForEach-Object { "    $_" }
    ""
    "  Nothing has been reverted. This is evidence -- keep it."
    "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    exit 3
}

"guard: vault untouched by that command ($realRoot); child exit $childExit"
exit $childExit
