# vault-lib.ps1 — constrained read/write verbs over the council memory vault.
#
# DESIGN (from the Claude consultation, 2026-10-14):
#   * The vault is the single source of truth. Plain markdown, YAML frontmatter,
#     [[wikilinks]]. No vector DB, no service, no daemon.
#   * The HARNESS is the only writer. Agents propose; this module decides what
#     lands on disk. Agents never get raw filesystem access.
#   * Every write is: path-allowlist -> reserved-name guard -> dedupe-on-write
#     -> frontmatter validation -> atomic replace -> git commit.
#   * `.obsidian/` and `.system/` are unreachable by every write verb.
#
# WHY THIS EXISTS: agents given raw write access eventually clobber a note,
# follow a symlink, or "tidy up" config. Constrained verbs make the safe path
# the only path. openat2-style kernel containment was rejected -- Linux only,
# and the threat model is accidents, not adversaries.

# --- configuration ---------------------------------------------------------

# The commit-isolation test must run against a throwaway repo -- a test that
# writes to live history will eventually pollute it -- so the root is
# redirectable by env var, but ONLY under two conditions, both required:
#
#   1. the target is inside %TEMP%, and
#   2. it contains the sentinel file `.vault-test-root`.
#
# A bare env var would be a hole, not a feature: every verb runs as a fresh
# process that inherits the agent's shell environment, so an injected line
# ("set OBSIDIAN_VAULT_ROOT then call append") would repoint every path guard
# at an attacker-chosen directory and the whole allowlist would resolve
# against it. The sentinel cannot be satisfied by accident -- nothing outside
# this test creates that filename -- and TEMP is never a real vault.
#
# Deliberately not a -Parameter either: a root passed by a caller is an
# unvalidated path, and every path guard below resolves against this value.
$script:VaultRoot  = 'C:\Users\Home\Documents\ObsidianVault'
$script:TestRoot   = '.vault-test-root'
$script:RealRoot   = $script:VaultRoot
# 'unset' | 'honored' | 'ignored'. The isolation test asserts on this rather
# than on warning capture -- dot-sourcing a plain .ps1 cannot take
# -WarningVariable (that needs script-level CmdletBinding), so a warning is
# the wrong channel for a fact a test must be able to check.
$script:VaultRootOverride = 'unset'

if ($env:OBSIDIAN_VAULT_ROOT) {
    $candidate = $env:OBSIDIAN_VAULT_ROOT
    try { $full = [System.IO.Path]::GetFullPath($candidate) } catch { $full = '' }
    $inTemp = $full -and $full.StartsWith($env:TEMP, [System.StringComparison]::OrdinalIgnoreCase)
    $sentinel = $inTemp -and (Test-Path -LiteralPath (Join-Path $full $script:TestRoot))
    if ($sentinel) {
        $script:VaultRoot = $full
        $script:VaultRootOverride = 'honored'
    }
    else {
        $script:VaultRootOverride = 'ignored'
        Write-Warning ("Ignoring OBSIDIAN_VAULT_ROOT='$candidate' -- an override must be inside " +
                       "%TEMP% and carry a '$($script:TestRoot)' sentinel. Using the real vault.")
    }
}

function Get-VaultOverrideStatus { return $script:VaultRootOverride }

# --- registry: the single source of truth -----------------------------------
#
# Every closed vocabulary below used to be a literal here AND a literal in
# vault-mcp.mjs. On 2026-10-17 one of those pairs had already drifted, and a
# second (VERBS vs the TOOLS catalogue) had shipped a tool that was advertised
# but undispatchable. See registry.json for the full account.
#
# The registry is loaded BEFORE anything else and FAILS CLOSED. That is
# deliberate: bug 1 in this file's history was a single parse error taking down
# every verb, so a missing or malformed registry must refuse to load loudly
# rather than fall back to defaults -- a silently-defaulted registry would
# enforce the WRONG vocabulary, which is worse than no vocabulary at all.
$script:RegistryPath = Join-Path $PSScriptRoot 'registry.json'

if (-not (Test-Path -LiteralPath $script:RegistryPath)) {
    throw ("vault-lib: registry.json is MISSING at '$script:RegistryPath'. " +
           "It is the single source of truth for every closed vocabulary " +
           "(folders, status, basis, probe kinds, verbs). Loading without it " +
           "would silently enforce the wrong rules, so the library refuses to load.")
}

try {
    $rawReg = [System.IO.File]::ReadAllText($script:RegistryPath)
    $script:VaultRegistry = $rawReg | ConvertFrom-Json
}
catch {
    throw ("vault-lib: registry.json could not be parsed -- $($_.Exception.Message). " +
           "Refusing to load rather than enforce a partial vocabulary.")
}

# Every required key is checked up front. A registry that parses but is missing
# a key would otherwise surface as an empty @() -- and an empty allowlist fails
# OPEN (nothing is forbidden), which is the opposite of what we want.
foreach ($regKey in @('writeFolders','createFolders','rootFiles','blockedFolders',
                      'status','basis','requiredFields','optionalFields',
                      'mutableKeys','immutableKeys','probeKinds','probeSuites',
                      'minProbePatternLength','verbs')) {
    if (-not ($script:VaultRegistry.PSObject.Properties.Name -contains $regKey)) {
        throw "vault-lib: registry.json is missing required key '$regKey'. Refusing to load."
    }
    if ($null -eq $script:VaultRegistry.$regKey) {
        throw "vault-lib: registry.json has '$regKey' = null. Refusing to load."
    }
}

# An empty array in a JSON file reads back as $null in PS 5.1's ConvertFrom-Json
# only when the value is literally absent; `[]` yields an empty array. Both are
# fatal for an allowlist, so both are refused.
foreach ($listKey in @('writeFolders','createFolders','rootFiles','blockedFolders',
                       'status','basis','requiredFields','optionalFields',
                       'mutableKeys','immutableKeys','probeKinds','probeSuites','verbs')) {
    if (@($script:VaultRegistry.$listKey).Count -eq 0) {
        throw "vault-lib: registry.json key '$listKey' is empty. An empty allowlist fails open. Refusing to load."
    }
}

# --- the vocabularies, derived ------------------------------------------------

# Write verbs may only create files inside these folders.
$script:WriteFolders   = @($script:VaultRegistry.writeFolders)

# Narrower than WriteFolders ON PURPOSE: `inbox` is reached through `propose`,
# which calls New-VaultNote -Folder 'inbox' internally. Exposing inbox on the
# MCP `create` enum would let an agent bypass the inbox's review queue by
# calling create directly. registry.json explains this in _createFolders.
$script:CreateFolders  = @($script:VaultRegistry.createFolders)

# Files at the vault ROOT that verbs may update. CORE.md must stay maintainable
# (edit is denied on it, so if no verb could reach it the index would freeze),
# but it must be an explicit allowlist -- "no folder" must never mean "any file".
$script:RootFiles      = @($script:VaultRegistry.rootFiles)

# Never writable, regardless of anything an agent says.
$script:BlockedFolders = @($script:VaultRegistry.blockedFolders)

$script:ValidStatus    = @($script:VaultRegistry.status)

# `basis` replaces the old source + confidence pair. Provenance still matters
# with a single writer, because external-model claims are where hallucination
# enters: a note sourced from Gemini must not be treated like one you observed.
#   user-stated     -- the user said it
#   observed        -- you verified it yourself
#   external-model  -- Gemini/Claude/web said it, unverified
#   inferred        -- you concluded it
$script:ValidBasis     = @($script:VaultRegistry.basis)

$script:RequiredFields = @($script:VaultRegistry.requiredFields)
$script:OptionalFields = @($script:VaultRegistry.optionalFields)

# Windows reserved device names -- writing these corrupts paths.
$script:ReservedNames = @(
    'CON','PRN','AUX','NUL',
    'COM1','COM2','COM3','COM4','COM5','COM6','COM7','COM8','COM9',
    'LPT1','LPT2','LPT3','LPT4','LPT5','LPT6','LPT7','LPT8','LPT9'
)

# --- verification probes ---------------------------------------------------
# A `verify` must be a WITNESS, not a second opinion in a lab coat. Claude's
# test (2026-10-17): "replace the caller with a rock" -- if verify returns the
# same result no matter what the caller says, it is a witness; if any
# caller-supplied text can move the outcome, it is grading prose.
#
# So the probe spec lives in the NOTE, declared at create time and never
# mutable afterwards. The caller names a note and NOTHING else. These kinds are
# the entire registry -- deliberately closed. Free-form commands would turn
# verify into an injection surface running with the agent's authority, which is
# strictly worse than having no verifier at all.
$script:ValidProbeKinds = @($script:VaultRegistry.probeKinds)

# `suite` names a test by ID; it never carries a command string. Same reason.
$script:AllowedProbeSuites = @($script:VaultRegistry.probeSuites)

# A pattern that matches everything proves nothing -- it would pass against a
# note that has no such symbol at all. Claude called this the can-fail control;
# refusing trivial patterns is the cheap half of it.
$script:MinProbePatternLength = [int]$script:VaultRegistry.minProbePatternLength

$script:ValidVerbs = @($script:VaultRegistry.verbs)

function Get-VaultRoot { return $script:VaultRoot }

