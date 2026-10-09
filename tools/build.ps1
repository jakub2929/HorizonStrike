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

# Run every section when executed (not when dot-sourced). Other sections add their call below.
if ($MyInvocation.InvocationName -ne '.') {
    New-Item -ItemType Directory -Force -Path $Dist | Out-Null
    Build-Converter -Dist $Dist
}
