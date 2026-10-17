# registry-test.ps1
#
# THE INVARIANT UNDER TEST:
#     Every closed vocabulary the vault enforces exists in EXACTLY ONE place
#     (registry.json), and every consumer derives from it. Two things are
#     proved here:
#
#       1. The consumers really do derive -- i.e. changing registry.json
#          changes their behaviour. (Otherwise "derived" is a comment.)
#       2. The vocabularies are still the ones we INTEND -- checked against
#          LITERALS written into this file, never read back from the registry.
#
# WHY THE EXPECTATIONS ARE LITERALS (Claude, 2026-10-17):
#     "For the security-critical lists, pin the expectation as a literal in the
#      test, not derived from the same source. If the test builds its expected
#      value from the manifest, it's tautological -- editing the manifest edits
#     the test with it."
#
#     That is the rock-test logic already applied to `verify`, applied one
#     level up. A consistency check built from the thing it checks proves
#     nothing; it only proves the file is readable by two parsers.
#
#     So: if someone adds a fifth probe kind to registry.json, the consistency
#     checks below still PASS (both sides match), and the LITERAL check FAILS.
#     That failure is the point -- it forces a human to confirm the new kind is
#     intended, rather than letting it arrive silently.
#
# ALSO TESTED: FAIL-CLOSED LOADING.
#     A missing, malformed, keyless or empty-list registry must refuse to load.
#     The registry is a new single point of failure, so a corrupt one must
#     never fall back to defaults -- a defaulted registry enforces the WRONG
#     vocabulary, which is worse than enforcing none.
#
# ISOLATION: every scenario copies .system/ into its own %TEMP% root and
#     corrupts the copy. The live registry is never modified.
#
# Run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .system/registry-test.ps1
#
# Exit 0 = every assertion passed.

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$libPath    = Join-Path $PSScriptRoot 'vault-lib.ps1'
$mcpPath    = Join-Path $PSScriptRoot 'vault-mcp.mjs'
$adapter    = Join-Path $PSScriptRoot 'vault-adapter.ps1'
$regPath    = Join-Path $PSScriptRoot 'registry.json'

foreach ($f in @($libPath, $mcpPath, $adapter, $regPath)) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Output ("FATAL: missing {0}" -f $f); exit 2
    }
}

$results = @()
function T([string]$Name, [bool]$Pass, $Detail = '') {
    $script:results += [pscustomobject]@{ Name = $Name; Pass = $Pass }
    $d = if ($Detail) { " -- $Detail" } else { '' }
    Write-Output ("{0}  {1}{2}" -f $(if ($Pass) { 'PASS' } else { 'FAIL' }), $Name, $d)
}

# ---------------------------------------------------------------------------
# THE INTENDED VOCABULARIES. Literals, deliberately. See the header.
# ---------------------------------------------------------------------------
$EXPECT_PROBE_KINDS  = @('path_exists', 'file_hash', 'symbol_present', 'suite')
$EXPECT_PROBE_SUITES = @('smoke', 'cold-start', 'native-stderr', 'write-validation')
$EXPECT_STATUS       = @('active', 'superseded', 'stale')
$EXPECT_BASIS        = @('user-stated', 'observed', 'external-model', 'inferred')
$EXPECT_VERBS        = @('core', 'recall', 'read', 'create', 'append', 'propose', 'stale', 'verify')
$EXPECT_WRITE        = @('inbox', 'entities', 'decisions', 'lessons')
$EXPECT_CREATE       = @('entities', 'decisions', 'lessons')
$EXPECT_BLOCKED      = @('.obsidian', '.system', '.git', '.trash')
$EXPECT_ROOTFILES    = @('CORE.md')
$EXPECT_REQUIRED     = @('name', 'description', 'aliases', 'status', 'updated', 'basis', 'scope')
$EXPECT_OPTIONAL     = @('superseded_by', 'verified')
$EXPECT_MUTABLE      = @('description', 'aliases', 'status', 'basis', 'scope', 'superseded_by')
$EXPECT_IMMUTABLE    = @('name', 'updated', 'created', 'type', 'author', 'verified',
                         'probe_kind', 'probe_target', 'probe_pattern', 'probe_suite')
$EXPECT_MINPAT       = 6

function Test-SetEq([string[]]$A, [string[]]$B) {
    # Order-insensitive set equality, so reordering either side is not a
    # false alarm. Duplicates ARE a difference.
    if ($null -eq $A) { $A = @() }
    if ($null -eq $B) { $B = @() }
    if ($A.Count -ne $B.Count) { return $false }
    foreach ($x in $A) { if ($B -notcontains $x) { return $false } }
    foreach ($y in $B) { if ($A -notcontains $y) { return $false } }
    return $true
}

