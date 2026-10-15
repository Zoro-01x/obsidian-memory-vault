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

$script:VaultRoot = 'C:\Users\Home\Documents\ObsidianVault'

# Write verbs may only create files inside these folders.
$script:WriteFolders = @('inbox', 'entities', 'decisions', 'lessons')

# Files at the vault ROOT that verbs may update. CORE.md must stay maintainable
# (edit is denied on it, so if no verb could reach it the index would freeze),
# but it must be an explicit allowlist -- "no folder" must never mean "any file".
$script:RootFiles = @('CORE.md')

# Never writable, regardless of anything an agent says.
$script:BlockedFolders = @('.obsidian', '.system', '.git', '.trash')

# Windows reserved device names -- writing these corrupts paths.
$script:ReservedNames = @(
    'CON','PRN','AUX','NUL',
    'COM1','COM2','COM3','COM4','COM5','COM6','COM7','COM8','COM9',
    'LPT1','LPT2','LPT3','LPT4','LPT5','LPT6','LPT7','LPT8','LPT9'
)

$script:ValidStatus = @('active','superseded','stale')

# `basis` replaces the old source + confidence pair. Provenance still matters
# with a single writer, because external-model claims are where hallucination
# enters: a note sourced from Gemini must not be treated like one you observed.
#   user-stated     -- the user said it
#   observed        -- you verified it yourself
#   external-model  -- Gemini/Claude/web said it, unverified
#   inferred        -- you concluded it
$script:ValidBasis = @('user-stated','observed','external-model','inferred')

# The only frontmatter the harness may set. Resist adding more: extra fields
# get filled inconsistently, and inconsistent frontmatter breaks retrieval.
#
# Dropped in the single-writer revision (was: type, created, source,
#   confidence):
#   type      -- redundant with the folder, which the path allowlist already
#                enforces. Two sources of truth for one fact can disagree.
#   created   -- git history has it, with an author and a diff.
#   source    -- merged into `basis`.
#   confidence-- merged into `basis`.
#
# Added:
#   scope     -- which project/repo this applies to. Without it, a convention
#                learned in one repo leaks into another.
#   verified  -- optional date; REQUIRED for notes about code or environment
#                state, because stale code facts are the dominant failure mode.
$script:RequiredFields = @('name','description','aliases','status',
                           'updated','basis','scope')

$script:OptionalFields = @('superseded_by','verified')

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
        return @{ committed = $false; reason = 'git not installed' }
    }

    $vault = $script:VaultRoot
    if ($Path) {
        $target = $Path -replace '\\', '/'
        & $git -C $vault add -- $target 2>$null | Out-Null
    }
    else {
        & $git -C $vault add -A 2>$null | Out-Null
    }
    $pending = & $git -C $vault status --porcelain 2>$null
    if (-not $pending) { return @{ committed = $false; reason = 'nothing to commit' } }

    $msg = "[$Author] $Message"
    # Set the real commit author, not just the message prefix. Previously the
    # repo identity (Council) was recorded and the agent name existed only as
    # message text -- reviewable by reading %s, but `git log --author=harness`
    # could not answer "which agent touched this?", which is the whole point
    # of attributing commits to a writer.
    $who   = if ($Author) { $Author } else { 'harness' }
    $email = (($who -replace '[^A-Za-z0-9._-]', '.') + '@vault.local')
    & $git -C $vault -c core.autocrlf=false -c user.name=$who -c user.email=$email commit -q -m $msg 2>$null | Out-Null
    $sha = (& $git -C $vault rev-parse --short HEAD 2>$null)
    return @{ committed = $true; sha = $sha; message = $msg }
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
        $raw = & $rg @rgArgs 2>$null
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
        [ValidateSet('active','superseded','stale')]
        [string]$Status = 'active',
        [ValidateSet('user-stated','observed','external-model','inferred')]
        [string]$Basis = 'inferred',
        [Parameter(Mandatory)][string]$Scope,          # which project/repo this applies to
        [string]$Verified = '',                        # required for code/env-state notes
        [string]$SupersededBy = '',
        [string]$Author = 'harness'                    # git author only; NOT written to frontmatter
    )

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
    return [pscustomobject]@{
        Path     = $rel
        FullPath = $full
        Created  = $true
        Commit   = $commit.sha
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
        [ValidateSet('user-stated','observed','external-model','inferred')]
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
    $mutable  = @('description', 'aliases', 'status', 'basis', 'scope', 'verified', 'superseded_by')
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
    return [pscustomobject]@{ Path = $RelativePath; Action = $action; Commit = $commit.sha; Set = $changed }
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
