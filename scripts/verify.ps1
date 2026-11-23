<#
.SYNOPSIS
  Verify isolation and integrity of a portable-pi drive.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\verify.ps1 -Drive E:\

.EXAMPLE
  # static checks only, no model call
  powershell -File scripts\verify.ps1 -Drive C:\Temp\usb-sim -NoModel
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Drive,
    [switch]$NoModel
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$fail = 0
function Pass([string]$m) { Write-Host "  PASS  $m" -ForegroundColor Green }
function Fail([string]$m) { Write-Host "  FAIL  $m" -ForegroundColor Red; $script:fail++ }
function Head([string]$m) { Write-Host ""; Write-Host "== $m" -ForegroundColor Cyan }

if (-not (Test-Path $Drive)) { throw "drive not found: $Drive" }
$Drive = (Resolve-Path $Drive).Path.TrimEnd('\', '/')

# Prefer the manifest shipped on the drive: it records the effective skill list.
$ManifestPath = Join-Path $Drive 'manifest.json'
if (-not (Test-Path $ManifestPath)) { $ManifestPath = Join-Path $RepoRoot 'manifest.json' }
$M = Get-Content $ManifestPath -Raw | ConvertFrom-Json

$agentDir = Join-Path $Drive $M.paths.agentDir
$skillsDir = Join-Path $Drive $M.paths.skillsDir
$cli = Join-Path $Drive ($M.paths.runtimeDir + '\node_modules\@earendil-works\pi-coding-agent\' + ($M.pi.entrypoint -replace '^@earendil-works/pi-coding-agent/', ''))
$nodeWin = Get-ChildItem (Join-Path $Drive 'bin\win') -Directory -Filter 'node-v*-win-x64' -ErrorAction SilentlyContinue | Select-Object -First 1
$nodeLinux = Get-ChildItem (Join-Path $Drive 'bin\linux') -Directory -Filter 'node-v*-linux-x64' -ErrorAction SilentlyContinue | Select-Object -First 1

# ── 1. layout ───────────────────────────────────────────────────────────
Head "Layout"
if ($nodeWin -and (Test-Path (Join-Path $nodeWin.FullName 'node.exe'))) { Pass "node win-x64: $($nodeWin.Name)" } else { Fail "node win-x64 missing" }
if ($nodeLinux -and (Test-Path (Join-Path $nodeLinux.FullName 'bin/node'))) { Pass "node linux-x64: $($nodeLinux.Name)" } else { Fail "node linux-x64 missing" }
if (Test-Path $cli) { Pass "pi entrypoint" } else { Fail "pi entrypoint missing: $cli" }
foreach ($f in @('auth.json', 'settings.json', 'AGENTS.md')) {
    if (Test-Path (Join-Path $agentDir $f)) { Pass "config/$f" } else { Fail "config/$f missing" }
}
if (Test-Path (Join-Path $Drive 'start.bat')) { Pass 'start.bat' } else { Fail 'start.bat missing' }
if (Test-Path (Join-Path $Drive 'start.sh')) { Pass 'start.sh' } else { Fail 'start.sh missing' }
if (Test-Path (Join-Path $Drive 'update.bat')) { Pass 'update.bat' } else { Fail 'update.bat missing' }
if (Test-Path (Join-Path $Drive 'update.sh')) { Pass 'update.sh' } else { Fail 'update.sh missing' }
foreach ($u in @('scripts\check-updates.mjs', 'scripts\vendor-packages.mjs', 'scripts\update.ps1', 'scripts\update.sh')) {
    if (Test-Path (Join-Path $Drive $u)) { Pass $u } else { Fail "$u missing" }
}

# ── 1b. drive root record (self-heal state) ─────────────────────────────
Head "Drive root"
$rootFile = Join-Path (Join-Path $Drive 'config') 'drive-root.txt'
$rootRecord = ''
if (Test-Path $rootFile) { $rootRecord = (Get-Content $rootFile -Raw).Trim() }
$currentRoot = if ($Drive -match '^[A-Za-z]:$') { $Drive + '\' } else { $Drive + '/' }
if (-not $rootRecord) { Fail 'config/drive-root.txt missing (rebuild the drive)' }
elseif ($rootRecord.TrimEnd([char[]]'\/') -ne $currentRoot.TrimEnd([char[]]'\/')) {
    Fail "recorded root '$rootRecord' != current '$currentRoot' - run start.bat/start.sh once to self-heal"
} else { Pass "recorded root matches the current one: $currentRoot" }

if ($currentRoot -match '^[A-Za-z]:') {
    $stale = @()
    foreach ($f in (Get-ChildItem (Join-Path $Drive $M.paths.agentDir) -Filter *.json -File -ErrorAction SilentlyContinue)) {
        $t = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
        if ($t -match '[A-Za-z]:\\' -and -not $t.Contains($currentRoot)) { $stale += $f.Name }
    }
    if ($stale.Count -eq 0) { Pass 'no stale absolute paths in config' }
    else { Fail "stale absolute paths in: $($stale -join ', ')" }
}

# ── 2. skills: exactly the whitelist ────────────────────────────────────
Head "Skills whitelist"
$expected = @($M.skills.include | ForEach-Object { $_.name })
if ($M.PSObject.Properties['packageSkills'] -and $M.packageSkills) { $expected += @($M.packageSkills) }
$present = @(Get-ChildItem $skillsDir -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'SKILL.md') } | ForEach-Object { $_.Name })
foreach ($n in $expected) {
    if ($present -contains $n) { Pass "$n" } else { Fail "$n missing on the drive" }
}
$extra = $present | Where-Object { $expected -notcontains $_ }
if ($extra) { Fail "unexpected skills on the drive: $($extra -join ', ')" } else { Pass "no unexpected skills" }

# ── 3. no host paths / device IPs in the shipped config ─────────────────
Head "No host-specific references"
$leaks = @()
foreach ($f in (Get-ChildItem $agentDir -Recurse -File -Include *.json, *.md | Where-Object { $_.Name -notin @('auth.json', 'models-store.json') -and $_.FullName -notlike (Join-Path $agentDir 'packages') + '*' })) {
    $text = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
    if ($text -match '[A-Za-z]:\\Users\\|/mnt/[a-z]/|/home/[a-z]|192\.168\.') { $leaks += $f.FullName }
}
if ($leaks.Count -eq 0) { Pass "no host paths or LAN endpoints" } else { Fail "host references in: $($leaks -join ', ')" }
foreach ($s in (Get-ChildItem $skillsDir -Recurse -File -Include *.md)) {
    $text = Get-Content $s.FullName -Raw -ErrorAction SilentlyContinue
    if ($text -match '[A-Za-z]:\\Users\\\\|/mnt/[a-z]/|/home/[a-z]|192\.168\.') { Fail "host path in skill: $($s.FullName)" }
}

# ── 3b. vendored packages, no SearXNG, vault on the drive ──────────────
Head "Third-party packages"
$pkgRoot = Join-Path $agentDir 'packages\node_modules'
$settingsPath = Join-Path $agentDir 'settings.json'
$settingsText = if (Test-Path $settingsPath) { Get-Content $settingsPath -Raw } else { '' }
$declared = @()
if ($M.PSObject.Properties['packages']) { $declared = @($M.packages) }
foreach ($p in $declared) {
    $pkgJson = Join-Path $pkgRoot (Join-Path $p.name 'package.json')
    if (-not (Test-Path $pkgJson)) { Fail "$($p.name) missing under config/pi/packages" ; continue }
    $v = (Get-Content $pkgJson -Raw | ConvertFrom-Json).version
    if ($p.version -and $v -ne $p.version) { Fail "$($p.name) version mismatch: drive $v, manifest $($p.version)" }
    else { Pass "$($p.name)@$v" }
    $rel = './packages/node_modules/' + $p.name
    if ($settingsText -notlike "*$rel*") { Fail "settings.json does not declare $rel" }
}
if ($declared.Count -gt 0 -and $settingsText -match 'searxng') { Fail 'web-search config references SearXNG' }
if ($declared.Count -gt 0 -and $settingsText -match '192\.168\.') { Fail 'settings.json references a LAN address' }
$wsPath = Join-Path $agentDir 'web-search.json'
if ($declared.Count -gt 0) {
    if (-not (Test-Path $wsPath)) { Fail 'config/pi/web-search.json missing' }
    elseif ((Get-Content $wsPath -Raw) -match 'searxng|192\.168\.') { Fail 'web-search.json references SearXNG or a LAN address' }
    else { Pass 'web-search.json without SearXNG/LAN' }
}
$hostSdk = @($declared | Where-Object { $_.PSObject.Properties['requiresHostSdk'] -and $_.requiresHostSdk })
if ($hostSdk.Count -gt 0) {
    $runtimeNm = Join-Path (Join-Path $Drive $M.paths.runtimeDir) 'node_modules'
    foreach ($rel in @('@earendil-works/pi-coding-agent/dist/index.js', '@earendil-works/pi-agent-core/package.json', '@earendil-works/pi-ai/package.json', 'typebox/package.json')) {
        # a version conflict may nest the dep under its dependent
        $flat = Join-Path $runtimeNm $rel
        $nested = Join-Path (Join-Path $runtimeNm '@earendil-works/pi-coding-agent/node_modules') $rel
        if ((Test-Path $flat) -or (Test-Path $nested)) { Pass "host SDK: $rel" } else { Fail "host SDK missing for child processes: tools/pi/node_modules/$rel" }
    }
}
if (-not (Test-Path (Join-Path $Drive 'workspace'))) { Fail 'workspace missing (llm-wiki vault home)' }
else { Pass 'workspace present (WIKI_HOME)' }

# ── 4. host config baseline (what must not change) ──────────────────────
Head "Host isolation"
$watch = @(
    (Join-Path $env:USERPROFILE '.pi\agent\skills'),
    (Join-Path $env:USERPROFILE '.pi\agent\npm'),
    (Join-Path $env:USERPROFILE '.pi\agent\extensions'),
    (Join-Path $env:USERPROFILE '.pi\agent\settings.json'),
    (Join-Path $env:USERPROFILE '.pi\agent\auth.json'),
    (Join-Path $env:USERPROFILE '.pi\agent\AGENTS.md'),
    (Join-Path $env:USERPROFILE '.agents\skills')
)
function Get-Snapshot {
    $lines = @()
    foreach ($p in $watch) {
        if (Test-Path $p) {
            foreach ($i in (Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue)) {
                $lines += "$($i.FullName)|$($i.Length)|$($i.LastWriteTimeUtc.Ticks)"
            }
        }
    }
    return ($lines | Sort-Object) -join "`n"
}
$before = Get-Snapshot

# ── 5. launcher smoke (no model) ────────────────────────────────────────
Head "Launcher"
$launch = & cmd /c "`"$Drive\start.bat`" --version" 2>&1
if (($launch -join "`n") -match '\d+\.\d+\.\d+') { Pass "start.bat --version -> $(($launch | Where-Object { $_ -match '\d+\.\d+\.\d+' }) -join ' ')" }
else { Fail "start.bat --version failed: $($launch -join ' | ')" }

# ── 6. live turn: skills mounted, marker, session on the drive ──────────
if (-not $NoModel) {
    Head "Live turn (model call)"
    $env:PI_CODING_AGENT_DIR = $agentDir
    $env:PI_CODING_AGENT_SESSION_DIR = Join-Path $agentDir 'sessions'
    $env:PI_SKIP_VERSION_CHECK = '1'
    $env:PI_TELEMETRY = '0'
    $nodeExe = Join-Path $nodeWin.FullName 'node.exe'
    $prompt = "Answer with exactly two lines and nothing else.`nMARK: PORTABLE-VERIFY-OK`nSKILLS: <comma separated names of the skills available to you>"
    $script:testDir = Join-Path ([IO.Path]::GetTempPath()) ("portable-pi-verify-" + [Guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Force -Path $script:testDir | Out-Null
    Push-Location $script:testDir
    try {
        $reply = & $nodeExe $cli -ns --skill $skillsDir -p $prompt 2>&1
    } finally { Pop-Location }
    $text = ($reply -join "`n")
    if ($text -match 'PORTABLE-VERIFY-OK') { Pass "model replied (marker present)" } else { Fail "model reply unexpected: $text" }

    # skills with disable-model-invocation: true are reachable only via /skill:name and are
    # deliberately absent from the model skill index
    $visible = @()
    foreach ($n in $expected) {
        $md = Join-Path (Join-Path $skillsDir $n) 'SKILL.md'
        $head = (Get-Content $md -TotalCount 20 -ErrorAction SilentlyContinue) -join "`n"
        if ($head -like '*disable-model-invocation: true*') { continue }
        $visible += $n
    }

    $missing = @()
    foreach ($n in $visible) { if ($text -notmatch [regex]::Escape($n)) { $missing += $n } }
    if ($missing.Count -eq 0) { Pass "all $($visible.Count) model-visible drive skills reported" }
    else { Fail "skills not reported by the model: $($missing -join ', ')" }

    # skills that come from a vendored package are in exclude[] as *standalone*
    # copies, but they are legitimately visible on the drive
    $fromPackages = @()
    if ($M.PSObject.Properties['packageSkills'] -and $M.packageSkills) { $fromPackages = @($M.packageSkills) }
    $excluded = @($M.skills.exclude | ForEach-Object { $_.name } | Where-Object { $fromPackages -notcontains $_ })
    $leaked = @($excluded | Where-Object { $text -match ('(^|[\s,])' + [regex]::Escape($_) + '($|[\s,.])') })
    if ($leaked.Count -eq 0) { Pass "no host/discovered skill leaked in" } else { Fail "leaked skills: $($leaked -join ', ')" }

    Head "Session isolation"
    $sessDir = Join-Path $agentDir 'sessions'
    $sess = @(Get-ChildItem $sessDir -Recurse -File -Filter *.jsonl -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
    if ($sess.Count -eq 1) { Pass "session written on the drive: $($sess[0].Name)" } else { Fail "no session file under $sessDir" }
    if ($sess.Count -eq 1 -and $sess[0].FullName -notlike "$agentDir*") { Fail "session escaped the drive" }

    Remove-Item Env:\PI_CODING_AGENT_DIR, Env:\PI_CODING_AGENT_SESSION_DIR -ErrorAction SilentlyContinue
    Remove-Item $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Head "Live turn"
    Write-Host "  SKIP  -NoModel" -ForegroundColor DarkGray
}

# ── 7. host config untouched ────────────────────────────────────────────
Head "Host config unchanged after the run"
$after = Get-Snapshot
if ($before -eq $after) { Pass "host skills/npm/extensions/settings/auth untouched" }
else {
    $b = $before -split "`n"; $a = $after -split "`n"
    $diff = Compare-Object $b $a | Select-Object -First 5
    Fail "host config changed: $($diff | ForEach-Object { $_.InputObject } | Out-String)"
}

Write-Host ""
if ($fail -eq 0) {
    Write-Host "VERIFY: PASS" -ForegroundColor Green
    exit 0
} else {
    Write-Host "VERIFY: $fail FAILURE(S)" -ForegroundColor Red
    exit 1
}