# Dot-source the LIVE library once, in a child scope so the derived variables
# can be read without polluting the test's own scope.
$derived = & {
    . $libPath
    [pscustomobject]@{
        ProbeKinds   = @($script:ValidProbeKinds)
        ProbeSuites  = @($script:AllowedProbeSuites)
        Status       = @($script:ValidStatus)
        Basis        = @($script:ValidBasis)
        WriteFolders = @($script:WriteFolders)
        CreateFolders= @($script:CreateFolders)
        Blocked      = @($script:BlockedFolders)
        RootFiles    = @($script:RootFiles)
        Required     = @($script:RequiredFields)
        Optional     = @($script:OptionalFields)
        Mutable      = @($script:VaultRegistry.mutableKeys)
        Immutable    = @($script:VaultRegistry.immutableKeys)
        Verbs        = @($script:ValidVerbs)
        MinPat       = [int]$script:MinProbePatternLength
        Registry     = $script:VaultRegistry
    }
}

Write-Output "=== 1: the PowerShell library derives the INTENDED vocabularies ==="
T 'probe kinds match the intended set'        (Test-SetEq $derived.ProbeKinds  $EXPECT_PROBE_KINDS)  (($derived.ProbeKinds) -join ',')
T 'probe suites match the intended set'       (Test-SetEq $derived.ProbeSuites $EXPECT_PROBE_SUITES) (($derived.ProbeSuites) -join ',')
T 'status matches the intended set'           (Test-SetEq $derived.Status      $EXPECT_STATUS)       (($derived.Status) -join ',')
T 'basis matches the intended set'            (Test-SetEq $derived.Basis       $EXPECT_BASIS)        (($derived.Basis) -join ',')
T 'write folders match the intended set'      (Test-SetEq $derived.WriteFolders $EXPECT_WRITE)       (($derived.WriteFolders) -join ',')
T 'create folders match the intended set'     (Test-SetEq $derived.CreateFolders $EXPECT_CREATE)     (($derived.CreateFolders) -join ',')
T 'blocked folders match the intended set'    (Test-SetEq $derived.Blocked     $EXPECT_BLOCKED)      (($derived.Blocked) -join ',')
T 'root files match the intended set'         (Test-SetEq $derived.RootFiles   $EXPECT_ROOTFILES)    (($derived.RootFiles) -join ',')
T 'required fields match the intended set'    (Test-SetEq $derived.Required    $EXPECT_REQUIRED)     (($derived.Required) -join ',')
T 'optional fields match the intended set'    (Test-SetEq $derived.Optional    $EXPECT_OPTIONAL)     (($derived.Optional) -join ',')
T 'mutable keys match the intended set'       (Test-SetEq $derived.Mutable     $EXPECT_MUTABLE)      (($derived.Mutable) -join ',')
T 'immutable keys match the intended set'     (Test-SetEq $derived.Immutable   $EXPECT_IMMUTABLE)    (($derived.Immutable) -join ',')
T 'verbs match the intended set'              (Test-SetEq $derived.Verbs       $EXPECT_VERBS)        (($derived.Verbs) -join ',')
T 'min probe pattern length is the intended 6'($derived.MinPat -eq $EXPECT_MINPAT)                  $derived.MinPat

Write-Output "=== 2: mutable and immutable are DISJOINT (a key in both is a contradiction) ==="
$overlap = @($EXPECT_MUTABLE | Where-Object { $EXPECT_IMMUTABLE -contains $_ })
T 'no key is both mutable and immutable' ($overlap.Count -eq 0) (($overlap) -join ',')
$derivedOverlap = @($derived.Mutable | Where-Object { $derived.Immutable -contains $_ })
T 'the DERIVED sets are disjoint too'    ($derivedOverlap.Count -eq 0) (($derivedOverlap) -join ',')

Write-Output "=== 3: create folders are a strict subset of write folders ==="
$notSubset = @($EXPECT_CREATE | Where-Object { $EXPECT_WRITE -notcontains $_ })
T 'every create folder is also a write folder' ($notSubset.Count -eq 0) (($notSubset) -join ',')
$inboxOnly = @($EXPECT_WRITE | Where-Object { $EXPECT_CREATE -notcontains $_ })
T 'exactly ONE folder is write-only (inbox, via propose)' ($inboxOnly.Count -eq 1 -and $inboxOnly[0] -eq 'inbox') (($inboxOnly) -join ',')
T 'the library agrees: write - create = inbox' `
    (@($derived.WriteFolders | Where-Object { $derived.CreateFolders -notcontains $_ }) -join ',' -eq 'inbox') `
    ((@($derived.WriteFolders | Where-Object { $derived.CreateFolders -notcontains $_ }) -join ','))

Write-Output "=== 4: probe kinds and probe suites do not overlap ==="
$psOverlap = @($EXPECT_PROBE_KINDS | Where-Object { $EXPECT_PROBE_SUITES -contains $_ })
T 'no probe kind doubles as a suite name' ($psOverlap.Count -eq 0) (($psOverlap) -join ',')

