<#
.SYNOPSIS
  Update an existing portable-pi drive without touching auth, sessions or settings.

.DESCRIPTION
  Reads <drive>/manifest.json and refreshes, component by component:
    - client:     the pi runtime (dist/bundle + pi-tui + photon-node + jiti)
    - extensions: the vendored packages (npm staging on the drive) and the skills
                  they expose, plus the whitelisted skills when this PC has the sources
    - host SDK:   re-vendored into tools/pi when a package sets requiresHostSdk, so
                  child pi processes (pi-subagents) keep working after a client update
  Never touches: config/pi/auth.json, config/pi/sessions/, config/pi/settings.json,
  config/pi/models.json, or user-created folders under config/pi/skills/.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File F:\scripts\update.ps1

.EXAMPLE
  powershell -File F:\scripts\update.ps1 -Check

.EXAMPLE
  powershell -File F:\scripts\update.ps1 -Drive F:\ -Components extensions -Yes

.EXAMPLE
  powershell -File F:\scripts\update.ps1 -Drive F:\ -PiVersion latest -ForcePi
#>
[CmdletBinding()]
param(
    [string]$Drive,
    [string]$PiVersion,
    [string]$Node,
    [ValidateSet('client', 'extensions', 'all')][string]$Components = 'all',
    [switch]$Check,
    [switch]$Yes,
    [switch]$SkipSkills,
    [switch]$NoVerify,
    [switch]$ForcePi
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $Drive) {
    # scripts/update.ps1 lives at <drive>/scripts
    $Drive = Split-Path -Parent $PSScriptRoot
}
if (-not (Test-Path $Drive)) { throw "drive not found: $Drive" }
$Drive = (Resolve-Path $Drive).Path.TrimEnd('\', '/')

$ManifestPath = Join-Path $Drive 'manifest.json'
if (-not (Test-Path $ManifestPath)) { throw "manifest.json not found on the drive: $ManifestPath" }
$M = Get-Content $ManifestPath -Raw | ConvertFrom-Json

$AgentDir = Join-Path $Drive $M.paths.agentDir
$RuntimeDir = Join-Path $Drive $M.paths.runtimeDir
$Staging = Join-Path ([IO.Path]::GetTempPath()) ("portable-pi-update-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $Staging | Out-Null

function Step([string]$t) { Write-Host "==> $t" -ForegroundColor Cyan }
function Ok([string]$t) { Write-Host "    $t" -ForegroundColor DarkGray }
function Warn([string]$t) { Write-Host "    ! $t" -ForegroundColor Yellow }

function Download([string]$url, [string]$dest) {
    for ($i = 1; $i -le 3; $i++) {
        try { Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 300; return }
        catch { if ($i -eq 3) { throw "download failed: $url`n$($_.Exception.Message)" }; Start-Sleep -Seconds (2 * $i) }
    }
}
function Get-Json([string]$url) {
    (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 60).Content | ConvertFrom-Json
}
function Extract([string]$archive, [string]$dest) {
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    & $tar -xf $archive -C $dest
    if ($LASTEXITCODE -ne 0) { throw "tar failed for $archive" }
}
function Resolve-Links([string]$root) {
    $links = @(Get-ChildItem $root -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    foreach ($l in $links) {
        $raw = $l.Target; if ($raw -is [array]) { $raw = $raw[0] }
        $resolved = if ($raw -and [IO.Path]::IsPathRooted($raw)) { $raw } else { Join-Path $l.DirectoryName $raw }
        $resolved = [IO.Path]::GetFullPath($resolved)
        Remove-Item -LiteralPath $l.FullName -Force -Recurse -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $resolved) { Copy-Item -LiteralPath $resolved -Destination $l.FullName -Recurse -Force }
    }
    if ($links.Count) { Ok "$($links.Count) symlink dereferenziati (exFAT)" }
}
function NpmUrl([string]$name, [string]$version) {
    if ($name.StartsWith('@')) {
        $p = $name.Split('/', 2)
        return "https://registry.npmjs.org/$([Uri]::EscapeDataString($p[0] + '/' + $p[1]))/-/$($p[1])-$version.tgz"
    }
    return "https://registry.npmjs.org/$name/-/$name-$version.tgz"
}
function Get-Latest([string]$name) {
    # scoped names: encode only the slash, the registry accepts @scope%2fname
    $url = if ($name.StartsWith('@')) {
        $p = $name.Split('/', 2); "https://registry.npmjs.org/$($p[0])%2f$($p[1])/latest"
    } else { "https://registry.npmjs.org/$name/latest" }
    (Get-Json $url).version
}
function Compare-Ver([string]$a, [string]$b) {
    $pa = ($a -replace '^v', '').Split('-')[0].Split('.')
    $pb = ($b -replace '^v', '').Split('-')[0].Split('.')
    for ($i = 0; $i -lt [Math]::Max($pa.Count, $pb.Count); $i++) {
        $x = if ($i -lt $pa.Count) { [int]$pa[$i] } else { 0 }
        $y = if ($i -lt $pb.Count) { [int]$pb[$i] } else { 0 }
        if ($x -ne $y) { return [Math]::Sign($x - $y) }
    }
    return 0
}

# The drive ships its own node/npm: use those, so the update does not depend on
# what is installed on the host (and npm's cache stays on the drive).
function Get-DriveToolchain {
    $win = @(Get-ChildItem (Join-Path $Drive 'bin\win') -Directory -Filter 'node-v*-win-x64' -ErrorAction SilentlyContinue)
    if ($win.Count -gt 0) {
        return [pscustomobject]@{
            Node = Join-Path $win[0].FullName 'node.exe'
            # run npm's CLI through node instead of npm.cmd: a .cmd wrapper with
            # '*> $log' redirection deadlocks Windows PowerShell
            Npm  = Join-Path (Join-Path $win[0].FullName 'node_modules') 'npm/bin/npm-cli.js'
        }
    }
    throw "node win-x64 not found on the drive (bin\win): rebuild it first"
}

function Invoke-Npm([string[]]$Arguments, [string]$Label) {
    $tc = Get-DriveToolchain
    # Keep npm's cache and prefix in the host temp: exFAT makes npm pathological
    # (32 KB clusters, thousands of cache entries) and a killed run can leave a
    # stale cache lock. Both dirs are removed with $Staging in the finally block.
    $env:NPM_CONFIG_CACHE = Join-Path $Staging 'npm-cache'
    $env:npm_config_fund = 'false'
    $env:npm_config_audit = 'false'
    $log = Join-Path $Staging ("npm-" + ($Label -replace '[^\w.-]', '_') + '.log')
    Ok "npm $Label"
    # npm writes notices on stderr; with ErrorActionPreference=Stop PowerShell
    # would turn them into a terminating NativeCommandError
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $tc.Node $tc.Npm @Arguments *> $log } finally { $ErrorActionPreference = $previous }
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        Get-Content $log | Select-Object -Last 12 | ForEach-Object { Warn $_ }
        throw "npm failed ($Label) with exit code $code, see the lines above"
    }
    return $tc
}

