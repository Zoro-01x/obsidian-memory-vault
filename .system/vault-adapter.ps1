# vault-adapter.ps1
#
# THE ONLY ENTRY POINT the MCP server uses. Reads ONE JSON object from stdin,
# dispatches to a constrained verb in vault-lib.ps1, writes ONE JSON object to
# stdout. Exit code 0 whenever JSON was produced, so the caller always parses
# rather than scraping stderr.
#
# WHY STDIN, NEVER ARGUMENTS: note bodies are arbitrary UTF-8 text full of
# quotes, newlines and code fences. As command-line arguments they arrive
# mangled (powershell.exe -File -Expression destroys inner double quotes) and
# that already cost real debugging time. JSON on stdin is exact.
#
# WHAT THIS IS NOT: it is not a second policy layer. Every guard -- path
# allowlist, dedupe, schema validation, atomic write, git commit -- lives in
# vault-lib.ps1. If a rule belongs there, it is enforced here for free.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Verb)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$WarningPreference     = 'SilentlyContinue'   # captured per-call; never stdout

# Must be set BEFORE the first byte of output, or PowerShell writes in the OEM
# codepage and UTF-8 note bodies come back as mojibake.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

. (Join-Path $PSScriptRoot 'vault-lib.ps1')

# --- request helpers -------------------------------------------------------

function Read-Request {
    # Raw bytes, decoded as UTF-8 by hand. [Console]::In decodes redirected
    # stdin with the OEM console codepage on Windows, which silently mangles
    # non-ASCII note bodies (em dashes, curly quotes, accented text) into
    # mojibake -- and mojibake gets written to disk and committed.
    $stdin = [System.Console]::OpenStandardInput()
    $ms = New-Object System.IO.MemoryStream
    $stdin.CopyTo($ms)
    $raw = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    $ms.Dispose()

    if ($raw.Length -gt 0) { $raw = $raw.TrimStart([char]0xFEFF) }
    if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }

    $obj = $raw | ConvertFrom-Json
    $h = @{}
    foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
    return $h
}
function Get-ArgString {
    param([hashtable]$A, [string]$Name, [string]$Default = '')
    if (-not $A.ContainsKey($Name) -or $null -eq $A[$Name]) { return $Default }
    return [string]$A[$Name]
}
function Get-ArgList {
    param([hashtable]$A, [string]$Name)
    if (-not $A.ContainsKey($Name) -or $null -eq $A[$Name]) { return @() }
    return @($A[$Name] | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
}
function Get-ArgInt {
    param([hashtable]$A, [string]$Name, [int]$Default)
    if (-not $A.ContainsKey($Name) -or $null -eq $A[$Name]) { return $Default }
    $n = 0
    if ([int]::TryParse([string]$A[$Name], [ref]$n)) { return $n }
    return $Default
}
function Get-ArgBool {
    param([hashtable]$A, [string]$Name, [bool]$Default)
    if (-not $A.ContainsKey($Name) -or $null -eq $A[$Name]) { return $Default }
    $v = [string]$A[$Name]
    if ($v -match '^(?i:true|1|yes)$')  { return $true }
    if ($v -match '^(?i:false|0|no)$')  { return $false }
    return $Default
}
function Get-ArgHashtable {
    # A JSON object arrives as PSCustomObject, not hashtable. Only the shape
    # changes; values stay exactly as sent.
    param([hashtable]$A, [string]$Name)
    if (-not $A.ContainsKey($Name) -or $null -eq $A[$Name]) { return @{} }
    $o = $A[$Name]
    if ($o -is [hashtable]) { return $o }
    $h = @{}
    foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value }
    return $h
}

# --- dispatch --------------------------------------------------------------
# Explicit whitelist. The verb name selects code; no input ever becomes a
# command name, a path or a function call.

$warnings = @()
$result   = $null
$ok       = $true
$errMsg   = ''
$errType  = ''