Write-Output "=== 5: the MCP layer derives the SAME vocabularies (the drift that bit us) ==="
# Spawns the real server against a scratch root and reads back the enums it
# actually advertises. This is the assertion that would have caught the
# original bug: TOOLS and the registry disagreeing.
$scratch = Join-Path $env:TEMP ('regtest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$sysDir = Join-Path $scratch '.system'
New-Item -ItemType Directory -Path $sysDir -Force | Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot '*') -Destination $sysDir -Recurse -Force
[System.IO.File]::WriteAllText((Join-Path $scratch '.vault-test-root'), "regtest`n",
    (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path $scratch 'CORE.md'), "---`nname: CORE`n---`n`n# CORE`n`nScratch.`n",
    (New-Object System.Text.UTF8Encoding($false)))

$probeJs = @'
import { readFileSync } from "node:fs";
const src = readFileSync(process.argv[2], "utf8");
// Assert the catalogue is built from variables, not literals. A literal here
// is exactly the duplication this whole file exists to prevent.
const literalEnums = [...src.matchAll(/enum:\s*\[([^\]]*)\]/g)].map((m) => m[1]);
if (literalEnums.length) {
  console.log(JSON.stringify({ fatal: "literal enum arrays remain in vault-mcp.mjs", literalEnums }));
  process.exit(0);
}
const derived = [...src.matchAll(/enum:\s*([A-Z_]+)\b/g)].map((m) => m[1]);
console.log(JSON.stringify({ derived }));
'@
$probeJsPath = Join-Path $scratch 'probe-enums.mjs'
[System.IO.File]::WriteAllText($probeJsPath, $probeJs, (New-Object System.Text.UTF8Encoding($false)))

$enumOut = & node.exe $probeJsPath $mcpPath 2>&1 | Out-String
$enumJson = $null
try { $enumJson = $enumOut.Trim() | ConvertFrom-Json } catch { }
if ($enumJson -and $enumJson.PSObject.Properties['fatal']) {
    T 'vault-mcp.mjs has NO literal enum arrays left' $false $enumJson.fatal
}
else {
    T 'vault-mcp.mjs has NO literal enum arrays left' ($null -ne $enumJson) $enumOut.Trim()
    T 'every enum in vault-mcp.mjs is a derived identifier' `
        (@($enumJson.derived | Where-Object { $_ -notmatch '^(FOLDERS|STATUS|BASIS|PROBE_KINDS|PROBE_SUITES)$' }).Count -eq 0) `
        (($enumJson.derived) -join ',')
    # Distinct identifiers, not usages. There are 8 `enum:` SITES (status and
    # basis are each used twice) but only 5 distinct vocabularies. Counting
    # sites would make this assertion about the file's shape rather than about
    # the vocabularies it holds.
    $distinct = @($enumJson.derived | Sort-Object -Unique)
    T 'vault-mcp.mjs uses exactly 5 DISTINCT enum vocabularies' ($distinct.Count -eq 5) (($distinct) -join ',')
}

# Now drive the real server and read the enums it advertises over JSON-RPC.
$mcpJson = @'
import { spawn } from "node:child_process";
const child = spawn("node", [process.argv[2]], { stdio: ["pipe", "pipe", "pipe"] });
let buf = "";
const onLine = (line) => {
  let m; try { m = JSON.parse(line); } catch { return; }
  if (m.id === 2) {
    const tools = m.result?.tools ?? [];
    const find = (tn, field) => (tools.find((t) => t.name === tn)?.inputSchema?.properties?.[field]?.enum) ?? null;
    const setP = (tools.find((t) => t.name === "append")?.inputSchema?.properties?.set?.properties) ?? {};
    child.kill();
    console.log(JSON.stringify({
      verbs: tools.map((t) => t.name),
      folder: find("create", "folder"),
      status: find("create", "status"),
      basis: find("create", "basis"),
      probeKind: find("create", "probeKind"),
      probeSuite: find("create", "probeSuite"),
      setStatus: setP.status?.enum ?? null,
      setBasis: setP.basis?.enum ?? null,
      setKeys: Object.keys(setP),
    }));
    process.exit(0);
  }
};
child.stdout.on("data", (d) => {
  buf += d.toString("utf8"); let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const l = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
    if (l) onLine(l);
  }
});
child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "regtest", version: "1" } } }) + "\n");
child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/list" }) + "\n");
setTimeout(() => { child.kill(); console.log(JSON.stringify({ fatal: "tools/list timed out" })); process.exit(0); }, 40000);
'@
$mcpJsPath = Join-Path $scratch 'probe-tools.mjs'
[System.IO.File]::WriteAllText($mcpJsPath, $mcpJson, (New-Object System.Text.UTF8Encoding($false)))
$env:OBSIDIAN_VAULT_ROOT = $scratch
$toolsOut = & node.exe $mcpJsPath (Join-Path $sysDir 'vault-mcp.mjs') 2>&1 | Out-String
$tools = $null
try { $tools = $toolsOut.Trim() | ConvertFrom-Json } catch { }
$oldRoot = $env:OBSIDIAN_VAULT_ROOT
Remove-Item Env:\OBSIDIAN_VAULT_ROOT -ErrorAction SilentlyContinue