function ConvertTo-VaultRelativePath {
    <#
      Absolute or vault-rooted path -> vault-relative path with backslashes,
      e.g. 'entities\Obsidian CDP access.md'.

      Retrieval returns RELATIVE paths because that is the only form the read
      verb accepts -- absolute paths are refused by design. Without this the
      recall -> read round-trip dead-ends on the very first call, which is
      exactly the sort of breakage nobody notices until it wastes an hour.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $candidate = $Path
    if (-not [System.IO.Path]::IsPathRooted($candidate)) {
        $candidate = Join-Path $script:VaultRoot $candidate
    }
    try { $full = [System.IO.Path]::GetFullPath($candidate) } catch { return $Path }

    $root = [System.IO.Path]::GetFullPath($script:VaultRoot)
    if ($full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($root.Length).TrimStart('\', '/')
    }
    return $Path
}

# --- path safety -----------------------------------------------------------

function Resolve-VaultSafePath {
    <#
      Resolve a candidate relative path and prove it is inside an allowed
      folder. Rejects: escaping the vault, blocked folders, reparse points
      (symlinks/junctions), and absolute paths.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [string[]]$AllowedFolders = $script:WriteFolders
    )
    if ([string]::IsNullOrWhiteSpace($RelativePath)) { throw 'RelativePath is empty.' }
    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "Absolute paths are refused: '$RelativePath'. Use a vault-relative path."
    }

    $norm = $RelativePath -replace '/', '\'
    # The @() matters: without it a single-segment path unrolls to a SCALAR,
    # $parts[0] then yields the first CHARACTER rather than the segment, and
    # the .Equals(.., StringComparison) call below fails with "Cannot find an
    # overload for Equals and the argument count: 2". Seen live on 'CORE.md'.
    $parts = @($norm.Split('\') | Where-Object { $_ -ne '' -and $_ -ne '.' })

    if ($parts.Count -eq 0) { throw 'Path resolves to nothing.' }

    $top = $parts[0]
    foreach ($blocked in $script:BlockedFolders) {
        if ($top.Equals($blocked, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Folder '$blocked' is not writable by any verb."
        }
    }
    if ($parts.Count -eq 1) {
        # Root-level file: must be on the explicit allowlist.
        if ($script:RootFiles -notcontains $top) {
            throw "Root file '$top' is not a writable target. Writable root files: $($script:RootFiles -join ', ')."
        }
    }
    elseif ($top -notin $AllowedFolders) {
        throw "Folder '$top' is not an allowed write target. Allowed: $($AllowedFolders -join ', ')"
    }

    $full = [System.IO.Path]::GetFullPath((Join-Path $script:VaultRoot ($parts -join '\')))

    # Belt and braces: confirm containment after full resolution.
    $rootFull = [System.IO.Path]::GetFullPath($script:VaultRoot)
    if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Resolved path escapes the vault: '$full'"
    }

    # Reject anything that traverses a reparse point (symlink/junction).
    $probe = $full
    while ($probe -and $probe -ne $rootFull) {
        if (Test-Path -LiteralPath $probe) {
            $item = Get-Item -LiteralPath $probe -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Refusing to traverse reparse point: '$probe'"
            }
        }
        $probe = Split-Path -Parent $probe
    }
    return $full
}

function Test-SafeNoteName {
    <#
      Validate a human-facing note name: no reserved device names, no illegal
      filename characters, not absurdly long. Returns the cleaned name.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $clean = ($Name -replace '[\x00-\x1F<>:"/\\|?*]', '').Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($clean)) { throw "Note name '$Name' is empty after sanitising." }
    if ($clean.Length -gt 120) { $clean = $clean.Substring(0,120).Trim() }

    $stem = ($clean -split '\.')[0]
    if ($stem.ToUpper() -in $script:ReservedNames) {
        throw "'$clean' collides with a Windows reserved device name."
    }
    return $clean
}

# --- frontmatter -----------------------------------------------------------

function ConvertTo-VaultFrontmatter {
    <#
      Serialise a hashtable as YAML. Deliberately minimal and hand-rolled so
      output is byte-stable across runs (git diffs stay readable).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Data)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('---')
    foreach ($key in ($Data.Keys | Sort-Object)) {
        $val = $Data[$key]
        if ($val -is [System.Collections.IEnumerable] -and $val -isnot [string]) {
            $items = @($val) | ForEach-Object { "'{0}'" -f ([string]$_ -replace "'", "''") }
            if ($items.Count -eq 0) { [void]$sb.AppendLine("${key}: []") }
            else { [void]$sb.AppendLine("${key}: [" + ($items -join ', ') + ']') }
        }
        elseif ($val -is [bool]) { [void]$sb.AppendLine("${key}: " + $(if ($val) {'true'} else {'false'})) }
        elseif ($null -eq $val -or [string]::IsNullOrWhiteSpace([string]$val)) {
            [void]$sb.AppendLine("${key}: ~")
        }
        else {
            $s = [string]$val
            # Quote anything that YAML would otherwise misread as a type.
            if ($s -match '^[\d.\-+eE~>|*&%!@`#{}[\],:?]+$') { $s = "'$($s -replace "'", "''")'" }
            elseif ($s -match '[:#]|^\s|\s$') { $s = "'$($s -replace "'", "''")'" }
            [void]$sb.AppendLine("${key}: $s")
        }
    }
    [void]$sb.AppendLine('---')
    return $sb.ToString()
}

function Read-VaultFrontmatter {
    <#
      Parse the leading YAML block of a note into a hashtable. Tolerant: a
      note with no or malformed frontmatter returns an empty hashtable rather
      than throwing, so a hand-edited note never breaks retrieval.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $result = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    $text = [System.IO.File]::ReadAllText($Path)
    if ($text -notmatch '^(?s)^\s*---\r?\n(.*?)\r?\n---') { return $result }

    $block = $Matches[1]
    foreach ($line in ($block -split "`r?`n")) {
        if ($line -match '^\s*([A-Za-z_][\w\-]*)\s*:\s*(.*)$') {
            $k = $Matches[1]; $v = $Matches[2].Trim()
            if ($v -eq '' -or $v -eq '~') { $result[$k] = $null }
            elseif ($v -match '^\[(.*)\]$') {
                $inner = $Matches[1]
                if ([string]::IsNullOrWhiteSpace($inner)) { $result[$k] = @() }
                else {
                    $result[$k] = @($inner -split ',' | ForEach-Object {
                        $_.Trim().Trim("'").Trim('"')
                    } | Where-Object { $_ })
                }
            }
            else { $result[$k] = $v.Trim("'").Trim('"') }
        }
    }
    return $result
}

function Get-VaultNoteBody {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $text = [System.IO.File]::ReadAllText($Path)
    if ($text -match '(?s)^\s*---\r?\n.*?\r?\n---\r?\n?(.*)$') { return $Matches[1].Trim() }
    return $text.Trim()
}

# --- write (atomic) --------------------------------------------------------

function Write-VaultFileAtomic {
    <#
      Write via temp file + os.replace semantics so a crash mid-write can
      never leave a half-written note. Also forces LF so git doesn't churn
      on CRLF/LF noise between agents.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FullPath,
        [Parameter(Mandatory)][string]$Content
    )
    $dir = Split-Path -Parent $FullPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $tmp = "$FullPath.$([Guid]::NewGuid().ToString('N')).tmp"
    $enc = New-Object System.Text.UTF8Encoding($false)   # no BOM -- Obsidian's JSON/MD parsers choke on BOM
    $lf  = ($Content -replace "`r`n", "`n")
    [System.IO.File]::WriteAllText($tmp, $lf, $enc)
    Move-Item -LiteralPath $tmp -Destination $FullPath -Force   # atomic replace on same volume
}

function Get-VaultGit {
    <#
      Resolve git.exe without depending on PATH. Git lives in a user-local
      tools dir here (no admin, so it can't go in a system path), and a
      silently-skipped commit defeats the entire purpose of the safety net.
    #>
    $cmd = Get-Command git -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        'C:\Users\Home\tools\git\cmd\git.exe',
        "$env:ProgramFiles\Git\cmd\git.exe",
        "${env:ProgramFiles(x86)}\Git\cmd\git.exe",
        "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe"
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}

function Invoke-VaultNative {
    <#
      THE shared native-execution boundary. Every git/rg call goes through here.

      WHY THIS EXISTS (found 2026-10-16 by demo-with-without.mjs, proven by
      native-stderr-test.ps1): the adapter sets $ErrorActionPreference='Stop'.
      Under that preference, Windows PowerShell 5.1 turns a native command's
      STDERR into a terminating error REGARDLESS of the process exit code. git
      warns on stderr about LF->CRLF (exit 0, a harmless warning) and the
      resulting throw landed AFTER New-VaultNote had already written and staged
      the file -- so the verb reported failure while the disk had changed.

      Two rules, both non-negotiable:
        1. stderr is captured as DATA, never as an error. The caller decides.
        2. the process EXIT CODE is the only success signal. Nonempty stderr
           with exit 0 is success; a clean-looking run with exit 1 is failure.

      Returns @{ Ok; ExitCode; StdOut; StdErr } so callers can surface stderr
      as a warning field instead of dying on it.

      IMPLEMENTATION NOTE (.NET Framework 4.x / PS 5.1): ProcessStartInfo has no
      ArgumentList here, so argument passing goes through the call operator
      (& $exe @Arguments), which is the one native argv marshaller PowerShell
      gets right. stderr is redirected to a TEMP FILE rather than merged with
      2>&1, so it stays separate data and never re-enters the error stream.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @()
    )
    if (-not (Test-Path -LiteralPath $FilePath)) {
        return @{ Ok = $false; ExitCode = -1; StdOut = ''; StdErr = "executable not found: $FilePath" }
    }

    $errFile = [System.IO.Path]::GetTempFileName()
    $prevEAP = $ErrorActionPreference
    try {
        # Capture stdout as data; steer stderr to a file so PS 5.1 cannot turn
        # it into ErrorRecords under EAP=Stop.
        $ErrorActionPreference = 'Continue'
        $stdout = (& $FilePath @Arguments 2> $errFile | Out-String)
        $code   = $LASTEXITCODE
        if ($null -eq $code) { $code = -1 }
        $stderr = ''
        if (Test-Path -LiteralPath $errFile) {
            $stderr = [System.IO.File]::ReadAllText($errFile)
        }
    }
    finally {
        $ErrorActionPreference = $prevEAP
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }

    # CRLF -> LF, and drop any trailing CR. Same reason as $stdout: callers
    # match on this text and a bare \r produces false mismatches. Note this is
    # NOT '' -replace .., which returns $null -- hence the explicit guard.
    if ($stderr) { $stderr = ($stderr -replace "`r`n", "`n") -replace "`r", "" }

    # Normalise CRLF -> LF AND strip any stray trailing CR before the caller
    # sees it. On Windows, text-mode reads of the temp file hand back lines
    # still holding their \r; a path ending in char 13 then makes
    # [System.IO.Path]::IsPathRooted throw "Illegal characters in path", which
    # killed `recall` on every hit. This is the same CRLF trap the write
    # validation suite documents for note bodies -- same root cause, one layer
    # up. Consumers receive LF-only text with no phantom empty line, and no
    # caller has to remember to clean it. (Found by smoke-test.mjs after the
    # first Invoke-VaultNative migration.)
    $stdout = ($stdout -replace "`r`n", "`n") -replace "`r", ""

    return @{
        Ok       = ($code -eq 0)      # exit code ALONE decides. Not stderr.
        ExitCode = $code
        StdOut   = $stdout
        StdErr   = $stderr
    }
}
function Save-VaultCommit {
    <#
      Commit the change so the agent name and diff are reviewable, and so any
      write can be undone. Warns loudly when git is absent rather than
      failing silently -- a skipped commit is the one failure mode that
      defeats the whole point of a safety net.

      Stages ONLY the path the verb wrote. The original `add -A` quietly
      bundled unrelated pending edits (library fixes, other notes) into
      whatever commit happened next, so commit messages stopped describing
      their diffs -- which is exactly the audit trail this safety net exists
      to provide. Pass -Path for a single-file commit, or omit it for an
      intentional bulk commit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Author = 'harness',
        [string]$Path = ''
    )
    $git = Get-VaultGit
    if (-not $git) {
        Write-Warning "git not found -- write was NOT committed and has no undo. Install git or fix Get-VaultGit."
        return @{ committed = $false; reason = 'git not installed'; partial = $false }
    }

    $vault = $script:VaultRoot
    $relTarget = if ($Path) { $Path -replace '\\', '/' } else { '' }
    if ($relTarget) { $addArgs = @('-C', $vault, 'add', '--', $relTarget) }
    else            { $addArgs = @('-C', $vault, 'add', '-A') }

    $add = Invoke-VaultNative -FilePath $git -Arguments $addArgs
    if (-not $add.Ok) {
        # The file is already on disk at this point (the caller wrote it before
        # calling us), so this is PARTIAL, not a clean refusal. Say so, and name
        # the path so the caller can recover instead of guessing.
        $detail = if ($add.StdErr) { $add.StdErr.Trim() } else { "exit $($add.ExitCode)" }
        return @{ committed = $false; partial = $true; path = $relTarget
                  reason   = "git add failed ($detail); the file WAS written and may be staged" }
    }

    $pending = Invoke-VaultNative -FilePath $git -Arguments @('-C', $vault, 'status', '--porcelain')
    if (-not $pending.Ok) {
        return @{ committed = $false; partial = $true; path = $relTarget
                  reason   = "git status failed ($($pending.StdErr.Trim())) after a successful add" }
    }
    if (-not $pending.StdOut.Trim()) { return @{ committed = $false; partial = $false; reason = 'nothing to commit' } }

    $msg = "[$Author] $Message"
    # Set the real commit author, not just the message prefix. Previously the
    # repo identity (Council) was recorded and the agent name existed only as
    # message text -- reviewable by reading %s, but `git log --author=harness`
    # could not answer "which agent touched this?", which is the whole point
    # of attributing commits to a writer.
    $who   = if ($Author) { $Author } else { 'harness' }
    $email = (($who -replace '[^A-Za-z0-9._-]', '.') + '@vault.local')
    $commit = Invoke-VaultNative -FilePath $git -Arguments @(
        '-C', $vault, '-c', 'core.autocrlf=false',
        '-c', "user.name=$who", '-c', "user.email=$email",
        'commit', '-q', '-m', $msg
    )
    if (-not $commit.Ok) {
        # Real post-write failure (hook, lock, identity). The note is on disk and
        # staged but has no commit. A bare "REFUSED" here would be a lie -- the
        # mutation already happened. Callers get partial=true to distinguish it.
        return @{ committed = $false; partial = $true; path = $relTarget
                  reason   = "git commit failed ($($commit.StdErr.Trim())); the file is on disk and staged but NOT committed" }
    }

    $sha = (Invoke-VaultNative -FilePath $git -Arguments @('-C', $vault, 'rev-parse', '--short', 'HEAD')).StdOut.Trim()
    $result = @{ committed = $true; sha = $sha; message = $msg; partial = $false }
    if ($add.StdErr.Trim() -or $commit.StdErr.Trim()) {
        # A warning on stderr with exit 0 is NOT a failure -- but it is worth
        # keeping as data rather than discarding (that is exactly the trap this
        # wrapper exists to fix: stderr used to become a terminating error).
        $result.stderr = (@($add.StdErr, $commit.StdErr) | Where-Object { $_ -and $_.Trim() }) -join "`n"
    }
    return $result
}

# --- public verbs ----------------------------------------------------------

function Find-VaultNote {
    <#
      RETRIEVAL. ripgrep over titles/bodies plus a boost for frontmatter
      description and aliases. Deliberately NOT embeddings: for a few thousand
      notes, grep + the wikilink graph is sufficient, and aliases in
      frontmatter cure most vocabulary-mismatch misses.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Query,
        [int]$Limit = 10
    )
    $rg = 'C:\Users\Home\tools\rg\ripgrep-14.1.1-x86_64-pc-windows-msvc\rg.exe'
    $hits = @()

    # Split into terms and match ANY of them, ranked below by how many matched.
    # The previous version passed the whole query as a single pattern, so
    # "bom encoding utf8" searched for that exact phrase and matched nothing --
    # and recall is the entry point to the whole memory, so a natural
    # multi-word query dead-ended exactly where it mattered most.
    $terms = @($Query -split '\s+' | Where-Object { $_ })

    if (Test-Path $rg) {
        # -F: terms are literal text, so a query containing ( . [ or similar
        # cannot be read as a regex and error out. -m caps per-file matches so
        # one big note can't dominate the budget. Multiple -e values OR.
        $rgArgs = @('--files-with-matches', '-m', '5', '-i', '-F', '--no-heading', '-g', '*.md', '-g', '!.obsidian/**')
        foreach ($t in $terms) { $rgArgs += @('-e', $t) }
        $rgArgs += $script:VaultRoot
        # Through Invoke-VaultNative: an rg warning (permissions, a broken
        # symlink) on stderr must not become a terminating error and take recall
        # down with it. Recall is the entry point to the whole memory.
        $rgResult = Invoke-VaultNative -FilePath $rg -Arguments $rgArgs
        $raw = $rgResult.StdOut -split "`n" | Where-Object { $_ }
        foreach ($f in @($raw)) { if ($f) { $hits += [pscustomobject]@{ Path = $f; Score = 1 } } }
    }
    if ($hits.Count -eq 0) {
        Get-ChildItem -Path $script:VaultRoot -Filter '*.md' -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\\.obsidian\\|\\\.system\\|\\\.git\\' } |
            ForEach-Object {
                $txt = [System.IO.File]::ReadAllText($_.FullName)
                foreach ($t in $terms) {
                    # Ordinal, not regex: fast and matches literally.
                    if ($txt.IndexOf($t, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        $hits += [pscustomobject]@{ Path = $_.FullName; Score = 1 }
                        break
                    }
                }
            }
    }

    # Boost: a hit in name/description/aliases outranks a hit deep in prose.
    $scored = foreach ($h in $hits) {
        # Keep the absolute path for reading, but HAND BACK a vault-relative
        # one: that is the form the read verb accepts.
        $rel  = ConvertTo-VaultRelativePath -Path $h.Path
        $fm   = Read-VaultFrontmatter -Path $h.Path
        $score = 1.0

        # Score per term, not per query. A note matching three of four query
        # words is a far better answer than one matching a single word, and
        # without this both land as equal hits.
        $aliasTxt = (@($fm.aliases) -join ' ')
        $matched  = 0
        foreach ($t in $terms) {
            $et  = [regex]::Escape($t)
            $hit = $false
            if ($fm.name -and $fm.name -match $et)              { $score += 6; $hit = $true }
            elseif ($aliasTxt -and $aliasTxt -match $et)         { $score += 4; $hit = $true }
            elseif ($fm.description -and $fm.description -match $et) { $score += 3; $hit = $true }
            if ($fm.scope -and $fm.scope -match $et)             { $score += 2; $hit = $true }
            if ($hit) { $matched++ }
        }
        if ($matched -gt 1) { $score += $matched * 2 }
        # Recency: an `updated` note beats a forgotten one on the same relevance.
        if ($fm.updated) {
            try {
                $ageDays = ((Get-Date) - [datetime]$fm.updated).TotalDays
                if ($ageDays -lt 30) { $score += 1.5 } elseif ($ageDays -lt 120) { $score += 0.5 }
            } catch { }
        }
        # Stale/superseded notes should surface below active ones, not vanish.
        if ($fm.status -eq 'stale' -or $fm.status -eq 'superseded') { $score -= 2 }
        $folder = Split-Path -Parent $rel
        [pscustomobject]@{
            Path        = $rel
            Name        = if ($fm.name) { $fm.name } else { [System.IO.Path]::GetFileNameWithoutExtension($rel) }
            Folder      = if ($folder) { $folder } else { '(root)' }
            Basis       = $fm.basis
            Scope       = $fm.scope
            Status      = $fm.status
            Verified    = $fm.verified
            Description = $fm.description
            Score       = $score
        }
    }
    return ($scored | Sort-Object Score -Descending | Select-Object -First $Limit)
}

function Get-VaultGraph {
    <#
      The wikilink graph, computed by grepping for [[target]].

      The CDP/app.metadataCache path was REMOVED (Claude review). It was not
      faster in any way that mattered -- this runs in milliseconds over a few
      thousand files -- and it carried real costs:
        * a dependency on Obsidian being open,
        * an open port (9223) that is arbitrary code execution inside Obsidian,
        * key-shape mismatch (metadataCache keys are folder-prefixed paths
          WITH .md, this returns bare names) requiring normalisation anyway.

      Obsidian stays a human viewer. It is not on the agent's critical path.
    #>
    [CmdletBinding()]
    param([string]$NoteName)

    $links = @()
    Get-ChildItem -Path $script:VaultRoot -Filter '*.md' -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\\.obsidian\\|\\\.system\\' } |
        ForEach-Object {
            $src = $_.Name
            $txt = [System.IO.File]::ReadAllText($_.FullName)

            # Strip fenced code blocks, inline code, and HTML comments FIRST.
            # Without this, a note that merely documents wikilink syntax
            # (e.g. "grep for [[name]]") emits a phantom edge -- seen live.
            $txt = [regex]::Replace($txt, '(?s)```.*?```', ' ')
            $txt = [regex]::Replace($txt, '`[^`\r\n]*`', ' ')
            $txt = [regex]::Replace($txt, '(?s)<!--.*?-->', ' ')

            foreach ($m in [regex]::Matches($txt, '\[\[([^\]|#]+)')) {
                $tgt = $m.Groups[1].Value.Trim()
                if ($tgt -match '\.md$') { $tgt = $tgt -replace '\.md$', '' }
                # Self-links are noise (a note linking to itself adds no edge).
                $bareSrc = $src -replace '\.md$', ''
                if ($tgt -and ($tgt -ne $bareSrc)) {
                    if ($NoteName) {
                        $n = $NoteName -replace '\.md$', ''
                        if ($bareSrc -eq $n) { $links += [pscustomobject]@{ Source=$src; Target=$tgt; Kind='outlink' } }
                        elseif ($tgt -eq $n)  { $links += [pscustomobject]@{ Source=$src; Target=$tgt; Kind='backlink' } }
                    }
                    else { $links += [pscustomobject]@{ Source=$src; Target=$tgt; Kind='outlink' } }
                }
            }
        }
    return $links
}

function Get-VaultCore {
    <#
      The always-loaded context block. Budget matters more than file count
      for a scraped-UI council: every byte here is pasted into a prompt box
      and costs tokens. Hard cap enforced.
    #>
    [CmdletBinding()]
    param([int]$MaxTokens = 1500)
    $core = Join-Path $script:VaultRoot 'CORE.md'
    if (-not (Test-Path -LiteralPath $core)) { return $null }
    $text = [System.IO.File]::ReadAllText($core)
    # ~4 chars/token is a deliberately conservative estimate.
    $cap = $MaxTokens * 4
    if ($text.Length -gt $cap) { return $text.Substring(0, $cap) + "`n...[core truncated to budget]" }
    return $text
}

function Test-VaultCodeShaped {
    <#
      Does this note describe code or environment state? Shared by validation
      (which requires a `verified` date on such notes) and the prune pass
      (which re-surfaces them when verification goes stale), so the two never
      disagree about what counts.
    #>
    [CmdletBinding()]
    param([string]$Text)
    return [bool]($Text -match '(?i)\b(code|repo|version|driver|install|config|api|path|command|flag|cli|dependency|package|port)\b')
}

function Test-VaultData {
    <#
      Validates a frontmatter hashtable WITHOUT touching disk, so the same
      rules can run before a write (refuse to create an invalid note) and
      after a read (report on an existing one). One definition means the rule
      cannot drift between the two paths -- which was the actual bug: the
      schema existed, but nothing ever ran it at write time.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Data,
        [string]$Path = ''
    )
    $problems = @()

    foreach ($f in $script:RequiredFields) {
        if (-not $Data.ContainsKey($f)) { $problems += "missing field: $f" }
    }
    if ($Data['status'] -and $Data['status'] -notin $script:ValidStatus) {
        $problems += "invalid status: '$($Data['status'])'"
    }
    if ($Data['basis'] -and $Data['basis'] -notin $script:ValidBasis) {
        $problems += "invalid basis: '$($Data['basis'])'"
    }
    if (-not $Data['description']) { $problems += 'empty description (retrieval hook)' }
    if (-not $Data['scope'])       { $problems += 'empty scope (which project/repo does this apply to?)' }

    # Dates are compared and aged programmatically; a free-text date like
    # "yes" or "recently" would silently break Get-VaultStale.
    foreach ($d in @('updated', 'verified')) {
        if ($Data[$d] -and [string]$Data[$d] -notmatch '^\d{4}-\d{2}-\d{2}$') {
            $problems += "$d must be YYYY-MM-DD, got '$($Data[$d])'"
        }
    }

    # Stale code facts are the dominant failure mode for a coding agent: a
    # confident memory about code that has since changed. Any note about code
    # or environment state must carry a verified date so it can be rechecked
    # before it is relied on.
    if ((Test-VaultCodeShaped -Text "$($Data['description']) $Path") -and -not $Data['verified']) {
        $problems += 'missing `verified` date (this note is about code/environment state)'
    }

    # --- probe spec (verification witness) ---
    # A probe is how a later session checks this note without asking a model.
    # It is optional, but if declared it must be executable: a probe spec that
    # cannot run is worse than none, because it reads as a guarantee.
    $pk = $Data['probe_kind']
    if ($pk) {
        if ($pk -notin $script:ValidProbeKinds) {
            $problems += "invalid probe_kind: '$pk'. Allowed: $($script:ValidProbeKinds -join ', ')"
        }
        if ($pk -eq 'suite') {
            if (-not $Data['probe_suite']) {
                $problems += 'probe_kind=suite requires probe_suite'
            }
            elseif ($Data['probe_suite'] -notin $script:AllowedProbeSuites) {
                $problems += "probe_suite '$($Data['probe_suite'])' is not allowlisted. Allowed: $($script:AllowedProbeSuites -join ', ')"
            }
        }
        else {
            # The other three kinds all point at a file inside the vault.
            if (-not $Data['probe_target']) {
                $problems += "probe_kind=$pk requires probe_target"
            }
            elseif ($Data['probe_target'] -match '(?i)^[A-Za-z]:|^\\{2}') {
                # Absolute paths would let a note point the witness at
                # C:\Windows\System32 and call the result evidence about the
                # vault. Probes observe this vault or they observe nothing.
                $problems += 'probe_target must be vault-relative, not an absolute path'
            }
            elseif ($Data['probe_target'] -match '(^|\\)\.\.($|\\)') {
                # Traversal is the same escape by another route. Checked HERE
                # and not only at resolve time, because a note declaring an
                # escaping probe is already a bad note -- letting it be created
                # and only failing later reads as a broken probe rather than a
                # rejected claim.
                $problems += 'probe_target must not traverse out of the vault (no .. segments)'
            }
        }
        if ($pk -eq 'symbol_present') {
            $pat = "$($Data['probe_pattern'])"
            if ([string]::IsNullOrWhiteSpace($pat)) {
                $problems += 'probe_kind=symbol_present requires probe_pattern'
            }
            elseif ($pat.Length -lt $script:MinProbePatternLength) {
                $problems += "probe_pattern is too short to be a real assertion (min $($script:MinProbePatternLength) chars)"
            }
        }
    }
    # These belong to the witness. Nothing else may set them, and `probe_*` is
    # intentionally absent from Update-VaultNote's whitelist: a probe the model
    # can rewrite after seeing the result proves nothing.
    foreach ($pf in @('probe_kind','probe_target','probe_pattern','probe_suite')) {
        if ($Data.ContainsKey($pf) -and -not $Data[$pf]) { $Data.Remove($pf) }
    }

    return $problems
}

