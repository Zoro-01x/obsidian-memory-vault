# write-validation-test.ps1
#
# Proves schema enforcement happens BEFORE writes, and that -Set respects its
# whitelist. Run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .system/write-validation-test.ps1
#
# Idempotent: every refusal creates nothing, and the -Set round trip changes
# status to stale and back to active, so re-running leaves no net change.
# SIDE EFFECT: that round trip produces two git commits (author `test`), which
# is unavoidable -- the verbs always commit.
#
# Exit code 0 = all assertions passed.
$ErrorActionPreference = 'Stop'
$vault = 'C:\Users\Home\Documents\ObsidianVault'
. (Join-Path $vault '.system\vault-lib.ps1')

$pass = 0; $fail = 0
function T([string]$name, [bool]$cond, [string]$detail = '') {
    if ($cond) { $script:pass++; "PASS  $name$(if($detail){' -- '+$detail})" }
    else       { $script:fail++; "FAIL  $name$(if($detail){' -- '+$detail})" }
}

"--- Test-VaultData runs without touching disk ---"
$p = @(Test-VaultData -Data @{} -Path 'nowhere.md')
T 'empty hashtable reports missing fields (not an exception)' ($p.Count -ge 7) "$($p.Count) problems"

"--- write-time validation in New-VaultNote ---"
# Code-shaped description WITHOUT a verified date must be refused before writing.
$before = @(Get-ChildItem "$vault\lessons" -Filter '*.md')
try {
    New-VaultNote -Folder 'lessons' -Name 'ZZ should not exist' `
        -Description 'This command line path config install breaks in v2' `
        -Body 'x' -Scope 'toolchain' -Basis 'observed' -Author 'test' | Out-Null
    T 'code-shaped note without verified is REFUSED' $false 'it was created'
} catch {
    T 'code-shaped note without verified is REFUSED' ($_.Exception.Message -match 'verified') $_.Exception.Message
}
$after = @(Get-ChildItem "$vault\lessons" -Filter '*.md')
T 'no file was written by the refused create' ($before.Count -eq $after.Count) "$($before.Count) -> $($after.Count)"

