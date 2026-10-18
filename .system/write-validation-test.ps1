# write-validation-test.ps1
#
# Proves schema enforcement happens BEFORE writes, and that -Set respects its
# whitelist. Run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .system/write-validation-test.ps1
#
# ISOLATION (this is the whole point of the file's shape):
#   This test NEVER writes to the real vault. It builds a scratch git repo
#   under %TEMP%, plants a .vault-test-root sentinel in it, points
#   OBSIDIAN_VAULT_ROOT at it, reloads the library, and then refuses to run
#   any write assertion unless the resolved root is that scratch repo.
#
#   Why the precondition exists: an earlier version of this file hardcoded the
#   live vault path on line 14 and dot-sourced the live library, so the -Set
#   round trip committed straight into live history. During a restore proof on
#   2026-10-15 that put two `test`-authored commits on top of the pushed
#   backup. A write test that reaches the real vault eventually commits to the
#   very audit trail it exists to protect.
#
# Idempotent: every refusal creates nothing, and the -Set round trip changes
# status to stale and back to active inside the SCRATCH repo, so the real
# vault's git state is untouched. The last assertion proves that directly by
# fingerprinting the real vault before and after the run.
#
# Exit codes:
#   0 = all assertions passed
#   1 = at least one assertion failed
#   2 = isolation precondition failed; NO write was attempted
$ErrorActionPreference = 'Stop'

# Resolve the vault this COPY of the test lives in, and the library NEXT TO it,
# from the script's own location. Never a literal path: a literal makes the
# test silently target the live vault no matter where it was cloned.
$sysDir = $PSScriptRoot
if (-not $sysDir) { throw 'cannot resolve $PSScriptRoot; run this with -File, do not paste it into a prompt' }
$vault  = Split-Path -Parent $sysDir
. (Join-Path $sysDir 'vault-lib.ps1')

$pass = 0; $fail = 0
function T([string]$name, [bool]$cond, [string]$detail = '') {
    if ($cond) { $script:pass++; "PASS  $name$(if($detail){' -- '+$detail})" }
    else       { $script:fail++; "FAIL  $name$(if($detail){' -- '+$detail})" }
}

# Fingerprints a git repo well enough to notice any write: HEAD, every ref,
# tracked changes, and untracked files.
function Get-VaultStateFingerprint([string]$Repo) {
    $g = Get-VaultGit
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $head   = & $g -C $Repo rev-parse HEAD 2>$null
    $refs   = @(& $g -C $Repo for-each-ref 2>$null)
    $porc   = @(& $g -C $Repo status --porcelain 2>$null)
    $ErrorActionPreference = $prev
    return (($head) + "`n" + (@($refs) -join "`n") + "`n" + (@($porc) -join "`n"))
}

