<#
.SYNOPSIS
  Update an existing portable-pi drive without touching auth, sessions or settings.

.DESCRIPTION
  Reads <drive>/manifest.json and refreshes:
    - the pi runtime (dist/bundle + pi-tui + photon-node)
    - optionally Node.js (win+linux) with -Node <version|latest>
    - the whitelisted skills, ONLY when this PC has the source folders
  Never touches: config/pi/auth.json, config/pi/sessions/, config/pi/settings.json,
  config/pi/models.json, or user-created folders under config/pi/skills/.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File F:\scripts\update.ps1

.EXAMPLE
  powershell -File F:\scripts\update.ps1 -Drive F:\ -PiVersion latest

.EXAMPLE
  powershell -File F:\scripts\update.ps1 -Drive F:\ -PiVersion 1.6.0 -ForcePi
#>
[CmdletBinding()]
param(
    [string]$Drive,
    [string]$PiVersion,
    [string]$Node,
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

try {
    Step "Update portable-pi at $Drive"

    # ── resolve requested pi version ─────────────────────────────────────
    if (-not $PiVersion) { $PiVersion = $M.pi.version }
    if ($PiVersion -eq 'latest') {
        $meta = Get-Json 'https://registry.npmjs.org/@earendil-works%2fpi-coding-agent/latest'
        $PiVersion = $meta.version
        Ok "registry: pi $PiVersion"
    }

    $nm = Join-Path $Drive ($M.paths.runtimeDir + '\node_modules')
    $installed = $M.pi.version
    $needPi = $ForcePi -or ($PiVersion -ne $installed)
    if (-not $needPi) {
        Step "pi $installed already up to date (use -ForcePi to reinstall)"
    } else {
        Step "pi: $installed -> $PiVersion"
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
        $nodeWin = Get-ChildItem (Join-Path $Drive 'bin\win') -Directory -Filter 'node-v*-win-x64' | Select-Object -First 1
        $v = & (Join-Path $nodeWin.FullName 'node.exe') $cli --version
        if ($v -notmatch '\d+\.\d+\.\d+') { throw "pi --version non risponde dopo l'aggiornamento: $v" }
        Ok "pi ora risponde: $v"
        $M.pi.version = $PiVersion
        $M.pi.runtimePackages[0].version = $PiVersion
    }

    # ── optional node update ─────────────────────────────────────────────
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
                foreach ($line in $lines) { if ($line -match ('\s' + [regex]::Escape($archive) + '$')) { $expected = ($line -split '\s+')[0]; break } }
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
        } else {
            Step "node $target already present"
        }
    }

    # ── skills (only when this PC has the sources) ───────────────────────
    if (-not $SkipSkills) {
        $roots = @{
            agent  = Join-Path $env:USERPROFILE '.pi\agent'
            agents = Join-Path $env:USERPROFILE '.agents'
            npm    = Join-Path $env:USERPROFILE '.pi\agent\npm\node_modules'
        }
        $missing = @()
        foreach ($s in @($M.skills.include)) {
            if (-not (Test-Path (Join-Path (Join-Path $roots[$s.root] $s.path) 'SKILL.md'))) { $missing += $s.name }
        }
        if ($missing.Count -eq 0) {
            Step "Aggiorno $($M.skills.include.Count) skill dalla whitelist"
            foreach ($s in @($M.skills.include)) {
                $src = Join-Path $roots[$s.root] $s.path
                $dst = Join-Path $Drive ($M.paths.skillsDir + '\' + $s.name)
                Remove-Item $dst -Recurse -Force -ErrorAction SilentlyContinue
                Copy-Item $src $dst -Recurse -Force
                Ok $s.name
            }
        } else {
            Warn "skill sources not available on this machine ($($missing -join ', ')): skills left untouched"
            Warn "skills you added to the drive are untouched"
        }
    }

    # ── vendored packages (only when this PC has the sources) ────────────
    if (-not $SkipSkills -and $M.PSObject.Properties['packages'] -and @($M.packages).Count -gt 0) {
        $hostModules = Join-Path $env:USERPROFILE '.pi\agent
pm
ode_modules'
        $missingPkgs = @($M.packages | Where-Object { -not (Test-Path (Join-Path $hostModules (Join-Path $_.name 'package.json'))) })
        if ($missingPkgs.Count -eq 0) {
            Step "Aggiorno $($M.packages.Count) pacchetti vendorizzati"
            $tmpProfile = Join-Path ([IO.Path]::GetTempPath()) ('portable-pi-packages-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
            @{ packages = @($M.packages) } | ConvertTo-Json -Depth 10 | Set-Content -Path $tmpProfile -Encoding utf8
            $nodeExe = (Get-Command node -ErrorAction SilentlyContinue)
            if (-not $nodeExe) { throw 'node is required on this machine to vendor packages' }
            & $nodeExe.Source (Join-Path $Drive 'scripts\vendor-packages.mjs') --profile $tmpProfile --dest (Join-Path $Drive ($M.paths.agentDir + '\packages')) --prune
            Remove-Item $tmpProfile -Force -ErrorAction SilentlyContinue
            if ($LASTEXITCODE -ne 0) { throw "vendor-packages.mjs failed with exit code $LASTEXITCODE" }
            # refresh the skills those packages expose (they live in config/pi/skills
            # because -ns disables package skill discovery); never deletes anything
            $pkgNm = Join-Path $Drive ($M.paths.agentDir + 'packages
ode_modules')
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
                    Ok "package skill $($sd.Name)"
                }
            }
        } else {
            Warn "package sources not available on this machine ($(($missingPkgs | ForEach-Object { $_.name }) -join ', ')): packages left untouched"
        }
    }

    # ── persist versions, then verify ────────────────────────────────────
    [IO.File]::WriteAllText($ManifestPath, ($M | ConvertTo-Json -Depth 20) + "`n", (New-Object System.Text.UTF8Encoding($false)))
    Ok "manifest.json sul drive aggiornato (pi $($M.pi.version), node $($M.node.version))"

    if (-not $NoVerify) {
        $v = Join-Path $Drive 'scripts\verify.ps1'
        if (Test-Path $v) {
            Step "Verification (no model call)"
            & $v -Drive $Drive -NoModel
            if ($LASTEXITCODE -ne 0) { throw "verify reported errors: see the output above" }
        } else { Warn "scripts\verify.ps1 not found, skipping verification" }
    }

    $driveLetter = (Split-Path -Qualifier $Drive).TrimEnd(':')
    try { Write-VolumeCache -DriveLetter $driveLetter -ErrorAction Stop; Ok 'volume cache flushed' } catch { Warn 'volume flush unavailable (needs elevation)' }

    Write-Host ""
    Write-Host "Update completed." -ForegroundColor Green
    Write-Host "Verifica completa con modello:  powershell -File $Drive\scripts\verify.ps1 -Drive $Drive" -ForegroundColor DarkGray
}
finally {
    Remove-Item $Staging -Recurse -Force -ErrorAction SilentlyContinue
}