# Bad date format must be refused.
try {
    New-VaultNote -Folder 'lessons' -Name 'ZZ bad date' -Description 'Some code path thing' `
        -Body 'x' -Scope 'toolchain' -Basis 'observed' -Verified 'recently' -Author 'test' | Out-Null
    T 'verified="recently" is REFUSED' $false 'accepted'
} catch {
    T 'verified="recently" is REFUSED' ($_.Exception.Message -match 'YYYY-MM-DD') $_.Exception.Message
}
T 'no stray ZZ files in lessons' (-not (Get-ChildItem "$vault\lessons" -Filter 'ZZ*.md')) ( (Get-ChildItem "$vault\lessons" -Filter 'ZZ*.md' | ForEach-Object Name) -join ',' )

"--- -Set whitelist in Update-VaultNote ---"
$target = 'decisions/Council write protocol.md'

foreach ($bad in @('name', 'updated', 'created', 'type', 'author')) {
    try {
        Update-VaultNote -RelativePath $target -Set @{ $bad = 'whatever' } -Author 'test' | Out-Null
        T "field '$bad' is NOT mutable" $false 'it was accepted'
    } catch {
        T "field '$bad' is NOT mutable" ($_.Exception.Message -match 'not mutable') ($_.Exception.Message -split "`n")[0]
    }
}
try {
    Update-VaultNote -RelativePath $target -Set @{ verified = 'someday' } -Author 'test' | Out-Null
    T 'verified set to garbage is REFUSED' $false 'accepted'
} catch {
    T 'verified set to garbage is REFUSED' ($_.Exception.Message -match 'YYYY-MM-DD') ($_.Exception.Message -split "`n")[0]
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

"--- every note still valid after the refactor ---"
Get-ChildItem $vault -Recurse -Filter '*.md' -File |
    Where-Object { $_.FullName -notmatch '\\\.obsidian\\|\\\.system\\' } |
    ForEach-Object {
        $v = Test-VaultNote -Path $_.FullName
        T "valid: $($_.Name)" $v.Valid (($v.Problems -join '; '))
    }

"--- commit isolation (throwaway repo) ---"
# The `git add -A` bug bundled unrelated pending edits into a note-shaped
# commit. This proves a verb stages ONLY the path it wrote. It runs against a
# scratch repo in TEMP, never the live vault -- a test that commits to live
# history eventually pollutes the very audit trail it exists to protect.
$git = Get-VaultGit
if (-not $git) {
    T 'git is available' $false 'Get-VaultGit returned null'
} else {
    $tmpRoot = Join-Path $env:TEMP ('vault-iso-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    $savedRoot = $env:OBSIDIAN_VAULT_ROOT
    try {
        foreach ($d in @('inbox','entities','decisions','lessons')) {
            New-Item -ItemType Directory -Path (Join-Path $tmpRoot $d) -Force | Out-Null
        }
        & $git -C $tmpRoot init -q 2>$null
        & $git -C $tmpRoot config user.name  'test'
        & $git -C $tmpRoot config user.email 'test@example.invalid'
        # Line-ending normalization OFF in the scratch repo. With the default
        # autocrlf, git warns on stderr about LF/CRLF, and under
        # $ErrorActionPreference='Stop' a native command's stderr becomes a
        # terminating error -- which silently killed this section after its
        # first assertion. A throwaway repo has no working-copy history to
        # preserve, so there is nothing for normalization to protect.
        & $git -C $tmpRoot config core.autocrlf false 2>$null
        & $git -C $tmpRoot config core.safecrlf false 2>$null

        # A tracked file that a verb will NOT touch, left deliberately dirty.
        $tracked = Join-Path $tmpRoot 'scratch-tracked.md'
        Set-Content -LiteralPath $tracked -Value "original`n" -Encoding UTF8
        & $git -C $tmpRoot add scratch-tracked.md
        & $git -C $tmpRoot commit -q -m 'seed tracked file'
        Set-Content -LiteralPath $tracked -Value "UNRELATED EDIT`n" -Encoding UTF8

        # An untracked file, also never touched by the verb.
        Set-Content -LiteralPath (Join-Path $tmpRoot 'scratch-untracked.md') -Value "untracked`n" -Encoding UTF8

        # Point the library at the scratch repo and reload it there.
        $env:OBSIDIAN_VAULT_ROOT = $tmpRoot
        . (Join-Path $vault '.system\vault-lib.ps1')
        T 'library reloaded against the throwaway repo' ((Get-VaultRoot) -eq $tmpRoot) (Get-VaultRoot)

        $isoNote = 'decisions/Isolation probe.md'
        New-VaultNote -Folder 'decisions' -Name 'Isolation probe' `
            -Description 'Scratch note used only by the isolation check' `
            -Body 'Body A' -Scope 'test' -Basis 'observed' -Author 'test' | Out-Null

        $headBefore = & $git -C $tmpRoot rev-parse HEAD
        Update-VaultNote -RelativePath $isoNote -AppendText 'Body B' -Author 'test' | Out-Null
        $headAfter = & $git -C $tmpRoot rev-parse HEAD

        $files = @(& $git -C $tmpRoot diff-tree --no-commit-id --name-only -r HEAD)
        T 'commit contains EXACTLY the note path' ($files.Count -eq 1 -and $files[0] -eq $isoNote) ($files -join ', ')
        T 'the verb produced a new commit' ($headBefore -ne $headAfter)

        $porcelain = @(& $git -C $tmpRoot status --porcelain)
        $trackedLine = $porcelain | Where-Object { $_ -match 'scratch-tracked\.md' }
        T 'dirty TRACKED file stays unstaged and uncommitted' ($null -ne $trackedLine -and $trackedLine -match '^ M ') ($porcelain -join ' | ')
        T 'UNTRACKED file still untracked' (@($porcelain | Where-Object { $_ -match 'scratch-untracked\.md' -and $_ -match '\?\?' }).Count -eq 1)

        # A refused write must stage nothing and commit nothing.
        $headBeforeBad = & $git -C $tmpRoot rev-parse HEAD
        try {
            New-VaultNote -Folder 'lessons' -Name 'ZZ refused' -Description 'Some code path thing' `
                -Body 'x' -Scope 'toolchain' -Basis 'observed' -Verified 'someday' -Author 'test' | Out-Null
            T 'refused write throws' $false 'it was accepted'
        } catch {
            T 'refused write throws' $true ($_.Exception.Message -split "`n")[0]
        }
        T 'refused write created NO commit' ((& $git -C $tmpRoot rev-parse HEAD) -eq $headBeforeBad)
        T 'refused write staged NOTHING' (@(& $git -C $tmpRoot diff --cached --name-only).Count -eq 0)
    }
    finally {
        if ($null -ne $savedRoot) { $env:OBSIDIAN_VAULT_ROOT = $savedRoot }
        else                       { Remove-Item Env:OBSIDIAN_VAULT_ROOT -ErrorAction SilentlyContinue }
        # Reload against the real vault so nothing after this sees the temp root.
        . (Join-Path $vault '.system\vault-lib.ps1')
        if (Test-Path -LiteralPath $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force }
        T 'throwaway repo cleaned up' (-not (Test-Path -LiteralPath $tmpRoot))
    }
}

""
"$pass passed, $fail failed"
exit $(if ($fail) { 1 } else { 0 })