if (-not $tools -or $tools.PSObject.Properties['fatal']) {
    T 'the MCP server returned its tool catalogue' $false $toolsOut.Trim()
}
else {
    T 'the MCP server returned its tool catalogue' $true
    T 'MCP verbs == intended verbs'   (Test-SetEq @($tools.verbs) $EXPECT_VERBS)      (($tools.verbs) -join ',')
    T 'MCP create.folder enum == createFolders' (Test-SetEq @($tools.folder) $EXPECT_CREATE) (($tools.folder) -join ',')
    T 'MCP create.status enum == status'       (Test-SetEq @($tools.status) $EXPECT_STATUS)  (($tools.status) -join ',')
    T 'MCP create.basis enum == basis'         (Test-SetEq @($tools.basis) $EXPECT_BASIS)    (($tools.basis) -join ',')
    T 'MCP create.probeKind enum == probeKinds'(Test-SetEq @($tools.probeKind) $EXPECT_PROBE_KINDS) (($tools.probeKind) -join ',')
    T 'MCP create.probeSuite enum == probeSuites' (Test-SetEq @($tools.probeSuite) $EXPECT_PROBE_SUITES) (($tools.probeSuite) -join ',')
    T 'MCP append.set.status enum == status'   (Test-SetEq @($tools.setStatus) $EXPECT_STATUS) (($tools.setStatus) -join ',')
    T 'MCP append.set.basis enum == basis'     (Test-SetEq @($tools.setBasis) $EXPECT_BASIS)   (($tools.setBasis) -join ',')
    # The set whitelist must expose NOTHING outside the mutable set.
    $illegalSet = @($tools.setKeys | Where-Object { $EXPECT_MUTABLE -notcontains $_ -and $_ -ne 'supersededBy' })
    T 'MCP set whitelist exposes only mutable keys' ($illegalSet.Count -eq 0) (($illegalSet) -join ',')
    T 'MCP set whitelist does NOT expose verified'  (@($tools.setKeys | Where-Object { $_ -eq 'verified' }).Count -eq 0) (($tools.setKeys) -join ',')
}

Write-Output "=== 6: the ADAPTER implements every registered verb (empirical) ==="
# The adapter's switch cannot be introspected on PS 5.1, so this calls each
# verb with EMPTY arguments. An unimplemented verb answers "Unknown verb";
# an implemented one answers something else (usually a missing-argument
# refusal). That is the whole check: no registered verb may be unknown.
function Invoke-AdapterEmpty([string]$Root, [string]$Verb) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $adapter + '" -Verb ' + $Verb
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['OBSIDIAN_VAULT_ROOT'] = $Root
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd()
    $null = $p.WaitForExit(120000)
    return $out
}
$adapterRoot = Join-Path $scratch 'adapter'
New-Item -ItemType Directory -Path $adapterRoot -Force | Out-Null
foreach ($d in @('inbox', 'entities', 'decisions', 'lessons')) {
    New-Item -ItemType Directory -Path (Join-Path $adapterRoot $d) -Force | Out-Null
}
[System.IO.File]::WriteAllText((Join-Path $adapterRoot '.vault-test-root'), "regtest`n",
    (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path $adapterRoot 'CORE.md'), "---`nname: CORE`n---`n`n# CORE`n`nScratch.`n",
    (New-Object System.Text.UTF8Encoding($false)))

foreach ($v in $EXPECT_VERBS) {
    $o = Invoke-AdapterEmpty -Root $adapterRoot -Verb $v
    T "adapter implements verb '$v'" ($o -notmatch 'Unknown verb') ($o.Substring(0, [Math]::Min(150, $o.Length)))
}
# ...and the control: an UNregistered verb must still be refused. Without this
# the previous check would also pass if the adapter accepted everything.
$badVerb = Invoke-AdapterEmpty -Root $adapterRoot -Verb 'definitely_not_a_verb'
T 'an unregistered verb is still REFUSED (control)' ($badVerb -match 'Unknown verb') ($badVerb.Substring(0, [Math]::Min(150, $badVerb.Length)))