function Test-VaultNote {
    <#
      True when an existing note passes every rule. Used by the read verb to
      surface schema problems, and by any pass that decides whether to promote
      or trust a note.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $fm       = Read-VaultFrontmatter -Path $Path
    $problems = @(Test-VaultData -Data $fm -Path $Path)

    return [pscustomobject]@{
        Path     = $Path
        Valid    = ($problems.Count -eq 0)
        Problems = $problems
    }
}

function New-VaultNote {
    <#
      CONSTRAINED VERB. Create a note in an allowed folder.

      Refuses rather than overwrites: dedupe is on (name + aliases), because
      an agent silently replacing an existing note is the single most common
      way this kind of vault rots. The error tells the agent to append or
      propose an edit instead.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Folder,        # inbox | entities | decisions | lessons
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$Body,
        [string[]]$Aliases = @(),
        [string]$Status = 'active',
        [string]$Basis = 'inferred',
        [Parameter(Mandatory)][string]$Scope,          # which project/repo this applies to
        [string]$Verified = '',                        # required for code/env-state notes
        [string]$SupersededBy = '',
        [string]$ProbeKind = '',                      # how a later session re-checks this note
        [string]$ProbeTarget = '',                    # vault-relative; never absolute
        [string]$ProbePattern = '',                   # symbol_present only
        [string]$ProbeSuite = '',                     # suite only; an ID, never a command
        [string]$Author = 'harness'                    # git author only; NOT written to frontmatter
    )

    # NO [ValidateSet] on Status / Basis / ProbeKind / ProbeSuite. They carried
    # literal lists, which made them a THIRD and FOURTH copy of vocabularies
    # that also lived in $script:ValidStatus / $script:ValidBasis /
    # $script:ValidProbeKinds / $script:AllowedProbeSuites and in
    # vault-mcp.mjs. ValidateSet is evaluated at PARSE time and cannot read a
    # variable -- IValidateSetValuesGenerator is PowerShell 6+, not Windows
    # PowerShell 5.1 -- so it was structurally incapable of deriving.
    #
    # These guards read the registry instead, and still reject BEFORE any byte
    # is written: the file write happens well after this point. They duplicate
    # Test-VaultData's checks on purpose (defense in depth), but both read the
    # same registry, so there is still one source of truth for the vocabulary.
    if ($Status -and $Status -notin $script:ValidStatus) {
        throw "invalid status: '$Status'. Allowed: $($script:ValidStatus -join ', ')"
    }
    if ($Basis -and $Basis -notin $script:ValidBasis) {
        throw "invalid basis: '$Basis'. Allowed: $($script:ValidBasis -join ', ')"
    }
    if ($ProbeKind -and $ProbeKind -notin $script:ValidProbeKinds) {
        throw "invalid probe_kind: '$ProbeKind'. Allowed: $($script:ValidProbeKinds -join ', ')"
    }
    if ($ProbeSuite -and $ProbeSuite -notin $script:AllowedProbeSuites) {
        throw "invalid probe_suite: '$ProbeSuite'. Allowed: $($script:AllowedProbeSuites -join ', ')"
    }

    $clean = Test-SafeNoteName -Name $Name
    $rel   = "$Folder\$clean.md"
    $full  = Resolve-VaultSafePath -RelativePath $rel

    if (Test-Path -LiteralPath $full) {
        throw ("Note already exists: '$rel'. " +
               "Do NOT overwrite. Use Update-VaultNote to append, or create a distinctly named note.")
    }

    # Dedupe on aliases too -- "Hermes" and "hermes-runtime" are the same thing.
    $allAliases = @($Aliases) + @($clean)
    foreach ($folder in $script:WriteFolders) {
        Get-ChildItem -Path (Join-Path $script:VaultRoot $folder) -Filter '*.md' -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                $fm = Read-VaultFrontmatter -Path $_.FullName
                $names = @($fm.name) + @($fm.aliases)
                foreach ($n in $names) {
                    if ($n -and ($allAliases -contains $n)) {
                        throw ("Possible duplicate: '$n' already exists at '$($_.FullName)'. " +
                               "Link to it instead of creating a second note.")
                    }
                }
            }
    }

    $now = (Get-Date).ToString('yyyy-MM-dd')
    $fm  = @{
        name         = $clean
        description  = $Description
        aliases      = @($Aliases)
        status       = $Status
        updated      = $now
        basis        = $Basis
        scope        = $Scope
    }
    if ($SupersededBy) { $fm.superseded_by = $SupersededBy }
    if ($Verified)     { $fm.verified     = $Verified }

    # The probe is declared here, once, at creation. It is NOT in
    # Update-VaultNote's whitelist, so it cannot be rewritten after a session
    # has seen what the probe returns -- a probe the writer can tune is a
    # second opinion wearing a lab coat.
    if ($ProbeKind)    { $fm.probe_kind    = $ProbeKind }
    if ($ProbeTarget)  { $fm.probe_target  = ($ProbeTarget -replace '/', '\').Trim() }
    if ($ProbePattern) { $fm.probe_pattern = $ProbePattern }
    if ($ProbeSuite)   { $fm.probe_suite   = $ProbeSuite }

    # Validate BEFORE writing, against the in-memory data -- the file does not
    # exist yet, so the on-disk validator cannot be used here. Without this the
    # schema was advisory: Test-VaultNote only ever reported problems after
    # the fact, and nothing stopped an invalid note from landing.
    $problems = @(Test-VaultData -Data $fm -Path $rel)
    if ($problems.Count) {
        throw "Refusing to create '$rel' -- it would fail its own validation: $($problems -join '; ')"
    }

    $content = (ConvertTo-VaultFrontmatter -Data $fm) + "`n" + $Body.Trim() + "`n"
    Write-VaultFileAtomic -FullPath $full -Content $content

    $commit = Save-VaultCommit -Message "create $rel" -Author $Author -Path $rel

    # Report the TRUE post-write state. Before this, the verb returned
    # Created=$true unconditionally: if git add/commit failed (a hook, a lock,
    # a git warning turned terminating by EAP=Stop) the caller was told the note
    # was committed when it was only on disk -- or, worse, the throw from inside
    # Save-VaultCommit surfaced as a flat refusal even though the file existed.
    # Now: the file IS on disk at this point no matter what, so a commit failure
    # is PARTIAL, never a clean refusal.
    $committed = [bool]$commit.committed
    $partial   = $false
    if ($commit -is [hashtable] -and $commit.ContainsKey('partial')) { $partial = [bool]$commit.partial }

    if (-not $committed -and -not $partial) {
        # Clean non-commit: git is absent, or nothing was there to commit.
        $why = 'unknown reason'
        if ($commit -is [hashtable] -and $commit.ContainsKey('reason') -and $commit.reason) { $why = $commit.reason }
        Write-Warning ("Note '$rel' is on disk but was NOT committed: $why")
    }

    $sha    = $null
    $reason = $null
    if ($commit -is [hashtable]) {
        if ($commit.ContainsKey('sha'))    { $sha    = $commit.sha }
        if ($commit.ContainsKey('reason')) { $reason = $commit.reason }
    }

    return [pscustomobject]@{
        Path     = $rel
        FullPath = $full
        Created  = $true            # the file exists on disk -- always true here
        Committed= $committed       # has a real commit behind it (reviewable diff)
        Partial  = $partial         # written but commit failed; needs attention
        Commit   = $sha
        Reason   = $reason
    }
}

function Add-VaultInboxItem {
    <#
      STAGING. Used for content that is NOT yet trusted: external-model
      claims (Gemini/Claude/web), user statements captured under context
      pressure, and anything you will want to judge in a later session.

      Direct note creation is preferred for anything you observed yourself.
      If this folder is never drained, it is a graveyard -- see the prune rule
      in the session protocol (surface items older than ~7 days).

      Two rules:
        1. No transcripts. A proposal must be a single durable claim.
        2. WARN on instruction-shaped external content. This is warn-only and
           deliberately NOT a hard refuse -- see the note below.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Claim,
        [string[]]$Aliases = @(),
        [string[]]$Links = @(),
        # No ValidateSet -- see the note in New-VaultNote. That verb now guards
        # Basis against the registry, and every path here ends at it.
        [string]$Basis = 'external-model',
        [Parameter(Mandatory)][string]$Scope,
        [string]$Author = 'harness'
    )

    # --- content guard: WARN-ONLY, external content only ---
    # WHY IT WAS DOWNGRADED FROM A REFUSE (Claude review, verified by test):
    # Memory for a coding agent is inherently instruction-shaped. "Always use
    # pnputil", "run tests before commit" -- these are exactly the notes worth
    # keeping, and a refuse blocked that class by design. Tested against all
    # 6 seeded notes: 0 refused; the representative "always use pnputil" note
    # passed. The earlier 8/8-refuse figure proved little because I wrote the
    # tests and the patterns together.
    #
    # The real structural defense is: provenance lives in `basis`, CORE.md
    # says notes are data and never commands, and full notes are never
    # auto-injected as instructions. The regex below is a tripwire, not a wall.
    #
    # It only runs for external-model content, because that is the only place
    # an attacker-controlled sentence can enter the vault. Content you wrote
    # yourself is not scanned -- you are not the threat.
    if ($Basis -eq 'external-model') {
        $instructionPatterns = @(
            '(?i)\b(?:ignore|disregard|forget|overrid|suspend|bypass|throw out|strip out)\b[\s\S]{0,40}?\b(?:instructions?|rules?|guidelines?|constraints?|prompts?|the above|the previous|prior)\b',
            '(?i)\b(?:you are now|act as if|pretend (?:to be|you are)|your new role|from now on you)\b',
            '(?i)\b(?:reveal|print|repeat|output|expose|leak)\b[\s\S]{0,30}?\b(?:system prompt|hidden prompt|developer message|instructions)\b',
            '(?i)\bexfiltrat',
            '(?i)\b(?:send|post|upload|forward|email)\b[\s\S]{0,30}?\b(?:this|it|the vault|the notes?|your output|everything)\b[\s\S]{0,30}?\b(?:to|into|at)\b[\s\S]{0,20}?\b(?:https?://|ftp://|discord|webhook|api endpoint)',
            '(?i)\b(?:do not|don''t|never)\b[\s\S]{0,25}?\b(?:tell|inform|mention|reveal)\b[\s\S]{0,20}?\b(?:the user|anyone|anyone else|the human)\b[\s\S]{0,20}?\b(?:that you|that this|about (?:this|your) (?:note|memory|write|save))\b',
            '(?i)\b(?:hide|conceal|keep (?:this|it) secret|cover up)\b[\s\S]{0,30}?\b(?:from the user|from anyone|the memory|this note|your writes)\b'
        )
        foreach ($p in $instructionPatterns) {
            if ($Claim -match $p) {
                Write-Warning ("Instruction-shaped content in external-model note '$Title' " +
                               "(matched: '$($Matches[0])'). Writing anyway -- review before promoting.")
                break
            }
        }
    }

    # Transcripts are still a hard refuse: they are a context-budget problem,
    # not a trust problem, and they fail the "still true in 3 months" test.
    if ($Claim.Length -gt 1200) {
        throw "Refused: proposal is $($Claim.Length) chars. Split it, or write a summary plus a link. Transcripts are not memory."
    }

    $linkBlock = ''
    if ($Links -and $Links.Count) {
        $linkBlock = "`n## Related`n" + (($Links | ForEach-Object { "- [[$_]]" }) -join "`n")
    }

    $body = @"
## Claim

$Claim

$linkBlock

## Disposition

- [ ] Reviewed by user
- [ ] Promoted to a permanent note
- [ ] Archived (not worth keeping)
"@

    $stamp = (Get-Date).ToString('yyyy-MM-dd-HHmmss')
    return New-VaultNote -Folder 'inbox' -Name "$Title ($stamp)" `
                         -Description $Claim.Trim().Substring(0, [Math]::Min(150, $Claim.Trim().Length)) `
                         -Body $body -Aliases $Aliases -Basis $Basis -Scope $Scope -Author $Author
}

