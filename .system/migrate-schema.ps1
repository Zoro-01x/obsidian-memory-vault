# migrate-schema.ps1 -- one-off: old schema (type/created/source/confidence)
#                          -> new schema (basis/scope/verified)
#
# Run once. Rewrites ONLY the frontmatter block; bodies are preserved verbatim.
# Safe to re-run: already-migrated notes are skipped.

. 'C:\Users\Home\Documents\ObsidianVault\.system\vault-lib.ps1'

$vault = 'C:\Users\Home\Documents\ObsidianVault'
$today = '2026-10-14'

# scope: which project/repo this applies to. Without it a convention learned
# in one repo leaks into another.
$scopes = @{
    'CORE.md'                          = 'vault'
    'Council memory substrate.md'      = 'council'
    'Council write protocol.md'        = 'council'
    'Council memory build state.md'    = 'council'
    'Obsidian CDP access.md'           = 'toolchain'
    'Intel UHD driver install.md'      = 'machine'
}

# verified: REQUIRED for code/environment-state notes. These describe a
# machine/software state that can silently change.
$verified = @{
    'Intel UHD driver install.md' = $today
    'Obsidian CDP access.md'      = $today
    'CORE.md'                     = $today
}

# confidence -> basis. `stated` meant "the user said it" -> user-stated.
$confidenceToBasis = @{
    'observed'  = 'observed'
    'inferred'  = 'inferred'
    'stated'    = 'user-stated'
}

$migrated = 0; $skipped = 0
Get-ChildItem $vault -Recurse -Filter '*.md' -File |
    Where-Object { $_.FullName -notmatch '\\\.obsidian\\|\\\.system\\' } |
    ForEach-Object {
        $file  = $_
        $fm    = Read-VaultFrontmatter -Path $file.FullName
        $body  = Get-VaultNoteBody   -Path $file.FullName

        if ($fm.ContainsKey('basis') -and $fm.ContainsKey('scope')) {
            "skip (already migrated): $($file.Name)"
            $script:skipped++
            return
        }

        # --- map old -> new ---
        $conf = $fm['confidence']
        $basis = if ($confidenceToBasis.ContainsKey([string]$conf)) { $confidenceToBasis[[string]$conf] } else { 'inferred' }

        # source field held a session tag; anything that came from a model
        # consult is external-model, not something we observed.
        $src = [string]$fm['source']
        if ($src -match '(?i)claude|gemini|external|model') { $basis = 'external-model' }

        $new = [ordered]@{
            name        = $fm['name']
            description = $fm['description']
            aliases     = if ($fm.ContainsKey('aliases')) { @($fm['aliases']) } else { @() }
            status      = if ($fm['status']) { $fm['status'] } else { 'active' }
            updated     = if ($fm['updated']) { $fm['updated'] } else { $today }
            basis       = $basis
            scope       = $scopes[$file.Name]
        }
        if ($fm.ContainsKey('superseded_by') -and $fm['superseded_by']) {
            $new['superseded_by'] = $fm['superseded_by']
        }
        if ($verified.ContainsKey($file.Name)) {
            $new['verified'] = $verified[$file.Name]
        }

        # required-field guard: refuse to write a note that would fail its own
        # validation. Presence is what matters for list fields -- `aliases: []`
        # is a valid, intentional empty list, not a missing field. Scalars must
        # be non-empty.
        $emptyIsMissing = @('name','description','basis','scope','status','updated')
        foreach ($req in $script:RequiredFields) {
            if (-not $new.Contains($req)) {
                throw "Migration refused for '$($file.Name)': required field '$req' absent. Fix the map."
            }
            if ($req -in $emptyIsMissing -and [string]::IsNullOrWhiteSpace([string]$new[$req])) {
                throw "Migration refused for '$($file.Name)': required field '$req' would be empty. Fix the map."
            }
        }

        $content = (ConvertTo-VaultFrontmatter -Data $new) + "`n" + $body.Trim() + "`n"
        Write-VaultFileAtomic -FullPath $file.FullName -Content $content
        "migrated: $($file.Name)  basis=$basis  scope=$($new['scope'])"
        $script:migrated++
    }

""
"migrated=$migrated  skipped=$skipped"
$r = Save-VaultCommit -Message 'migrate frontmatter to single-writer schema (basis/scope/verified; drop type/created/source/confidence)' -Author 'migrate'
"commit: $($r.sha)"