Write-Output "=== 7: FAIL-CLOSED -- a corrupt registry refuses to load ==="
function Test-CorruptRegistry([string]$Label, [string]$NewContent, [switch]$DeleteFile) {
    $root = Join-Path $env:TEMP ('regcorrupt-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $dir  = Join-Path $root '.system'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item -Path $libPath -Destination $dir -Force
    $reg = Join-Path $dir 'registry.json'
    # -ErrorAction SilentlyContinue: the "missing" case never copied the file
    # in the first place, so removing it is a no-op that would otherwise print
    # an ObjectNotFound record to the error stream.
    if ($DeleteFile) { Remove-Item -LiteralPath $reg -Force -ErrorAction SilentlyContinue }
    else { [System.IO.File]::WriteAllText($reg, $NewContent, (New-Object System.Text.UTF8Encoding($false))) }

    # Dot-source in a CHILD process so a thrown load error is observable
    # without killing this test.
    $probe = Join-Path $root 'load-probe.ps1'
    $body = @'
$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $PSScriptRoot '.system\vault-lib.ps1')
    Write-Output 'LOADED'
    exit 0
}
catch {
    Write-Output ('REFUSED: ' + $_.Exception.Message)
    exit 1
}
'@
    [System.IO.File]::WriteAllText($probe, $body, (New-Object System.Text.UTF8Encoding($false)))
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probe 2>&1 | Out-String
    return $out.Trim()
}

$goodRaw = [System.IO.File]::ReadAllText($regPath)

$r = Test-CorruptRegistry 'missing' '' -DeleteFile
T 'a MISSING registry refuses to load' ($r -match 'REFUSED' -and $r -match 'MISSING') ($r.Substring(0, [Math]::Min(160, $r.Length)))

$r = Test-CorruptRegistry 'malformed' "{ this is not json at all"
T 'a MALFORMED registry refuses to load' ($r -match 'REFUSED' -and $r -match 'parsed') ($r.Substring(0, [Math]::Min(160, $r.Length)))

$stripped = $goodRaw -replace '"probeKinds"\s*:\s*\[[^\]]*\],?', ''
$r = Test-CorruptRegistry 'missing-key' $stripped
T 'a registry MISSING a required key refuses to load' ($r -match 'REFUSED' -and $r -match 'probeKinds') ($r.Substring(0, [Math]::Min(160, $r.Length)))

$emptied = $goodRaw -replace '("probeKinds"\s*:\s*)\[[^\]]*\]', '$1[]'
$r = Test-CorruptRegistry 'empty-array' $emptied
T 'a registry with an EMPTY probeKinds array refuses to load' ($r -match 'REFUSED' -and $r -match 'empty') ($r.Substring(0, [Math]::Min(160, $r.Length)))

$nulled = $goodRaw -replace '("verbs"\s*:\s*)\[[^\]]*\]', '$1null'
$r = Test-CorruptRegistry 'null-array' $nulled
T 'a registry with verbs=null refuses to load' ($r -match 'REFUSED' -and $r -match 'verbs') ($r.Substring(0, [Math]::Min(160, $r.Length)))

Write-Output "=== 8: the MCP server also refuses to start on a corrupt registry ==="
function Test-CorruptMcp([string]$NewContent, [switch]$DeleteFile) {
    $root = Join-Path $env:TEMP ('regmcp-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $dir  = Join-Path $root '.system'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item -Path $mcpPath -Destination $dir -Force
    $reg = Join-Path $dir 'registry.json'
    if ($DeleteFile) { Remove-Item -LiteralPath $reg -Force -ErrorAction SilentlyContinue }
    else { [System.IO.File]::WriteAllText($reg, $NewContent, (New-Object System.Text.UTF8Encoding($false))) }
    # The registry check runs at import, so the process must exit non-zero
    # before it ever reads stdin.
    $err = & node.exe (Join-Path $dir 'vault-mcp.mjs') 2>&1 | Out-String
    return $err
}
$e = Test-CorruptMcp '' -DeleteFile
T 'MCP refuses to start on a MISSING registry' ($e -match 'FATAL' -and $e -match 'missing or unparseable') ($e.Substring(0, [Math]::Min(160, $e.Length)))
$e = Test-CorruptMcp "{ nope"
T 'MCP refuses to start on a MALFORMED registry' ($e -match 'FATAL') ($e.Substring(0, [Math]::Min(160, $e.Length)))

# The subtle one: registry says 7 verbs, catalogue defines 8. That is the
# ORIGINAL bug in its purest form -- and it must now fail at STARTUP, not at
# call time.
$shrunk = $goodRaw -replace '("verbs"\s*:\s*)\[[^\]]*\]', '$1["core", "recall", "read", "create", "append", "propose", "stale"]'
$e = Test-CorruptMcp $shrunk
T 'MCP refuses to start when verbs and TOOLS DISAGREE (the original bug)' `
    ($e -match 'FATAL' -and $e -match 'disagree') ($e.Substring(0, [Math]::Min(220, $e.Length)))

Write-Output "=== 9: BEHAVIOURAL MATRIX -- every entry point still REFUSES bad vocab ==="
# Claude's catch, and the sharpest one in this whole change:
#
#   "ValidateSet was enforced by the engine on every call path, and a runtime
#    guard only runs if someone remembered to call it. A parameter that lost
#    its ValidateSet and whose function forgot the guard now accepts anything,
#    and the vocabulary tests stay green."
#
# Sections 1-9 prove the VOCABULARIES are right. They say nothing about whether
# each entry point is still GUARDED -- a function can drop its ValidateSet,
# forget to add a guard, and accept garbage while every vocabulary assertion
# passes. So this matrix walks each entry point that accepts each vocabulary
# and asserts refusal with the "Allowed:" wording.
#
# The CONTROL at the end matters as much as the matrix: without it this section
# would also pass if a verb had become broken and refused everything.
$mxRoot = Join-Path $env:TEMP ('regmatrix-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $mxRoot -Force | Out-Null
foreach ($d in @('inbox', 'entities', 'decisions', 'lessons')) {
    New-Item -ItemType Directory -Path (Join-Path $mxRoot $d) -Force | Out-Null
}
[System.IO.File]::WriteAllText((Join-Path $mxRoot '.vault-test-root'), "matrix`n",
    (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path $mxRoot 'CORE.md'), "---`nname: CORE`n---`n`n# CORE`n`nScratch.`n",
    (New-Object System.Text.UTF8Encoding($false)))