function Update-VaultNote {
    <#
      Three ways to change a note, all of them non-destructive in spirit:

        -AppendText   add a section (the common case)
        -ReplaceBody  swap the whole body -- deliberately awkward, because
                      "agent rewrites a file from its memory of an earlier read"
                      is how notes get clobbered
        -Set          edit frontmatter fields through a whitelist

      -Set exists because without it `status: superseded` is unreachable: a
      note could never be retired, so every note would live forever as
      `active` and the stale pass would only ever report stale items, never
      superseded ones. Updated is deliberately NOT in the whitelist -- it is
      always today's date, so an agent cannot backdate its own edit, and
      neither is `name`, because renaming means a new note plus a supersede
      pointer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [string]$AppendText = '',
        [string]$ReplaceBody = '',
        [hashtable]$Set = @{},
        [string]$Author = 'harness'
    )
    $full = Resolve-VaultSafePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $full)) { throw "No such note: '$RelativePath'" }

    $fm   = Read-VaultFrontmatter -Path $full
    $body = Get-VaultNoteBody -Path $full

    if ($ReplaceBody -and -not $PSBoundParameters.ContainsKey('AppendText')) {
        $body = $ReplaceBody.Trim()
        $action = 'replace'
    }
    elseif ($AppendText) {
        $body = ($body.TrimEnd() + "`n`n" + $AppendText.Trim())
        $action = 'append'
    }

    # --- frontmatter whitelist ---
    #
    # `verified` was removed here on 2026-10-17, on the joint recommendation of
    # two independent consultations. Claude: moving it "takes the model out of
    # the loop for the one field that matters most." Meta: "refuse to infer
    # missing fields -- if verified is null, leave it null. Do not set
    # verified: today because content matches."
    #
    # The failure this closes: a note sits unverified, then the same agent that
    # wrote it back-dates a verified stamp later, having checked nothing. The
    # declaration survives in git history, so the note still READS as verified
    # while no check ever ran. Re-verification is now the verify verb's job --
    # it executes a probe and appends to an evidence log the write verbs cannot
    # reach. A model may declare `verified` when creating a fresh note; it can
    # never re-certify one after the fact.
    #
    # The list itself now comes from registry.json rather than a literal here.
    # It had ALSO been duplicated in vault-mcp.mjs's documented `set` whitelist,
    # which is how the two could disagree about what `verified` meant. Note the
    # name split that survives deliberately: the MCP schema exposes camelCase
    # `supersededBy`, the adapter normalises it to snake_case at line ~220, and
    # the registry records the snake_case form the library actually enforces.
    $mutable  = @($script:VaultRegistry.mutableKeys)
    $changed  = @()
    foreach ($k in @($Set.Keys)) {
        if ($mutable -notcontains $k) {
            throw "Field '$k' is not mutable through update. Mutable: $($mutable -join ', '). " +
                  "To rename, create a new note and set superseded_by."
        }
        $fm[$k] = $Set[$k]
        $changed += $k
    }

    if ($changed.Count -and $action)      { $action = "$action+set($($changed -join ','))" }
    elseif ($changed.Count)               { $action = "set($($changed -join ','))" }
    elseif (-not $action)                 { throw 'Specify -AppendText, -ReplaceBody, or -Set.' }

    # The result must still be a valid note; refuse rather than leave a note
    # that the schema would reject on the next read.
    $problems = @(Test-VaultData -Data $fm -Path $RelativePath)
    if ($problems.Count) {
        throw "Refusing to update '$RelativePath' -- it would end up invalid: $($problems -join '; ')"
    }

    $fm.updated = (Get-Date).ToString('yyyy-MM-dd')
    $content = (ConvertTo-VaultFrontmatter -Data $fm) + "`n" + $body.Trim() + "`n"
    Write-VaultFileAtomic -FullPath $full -Content $content

    $commit = Save-VaultCommit -Message "$action $RelativePath" -Author $Author -Path $RelativePath

    # Same honesty rule as New-VaultNote: the file was already rewritten at this
    # point, so a failed commit is PARTIAL, never a silent success and never a
    # refusal. The caller decides how loudly to report it.
    $committed = [bool]$commit.committed
    $partial   = $false
    $reason    = $null
    if ($commit -is [hashtable]) {
        if ($commit.ContainsKey('partial')) { $partial = [bool]$commit.partial }
        if ($commit.ContainsKey('reason'))  { $reason  = $commit.reason }
    }
    if (-not $committed -and -not $partial) {
        $why = if ($reason) { $reason } else { 'unknown reason' }
        Write-Warning ("'$RelativePath' was updated on disk but NOT committed: $why")
    }
    $sha = $null
    if ($commit -is [hashtable] -and $commit.ContainsKey('sha')) { $sha = $commit.sha }
    return [pscustomobject]@{
        Path = $RelativePath; Action = $action; Commit = $sha; Set = $changed
        Committed = $committed; Partial = $partial; Reason = $reason
    }
}