# ── check mode: ask the registry and stop ────────────────────────────────
if ($Check) {
    $script = Join-Path $PSScriptRoot 'check-updates.mjs'
    if (-not (Test-Path $script)) { throw "check-updates.mjs not found next to update.ps1" }
    try { $tc = Get-DriveToolchain; $nodeExe = $tc.Node } catch {
        $hostNode = Get-Command node -ErrorAction SilentlyContinue
        $nodeExe = if ($hostNode) { $hostNode.Source } else { $null }
    }
    if (-not $nodeExe) { throw 'node not found (drive toolchain missing and no node on the host)' }
    & $nodeExe $script --drive $Drive --node --json (Join-Path $Drive 'temp\update-plan.json')
    exit $LASTEXITCODE
}

# ── what the plan is ─────────────────────────────────────────────────────
$doClient = $Components -in @('client', 'all')
$doExt = $Components -in @('extensions', 'all')
Step "Update portable-pi at $Drive ($Components)"
Ok "client: $(if ($doClient) { 'sì' } else { 'no' }) | extensions: $(if ($doExt) { 'sì' } else { 'no' }) | solo rete + drive, niente host"

if (-not $Yes) {
    $answer = Read-Host 'Procedo con questi componenti? [S/n]'
    if ($answer -match '^[nN]') { Write-Host 'Annullato.'; exit 0 }
}

$clientChanged = $false
$extChanged = $false

