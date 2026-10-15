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

""
"$pass passed, $fail failed"
exit $(if ($fail) { 1 } else { 0 })