function Get-VaultStale {
    <#
      THE PRUNE / VERIFY PASS. Two decay modes this exists to surface:

        1. An inbox nobody drains. Nothing gets consolidated and the folder
           turns into a graveyard of half-trusted claims. Rule: surface inbox
           items older than ~InboxDays and either promote or delete them.
        2. Stale code facts. A note confidently describing a driver, a port,
           a version or a path that has since changed. Without this pass,
           `verified` would just be decoration.

      It also reports notes already marked stale/superseded, so the status
      field gets acted on instead of being written once and forgotten.

      Read-only. Deletion is a human/agent decision with git as the safety
      net -- no verb here removes anything.
    #>
    [CmdletBinding()]
    param(
        [int]$InboxDays   = 7,
        [int]$VerifiedDays = 90
    )
    $now = Get-Date
    $rows = @()

    $files = Get-ChildItem -Path $script:VaultRoot -Filter '*.md' -Recurse -File -ErrorAction SilentlyContinue |
             Where-Object { $_.FullName -notmatch '\\\.obsidian\\|\\\.system\\|\\\.git\\' }

    foreach ($f in $files) {
        $rel    = $f.FullName.Substring($script:VaultRoot.Length + 1)
        $folder = $f.Directory.Name
        $fm     = Read-VaultFrontmatter -Path $f.FullName

        $ageDays = $null
        if ($fm.updated) { try { $ageDays = [int]($now - [datetime]$fm.updated).TotalDays } catch { } }

        $reasons = @()

        if ($folder -eq 'inbox' -and $null -ne $ageDays -and $ageDays -ge $InboxDays) {
            $reasons += "inbox item $ageDays days old -- drain it (promote or delete)"
        }
        if ($fm.status -eq 'stale')     { $reasons += 'marked stale' }
        if ($fm.status -eq 'superseded') {
            $by = if ($fm.superseded_by) { " by '$($fm.superseded_by)'" } else { '' }
            $reasons += "superseded$by"
        }

        # The verification clock. A code/environment note that has not been
        # rechecked recently is a claim, not a fact.
        if ($fm.verified) {
            try {
                $vAge = [int]($now - [datetime]$fm.verified).TotalDays
                if ($vAge -ge $VerifiedDays) { $reasons += "not verified for $vAge days -- recheck before relying on it" }
            } catch { }
        }
        elseif (Test-VaultCodeShaped -Text "$($fm.description) $rel") {
            $reasons += 'about code/environment but has NO verified date'
        }

        if ($reasons.Count) {
            $rows += [pscustomobject]@{
                Path     = $rel
                Folder   = $folder
                Reasons  = $reasons
                Updated  = $fm.updated
                Verified = $fm.verified
                Status   = $fm.status
                AgeDays  = $ageDays
            }
        }
    }
    return ($rows | Sort-Object Folder, Path)
}

