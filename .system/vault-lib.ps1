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

# Never writable, regardless of anything an agent says.
$script:BlockedFolders = @('.obsidian', '.system', '.git', '.trash')

# Windows reserved device names -- writing these corrupts paths.
$script:ReservedNames = @(
    'CON','PRN','AUX','NUL',
    'COM1','COM2','COM3','COM4','COM5','COM6','COM7','COM8','COM9',
    'LPT1','LPT2','LPT3','LPT4','LPT5','LPT6','LPT7','LPT8','LPT9'
)

$script:ValidTypes      = @('entity','decision','lesson','fact','inbox')
$script:ValidStatus     = @('active','superseded','stale')
$script:ValidConfidence = @('stated','observed','inferred')

# The only frontmatter an agent may set. Resist adding more: agents fill
# extra fields inconsistently, and inconsistent frontmatter breaks retrieval.
$script:RequiredFields = @('name','type','description','aliases','status',
                           'created','updated','source','confidence')

function Get-VaultRoot { return $script:VaultRoot }

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
    $parts = $norm.Split('\') | Where-Object { $_ -ne '' -and $_ -ne '.' }

    if ($parts.Count -eq 0) { throw 'Path resolves to nothing.' }

    $top = $parts[0]
    foreach ($blocked in $script:BlockedFolders) {
        if ($top.Equals($blocked, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Folder '$blocked' is not writable by any verb."
        }
    }
    if ($top -notin $AllowedFolders) {
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
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Author = 'harness'
    )
    $git = Get-VaultGit
    if (-not $git) {
        Write-Warning "git not found -- write was NOT committed and has no undo. Install git or fix Get-VaultGit."
        return @{ committed = $false; reason = 'git not installed' }
    }

    $vault = $script:VaultRoot
    & $git -C $vault add -A 2>$null | Out-Null
    $pending = & $git -C $vault status --porcelain 2>$null
    if (-not $pending) { return @{ committed = $false; reason = 'nothing to commit' } }

    $msg = "[$Author] $Message"
    & $git -C $vault -c core.autocrlf=false commit -q -m $msg 2>$null | Out-Null
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

    if (Test-Path $rg) {
        # -m caps per-file matches so one big note can't dominate the budget.
        $raw = & $rg --files-with-matches -m 3 -i --no-heading -g '*.md' -g '!.obsidian/**' `
                    -e $Query $script:VaultRoot 2>$null
        foreach ($f in @($raw)) { if ($f) { $hits += [pscustomobject]@{ Path = $f; Score = 1 } } }
    }
    if ($hits.Count -eq 0) {
        Get-ChildItem -Path $script:VaultRoot -Filter '*.md' -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\\.obsidian\\|\\\.system\\|\\\.git\\' } |
            ForEach-Object {
                if ([System.IO.File]::ReadAllText($_.FullName) -match [regex]::Escape($Query)) {
                    $hits += [pscustomobject]@{ Path = $_.FullName; Score = 1 }
                }
            }
    }

    # Boost: a hit in name/description/aliases outranks a hit deep in prose.
    $scored = foreach ($h in $hits) {
        $fm = Read-VaultFrontmatter -Path $h.Path
        $score = 1.0
        if ($fm.name -and $fm.name -match [regex]::Escape($Query)) { $score += 6 }
        if ($fm.aliases -and (@($fm.aliases) -join ' ') -match [regex]::Escape($Query)) { $score += 4 }
        if ($fm.description -and $fm.description -match [regex]::Escape($Query)) { $score += 3 }
        if ($fm.type) { $score += 0.5 }
        [pscustomobject]@{
            Path        = $h.Path
            Name        = if ($fm.name) { $fm.name } else { [System.IO.Path]::GetFileNameWithoutExtension($h.Path) }
            Type        = $fm.type
            Description = $fm.description
            Status      = $fm.status
            Score       = $score
        }
    }
    return ($scored | Sort-Object Score -Descending | Select-Object -First $Limit)
}

function Get-VaultGraph {
    <#
      The wikilink graph. Primary source is Obsidian's own
      app.metadataCache via CDP (authoritative, cheap). Falls back to
      grepping for [[name]], which never breaks.
    #>
    [CmdletBinding()]
    param(
        [string]$NoteName,
        [switch]$ViaObsidian
    )
    if ($ViaObsidian) {
        try {
            . 'C:\Users\Home\Downloads\cdp-lib.ps1'
            $page = (Get-CdpTargets -Endpoint 'http://127.0.0.1:9223') |
                    Where-Object { $_.url -like '*index.html*' -and $_.webSocketDebuggerUrl } |
                    Select-Object -First 1
            if ($page) {
                $js = '(function(){try{var m=window.app.metadataCache;return JSON.stringify({resolved:m.resolvedLinks||{},unresolved:m.unresolvedLinks||{}});}catch(e){return null}})()'
                $raw = Invoke-CdpEval -Target $page -Expression $js
                if ($raw) {
                    $data = $raw | ConvertFrom-Json
                    if ($NoteName) {
                        $out = @()
                        foreach ($p in $data.resolved.PSObject.Properties) {
                            if ($p.Name -eq $NoteName) {
                                foreach ($t in $p.Value.PSObject.Properties) {
                                    $out += [pscustomobject]@{ Source = $p.Name; Target = $t.Name; Kind = 'outlink' }
                                }
                            }
                            elseif ($p.Value.PSObject.Properties[$NoteName]) {
                                $out += [pscustomobject]@{ Source = $p.Name; Target = $NoteName; Kind = 'backlink' }
                            }
                        }
                        return $out
                    }
                    return $data
                }
            }
        } catch { Write-Verbose "Obsidian CDP unavailable, falling back to grep: $($_.Exception.Message)" }
    }

    # Fallback: grep for [[target]]. No dependency, always works.
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
                # Normalise the extension so edges join: Obsidian's own
                # metadataCache returns targets WITHOUT the .md suffix.
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

function Test-VaultNote {
    <#
      True when the note passes every write-time rule. Used by the promotion
      pass to reject inbox items that are malformed before they go live.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $fm = Read-VaultFrontmatter -Path $Path
    $problems = @()
    foreach ($f in $script:RequiredFields) {
        if (-not $fm.ContainsKey($f)) { $problems += "missing field: $f" }
    }
    if ($fm.type -and $fm.type -notin $script:ValidTypes)     { $problems += "invalid type: '$($fm.type)'" }
    if ($fm.status -and $fm.status -notin $script:ValidStatus){ $problems += "invalid status: '$($fm.status)'" }
    if ($fm.confidence -and $fm.confidence -notin $script:ValidConfidence) { $problems += "invalid confidence: '$($fm.confidence)'" }
    if (-not $fm.description) { $problems += 'empty description (retrieval hook)' }

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
        [ValidateSet('entity','decision','lesson','fact','inbox')]
        [string]$Type = 'inbox',
        [string[]]$Aliases = @(),
        [ValidateSet('active','superseded','stale')]
        [string]$Status = 'active',
        [ValidateSet('stated','observed','inferred')]
        [string]$Confidence = 'inferred',
        [string]$Source = 'harness',
        [string]$SupersededBy = '',
        [string]$Author = 'harness'
    )

    $clean = Test-SafeNoteName -Name $Name
    $rel   = "$Folder\$clean.md"
    $full  = Resolve-VaultSafePath -RelativePath $rel

    if (Test-Path -LiteralPath $full) {
        $existing = Read-VaultFrontmatter -Path $full
        throw ("Note already exists: '$rel' (type=$($existing.type)). " +
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
        type         = $Type
        description  = $Description
        aliases      = @($Aliases)
        status       = $Status
        created      = $now
        updated      = $now
        source       = $Source
        confidence   = $Confidence
    }
    if ($SupersededBy) { $fm.superseded_by = $SupersededBy }

    $content = (ConvertTo-VaultFrontmatter -Data $fm) + "`n" + $Body.Trim() + "`n"
    Write-VaultFileAtomic -FullPath $full -Content $content

    $commit = Save-VaultCommit -Message "create $rel" -Author $Author
    return [pscustomobject]@{
        Path     = $rel
        FullPath = $full
        Created  = $true
        Commit   = $commit.sha
    }
}

function Add-VaultInboxItem {
    <#
      THE ANTI-DUMPING VALVE. Agents write here by default; nothing reaches
      entities/decisions until a consolidation pass promotes it.

      Two hard rules enforced here:
        1. No transcripts. A proposal must be a single durable claim.
        2. Data, not instructions. Anything that reads like a command to a
           future agent is refused -- notes get replayed into every session,
           so an injected line becomes persistent instruction.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Claim,
        [ValidateSet('entity','decision','lesson','fact','inbox')]
        [string]$Type = 'inbox',
        [string[]]$Aliases = @(),
        [string[]]$Links = @(),
        [ValidateSet('stated','observed','inferred')]
        [string]$Confidence = 'inferred',
        [string]$Source = 'harness',
        [string]$Author = 'harness'
    )

    # --- the two content guards ---
    # NOTE: patterns here are deliberately structural, not literal. The first
    # version of this guard used `ignore (all|any|previous) instructions`,
    # which silently missed "ignore ALL PREVIOUS instructions" because it
    # only allowed ONE adjective. Anything that matches a concept should match
    # any reasonable phrasing of it.
    $instructionPatterns = @(
        # "ignore/disregard/forget/suspend ... instructions/rules/prompt/guidelines"
        # with any number of words in between.
        '(?i)\b(?:ignore|disregard|forget|overrid|suspend|bypass|throw out|strip out)\b[\s\S]{0,40}?\b(?:instructions?|rules?|guidelines?|constraints?|prompts?|the above|the previous|prior)\b',
        # "you are now / act as if / pretend to be / your new role"
        '(?i)\b(?:you are now|act as if|pretend (?:to be|you are)|your new role|from now on you)\b',
        # "system prompt" / "developer message" in an imperative context
        '(?i)\b(?:reveal|print|repeat|output|expose|leak)\b[\s\S]{0,30}?\b(?:system prompt|hidden prompt|developer message|instructions)\b',
        # exfiltration: sending content off-machine
        '(?i)\bexfiltrat',
        '(?i)\b(?:send|post|upload|forward|email|upload)\b[\s\S]{0,30}?\b(?:this|it|the vault|the notes?|your output|everything)\b[\s\S]{0,30}?\b(?:to|into|at)\b[\s\S]{0,20}?\b(?:https?://|ftp://|discord|webhook|api endpoint)',
        # concealment -- but ONLY concealment of the agent's own actions.
        # The first version matched any "do not tell the user ..." sentence and
        # wrongly refused ordinary advice like "do not tell the user the install
        # worked until it is confirmed". The attack is specifically an agent
        # hiding that it wrote to memory, so require a reflexive object.
        '(?i)\b(?:do not|don''t|never)\b[\s\S]{0,25}?\b(?:tell|inform|mention|reveal)\b[\s\S]{0,20}?\b(?:the user|anyone|anyone else|the human)\b[\s\S]{0,20}?\b(?:that you|that this|about (?:this|your) (?:note|memory|write|save))\b',
        '(?i)\b(?:hide|conceal|keep (?:this|it) secret|cover up)\b[\s\S]{0,30}?\b(?:from the user|from anyone|the memory|this note|your writes)\b'
        # NOTE: a "credential harvesting" pattern was tried here and removed.
        # It was brittle (missed verb-before-secret phrasing) and low value:
        # notes are inert data, and an agent reading a sentence about an API
        # key will not act on it. The instruction-shape patterns above are the
        # ones that actually prevent an agent being manipulated. A guard that
        # needs constant patching is worse than no guard -- it breeds false
        # confidence and refuses legitimate memory.
    )
    foreach ($p in $instructionPatterns) {
        if ($Claim -match $p) {
            $shown = $Matches[0]
            throw "Refused: note body reads as an instruction to a future agent (matched: '$shown'). Notes are data, never commands."
        }
    }
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
    return New-VaultNote -Folder 'inbox' -Name "$Title ($stamp)" -Description $Claim.Trim().Substring(0, [Math]::Min(150, $Claim.Trim().Length)) `
                         -Body $body -Type $Type -Aliases $Aliases -Confidence $Confidence -Source $Source -Author $Author
}

function Update-VaultNote {
    <#
      Append-only by default. Full-body replacement requires -Replace and is
      deliberately awkward, because "agent rewrites a file from its memory of
      an earlier read" is how notes get clobbered.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [string]$AppendText = '',
        [string]$ReplaceBody = '',
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
    else { throw 'Specify -AppendText or -ReplaceBody.' }

    $fm.updated = (Get-Date).ToString('yyyy-MM-dd')
    $content = (ConvertTo-VaultFrontmatter -Data $fm) + "`n" + $body.Trim() + "`n"
    Write-VaultFileAtomic -FullPath $full -Content $content

    $commit = Save-VaultCommit -Message "$action $RelativePath" -Author $Author
    return [pscustomobject]@{ Path = $RelativePath; Action = $action; Commit = $commit.sha }
}

function Get-VaultStats {
    [CmdletBinding()]
    $files = Get-ChildItem -Path $script:VaultRoot -Filter '*.md' -Recurse -File -ErrorAction SilentlyContinue |
             Where-Object { $_.FullName -notmatch '\\\.obsidian\\|\\\.system\\|\\\.git\\' }
    $byFolder = $files | Group-Object { $_.DirectoryName.Replace("$script:VaultRoot\",'').Split('\')[0] }
    return [pscustomobject]@{
        Total   = $files.Count
        Words   = ($files | ForEach-Object { ([System.IO.File]::ReadAllText($_.FullName) -split '\s+').Count } |
                    Measure-Object -Sum).Sum
        Folders = ($byFolder | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join '  '
    }
}

# NOTE: this file is dot-sourced, not imported as a module, so there is no
# Export-ModuleMember. Dot-sourcing puts every function directly in scope.