try {
    $a = Read-Request

    switch ($Verb) {

        'core' {
            # The always-loaded context block, hard-capped so it cannot silently
            # grow into the whole session budget.
            $core = Get-VaultCore -MaxTokens (Get-ArgInt $a 'maxTokens' 1500)
            $result = @{ core = [string]$core }
        }

        'recall' {
            $q = Get-ArgString $a 'query'
            if ([string]::IsNullOrWhiteSpace($q)) { throw 'recall: `query` is required.' }
            $hits = @(Find-VaultNote -Query $q -Limit (Get-ArgInt $a 'limit' 10))
            $rows = @(foreach ($h in $hits) {
                [pscustomobject]@{
                    path        = $h.Path
                    name        = $h.Name
                    folder      = $h.Folder
                    description = $h.Description
                    basis       = $h.Basis
                    scope       = $h.Scope
                    status      = $h.Status
                    verified    = $h.Verified
                    score       = [math]::Round($h.Score, 2)
                }
            })
            $result = @{ query = $q; count = $rows.Count; hits = $rows }
        }

        'read' {
            $p = Get-ArgString $a 'path'
            if ([string]::IsNullOrWhiteSpace($p)) { throw 'read: `path` is required.' }

            $norm = ($p -replace '/', '\').Trim()
            # Be forgiving about the form of a path, but not about where it
            # lands: absolute paths inside the vault are normalised to
            # relative (recall once returned them), while absolute paths
            # OUTSIDE it still fall through to Resolve-VaultSafePath and are
            # refused.
            if ([System.IO.Path]::IsPathRooted($norm)) {
                $norm = ConvertTo-VaultRelativePath -Path $norm
            }
            if ($norm -ieq 'CORE.md') {
                # CORE sits at the root, outside the four write folders, so it
                # cannot go through the write allowlist. Reading it is fine.
                $full = Join-Path (Get-VaultRoot) 'CORE.md'
            }
            else {
                $full = Resolve-VaultSafePath -RelativePath $norm `
                            -AllowedFolders @('inbox', 'entities', 'decisions', 'lessons')
            }
            if (-not (Test-Path -LiteralPath $full)) { throw "No such note: '$p'" }

            $fm   = Read-VaultFrontmatter -Path $full
            $body = Get-VaultNoteBody    -Path $full
            $chk  = Test-VaultNote       -Path $full

            $back = @()
            if (Get-ArgBool $a 'backlinks' $true) {
                $bare = [System.IO.Path]::GetFileNameWithoutExtension($full)
                $back = @(Get-VaultGraph -NoteName $bare |
                          Where-Object { $_.Kind -eq 'backlink' } |
                          ForEach-Object { $_.Source })
            }

            $result = @{
                path      = $p
                frontmatter = $fm
                body      = $body
                backlinks = $back
                valid     = [bool]$chk.Valid
                problems  = @($chk.Problems)
            }
        }

        'create' {
            # Permanent note. Refuses on name/alias collision rather than
            # overwriting -- see New-VaultNote.
            $r = New-VaultNote `
                    -Folder       (Get-ArgString $a 'folder') `
                    -Name         (Get-ArgString $a 'name') `
                    -Description  (Get-ArgString $a 'description') `
                    -Body         (Get-ArgString $a 'body') `
                    -Aliases      (Get-ArgList  $a 'aliases') `
                    -Status       (Get-ArgString $a 'status' 'active') `
                    -Basis        (Get-ArgString $a 'basis' 'inferred') `
                    -Scope        (Get-ArgString $a 'scope') `
                    -Verified     (Get-ArgString $a 'verified') `
                    -SupersededBy (Get-ArgString $a 'supersededBy') `
                    -Author       (Get-ArgString $a 'author' 'harness')
            $result = @{ created = $r.Path; commit = $r.Commit }
        }

        'append' {
            # Append-only by default; replacing a whole body needs an explicit
            # replaceBody, because "rewrite from memory of an earlier read" is
            # how notes get clobbered. `set` edits frontmatter through a
            # whitelist -- the only way to mark a note superseded.
            $append  = Get-ArgString   $a 'text'
            $replace = Get-ArgString   $a 'replaceBody'
            $set     = Get-ArgHashtable $a 'set'

            # camelCase in, snake_case in the frontmatter.
            if ($set.ContainsKey('supersededBy') -and -not $set.ContainsKey('superseded_by')) {
                $set['superseded_by'] = $set['supersededBy']
                $set.Remove('supersededBy')
            }

            $splat = @{
                RelativePath = Get-ArgString $a 'path'
                Author       = Get-ArgString $a 'author' 'harness'
            }
            if (-not [string]::IsNullOrEmpty($replace)) { $splat.ReplaceBody = $replace }
            elseif (-not [string]::IsNullOrEmpty($append)) { $splat.AppendText = $append }
            if ($set.Count) { $splat.Set = $set }

            $r = Update-VaultNote @splat
            $result = @{ path = $r.Path; action = $r.Action; commit = $r.Commit; set = @($r.Set) }
        }

        'propose' {
            # Staging only -- for content I have NOT verified: external-model
            # claims, or user statements captured under context pressure.
            # Anything I observed myself should go through `create`.
            $w = $null
            $r = Add-VaultInboxItem `
                    -Title  (Get-ArgString $a 'title') `
                    -Claim  (Get-ArgString $a 'claim') `
                    -Aliases (Get-ArgList $a 'aliases') `
                    -Links  (Get-ArgList $a 'links') `
                    -Basis  (Get-ArgString $a 'basis' 'external-model') `
                    -Scope  (Get-ArgString $a 'scope') `
                    -Author (Get-ArgString $a 'author' 'harness') `
                    -WarningVariable w -WarningAction SilentlyContinue

            # Only .Message: a full WarningRecord serialises to kilobytes of
            # InvocationInfo noise (measured).
            $warnings = @($w | ForEach-Object { $_.Message })
            $result   = @{ created = $r.Path; commit = $r.Commit; warnings = $warnings }
        }

        'stale' {
            # The prune/verify pass. Read-only -- nothing here deletes.
            $rows = @(Get-VaultStale `
                        -InboxDays    (Get-ArgInt $a 'inboxDays' 7) `
                        -VerifiedDays (Get-ArgInt $a 'verifiedDays' 90))
            $result = @{ count = $rows.Count; items = $rows }
        }

        default {
            throw "Unknown verb '$Verb'. Allowed: core, recall, read, create, append, propose, stale"
        }
    }
}
catch {
    $ok      = $false
    $errMsg  = $_.Exception.Message
    $errType = $_.Exception.GetType().Name
}

$payload = @{ ok = $ok; verb = $Verb }
if ($ok) { $payload.result = $result }
else     { $payload.error = $errMsg; $payload.errorType = $errType }
if ($warnings.Count) { $payload.warnings = $warnings }

try {
    [Console]::Out.Write(((ConvertTo-Json -InputObject $payload -Depth 12 -Compress) + "`n"))
    exit 0
}
catch {
    [Console]::Out.Write(('{"ok":false,"error":"result could not be serialised"}' + "`n"))
    exit 1
}