# NOTE: this file is dot-sourced, not imported as a module, so there is no
# Export-ModuleMember. Dot-sourcing puts every function directly in scope.

# --- verification: the witness ---------------------------------------------

# `suite` names one of these. Never a command string -- an arbitrary command
# with the agent's authority behind it would make verify an injection surface,
# which is worse than having no verifier at all.
$script:ProbeSuites = @{
    'smoke'            = @{ File = '.system\smoke-test.mjs';            Runner = 'node' }
    'cold-start'       = @{ File = '.system\cold-start-test.mjs';        Runner = 'node' }
    'native-stderr'    = @{ File = '.system\native-stderr-test.ps1';     Runner = 'ps1'  }
    'write-validation' = @{ File = '.system\write-validation-test.ps1';  Runner = 'ps1'  }
}

# Append-only, and unreachable by every write verb: `.system` is in
# $script:BlockedFolders. That is the whole point -- evidence the model cannot
# edit is the difference between a witness and a claim about a witness.
$script:VerifyLogName = '.system\verify-log.ndjson'

function Resolve-VaultProbeTarget {
    <#
      Probe targets are vault-relative and may not traverse. Returns $null for
      anything that would escape the root, so the caller reports `failed`
      rather than quietly observing some other directory.
    #>
    [CmdletBinding()]
    param([string]$Target)

    $rel = ("$Target" -replace '/', '\').Trim().Trim('"').Trim("'")
    if ([string]::IsNullOrWhiteSpace($rel)) { return $null }
    # Absolute (drive letter or UNC). Note the parens: in PowerShell a bare
    # `-or` cannot sit between two statements -- that is a parse error, and it
    # took the WHOLE library down, so every verb failed, not just verify.
    if (($rel -match '^(?i)[A-Za-z]:') -or ($rel -match '^\\{2}')) { return $null }
    if ($rel -match '(^|\\)\.\.($|\\)') { return $null }                          # traversal

    $root = [System.IO.Path]::GetFullPath($script:VaultRoot)
    $full = [System.IO.Path]::GetFullPath((Join-Path $root $rel))
    if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $full
}

function Get-VaultSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.IO.File]::ReadAllBytes($Path))
        return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha.Dispose() }
}

