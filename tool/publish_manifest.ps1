<#
.SYNOPSIS
    Publishes the signed update manifest to the GitHub Pages branch.
.DESCRIPTION
    Copies manifest.json and manifest.json.sig into updates/ on the pages
    branch and pushes. The manifest is copied byte for byte: the detached
    signature covers the exact bytes, so nothing is reformatted or re-encoded.

    Run this after signing the manifest with tool\update_keys.dart, and after
    the installer it points at has been published.
.PARAMETER ManifestPath
    Signed manifest. Defaults to build\update-manifest.json.
.PARAMETER SignaturePath
    Detached signature. Defaults to <manifest>.sig.
.PARAMETER Branch
    Pages branch. Defaults to gh-pages.
.PARAMETER Remote
    Remote to publish to. Defaults to origin.
.PARAMETER SkipPush
    Update the pages branch locally and stop before pushing.
#>
param(
    [string]$ManifestPath = 'build\update-manifest.json',
    [string]$SignaturePath,
    [string]$Branch = 'gh-pages',
    [string]$Remote = 'origin',
    [switch]$SkipPush
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
$worktree = $null
try {
    if (-not $SignaturePath) {
        $SignaturePath = "$ManifestPath.sig"
    }
    foreach ($path in @($ManifestPath, $SignaturePath)) {
        if (-not (Test-Path $path)) {
            throw "Not found: $path"
        }
    }

    $manifest = Get-Content -Path $ManifestPath -Raw
    try {
        $parsed = $manifest | ConvertFrom-Json
    }
    catch {
        throw 'The manifest is not valid JSON.'
    }
    if ($parsed.schema -ne 1) {
        throw 'The manifest schema must be 1.'
    }
    $entries = @($parsed.channels.PSObject.Properties)
    if ($entries.Count -eq 0) {
        throw 'The manifest lists no channels.'
    }
    $summary = ($entries | ForEach-Object { "$($_.Name) $($_.Value.version)" }) -join ', '

    git fetch $Remote $Branch
    if ($LASTEXITCODE -ne 0) {
        throw "Could not fetch $Remote/$Branch."
    }

    $worktree = Join-Path ([IO.Path]::GetTempPath()) (
        'stackpilot-pages-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    git worktree add --force -B $Branch $worktree "$Remote/$Branch"
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not create a worktree for the pages branch.'
    }

    $updatesDir = Join-Path $worktree 'updates'
    New-Item -ItemType Directory -Force -Path $updatesDir | Out-Null
    Copy-Item -Path $ManifestPath -Destination (Join-Path $updatesDir 'manifest.json') -Force
    Copy-Item -Path $SignaturePath -Destination (Join-Path $updatesDir 'manifest.json.sig') -Force

    # The signature covers exact bytes, so no end-of-line or encoding
    # conversion may happen on commit.
    [IO.File]::WriteAllText(
        (Join-Path $worktree '.gitattributes'),
        "* -text`n",
        (New-Object Text.ASCIIEncoding))

    git -C $worktree -c core.autocrlf=false add --all
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not stage the manifest.'
    }
    git -C $worktree diff --cached --quiet
    if ($LASTEXITCODE -eq 0) {
        Write-Host "The published manifest already matches ($summary)." -ForegroundColor Yellow
    }
    else {
        git -C $worktree commit -m "Publish update manifest: $summary"
        if ($LASTEXITCODE -ne 0) {
            throw 'Could not commit the manifest.'
        }

        # Prove the committed bytes match the signed files: the signature covers
        # exact bytes, so a stray line-ending conversion would break every client.
        $pairs = @(
            @{ Source = $ManifestPath; Repo = 'updates/manifest.json' },
            @{ Source = $SignaturePath; Repo = 'updates/manifest.json.sig' }
        )
        foreach ($pair in $pairs) {
            $published = Join-Path $worktree $pair.Repo
            Remove-Item -Path $published -Force
            git -C $worktree checkout -- $pair.Repo
            if ($LASTEXITCODE -ne 0) {
                throw "Could not read back $($pair.Repo)."
            }
            $expected = (Get-FileHash -Algorithm SHA256 -Path $pair.Source).Hash
            $actual = (Get-FileHash -Algorithm SHA256 -Path $published).Hash
            if ($expected -ne $actual) {
                throw "$($pair.Repo) changed on commit; the signature would not match."
            }
        }
        if ($SkipPush) {
            Write-Host "Committed to $Branch; skipping push." -ForegroundColor Yellow
        }
        else {
            git -C $worktree push $Remote $Branch
            if ($LASTEXITCODE -ne 0) {
                throw "Could not push $Branch."
            }
            Write-Host "Published $summary to $Branch." -ForegroundColor Green
        }
    }
}
finally {
    if ($worktree -and (Test-Path $worktree)) {
        git worktree remove --force $worktree 2>$null
    }
    Pop-Location
}