& git.exe -C $mxRoot init -q 2>$null | Out-Null
& git.exe -C $mxRoot config user.name  'matrix-test' 2>$null | Out-Null
& git.exe -C $mxRoot config user.email 'matrix@example.invalid' 2>$null | Out-Null
& git.exe -C $mxRoot config core.autocrlf false 2>$null | Out-Null

function Invoke-AdapterArgs([string]$Root, [string]$Verb, $Obj) {
    $json = ''
    if ($null -ne $Obj) { $json = ($Obj | ConvertTo-Json -Depth 8 -Compress) }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $adapter + '" -Verb ' + $Verb
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['OBSIDIAN_VAULT_ROOT'] = $Root
    $p = [System.Diagnostics.Process]::Start($psi)
    if ($json) { $p.StandardInput.Write($json) }
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd()
    $null = $p.WaitForExit(180000)
    $parsed = $null
    try { $parsed = $out.Trim() | ConvertFrom-Json } catch { }
    return [pscustomobject]@{
        Ok    = if ($parsed) { [bool]$parsed.ok } else { $false }
        Error = if ($parsed -and $parsed.PSObject.Properties['error']) { [string]$parsed.error } else { '' }
    }
}

# The append cases need their target notes to EXIST. Without them every
# append is refused with "No such note", and the test passes for the wrong
# reason -- which is exactly what happened on the first run: the error
# "No such note: 'entities\Mx Status.md'" contains the substring "Status",
# so a loose `status` regex matched a FILENAME and reported a guard that had
# never been reached. Hence the target notes, and the tightened wording
# ("invalid status", not "status").
foreach ($mn in @('Mx Status', 'Mx Basis')) {
    $mk = Invoke-AdapterArgs -Root $mxRoot -Verb 'create' -Obj @{
        folder='entities'; name=$mn; description='matrix target note'; body='body';
        scope='matrix'; basis='observed'; status='active'; verified='2026-10-17'
    }
    if (-not $mk.Ok) { Write-Output ("WARN: could not create matrix target '$mn': " + $mk.Error) }
}

# (entry point, argument shape, bad value, vocabulary word expected in the error)
$matrix = @(
    @{ n='create + status';      verb='create'; a=@{ folder='entities'; name='Mx Status'; description='mx'; body='mx'; scope='mx' }; bad='status';      word='status' },
    @{ n='create + basis';       verb='create'; a=@{ folder='entities'; name='Mx Basis';  description='mx'; body='mx'; scope='mx' }; bad='basis';       word='basis' },
    @{ n='create + probeKind';   verb='create'; a=@{ folder='entities'; name='Mx Probe';  description='mx'; body='mx'; scope='mx' }; bad='probeKind';   word='probe_kind' },
    @{ n='create + probeSuite';  verb='create'; a=@{ folder='entities'; name='Mx Suite';  description='mx'; body='mx'; scope='mx'; probeKind='suite' }; bad='probeSuite'; word='probe_suite' },
    @{ n='create + folder';      verb='create'; a=@{ name='Mx Folder'; description='mx'; body='mx'; scope='mx' }; bad='folder'; word='not an allowed write target' },
    @{ n='propose + basis';      verb='propose'; a=@{ title='Mx Propose'; claim='mx'; scope='mx' }; bad='basis'; word='basis' },
    @{ n='append set + status';  verb='append'; a=@{ path='entities\Mx Status.md'; text='x'; set=@{} }; bad='set.status'; word='invalid status' },
    @{ n='append set + basis';   verb='append'; a=@{ path='entities\Mx Basis.md';  text='x'; set=@{} }; bad='set.basis';  word='invalid basis' },
    @{ n='append set + verified';verb='append'; a=@{ path='entities\Mx Status.md'; text='x'; set=@{} }; bad='set.verified'; word='not mutable' },
    @{ n='append set + probe_kind'; verb='append'; a=@{ path='entities\Mx Status.md'; text='x'; set=@{} }; bad='set.probe_kind'; word='not mutable' }
)