# True only if the resolved root is inside %TEMP% AND carries the sentinel.
# Fail closed: anything else is a reason to stop, not a reason to continue.
function Test-WriteIsolation {
    $root   = [System.IO.Path]::GetFullPath((Get-VaultRoot))
    $temp   = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
    $under  = $root.StartsWith($temp + '\', [System.StringComparison]::OrdinalIgnoreCase)
    $sent   = Test-Path -LiteralPath (Join-Path $root '.vault-test-root')
    return @{ Root = $root; UnderTemp = $under; Sentinel = $sent; Ok = ($under -and $sent) }
}

function Stop-NotIsolated([string]$Where, $State) {
    "ABORT before '$Where': this test may only write inside a scratch repo."
    "  resolved vault root : $($State.Root)"
    "  override status     : $(Get-VaultOverrideStatus)"
    "  inside %TEMP%       : $($State.UnderTemp)"
    "  sentinel present    : $($State.Sentinel)"
    "No write was attempted."
    exit 2
}

$realVault = $vault
$realBefore = Get-VaultStateFingerprint -Repo $realVault

"--- Test-VaultData runs without touching disk ---"
$p = @(Test-VaultData -Data @{} -Path 'nowhere.md')
T 'empty hashtable reports missing fields (not an exception)' ($p.Count -ge 7) "$($p.Count) problems"

"--- scratch repo (the ONLY place this test writes) ---"
$tmpRoot = Join-Path $env:TEMP ('vault-iso-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$savedRoot = $env:OBSIDIAN_VAULT_ROOT
try {
    $g = Get-VaultGit
    T 'git is available' ([bool]$g) $(if ($g) { $g } else { 'Get-VaultGit returned null' })
    if (-not $g) { throw 'git is required for the write assertions' }

    foreach ($d in @('inbox','entities','decisions','lessons')) {
        New-Item -ItemType Directory -Path (Join-Path $tmpRoot $d) -Force | Out-Null
    }
    & $g -C $tmpRoot init -q 2>$null
    & $g -C $tmpRoot config user.name  'test'
    & $g -C $tmpRoot config user.email 'test@example.invalid'
    # Line-ending normalization OFF in the scratch repo. With the default
    # autocrlf, git warns on stderr about LF/CRLF, and under
    # $ErrorActionPreference='Stop' a native command's stderr becomes a
    # terminating error -- which silently killed this section after its first
    # assertion. A throwaway repo has no working-copy history to preserve, so
    # there is nothing for normalization to protect.
    & $g -C $tmpRoot config core.autocrlf false 2>$null
    & $g -C $tmpRoot config core.safecrlf false 2>$null

    # The sentinel is what makes the override legal; without it the library
    # refuses the env var and stays on the real vault.
    Set-Content -LiteralPath (Join-Path $tmpRoot '.vault-test-root') -Value 'test-only' -Encoding UTF8
    $env:OBSIDIAN_VAULT_ROOT = $tmpRoot
    . (Join-Path $sysDir 'vault-lib.ps1')

    # ---- FAILOUT PRECONDITION ----
    # Nothing below writes until this holds. This is what makes a future edit
    # harmless: the root cannot drift back to a real vault without the test
    # stopping first.
    $iso = Test-WriteIsolation
    T 'library reloaded against the scratch repo' ((Get-VaultRoot) -eq $tmpRoot) (Get-VaultRoot)
    T 'sentinel override was HONORED' ((Get-VaultOverrideStatus) -eq 'honored') (Get-VaultOverrideStatus)
    if (-not $iso.Ok) { Stop-NotIsolated 'write assertions' $iso }
    T 'isolation precondition met (inside %TEMP% + sentinel)' $true $iso.Root

    # Seed the fixture INSIDE the scratch repo. Depending on a note that exists
    # in the live vault is what tied these assertions to the live vault.
    $target = 'decisions/Write fixture.md'
    New-VaultNote -Folder 'decisions' -Name 'Write fixture' `
        -Description 'Fixture note used only by the write-validation test' `
        -Body ('Body of the fixture. ' * 8).Trim() `
        -Scope 'test' -Basis 'observed' -Author 'test' | Out-Null
    T 'fixture note seeded in the scratch repo' (Test-Path -LiteralPath (Join-Path $tmpRoot $target))

    "--- write-time validation in New-VaultNote ---"
    # Code-shaped description WITHOUT a verified date must be refused before writing.
    $before = @(Get-ChildItem (Join-Path $tmpRoot 'lessons') -Filter '*.md')
    try {
        New-VaultNote -Folder 'lessons' -Name 'ZZ should not exist' `
            -Description 'This command line path config install breaks in v2' `
            -Body 'x' -Scope 'toolchain' -Basis 'observed' -Author 'test' | Out-Null
        T 'code-shaped note without verified is REFUSED' $false 'it was created'
    } catch {
        T 'code-shaped note without verified is REFUSED' ($_.Exception.Message -match 'verified') $_.Exception.Message
    }
    $after = @(Get-ChildItem (Join-Path $tmpRoot 'lessons') -Filter '*.md')
    T 'no file was written by the refused create' ($before.Count -eq $after.Count) "$($before.Count) -> $($after.Count)"

    # The SAME code-shaped claim CAN be staged into inbox/. propose cannot pass
    # a verified date at all, so requiring one there made every code-shaped
    # external claim unstaggable -- which pushes the agent toward laundering it
    # as `observed` instead. Found by adversarial-demo-test 2026-10-18; no
    # suite had proposed a code-shaped claim before that demo. The control
    # immediately below proves the exemption is staging-only: promotion still
    # refuses the identical description.
    $inboxBefore = @(Get-ChildItem (Join-Path $tmpRoot 'inbox') -Filter '*.md')
    try {
        New-VaultNote -Folder 'inbox' -Name 'ZZ staged code claim' `
            -Description 'This command line path config install breaks in v2' `
            -Body 'x' -Scope 'toolchain' -Basis 'external-model' -Author 'test' | Out-Null
        T 'code-shaped claim CAN be staged into inbox (staging is unverified by construction)' $true
    } catch {
        T 'code-shaped claim CAN be staged into inbox (staging is unverified by construction)' $false $_.Exception.Message
    }
    $inboxAfter = @(Get-ChildItem (Join-Path $tmpRoot 'inbox') -Filter '*.md')
    T 'the staged claim was written to inbox' ($inboxAfter.Count -eq ($inboxBefore.Count + 1)) "$($inboxBefore.Count) -> $($inboxAfter.Count)"
    try {
        New-VaultNote -Folder 'entities' -Name 'ZZ promoted code claim' `
            -Description 'This command line path config install breaks in v2' `
            -Body 'x' -Scope 'toolchain' -Basis 'observed' -Author 'test' | Out-Null
        T 'control: the identical description is STILL REFUSED on promotion to entities' $false 'it was created'
    } catch {
        T 'control: the identical description is STILL REFUSED on promotion to entities' ($_.Exception.Message -match 'verified') ($_.Exception.Message -split "`n")[0]
    }

    # Bad date format must be refused.
    try {
        New-VaultNote -Folder 'lessons' -Name 'ZZ bad date' -Description 'Some code path thing' `
            -Body 'x' -Scope 'toolchain' -Basis 'observed' -Verified 'recently' -Author 'test' | Out-Null
        T 'verified="recently" is REFUSED' $false 'accepted'
    } catch {
        T 'verified="recently" is REFUSED' ($_.Exception.Message -match 'YYYY-MM-DD') $_.Exception.Message
    }
    T 'no stray ZZ files in lessons' (-not (Get-ChildItem (Join-Path $tmpRoot 'lessons') -Filter 'ZZ*.md')) ((Get-ChildItem (Join-Path $tmpRoot 'lessons') -Filter 'ZZ*.md' | ForEach-Object Name) -join ',')

    "--- -Set whitelist in Update-VaultNote ---"
    foreach ($bad in @('name', 'updated', 'created', 'type', 'author')) {
        try {
            Update-VaultNote -RelativePath $target -Set @{ $bad = 'whatever' } -Author 'test' | Out-Null
            T "field '$bad' is NOT mutable" $false 'it was accepted'
        } catch {
            T "field '$bad' is NOT mutable" ($_.Exception.Message -match 'not mutable') ($_.Exception.Message -split "`n")[0]
        }
    }
    # `verified` left the -Set whitelist on 2026-10-17. Two independent
    # consultations converged on it: a model that can re-stamp `verified` on a
    # note it already wrote is a model that certifies its own homework, and
    # git history keeps the unverified original while the note still READS as
    # verified. Re-verification is now the `verify` verb's job: it executes a
    # probe and appends to an evidence log under .system/ that no write verb
    # can reach.
    try {
        Update-VaultNote -RelativePath $target -Set @{ verified = 'someday' } -Author 'test' | Out-Null
        T 'verified is NOT mutable through set' $false 'it was accepted'
    } catch {
        T 'verified is NOT mutable through set' ($_.Exception.Message -match 'not mutable') ($_.Exception.Message -split "`n")[0]
    }
    try {
        Update-VaultNote -RelativePath $target -Set @{ status = 'banana' } -Author 'test' | Out-Null
        T "status='banana' is REFUSED" $false 'accepted'
    } catch {
        T "status='banana' is REFUSED" ($_.Exception.Message -match 'invalid status|would end up invalid') ($_.Exception.Message -split "`n")[0]
    }

    "--- real set round trip (then restore) ---"
    $beforeFm = Read-VaultFrontmatter -Path (Resolve-VaultSafePath $target)
    $r = Update-VaultNote -RelativePath $target -Set @{ status = 'stale' } -Author 'test'
    $midFm = Read-VaultFrontmatter -Path (Resolve-VaultSafePath $target)
    T 'status actually changed to stale' ($midFm.status -eq 'stale') "status=$($midFm.status) action=$($r.Action)"
    T 'updated was refreshed to today' ($midFm.updated -eq (Get-Date).ToString('yyyy-MM-dd')) $midFm.updated
    T 'other fields untouched' ($midFm.basis -eq $beforeFm.basis -and $midFm.scope -eq $beforeFm.scope -and @($midFm.aliases).Count -eq @($beforeFm.aliases).Count)
    $r2 = Update-VaultNote -RelativePath $target -Set @{ status = 'active' } -Author 'test'
    $back = Read-VaultFrontmatter -Path (Resolve-VaultSafePath $target)
    T 'restored to active' ($back.status -eq 'active') "status=$($back.status)"
    T 'body survived the two frontmatter edits' ((Get-VaultNoteBody -Path (Resolve-VaultSafePath $target)).Length -gt 50)

    "--- the round trip really committed (into the SCRATCH repo) ---"
    # git's --author matches against "Name <email>", so a '^test$' anchor never
    # matches anything. Key on the verb's commit subject instead.
    $isoCommits = @(& $g -C $tmpRoot log --format='%an|%s' | Where-Object { $_ -match '\[test\] set\(status\)' })
    T 'scratch repo gained the round-trip commits' (@($isoCommits).Count -eq 2) (@($isoCommits) -join ' ; ')

    "--- every note still valid after the refactor ---"
    Get-ChildItem $tmpRoot -Recurse -Filter '*.md' -File |
        Where-Object { $_.FullName -notmatch '\\\.obsidian\\|\\\.system\\' } |
        ForEach-Object {
            $v = Test-VaultNote -Path $_.FullName
            T "valid: $($_.Name)" $v.Valid (($v.Problems -join '; '))
        }

    "--- commit isolation (staging discipline) ---"
    # The `git add -A` bug bundled unrelated pending edits into a note-shaped
    # commit. This proves a verb stages ONLY the path it wrote.
    $tracked = Join-Path $tmpRoot 'scratch-tracked.md'
    Set-Content -LiteralPath $tracked -Value "original`n" -Encoding UTF8
    & $g -C $tmpRoot add scratch-tracked.md
    & $g -C $tmpRoot commit -q -m 'seed tracked file'
    Set-Content -LiteralPath $tracked -Value "UNRELATED EDIT`n" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $tmpRoot 'scratch-untracked.md') -Value "untracked`n" -Encoding UTF8

    $headBefore = & $g -C $tmpRoot rev-parse HEAD
    Update-VaultNote -RelativePath $target -AppendText 'Body B' -Author 'test' | Out-Null
    $headAfter = & $g -C $tmpRoot rev-parse HEAD

    $files = @(& $g -C $tmpRoot diff-tree --no-commit-id --name-only -r HEAD)
    T 'commit contains EXACTLY the note path' ($files.Count -eq 1 -and $files[0] -eq $target) ($files -join ', ')
    T 'the verb produced a new commit' ($headBefore -ne $headAfter)

    $porcelain = @(& $g -C $tmpRoot status --porcelain)
    $trackedLine = $porcelain | Where-Object { $_ -match 'scratch-tracked\.md' }
    T 'dirty TRACKED file stays unstaged and uncommitted' ($null -ne $trackedLine -and $trackedLine -match '^ M ') ($porcelain -join ' | ')
    T 'UNTRACKED file still untracked' (@($porcelain | Where-Object { $_ -match 'scratch-untracked\.md' -and $_ -match '\?\?' }).Count -eq 1)

    # A refused write must stage nothing and commit nothing.
    $headBeforeBad = & $g -C $tmpRoot rev-parse HEAD
    try {
        New-VaultNote -Folder 'lessons' -Name 'ZZ refused' -Description 'Some code path thing' `
            -Body 'x' -Scope 'toolchain' -Basis 'observed' -Verified 'someday' -Author 'test' | Out-Null
        T 'refused write throws' $false 'it was accepted'
    } catch {
        T 'refused write throws' $true ($_.Exception.Message -split "`n")[0]
    }
    T 'refused write created NO commit' ((& $g -C $tmpRoot rev-parse HEAD) -eq $headBeforeBad)
    T 'refused write staged NOTHING' (@(& $g -C $tmpRoot diff --cached --name-only).Count -eq 0)
}
finally {
    if ($null -ne $savedRoot) { $env:OBSIDIAN_VAULT_ROOT = $savedRoot }
    else                       { Remove-Item Env:OBSIDIAN_VAULT_ROOT -ErrorAction SilentlyContinue }
    # Reload against the real vault so nothing after this sees the temp root.
    . (Join-Path $sysDir 'vault-lib.ps1')
    if (Test-Path -LiteralPath $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force }
}

"--- the real vault was not written to ---"
$realAfter = Get-VaultStateFingerprint -Repo $realVault
T 'scratch repo cleaned up' (-not (Test-Path -LiteralPath $tmpRoot))
T 'real vault git state unchanged by this run' ($realBefore -eq $realAfter) `
    $(if ($realBefore -eq $realAfter) { $realVault } else { "CHANGED -- real vault HEAD/status/refs moved during the run" })

""
"$pass passed, $fail failed"
exit $(if ($fail) { 1 } else { 0 })
