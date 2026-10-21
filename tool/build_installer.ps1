<#
.SYNOPSIS
    Builds StackPilot and packages it with Inno Setup.
.PARAMETER SkipBuild
    Reuse the existing release build instead of running flutter build windows.
.PARAMETER Version
    Override the version read from pubspec.yaml (for example 1.2.0).
#>
param(
    [switch]$SkipBuild,
    [string]$Version
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    if (-not $Version) {
        $versionLine = Get-Content -Path 'pubspec.yaml' |
            Where-Object { $_ -match '^version:\s*(\S+)' } |
            Select-Object -First 1
        if ($versionLine -notmatch '^version:\s*(\S+)') {
            throw 'Could not read the version from pubspec.yaml.'
        }
        $Version = $Matches[1].Split('+')[0]
    }

    if (-not $SkipBuild) {
        Write-Host "Building StackPilot $Version..." -ForegroundColor Cyan
        flutter build windows --release
    }

    $releaseDir = Join-Path $root 'build\windows\x64\runner\Release'
    if (-not (Test-Path (Join-Path $releaseDir 'stackpilot.exe'))) {
        throw "Release build not found at $releaseDir. Run without -SkipBuild first."
    }

    $isccCandidates = @(
        (Join-Path $root '.tools\InnoSetup\ISCC.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe')
    )
    $iscc = $isccCandidates |
        Where-Object { $_ -and (Test-Path $_) } |
        Select-Object -First 1
    if (-not $iscc) {
        $command = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
        if ($command) {
            $iscc = $command.Source
        }
    }
    if (-not $iscc) {
        throw @'
Inno Setup 6 was not found.
Install it with: winget install --id JRSoftware.InnoSetup --exact
Then run this script again.
'@
    }

    $outputDir = Join-Path $root 'build\installer'
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

    Write-Host "Packaging with $iscc..." -ForegroundColor Cyan
    & $iscc "/DAppVersion=$Version" (Join-Path $root 'installer\stackpilot.iss')
    if ($LASTEXITCODE -ne 0) {
        throw "Inno Setup failed with exit code $LASTEXITCODE."
    }

    $installer = Join-Path $outputDir "StackPilot-$Version-Setup.exe"
    if (-not (Test-Path $installer)) {
        throw "Expected installer was not created at $installer."
    }

    $sizeMb = [math]::Round((Get-Item $installer).Length / 1MB, 1)
    Write-Host "Installer ready: $installer ($sizeMb MB)" -ForegroundColor Green
}
finally {
    Pop-Location
}