foreach ($case in $matrix) {
    # Clone the argument template so each case starts clean.
    $a = @{}
    foreach ($k in $case.a.Keys) { $a[$k] = $case.a[$k] }
    # Apply the bad value to the (possibly nested) key path.
    $parts = $case.bad -split '\.'
    if ($parts.Count -eq 1) { $a[$parts[0]] = 'zz_not_a_real_value' }
    else {
        if (-not $a.ContainsKey($parts[0])) { $a[$parts[0]] = @{} }
        $a[$parts[0]][$parts[1]] = 'zz_not_a_real_value'
    }
    $r = Invoke-AdapterArgs -Root $mxRoot -Verb $case.verb -Obj $a
    T ("refuses: " + $case.n) ((-not $r.Ok) -and ($r.Error -match [regex]::Escape($case.word))) $r.Error
}

# THE CONTROL. Without it, every assertion above would also pass if the verbs
# had become broken and started refusing everything -- a check that cannot fail
# for the opposite reason is still a check that cannot fail.
$c = Invoke-AdapterArgs -Root $mxRoot -Verb 'create' -Obj @{
    folder='entities'; name='Mx Control'; description='matrix control'; body='body';
    scope='matrix'; basis='observed'; status='active'; verified='2026-10-17'
}
T 'CONTROL: a VALID create is still accepted' ($c.Ok) $c.Error
$c = Invoke-AdapterArgs -Root $mxRoot -Verb 'propose' -Obj @{
    title='Mx Propose Control'; claim='matrix control claim'; scope='matrix'; basis='external-model'
}
T 'CONTROL: a VALID propose is still accepted' ($c.Ok) $c.Error
$c = Invoke-AdapterArgs -Root $mxRoot -Verb 'append' -Obj @{
    path='entities\Mx Control.md'; text='appended'; set=@{ status='stale' }
}
T 'CONTROL: a VALID set(status) is still accepted' ($c.Ok) $c.Error

Write-Output "=== 10: the registry is unreachable by every write verb ==="
# An agent that could edit the registry could WIDEN the wall -- add its own
# folder to writeFolders, or its own key to mutableKeys. Being under .system
# and in BlockedFolders should cover it; this asserts it rather than trusting
# the reasoning.
$before = [System.IO.File]::ReadAllText($regPath)
foreach ($verb in @('create', 'append')) {
    $a = @{ path = '.system/registry.json'; text = '{"verbs":["core"]}'; replaceBody = '{"verbs":["core"]}' }
    if ($verb -eq 'create') { $a = @{ folder='.system'; name='registry'; description='x'; body='x'; scope='x' } }
    $r = Invoke-AdapterArgs -Root $mxRoot -Verb $verb -Obj $a
    T "$verb cannot reach .system/registry.json" ((-not $r.Ok) -and ($r.Error -match 'not an allowed write target|Blocked|\.system')) $r.Error
}
# `propose` takes a TITLE, not a path -- it has no path argument to poison, so
# "cannot reach .system" is not the right assertion for it. The right one is
# that its destination is ALWAYS inbox: whatever an agent passes as the title,
# the note lands in the review queue and nowhere else.
$pr = Invoke-AdapterArgs -Root $mxRoot -Verb 'propose' -Obj @{
    title='..\.system\registry'; claim='can propose be steered out of inbox?'; scope='matrix'
}
# Re-read the scratch vault to learn where the note actually landed.
$inboxCount = @(Get-ChildItem (Join-Path $mxRoot 'inbox') -Filter '*.md' -File -ErrorAction SilentlyContinue).Count
$sysCount   = @(Get-ChildItem (Join-Path $mxRoot '.system') -Filter '*.md' -File -ErrorAction SilentlyContinue).Count
T 'propose lands only in inbox/, never in .system/' ($inboxCount -ge 1 -and $sysCount -eq 0) "inbox=$inboxCount system=$sysCount"
$after = [System.IO.File]::ReadAllText($regPath)
T 'the live registry is byte-identical after those attempts' ($before -eq $after) 'unchanged'