try {
    # ── client: resolve requested pi version ────────────────────────────
    if ($doClient) {
        if (-not $PiVersion) { $PiVersion = $M.pi.version }
        if ($PiVersion -eq 'latest') {
            $meta = Get-Json 'https://registry.npmjs.org/@earendil-works%2fpi-coding-agent/latest'
            $PiVersion = $meta.version
            Ok "registry: pi $PiVersion"
        }

        $nm = Join-Path $RuntimeDir 'node_modules'
        $installed = $M.pi.version
        $needPi = $ForcePi -or ($PiVersion -ne $installed)
        if (-not $needPi) {
            Step "client: pi $installed già aggiornato (usa -ForcePi per reinstallare)"
        } else {
            Step "client: pi $installed -> $PiVersion"
            foreach ($p in @($M.pi.runtimePackages)) {
                $version = $p.version
                if ($p.name -eq '@earendil-works/pi-coding-agent') { $version = $PiVersion }
                $dest = Join-Path $nm ($p.name -replace '/', '\')
                $tgz = Join-Path $Staging ((($p.name -replace '[/@]', '_')) + '.tgz')
                Ok "downloading $($p.name)@$version"
                Download (NpmUrl $p.name $version) $tgz
                $x = Join-Path $Staging ('x-' + ($p.name -replace '[/@]', '_'))
                Remove-Item $x -Recurse -Force -ErrorAction SilentlyContinue
                Extract $tgz $x
                Resolve-Links $x
                $pkg = Join-Path $x 'package'
                if (-not (Test-Path $pkg)) { throw "unexpected tarball layout for $($p.name)" }
                $new = "$dest.new"
                Remove-Item $new -Recurse -Force -ErrorAction SilentlyContinue
                New-Item -ItemType Directory -Force -Path $new | Out-Null
                foreach ($keep in @($p.keep)) {
                    if ($keep -eq '*') { Copy-Item (Join-Path $pkg '*') -Destination $new -Recurse -Force }
                    else {
                        $dst = Join-Path $new $keep
                        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
                        Copy-Item (Join-Path $pkg $keep) -Destination $dst -Recurse -Force
                    }
                }
                # swap: only the package directory is replaced, nothing else on the drive
                Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue
                Move-Item $new $dest
                Ok "$($p.name) $(if ($p.name -eq '@earendil-works/pi-coding-agent') { $PiVersion } else { $version }) ($((Get-ChildItem $dest -Recurse -File).Count) file)"
            }

            $cli = Join-Path $nm '@earendil-works\pi-coding-agent\dist\bundle\cli.js'
            $tc = Get-DriveToolchain
            $v = & $tc.Node $cli --version
            if ($v -notmatch '\d+\.\d+\.\d+') { throw "pi --version non risponde dopo l'aggiornamento: $v" }
            Ok "pi ora risponde: $v"
            $M.pi.version = $PiVersion
            $M.pi.runtimePackages[0].version = $PiVersion
            $clientChanged = $true
        }

        # optional node update
        if ($Node) {
            $target = $Node
            if ($Node -eq 'latest') {
                $idx = Get-Json 'https://nodejs.org/dist/index.json'
                $lts = $idx | Where-Object { $_.lts -and $_.version -match '^v24\.' } | Select-Object -First 1
                $target = $lts.version.TrimStart('v')
                Ok "LTS: node $target"
            }
            if ($target -ne $M.node.version) {
                Step "node: $($M.node.version) -> $target"
                $sums = Join-Path $Staging 'SHASUMS256.txt'
                Download ("https://nodejs.org/dist/v$target/SHASUMS256.txt") $sums
                $lines = Get-Content $sums
                foreach ($t in @($M.node.targets)) {
                    $archive = $t.archive.Replace('{version}', $target)
                    $url = $t.url.Replace('{version}', $target)
                    $file = Join-Path $Staging $archive
                    Ok "downloading $archive"
                    Download $url $file
                    $expected = $null
                    foreach ($l in $lines) { if ($l -match ('\s' + [regex]::Escape($archive) + '$')) { $expected = ($l -split '\s+')[0]; break } }
                    $sha = [Security.Cryptography.SHA256]::Create()
                    $fs = [IO.File]::OpenRead($file)
                    try { $hash = $sha.ComputeHash($fs) } finally { $fs.Dispose(); $sha.Dispose() }
                    $actual = -join ($hash | ForEach-Object { $_.ToString('x2') })
                    if ($actual -ne $expected.ToLower()) { throw "checksum mismatch: $archive" }
                    $x = Join-Path $Staging ('x-' + $t.id)
                    Remove-Item $x -Recurse -Force -ErrorAction SilentlyContinue
                    Extract $file $x
                    Resolve-Links $x
                    $top = Get-ChildItem $x -Directory | Select-Object -First 1
                    $dest = Join-Path $Drive (($t.installDir).Replace('{version}', $target))
                    Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue
                    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
                    Move-Item $top.FullName $dest
                    Ok "installato $($t.id)"
                }
                $M.node.version = $target
                $clientChanged = $true
            } else {
                Step "node $target already present"
            }
        }
    }

    # ── extensions: npm staging on the drive, then vendor ───────────────
    if ($doExt -and -not $SkipSkills) {
        $pkgs = if ($M.PSObject.Properties['packages'] -and $M.packages) { @($M.packages) } else { @() }
        if ($pkgs.Count -gt 0) {
            $targets = @()
            foreach ($p in $pkgs) {
                $latest = try { Get-Latest $p.name } catch { Warn "registry: $($p.name) non raggiungibile"; $p.version }
                $targets += [pscustomobject]@{ name = $p.name; current = $p.version; latest = $latest; update = ((Compare-Ver $latest $p.version) -gt 0) }
            }
            $todo = @($targets | Where-Object { $_.update })
            # manifest vs what is actually vendored: a half-applied update must be repairable
            $pkgNmCheck = Join-Path (Join-Path $AgentDir 'packages') 'node_modules'
            $mismatch = @()
            foreach ($p in $pkgs) {
                $pj = Join-Path $pkgNmCheck (Join-Path $p.name 'package.json')
                if (-not (Test-Path $pj)) { $mismatch += $p.name; continue }
                $onDisk = (Get-Content $pj -Raw | ConvertFrom-Json).version
                if ($onDisk -and $p.version -and $onDisk -ne $p.version) { $mismatch += $p.name }
            }
            if ($mismatch.Count -gt 0) { Warn "drive disallineato dal manifest: $($mismatch -join ', ')" }
            if ($todo.Count -eq 0 -and $mismatch.Count -eq 0) {
                Step 'extensions: già aggiornate'
            } else {
                Step "extensions: $(($todo | ForEach-Object { "$($_.name) $($_.current) -> $($_.latest)" }) -join ', ')"

                # install every package at its target version in one staging tree;
                # the vendor step then mirrors the whole profile (prune included)
                $stage = Join-Path $Staging 'ext-stage'
                Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
                New-Item -ItemType Directory -Force -Path $stage | Out-Null
                $specs = @($targets | ForEach-Object { "$($_.name)@$($_.latest)" })
                Invoke-Npm -Label 'extensions' -Arguments (@('install', '--prefix', $stage, '--omit=dev', '--no-audit', '--no-fund', '--ignore-scripts', '--package-lock=false', '--legacy-peer-deps', '--omit=optional') + $specs) | Out-Null

                $profilePkgs = @()
                foreach ($p in $pkgs) {
                    $t = $targets | Where-Object { $_.name -eq $p.name } | Select-Object -First 1
                    $entry = [ordered]@{ name = $p.name; spec = "npm:$($p.name)@$($t.latest)" }
                    $skip = @()
                    if ($p.PSObject.Properties['skipOptional'] -and $p.skipOptional) { $skip = @($p.skipOptional) }
                    elseif ($p.PSObject.Properties['skippedOptional'] -and $p.skippedOptional) { $skip = @($p.skippedOptional) }
                    if ($skip.Count -gt 0) { $entry.skipOptional = $skip }
                    if ($p.PSObject.Properties['requiresHostSdk'] -and $p.requiresHostSdk) { $entry.requiresHostSdk = $true }
                    $profilePkgs += $entry
                }
                $tmpProfile = Join-Path $Staging 'profile-packages.json'
                [IO.File]::WriteAllText($tmpProfile, (@{ packages = $profilePkgs } | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))

                # exFAT writes in 32 KB clusters: budget by file count, not bytes.
                # The old tree is removed BEFORE copying, so only one copy exists.
                $pkgDir = Join-Path $AgentDir 'packages'
                $stageFiles = @(Get-ChildItem (Join-Path $stage 'node_modules') -Recurse -File -ErrorAction SilentlyContinue).Count
                $needMb = [Math]::Ceiling($stageFiles * 32KB / 1MB) + 60
                $letter = (Split-Path -Qualifier $Drive).TrimEnd(':')
                $freeMb = [Math]::Floor((Get-PSDrive -Name $letter -ErrorAction SilentlyContinue).Free / 1MB)
                # the old tree is deleted before copying: count its space as available
                if (Test-Path $pkgDir) {
                    $oldFiles = @(Get-ChildItem $pkgDir -Recurse -File -ErrorAction SilentlyContinue).Count
                    $freeMb += [Math]::Ceiling($oldFiles * 32KB / 1MB)
                }
                Ok "spazio: $stageFiles file in staging, stimati $needMb MB, liberi $freeMb MB"
                if ($freeMb -gt 0 -and $freeMb -lt $needMb) {
                    throw "spazio insufficiente sul drive: servono ~$needMb MB, liberi $freeMb MB. Libera spazio (o usa una chiavetta piu' grande) e riprova: nessuna modifica e' stata fatta."
                }
                if (Test-Path $pkgDir) { Remove-Item $pkgDir -Recurse -Force -ErrorAction SilentlyContinue }

                $tc = Get-DriveToolchain
                $vendorScript = Join-Path $Drive 'scripts\vendor-packages.mjs'
                $log = Join-Path $Staging 'vendor.log'
                & $tc.Node $vendorScript --profile $tmpProfile --dest (Join-Path $AgentDir 'packages') `
                    --host-packages (Join-Path $stage 'node_modules') --prune --allow-missing --json (Join-Path $Staging 'vendor.report') *> $log
                if ($LASTEXITCODE -ne 0) { Get-Content $log | Select-Object -Last 15 | ForEach-Object { Warn $_ }; throw 'vendor-packages.mjs failed' }
                foreach ($l in (Get-Content $log | Where-Object { $_ -match 'MB|!' })) { Ok $l.Trim() }

                # refresh the versions the drive records, and the skills packages expose
                foreach ($p in @($M.packages)) {
                    $t = $targets | Where-Object { $_.name -eq $p.name } | Select-Object -First 1
                    $p.version = $t.latest
                    $p.spec = "npm:$($p.name)@$($t.latest)"
                }
                Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
                $extChanged = $true
            }
        } else { Step 'extensions: nessun pacchetto nel profilo' }

        # package-provided skills are mirrored into config/pi/skills because -ns
        # disables package skill discovery: reconcile them on every update
        $pkgSkills = @()
        $pkgNm = Join-Path (Join-Path $AgentDir 'packages') 'node_modules'
        $pkgDirs = @()
        foreach ($d in (Get-ChildItem $pkgNm -Directory -ErrorAction SilentlyContinue)) {
            if ($d.Name.StartsWith('@')) { $pkgDirs += @(Get-ChildItem $d.FullName -Directory -ErrorAction SilentlyContinue) } else { $pkgDirs += $d }
        }
        foreach ($pd in $pkgDirs) {
            $skDir = Join-Path $pd.FullName 'skills'
            if (-not (Test-Path $skDir)) { continue }
            foreach ($sd in (Get-ChildItem $skDir -Directory -ErrorAction SilentlyContinue)) {
                if (-not (Test-Path (Join-Path $sd.FullName 'SKILL.md'))) { continue }
                $dst = Join-Path (Join-Path $Drive $M.paths.skillsDir) $sd.Name
                Remove-Item $dst -Recurse -Force -ErrorAction SilentlyContinue
                Copy-Item $sd.FullName $dst -Recurse -Force
                $pkgSkills += $sd.Name
                Ok "package skill $($sd.Name)"
            }
        }
        $M | Add-Member -NotePropertyName packageSkills -NotePropertyValue @($pkgSkills) -Force

        # whitelisted skills: only when this PC has the sources
        $roots = @{
            agent  = Join-Path $env:USERPROFILE '.pi\agent'
            agents = Join-Path $env:USERPROFILE '.agents'
            npm    = Join-Path $env:USERPROFILE '.pi\agent\npm\node_modules'
        }
        $includes = @($M.skills.include)
        if ($includes.Count -gt 0) {
            $missing = @()
            foreach ($s in $includes) {
                if (-not (Test-Path (Join-Path (Join-Path $roots[$s.root] $s.path) 'SKILL.md'))) { $missing += $s.name }
            }
            if ($missing.Count -eq 0) {
                Step "skills: aggiorno $($includes.Count) dalla whitelist"
                foreach ($s in $includes) {
                    $src = Join-Path $roots[$s.root] $s.path
                    $dst = Join-Path $Drive ($M.paths.skillsDir + '\' + $s.name)
                    Remove-Item $dst -Recurse -Force -ErrorAction SilentlyContinue
                    Copy-Item $src $dst -Recurse -Force
                    Ok $s.name
                }
            } else {
                Warn "skill sources not available on this machine ($($missing -join ', ')): skills left untouched"
            }
        }
    }

    # ── host SDK: needed by packages that spawn child pi processes ──────
    $needHostSdk = @(if ($M.PSObject.Properties['packages'] -and $M.packages) {
        $M.packages | Where-Object { $_.PSObject.Properties['requiresHostSdk'] -and $_.requiresHostSdk }
    })
    if ($needHostSdk.Count -gt 0 -and ($doClient -or $doExt)) {
        $runtimeNm = Join-Path $RuntimeDir 'node_modules'
        $marker = Join-Path $runtimeNm '@earendil-works\pi-coding-agent\dist\index.js'
        if ($clientChanged -or $extChanged -or -not (Test-Path $marker)) {
            Step "host SDK: pi $($M.pi.version) per $($needHostSdk.name -join ', ')"
            $stage = Join-Path $Staging 'hostsdk-stage'
            Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Force -Path $stage | Out-Null
            Invoke-Npm -Label 'host-sdk' -Arguments @('install', '--prefix', $stage, '--omit=dev', '--no-audit', '--no-fund', '--ignore-scripts', '--package-lock=false', '--legacy-peer-deps', '--omit=optional', "@earendil-works/pi-coding-agent@$($M.pi.version)") | Out-Null
            $tmpProfile = Join-Path $Staging 'host-sdk.json'
            $json = @{ packages = @(@{ name = '@earendil-works/pi-coding-agent'; spec = "npm:@earendil-works/pi-coding-agent@$($M.pi.version)" }) } | ConvertTo-Json -Depth 5
            [IO.File]::WriteAllText($tmpProfile, $json, (New-Object System.Text.UTF8Encoding($false)))
            $tc = Get-DriveToolchain
            $log = Join-Path $Staging 'host-sdk.log'
            & $tc.Node (Join-Path $Drive 'scripts\vendor-packages.mjs') --profile $tmpProfile --dest $RuntimeDir `
                --host-packages (Join-Path $stage 'node_modules') --allow-host-provided --force --allow-missing --json (Join-Path $Staging 'host-sdk.report') *> $log
            if ($LASTEXITCODE -ne 0) { Get-Content $log | Select-Object -Last 15 | ForEach-Object { Warn $_ }; throw 'host SDK vendoring failed' }
            foreach ($l in (Get-Content $log | Where-Object { $_ -match 'MB|!' })) { Ok $l.Trim() }
            Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path $marker)) { throw "host SDK incomplete: $marker missing" }
        } else {
            Step 'host SDK: già presente e allineato al client'
        }
    }

    # ── persist versions, then verify ────────────────────────────────────
    [IO.File]::WriteAllText($ManifestPath, ($M | ConvertTo-Json -Depth 20) + "`n", (New-Object System.Text.UTF8Encoding($false)))
    Ok "manifest.json sul drive aggiornato (pi $($M.pi.version), node $($M.node.version))"

    if (-not $NoVerify) {
        $v = Join-Path $Drive 'scripts\verify.ps1'
        if (Test-Path $v) {
            Step 'Verification (no model call)'
            & $v -Drive $Drive -NoModel
            if ($LASTEXITCODE -ne 0) { throw 'verify reported errors: see the output above' }
        } else { Warn 'scripts\verify.ps1 not found, skipping verification' }
    }

    $driveLetter = (Split-Path -Qualifier $Drive).TrimEnd(':')
    try { Write-VolumeCache -DriveLetter $driveLetter -ErrorAction Stop; Ok 'volume cache flushed' } catch { Warn 'volume flush unavailable (needs elevation)' }

    Write-Host ''
    Write-Host 'Update completed.' -ForegroundColor Green
    Write-Host "Verifica completa con modello:  powershell -File $Drive\scripts\verify.ps1 -Drive $Drive" -ForegroundColor DarkGray
}
finally {
    Remove-Item $Staging -Recurse -Force -ErrorAction SilentlyContinue
}
