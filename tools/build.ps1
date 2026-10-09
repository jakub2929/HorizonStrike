<#
.SYNOPSIS
  Builds the Horizon Strike package into dist/ (docs/ARCHITECTURE.md "Installed layout").

.DESCRIPTION
  Sections are owned by different teammates and stay self-contained; each one is a function that only writes
  below -Dist. Dot-source this file to call a single section, or run it to build everything.

    powershell -ExecutionPolicy Bypass -File tools/build.ps1 [-Dist <dir>]
    . tools/build.ps1; Build-Converter -Dist dist
#>
param(
    [string]$Dist = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist')
)
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot

# ============================================================================================================
# BEGIN Build-Converter (owner: cs2)
#   dotnet publish of converter/src/Hzs.Cli as a self-contained win-x64 app (the player needs no .NET runtime)
#   -> <Dist>/converter/hzsconv.exe + its managed and native dlls (libSkiaSharp.dll, spirv-cross.dll), plus the
#   license files of what it bundles; THIRD_PARTY_NOTICES.txt -> <Dist>/.
#   Not trimmed and not single-file: the converter reads generated sheet rows through reflection and loads
#   native libraries next to the exe. The publish overwrites <Dist>/converter in place and never deletes;
#   build a release from an empty dist/ so no stale file survives.
# ============================================================================================================
function Build-Converter {
    param([Parameter(Mandatory)][string]$Dist)
    $proj = Join-Path $RepoRoot 'converter/src/Hzs.Cli/Hzs.Cli.csproj'
    $out = Join-Path $Dist 'converter'

    # no symbols or XML docs in the package
    & dotnet publish $proj -c Release -r win-x64 --self-contained true -o $out `
        -p:PublishSingleFile=false -p:PublishTrimmed=false -p:DebugType=none -p:DebugSymbols=false `
        -p:GenerateDocumentationFile=false -p:PublishReferencesDocumentationFiles=false `
        -p:PublishDocumentationFile=false -p:AllowedReferenceRelatedFileExtensions=none `
        -p:SatelliteResourceLanguages=en --nologo
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed ($LASTEXITCODE)" }
    # SkiaSharp's native assets carry an 89 MB libSkiaSharp.pdb that DebugType=none does not cover
    $skiaPdb = Join-Path $out 'libSkiaSharp.pdb'
    if (Test-Path -LiteralPath $skiaPdb) { Remove-Item -LiteralPath $skiaPdb }
    $extra = @(Get-ChildItem -LiteralPath $out -Recurse -File | Where-Object { $_.Extension -in '.pdb', '.xml' })
    if ($extra.Count -gt 0) { Write-Warning "debug/doc files in the publish: $($extra.Name -join ', ')" }

    # license texts of bundled third-party code (listed in THIRD_PARTY_NOTICES.txt)
    $nuget = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $env:USERPROFILE '.nuget/packages' }
    $licenses = Join-Path $out 'licenses'
    New-Item -ItemType Directory -Force -Path $licenses | Out-Null
    $runtimeConfig = Get-Content -Raw (Join-Path $out 'hzsconv.runtimeconfig.json') | ConvertFrom-Json
    $netVersion = ($runtimeConfig.runtimeOptions.includedFrameworks | Where-Object name -eq 'Microsoft.NETCore.App').version
    $copies = @(
        @('skiasharp.nativeassets.win32/4.151.1/THIRD-PARTY-NOTICES.txt', 'SkiaSharp-THIRD-PARTY-NOTICES.txt'),
        @('system.io.hashing/10.0.10/THIRD-PARTY-NOTICES.TXT', 'System.IO.Hashing-THIRD-PARTY-NOTICES.txt'),
        @("microsoft.netcore.app.runtime.win-x64/$netVersion/THIRD-PARTY-NOTICES.TXT", 'dotnet-runtime-THIRD-PARTY-NOTICES.txt'),
        @("microsoft.netcore.app.runtime.win-x64/$netVersion/LICENSE.TXT", 'dotnet-runtime-LICENSE.txt')
    )
    foreach ($c in $copies) {
        $src = if ([IO.Path]::IsPathRooted($c[0])) { $c[0] } else { Join-Path $nuget $c[0] }
        if (-not (Test-Path $src)) { throw "license file missing: $src" }
        Copy-Item -LiteralPath $src -Destination (Join-Path $licenses $c[1]) -Force
    }
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'THIRD_PARTY_NOTICES.txt') -Destination $Dist -Force

    & (Join-Path $out 'hzsconv.exe') --help | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "hzsconv.exe --help failed ($LASTEXITCODE)" }
    $mb = [math]::Round(((Get-ChildItem -LiteralPath $out -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 1)
    Write-Host "Build-Converter: $out ($mb MB)"
}
# END Build-Converter
# ============================================================================================================

# ============================================================================================================
# BEGIN Build-Game (owner: hra)
#   Godot 4.7.2 export of game/ with the preset "Windows Desktop" (game/export_presets.cfg: pck embedded, no
#   console wrapper, dev/ excluded, product name/company/icon our own) -> <Dist>/HorizonStrike.exe, plus
#   <Dist>/licenses/Godot-LICENSES.txt (engine + bundled libraries, from the engine itself), README.txt and
#   LICENSE.txt (MIT, EM) when the repository has none. Godot: -Godot <exe>, $env:GODOT, or the WinGet install.
# ============================================================================================================
function Build-Game {
    param(
        [Parameter(Mandatory)][string]$Dist,
        [string]$Godot = $env:GODOT
    )
    if (-not $Godot) {
        $Godot = Join-Path $env:LOCALAPPDATA 'Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.7.2-stable_win64_console.exe'
    }
    if (-not (Test-Path -LiteralPath $Godot)) { throw "Godot 4.7.2 not found: $Godot (pass -Godot or set GODOT)" }
    $gameDir = Join-Path $RepoRoot 'game'
    New-Item -ItemType Directory -Force -Path $Dist | Out-Null
    $exe = Join-Path (Resolve-Path -LiteralPath $Dist) 'HorizonStrike.exe'
    $log = Join-Path ([IO.Path]::GetTempPath()) 'hzs-build-game.log'

    # import pass first (fresh checkouts have no .godot/), then the release export
    & $Godot --headless --path $gameDir --import *> $log
    if ($LASTEXITCODE -ne 0) { throw "Godot import failed ($LASTEXITCODE), see $log" }
    if (Test-Path -LiteralPath $exe) { Remove-Item -LiteralPath $exe }
    & $Godot --headless --path $gameDir --export-release 'Windows Desktop' $exe *>> $log
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exe)) { throw "Godot export failed ($LASTEXITCODE), see $log" }
    $pck = [IO.Path]::ChangeExtension($exe, '.pck')
    if (Test-Path -LiteralPath $pck) { throw "unexpected separate pck (embed_pck should be on): $pck" }

    $licenses = Join-Path $Dist 'licenses'
    New-Item -ItemType Directory -Force -Path $licenses | Out-Null
    & $Godot --headless --path $gameDir --script res://dev/print_licenses.gd -- (Join-Path (Resolve-Path -LiteralPath $licenses) 'Godot-LICENSES.txt') *>> $log
    if ($LASTEXITCODE -ne 0) { throw "writing Godot licenses failed ($LASTEXITCODE), see $log" }

    $license = Join-Path $RepoRoot 'LICENSE.txt'
    if (Test-Path -LiteralPath $license) {
        Copy-Item -LiteralPath $license -Destination $Dist -Force
    } else {
        Set-Content -LiteralPath (Join-Path $Dist 'LICENSE.txt') -Encoding ascii -Value @'
MIT License

Copyright (c) 2026 EM

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
'@
    }
    $readme = Join-Path $RepoRoot 'README.txt'
    if (Test-Path -LiteralPath $readme) {
        Copy-Item -LiteralPath $readme -Destination $Dist -Force
    } else {
        Set-Content -LiteralPath (Join-Path $Dist 'README.txt') -Encoding ascii -Value @'
Horizon Strike (working title) - Counter-Strike 2 x Horizon Zero Dawn Complete Edition

Start it from Melty (it passes your CS2 folder: HorizonStrike.exe --game <CS2 folder>).
Horizon Zero Dawn Complete Edition must be installed on Steam; the game finds it by itself.
No game files are included: on first start the converter (converter\hzsconv.exe) reads your own CS2 and
Horizon Zero Dawn installs (read-only) and writes a local cache to %LOCALAPPDATA%\HorizonStrike\cache.
The cache limit can be changed in the Esc menu. Logs: %LOCALAPPDATA%\HorizonStrike\logs\latest.log

Controls: WASD move, Shift walk, Ctrl crouch, Space jump, mouse aim/fire, R reload, 1-4 weapon slots,
B buy wheel (not in combat), F inspect, Esc menu.
'@
    }
    $mb = [math]::Round((Get-Item -LiteralPath $exe).Length / 1MB, 1)
    Write-Host "Build-Game: $exe ($mb MB)"
}
# END Build-Game
# ============================================================================================================

# Run every section when executed (not when dot-sourced). Other sections add their call below.
if ($MyInvocation.InvocationName -ne '.') {
    New-Item -ItemType Directory -Force -Path $Dist | Out-Null
    Build-Converter -Dist $Dist
    Build-Game -Dist $Dist
}