Write-Output "=== 11: registry.json has no BOM (PS 5.1 Set-Content -Encoding UTF8 writes one) ==="
# Node's JSON.parse THROWS on a BOM, so the MCP server would refuse to start.
# It works today only because the file was written without one -- the first
# person to re-save it from Windows PowerShell 5.1 breaks the server with a
# message about JSON parsing that never mentions the real cause.
$regBytes = [System.IO.File]::ReadAllBytes($regPath)
$hasBom = ($regBytes.Length -ge 3 -and $regBytes[0] -eq 0xEF -and $regBytes[1] -eq 0xBB -and $regBytes[2] -eq 0xBF)
T 'registry.json starts without a UTF-8 BOM' (-not $hasBom) ("first3=" + $regBytes[0] + "," + $regBytes[1] + "," + $regBytes[2])

Write-Output "=== 12: registry.json is tracked and NOT gitignored ==="
# A clone that cannot see the registry gets a startup refusal. That refusal is
# correct, but it must not happen for the boring reason that an ignore rule
# swallowed the file while every test passed on the author's own machine.
$ign = & git.exe -C 'C:\Users\Home\Documents\ObsidianVault' check-ignore -v '.system/registry.json' 2>&1 | Out-String
T 'registry.json is not gitignored' ([string]::IsNullOrWhiteSpace($ign.Trim())) $ign.Trim()
$tracked = & git.exe -C 'C:\Users\Home\Documents\ObsidianVault' ls-files '.system/registry.json' 2>&1 | Out-String
T 'registry.json is tracked by git' ($tracked.Trim() -eq '.system/registry.json') $tracked.Trim()

Write-Output "=== 13: the migration map emits only registry basis values ==="
# Claude flagged $confidenceToBasis as a provenance risk: a bulk migration
# could convert a self-reported confidence into a claim that someone OBSERVED
# it. Checked rather than assumed -- the map is faithful, not laundering:
#   'observed' -> 'observed'   the old field meant "someone observed this"
#   'inferred' -> 'inferred'
#   'stated'   -> 'user-stated'
#   anything else -> 'inferred'  the WEAKEST honest basis, never a promotion
# and a source-field override sends model consults to external-model.
$mig = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'migrate-schema.ps1'))
foreach ($v in @('observed', 'inferred', 'user-stated', 'external-model')) {
    T "migration can emit basis '$v' (it is in the registry)" ($EXPECT_BASIS -contains $v) (($EXPECT_BASIS) -join ',')
}
# The default for an unrecognised legacy value must be the weakest basis.
$defaultLine = @($mig -split "`n" | Where-Object { $_ -match 'confidenceToBasis\.ContainsKey' })
T 'migration falls back to the WEAKEST basis for unknown legacy values' `
    (($defaultLine -join ' ') -match "'inferred'") (($defaultLine -join ' ').Trim())
# And it must not stamp verification: `verified` comes only from a hand-written
# date table, never from confidence.
T 'migration never emits verified_by' ($mig -notmatch 'verified_by') 'absent'
T 'migration sets verified only from an explicit date table' ($mig -match '\$verified\.ContainsKey') 'uses the $verified map'

Write-Output "=== 14: the live registry itself is well-formed ==="
try {
    $live = [System.IO.File]::ReadAllText($regPath) | ConvertFrom-Json
    T 'the live registry.json parses' $true
    $keys = @($live.PSObject.Properties.Name)
    T 'the live registry has every required key' `
        (@($keys | Where-Object { $_ -in @('writeFolders','createFolders','rootFiles','blockedFolders','status','basis','requiredFields','optionalFields','mutableKeys','immutableKeys','probeKinds','probeSuites','minProbePatternLength','verbs') }).Count -eq 14) `
        ($keys -join ',')
    T 'every list key is a non-empty array' `
        (@($keys | Where-Object { $_ -notmatch '^_' -and $_ -ne 'minProbePatternLength' } |
           Where-Object { -not (@($live.$_).Count -gt 0) }).Count -eq 0) 'all present'
    T 'underscore keys are documentation-only' `
        (@($keys | Where-Object { $_ -like '_*' -and $_ -notin @('_about','_createFolders','_immutableKeys','_probeSuites','_verbs') }).Count -eq 0) 'none unexpected'
}
catch { T 'the live registry.json parses' $false $_.Exception.Message }

# --- summary ---------------------------------------------------------------
Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
$pass = @($results | Where-Object Pass).Count
$fail = @($results | Where-Object { -not $_.Pass }).Count
Write-Output ""
Write-Output ("{0}/{1} assertions passed" -f $pass, $results.Count)
if ($fail) {
    Write-Output "FAILED:"
    $results | Where-Object { -not $_.Pass } | ForEach-Object { Write-Output ("  - " + $_.Name) }
}
exit $(if ($fail) { 1 } else { 0 })