function Invoke-VaultProbe {
    <#
      Executes ONE probe from the closed registry. Returns a structured result
      -- never prose, never a bare boolean.

      CANARY CONTROLS (Claude, 2026-10-17): "a probe that can't fail proves
      nothing." Every kind runs a control that MUST fail. If the control
      passes, the probe is broken and the result is `failed` -- not a pass, and
      not an error to be swallowed. A verifier that cannot distinguish a
      working probe from a dead one will happily certify a note with a probe
      that matches everything.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Kind,
        [string]$Target = '',
        [string]$Pattern = '',
        [string]$Suite = '',
        [int]$TimeoutMs = 120000
    )

    $r = @{
        Kind = $Kind; Ok = $false; Ran = $false
        Detail = ''; Evidence = ''; ControlOk = $false; ControlDetail = ''
    }

    switch ($Kind) {

        'path_exists' {
            $full = Resolve-VaultProbeTarget -Target $Target
            if (-not $full) {
                $r.Detail = "probe_target '$Target' does not resolve inside the vault"
                break
            }
            $r.Ran = $true
            $r.Ok = [bool](Test-Path -LiteralPath $full)
            $r.Detail = "Test-Path $Target -> $($r.Ok)"
            $r.Evidence = "exists=$($r.Ok)"

            # Canary: a sentinel nothing ever creates. It MUST be absent.
            $canary = Join-Path ([System.IO.Path]::GetFullPath($script:VaultRoot)) '.system\__vault_probe_canary__.md'
            $r.ControlOk = -not (Test-Path -LiteralPath $canary)
            $r.ControlDetail = "canary absent -> $($r.ControlOk)"
        }

        'file_hash' {
            $full = Resolve-VaultProbeTarget -Target $Target
            if (-not $full) {
                $r.Detail = "probe_target '$Target' does not resolve inside the vault"
                break
            }
            if (-not (Test-Path -LiteralPath $full)) {
                $r.Detail = "probe_target does not exist: $Target"
                break   # Ran stays false -> caller reports failed
            }
            $r.Ran = $true
            try {
                $h = Get-VaultSha256 -Path $full
                $r.Ok = ($h -match '^[0-9a-f]{64}$')
                $r.Detail = "sha256 computed"
                $r.Evidence = "sha256:$h"
                # Canary: a real SHA-256 is exactly 64 lowercase hex chars.
                $r.ControlOk = $r.Ok
                $r.ControlDetail = "digest shape -> $($r.Ok)"
            }
            catch {
                $r.Detail = "hash failed: $($_.Exception.Message)"
            }
        }

        'symbol_present' {
            $full = Resolve-VaultProbeTarget -Target $Target
            if (-not $full) {
                $r.Detail = "probe_target '$Target' does not resolve inside the vault"
                break
            }
            if (-not (Test-Path -LiteralPath $full)) {
                $r.Detail = "probe_target does not exist: $Target"
                break
            }
            $r.Ran = $true
            try {
                # Text is normalised LF-first: rg and .NET text reads both hand
                # back CRLF on Windows, and a phantom \r breaks line matching.
                $lines = ([System.IO.File]::ReadAllText($full) -replace "`r`n", "`n") -split "`n"
                $hits  = @()
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -match $Pattern) {
                        $hits += ('{0}: {1}' -f ($i + 1), $lines[$i].Trim())
                        if ($hits.Count -ge 3) { break }   # enough to prove it, small enough to read
                    }
                }
                $r.Ok = ($hits.Count -gt 0)
                $r.Detail = "$($hits.Count) match(es) for pattern in $Target"
                $r.Evidence = ($hits -join "`n")

                # Canary: the SAME pattern plus a random nonce must match
                # NOTHING. If that also matches, the pattern is matching
                # everything and the probe proves nothing.
                $nonce = [System.IO.Path]::GetRandomFileName() -replace '[^A-Za-z0-9]', ''
                $ctrlOk = $true
                foreach ($ln in $lines) { if ($ln -match ($Pattern + $nonce)) { $ctrlOk = $false; break } }
                $r.ControlOk = $ctrlOk
                $r.ControlDetail = "nonce-appended pattern matched nothing -> $ctrlOk"
            }
            catch {
                $r.Detail = "pattern match failed: $($_.Exception.Message)"
            }
        }

        'suite' {
            $spec = $script:ProbeSuites[$Suite]
            if (-not $spec) {
                $r.Detail = "suite '$Suite' is not allowlisted"
                break
            }
            $suiteFull = Resolve-VaultProbeTarget -Target $spec.File
            if (-not $suiteFull -or -not (Test-Path -LiteralPath $suiteFull)) {
                $r.Detail = "suite file missing: $($spec.File)"
                break
            }
            $r.Ran = $true

            $exe  = $null; $arg = $null
            if ($spec.Runner -eq 'node') { $exe = 'node.exe'; $arg = "`"$suiteFull`"" }
            else {
                $exe  = 'powershell.exe'
                $arg  = "-NoProfile -ExecutionPolicy Bypass -File `"$suiteFull`""
            }

            # Run the process directly and read ITS ExitCode. Deliberately NOT
            # through the shell: Claude's pitfall (2026-10-17) is a stale
            # $LASTEXITCODE from an earlier command masquerading as this
            # probe's result. Reading $p.ExitCode off this process object makes
            # that class of bug impossible -- there is no ambient register.
            # stdout/stderr go to temp files, never through the error stream.
            $outF = [System.IO.Path]::GetTempFileName()
            $errF = [System.IO.Path]::GetTempFileName()
            try {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $exe; $psi.Arguments = $arg
                $psi.WorkingDirectory = $script:VaultRoot
                $psi.UseShellExecute = $false
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError  = $true
                $p = [System.Diagnostics.Process]::Start($psi)
                $so = $p.StandardOutput.ReadToEndAsync()
                $se = $p.StandardError.ReadToEndAsync()
                if (-not $p.WaitForExit($TimeoutMs)) {
                    try { $p.Kill() } catch { }
                    $r.Detail = "suite '$Suite' TIMED OUT after ${TimeoutMs}ms"
                    break    # timeout is a failure, never a pass
                }
                $code = $p.ExitCode
                $p.WaitForExit()   # flush async readers
                [System.IO.File]::WriteAllText($outF, $so.Result)
                [System.IO.File]::WriteAllText($errF, $se.Result)

                $tail = (($so.Result -replace "`r`n", "`n") -split "`n" | Select-Object -Last 12) -join "`n"
                $r.Ok = ($code -eq 0)
                $r.Detail = "suite '$Suite' exit=$code"
                $r.Evidence = "exit=$code`n$tail"

                # Canary: the exit code is a real, bounded integer and the
                # process produced SOME output. A runner that silently failed
                # to start can hand back neither.
                $r.ControlOk = (($code -ge 0) -and ($code -lt 200) -and ($so.Result.Length -gt 0))
                $r.ControlDetail = "exit code sane and stdout non-empty -> $($r.ControlOk)"
            }
            finally {
                Remove-Item -LiteralPath $outF, $errF -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # A control that did not fail means the probe never actually tested
    # anything. Downgrade to failed rather than reporting a pass from an
    # instrument that is not measuring.
    if ($r.Ok -and -not $r.ControlOk) {
        $r.Ok = $false
        $r.Detail = "CANARY CONTROL FAILED -- probe result discarded. $($r.ControlDetail)"
    }
    return $r
}

function Invoke-VaultVerify {
    <#
      THE VERIFY VERB. Answers one question and refuses the others:

          "Does the world still satisfy the predicate this note declared?"

      It does NOT answer "is this claim true?" -- a probe witnesses a
      predicate, not a proposition. ChatGPT's dividing line (2026-10-17):
      `validate` asks "is this record structurally permitted?", `verify` asks
      "what can the system independently establish right now?". A record can be
      perfectly valid YAML and still hold a fabricated claim.

      Three outcomes, and the error rule is fail-closed:
          verified      -- every check ran and passed
          failed        -- a check failed, OR could not run
          unverifiable  -- no probe was declared

      An exception, timeout, missing file or empty capture is ALWAYS `failed`.
      Never a pass. A verifier that cannot run its checks is the exact bug this
      exists to prevent: hallucinated success.

      Writes ONLY to the append-only evidence log under `.system/`, which every
      write verb is blocked from. It never edits the note -- the checker must
      not change the object whose state it is attesting to.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RelativePath)

    $rel = ($RelativePath -replace '/', '\').Trim()
    if ([System.IO.Path]::IsPathRooted($rel)) { $rel = ConvertTo-VaultRelativePath -Path $rel }

    $checks  = New-Object System.Collections.Generic.List[object]
    $fm      = @{}
    $hash    = $null

    # The three axes, initialised to their SAFEST value. `unknown` is not
    # `unchanged`: if a hash cannot be computed or a prior record is missing or
    # unparseable, the honest answer is that drift is unknown -- and unknown
    # must not read as clean. Likewise probe_ok starts false, so an early
    # exception leaves a failing record rather than an unqualified one.
    $probeOk       = $false
    $driftState    = 'unrecorded'
    $specDrift     = 'unknown'
    $prev          = $null
    $schemaOk      = $false
    $logCorrupt    = $false

    function Add-Check([string]$Name, [bool]$Ok, [string]$Detail) {
        # No $script: here. PowerShell scoping is dynamic, so this nested
        # function sees the caller's local $checks; `$script:checks` would
        # instead resolve to vault-lib's script scope and silently collect
        # nothing -- every check would vanish and the result would read clean.
        $checks.Add([pscustomobject]@{ check = $Name; ok = $Ok; detail = $Detail })
    }

    try {
        # 1. Read the artifact from DISK. Never accept note content from the
        #    caller -- that grades the story, not the artifact.
        $full = $null
        try { $full = Resolve-VaultSafePath -RelativePath $rel }
        catch { Add-Check 'resolve' $false $_.Exception.Message; throw }

        if (-not (Test-Path -LiteralPath $full)) {
            Add-Check 'read' $false "no such note: $rel"; throw "no such note: $rel"
        }
        $fm   = Read-VaultFrontmatter -Path $full
        $body = Get-VaultNoteBody -Path $full
        Add-Check 'read' $true "read $rel from disk ($([System.IO.FileInfo]$full) bytes)"

        # 2. Schema, with OUR parser -- not the model asserting it is valid.
        $problems = @(Test-VaultData -Data $fm -Path $rel)
        $schemaOk = ($problems.Count -eq 0)
        Add-Check 'schema' $schemaOk $(if ($problems.Count) { $problems -join '; ' } else { 'frontmatter satisfies the schema' })

        # 3. Temporal. A `verified` date in the future is a stamp for work not
        #    yet done, and Get-VaultStale would then read it as fresh forever.
        if ($fm.verified) {
            $future = $false
            try { $future = ([datetime]$fm.verified).Date -gt (Get-Date).Date }
            catch { $future = $true }
            Add-Check 'temporal' (-not $future) "verified=$($fm.verified)"
            if ($future) { $schemaOk = $false }
        }

        # 4. Content hash, taken now. Bound to the log below, so drift between
        #    two verifies is detectable instead of invisible.
        try { $hash = Get-VaultSha256 -Path $full; Add-Check 'fingerprint' $true "sha256:$($hash.Substring(0,16))..." }
        catch { Add-Check 'fingerprint' $false $_.Exception.Message; $hash = $null }

        # 5. Load the prior record for this note. Unparseable or absent is
        #    `unknown` drift, NOT `unchanged` -- treating "I have no history"
        #    as "nothing changed" is how a re-verified note reads clean after
        #    an edit it never recorded.
        $logFull = Join-Path $script:VaultRoot $script:VerifyLogName
        if (Test-Path -LiteralPath $logFull) {
            $sawLine = $false
            foreach ($ln in ([System.IO.File]::ReadAllText($logFull) -split "`r?`n" | Where-Object { $_ })) {
                try {
                    $e = $ln | ConvertFrom-Json
                    if ($e.path -eq $rel) { $prev = $e; $sawLine = $true }
                } catch {
                    # A corrupt line must not be mistaken for "no history".
                    $sawLine = $true
                    $logCorrupt = $true
                    Add-Check 'log-parse' $false 'a prior log line for this note could not be parsed'
                }
            }
            if ($logCorrupt) { $driftState = 'unknown' }
        }

        # 5b. SPEC drift is a different animal from BODY drift, and must not
        #     share its policy. The probe spec is absent from append's set
        #     whitelist, so by construction it cannot change through the write
        #     path. If its recorded spec no longer matches, something bypassed
        #     that path -- an integrity violation, not staleness. Loud, hard,
        #     and reported on its own axis so it is never averaged away.
        if ($prev) {
            # Compare against the SPEC fields the log actually recorded.
            $prevK = "$($prev.probe_kind)"; $prevT = "$($prev.probe_target)"
            $prevP = "$($prev.probe_pattern)"; $prevS = "$($prev.probe_suite)"
            $sameSpec = ($prevK -eq "$($fm.probe_kind)") -and ($prevT -eq "$($fm.probe_target)") `
                        -and ($prevP -eq "$($fm.probe_pattern)") -and ($prevS -eq "$($fm.probe_suite)")
            if ($sameSpec) { $specDrift = 'unchanged' }
            else {
                $specDrift = 'changed'
                Add-Check 'spec-drift' $false 'PROBE SPEC CHANGED since last verify -- the spec is not mutable through the write path, so this means the write path was bypassed'
            }
        }
        else { $specDrift = 'unknown' }

        # 5c. BODY drift. Ordinary staleness: the artifact is no longer the one
        #     that was checked.
        if ($prev -and $hash) {
            $same = ($prev.content_hash -eq $hash)
            $driftState = $(if ($same) { 'unchanged' } else { 'changed' })
            Add-Check 'drift' $same $(if ($same) { 'content unchanged since last verify' } else { "CONTENT CHANGED since last verify (was $($prev.content_hash.Substring(0,16))..., now $($hash.Substring(0,16))...)" })
        }
        elseif (-not $prev) { Add-Check 'drift' $true 'no prior verification on record' }

        # 6. The probe. No declared probe means nothing can be witnessed --
        #    which is `unverifiable`, never a default pass.
        if (-not $fm.probe_kind) {
            Add-Check 'probe' $false 'no probe declared on this note -- nothing can be independently witnessed'
        }
        else {
            $pr = Invoke-VaultProbe -Kind "$($fm.probe_kind)" -Target "$($fm.probe_target)" `
                                      -Pattern "$($fm.probe_pattern)" -Suite "$($fm.probe_suite)"
            Add-Check "probe:$($fm.probe_kind)" ([bool]$pr.Ok) "$($pr.Detail) | control: $($pr.ControlDetail)"
            if ($pr.Evidence) { Add-Check 'probe-evidence' $true ($pr.Evidence -replace "`r`n", "`n" -replace "`n", ' / ') }
            $probeOk = [bool]$pr.Ok
        }
    }
    catch {
        # Fail closed. An exception during verification is a failure to
        # verify, and a failure to verify is never a pass.
    }

    # --- collapse the axes: a pure CONJUNCTION ---
    # Fail-closed is a rule about what a consumer may BELIEVE, not about how
    # many fields the log carries. Keeping the axes separate buys the
    # diagnostic (WHY did it fail?) while the verdict stays as strict as the
    # single-bit original: verified requires the predicate to hold AND the
    # content to be unchanged AND the spec to be unchanged. Drift can only ever
    # LOWER the verdict, never raise it.
    #
    # Drift has THREE states, and conflating the last two was the bug this
    # revision fixes:
    #
    #   unchanged    history exists and the hash matches
    #   changed      history exists and the hash moved
    #   unrecorded   NO history for this note -- the normal case for a first
    #                verify. Nothing has changed because nothing was recorded.
    #   unknown      history exists but could not be read or parsed. This is
    #                the dangerous one: it means evidence that should be there
    #                is not. Never clean.
    #
    # Treating `unrecorded` as unknown failed every first verify; treating
    # `unknown` as unrecorded would let an unreadable log silently clear an
    # edited note. Only the split is honest.
    $cleanDrift = ($driftState -in @('unchanged', 'unrecorded'))
    $cleanSpec  = ($specDrift  -in @('unchanged', 'unknown'))   # unknown spec = no prior spec to compare

    if (-not $fm.ContainsKey('probe_kind') -or -not $fm['probe_kind']) {
        $outcome = $(if ($schemaOk) { 'unverifiable' } else { 'failed' })
    }
    elseif ($probeOk -and $cleanDrift -and $cleanSpec -and $schemaOk) {
        $outcome = 'verified'
    }
    elseif ($specDrift -eq 'changed') {
        # Integrity violation outranks everything else in the verdict, because
        # a moved spec means the probe result cannot be trusted at all.
        $outcome = 'failed'
    }
    else { $outcome = 'failed' }

    $record = [pscustomobject]@{
        ts           = (Get-Date).ToString('o')
        path         = $rel
        outcome      = $outcome
        content_hash = $hash
        basis        = $fm['basis']
        verified     = $fm['verified']
        probe        = $fm['probe_kind']
        # --- the three axes, reported SEPARATELY ---
        # Collapsing them into one `failed` was the original design and it was
        # wrong: it conflates "the world contradicts the claim" with "the note
        # changed since the world was checked". Both consultations said keep
        # them apart, and both insisted fail-closed is preserved by the
        # CONJUNCTION, not by having fewer fields.
        #
        #   probe_ok       did the predicate hold?
        #   drift          unchanged | changed | unknown
        #   spec_drift     did the PROBE SPEC itself move? That is an integrity
        #                  violation, not staleness -- the spec is absent from
        #                  append's whitelist, so a differing hash means
        #                  something bypassed the write path.
        #
        # `outcome` stays a pure AND: verified only when probe_ok AND drift is
        # unchanged AND spec_drift is unchanged. Drift never promotes to
        # verified. What these fields buy is the DIAGNOSTIC -- why it failed --
        # instead of one bit that says only that it did.
        probe_ok       = $probeOk
        drift          = $driftState
        spec_drift     = $specDrift
        # The spec fields are logged so the NEXT verify can compare spec
        # against spec. Without them spec-drift could never be detected: the
        # note's current spec is all you have, and comparing it to itself
        # always matches.
        probe_kind      = $fm['probe_kind']
        probe_target    = $fm['probe_target']
        probe_pattern   = $fm['probe_pattern']
        probe_suite     = $fm['probe_suite']
        prior_hash      = $(if ($prev) { $prev.content_hash } else { $null })
        prior_probe_ok  = $(if ($prev) { $prev.probe_ok } else { $null })
        prior_drift     = $(if ($prev) { $prev.drift } else { $null })
        checks         = $checks.ToArray()
    }

    # Append to the evidence log. The write verbs cannot reach `.system/`, so
    # this is the one place a record about a note can live where the model that
    # wrote the note cannot quietly amend it.
    #
    # The directory is created if absent. Without this a vault whose .system/
    # was never populated (a scratch clone, a fresh machine) silently loses
    # every evidence record, and -- worse -- the DRIFT check below then finds no
    # prior record and reads a re-edited note as freshly verified. The log
    # failing is exactly the failure mode this verb exists to prevent, so it
    # must not be able to degrade quietly.
    try {
        $logDir = Split-Path -Parent $logFull
        if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $line = (ConvertTo-Json -InputObject $record -Depth 6 -Compress)
        [System.IO.File]::AppendAllText($logFull, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
    }
    catch {
        $record | Add-Member -NotePropertyName log_error -NotePropertyValue $_.Exception.Message -Force
    }

    return $record
}
