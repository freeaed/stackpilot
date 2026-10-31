<#
.SYNOPSIS
    Builds StackPilot and packages it with Inno Setup.
.DESCRIPTION
    The version comes from pubspec.yaml unless -Version is given. Release
    identity (version, channel, update URL, update public key) is compiled into
    the executable with --dart-define, so the installed app knows where to look
    for signed updates.

    Code signing is optional for local builds and expected for published
    releases. Pass -CertificatePath/-CertificatePassword (PFX) or
    -CertificateThumbprint (a store/token certificate) to sign stackpilot.exe
    and the installer. Without a certificate the script warns and still builds.
.PARAMETER SkipBuild
    Reuse the existing release build instead of running flutter build windows.
.PARAMETER Version
    Override the version read from pubspec.yaml (for example 1.2.0).
.PARAMETER Channel
    Release channel compiled into the build: stable or preview.
.PARAMETER UpdateUrl
    HTTPS URL of the signed update manifest. Defaults to
    STACKPILOT_UPDATE_URL.
.PARAMETER UpdatePublicKey
    Base64 Ed25519 public key used to verify the manifest. Defaults to
    STACKPILOT_UPDATE_PUBLIC_KEY.
.PARAMETER ComponentCatalogUrl
    Optional HTTPS URL of the signed component catalog. Defaults to
    STACKPILOT_COMPONENT_CATALOG_URL. Empty uses the built-in catalog.
.PARAMETER PayloadDir
    Folder containing payload.json and the component archives. When set, the
    payload is installed next to stackpilot.exe for offline setup.
.PARAMETER CertificatePath
    PFX/P12 certificate used to sign the executable and the installer.
.PARAMETER CertificatePassword
    Password for the signing certificate.
.PARAMETER CertificateThumbprint
    SHA-1 thumbprint of a code-signing certificate in the CurrentUser or
    LocalMachine store. Use this for a hardware-token or EV certificate, where
    the private key cannot be exported to a PFX. Defaults to
    STACKPILOT_CERTIFICATE_THUMBPRINT.
.PARAMETER TimestampUrl
    RFC 3161 timestamp server. Defaults to http://timestamp.digicert.com.
.PARAMETER SignTool
    Full path to signtool.exe. Defaults to PATH or the Windows SDK.
.PARAMETER SelfSigned
    Sign with a generated self-signed certificate. Useful for internal testing,
    but Windows SmartScreen still warns because the publisher is unknown.
.PARAMETER RequireSigning
    Fail instead of warning when no certificate is available. Use this for
    stable releases that are published to users.
.PARAMETER SkipSign
    Build without code signing even when a certificate is available.
#>
param(
    [switch]$SkipBuild,
    [string]$Version,
    [ValidateSet('stable', 'preview')]
    [string]$Channel = 'stable',
    [string]$UpdateUrl = $env:STACKPILOT_UPDATE_URL,
    [string]$UpdatePublicKey = $env:STACKPILOT_UPDATE_PUBLIC_KEY,
    [string]$ComponentCatalogUrl = $env:STACKPILOT_COMPONENT_CATALOG_URL,
    [string]$PayloadDir,
    [string]$CertificatePath = $env:STACKPILOT_CERTIFICATE,
    [string]$CertificatePassword = $env:STACKPILOT_CERTIFICATE_PASSWORD,
    [string]$CertificateThumbprint = $env:STACKPILOT_CERTIFICATE_THUMBPRINT,
    [string]$TimestampUrl = 'http://timestamp.digicert.com',
    [string]$SignTool,
    [switch]$SelfSigned,
    [switch]$RequireSigning,
    [switch]$SkipSign
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    $buildNumber = ''
    if (-not $Version) {
        $versionLine = Get-Content -Path 'pubspec.yaml' |
            Where-Object { $_ -match '^version:\s*(\S+)' } |
            Select-Object -First 1
        if ($versionLine -notmatch '^version:\s*(\S+)') {
            throw 'Could not read the version from pubspec.yaml.'
        }
        $versionValue = $Matches[1]
        $parts = $versionValue.Split('+', 2)
        $Version = $parts[0]
        if ($parts.Length -gt 1) {
            $buildNumber = $parts[1]
        }
    }

    # A pre-release version defaults to the preview channel unless -Channel is
    # given explicitly.
    if (-not $PSBoundParameters.ContainsKey('Channel') -and $Version.Contains('-')) {
        $Channel = 'preview'
    }

    # Inno Setup's VersionInfoVersion must be numeric, so a pre-release tag such
    # as 1.3.0-preview.1 is reduced to 1.3.0 for the file version.
    if ($Version -match '^(\d+)\.(\d+)(?:\.(\d+))?') {
        $patch = if ($Matches.Count -gt 3 -and $Matches[3]) { $Matches[3] } else { '0' }
        $numericVersion = "$($Matches[1]).$($Matches[2]).$patch"
    }
    else {
        $numericVersion = '1.0.0'
    }

    if ($UpdateUrl) {
        $manifestUri = $null
        if (-not [Uri]::TryCreate($UpdateUrl, [UriKind]::Absolute, [ref]$manifestUri) -or
            $manifestUri.Scheme -ne 'https') {
            throw 'UpdateUrl must be an absolute HTTPS URL.'
        }
        if (-not $UpdatePublicKey) {
            throw 'UpdatePublicKey is required when UpdateUrl is set.'
        }
    }
    if ($UpdatePublicKey -and -not $UpdateUrl) {
        Write-Warning 'UpdatePublicKey is set without UpdateUrl; updates stay disabled.'
    }
    if ($ComponentCatalogUrl) {
        $catalogUri = $null
        if (-not [Uri]::TryCreate($ComponentCatalogUrl, [UriKind]::Absolute, [ref]$catalogUri) -or
            $catalogUri.Scheme -ne 'https') {
            throw 'ComponentCatalogUrl must be an absolute HTTPS URL.'
        }
        if (-not $UpdatePublicKey) {
            throw 'ComponentCatalogUrl needs the update public key to verify the catalog.'
        }
    }

    $payloadFull = $null
    if ($PayloadDir) {
        if (-not (Test-Path $PayloadDir)) {
            throw "Payload folder not found: $PayloadDir"
        }
        $payloadFull = (Resolve-Path $PayloadDir).Path
        if (-not (Test-Path (Join-Path $payloadFull 'payload.json'))) {
            throw "Payload folder has no payload.json: $payloadFull"
        }
    }

    if (-not $SkipBuild) {
        $defines = @(
            "STACKPILOT_VERSION=$Version",
            "STACKPILOT_CHANNEL=$Channel"
        )
        if ($buildNumber) {
            $defines += "STACKPILOT_BUILD=$buildNumber"
        }
        if ($UpdateUrl) {
            $defines += "STACKPILOT_UPDATE_URL=$UpdateUrl"
        }
        if ($UpdatePublicKey) {
            $defines += "STACKPILOT_UPDATE_PUBLIC_KEY=$UpdatePublicKey"
        }
        if ($ComponentCatalogUrl) {
            $defines += "STACKPILOT_COMPONENT_CATALOG_URL=$ComponentCatalogUrl"
        }

        Write-Host "Building StackPilot $Version ($Channel)..." -ForegroundColor Cyan
        $defineArgs = $defines | ForEach-Object { "--dart-define=$_" }
        & flutter build windows --release @defineArgs
        if ($LASTEXITCODE -ne 0) {
            throw "flutter build failed with exit code $LASTEXITCODE."
        }
    }

    $releaseDir = Join-Path $root 'build\windows\x64\runner\Release'
    $exePath = Join-Path $releaseDir 'stackpilot.exe'
    if (-not (Test-Path $exePath)) {
        throw "Release build not found at $releaseDir. Run without -SkipBuild first."
    }

    function Resolve-SignTool {
        if ($SignTool) {
            if (-not (Test-Path $SignTool)) {
                throw "signtool.exe not found at $SignTool"
            }
            return (Resolve-Path $SignTool).Path
        }
        $command = Get-Command 'signtool.exe' -ErrorAction SilentlyContinue
        if ($command) {
            return $command.Source
        }
        $kitsRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
        if (Test-Path $kitsRoot) {
            $candidate = Get-ChildItem $kitsRoot -Directory |
                Sort-Object Name -Descending |
                ForEach-Object { Join-Path $_.FullName 'x64\signtool.exe' } |
                Where-Object { Test-Path $_ } |
                Select-Object -First 1
            if ($candidate) {
                return $candidate
            }
        }
        return $null
    }

    function Invoke-SignFile([string]$File) {
        if ($script:certThumbprint) {
            & $script:signTool sign /fd SHA256 /sha1 $script:certThumbprint `
                /tr $TimestampUrl /td SHA256 $File
        }
        else {
            & $script:signTool sign /fd SHA256 /f $CertificatePath `
                /p $CertificatePassword `
                /tr $TimestampUrl /td SHA256 $File
        }
        if ($LASTEXITCODE -ne 0) {
            throw "Signing failed for $File (exit code $LASTEXITCODE)."
        }
        Write-Host "Signed $File" -ForegroundColor Green
    }

    function Resolve-SigningThumbprint([string]$Thumbprint) {
        $clean = ($Thumbprint -replace '\s', '').ToUpperInvariant()
        foreach ($store in @('Cert:\CurrentUser\My', 'Cert:\LocalMachine\My')) {
            $candidate = Get-ChildItem $store -CodeSigningCert -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Thumbprint -eq $clean -and
                    $_.HasPrivateKey -and
                    $_.NotAfter -gt (Get-Date)
                } |
                Select-Object -First 1
            if ($candidate) {
                return $clean
            }
        }
        throw "No valid code-signing certificate with a private key was found for thumbprint $Thumbprint. Install the token/HSM certificate for this user or choose another store."
    }

    function New-SelfSignedCertificateFile {
        $pfxPath = Join-Path $root 'build\signing\stackpilot-selfsigned.pfx'
        if (Test-Path $pfxPath) {
            return $pfxPath
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $pfxPath) |
            Out-Null
        $certificate = New-SelfSignedCertificate `
            -Type CodeSigningCert `
            -Subject 'CN=StackPilot Self-Signed' `
            -FriendlyName 'StackPilot self-signed' `
            -KeyUsage DigitalSignature `
            -CertStoreLocation 'Cert:\CurrentUser\My' `
            -NotAfter (Get-Date).AddYears(2)
        $secure = ConvertTo-SecureString -String 'stackpilot' -Force -AsPlainText
        Export-PfxCertificate -Cert $certificate -FilePath $pfxPath `
            -Password $secure | Out-Null
        Write-Host "Created self-signed certificate at $pfxPath" -ForegroundColor Yellow
        return $pfxPath
    }

    $script:signTool = $null
    $script:certThumbprint = $null
    if ($SelfSigned -and ($CertificatePath -or $CertificateThumbprint)) {
        throw 'Use either -SelfSigned, -CertificatePath, or -CertificateThumbprint, not more than one.'
    }
    if ($CertificatePath -and $CertificateThumbprint) {
        throw 'Use either -CertificatePath or -CertificateThumbprint, not both.'
    }
    if ($SelfSigned -and -not $SkipSign) {
        $CertificatePath = New-SelfSignedCertificateFile
        $CertificatePassword = 'stackpilot'
        Write-Warning 'Self-signed certificate: the signature exists, but Windows SmartScreen still shows "Windows protected your PC" because the publisher is unknown. Use a CA-issued certificate for releases.'
    }

    if ($RequireSigning -and $SkipSign) {
        throw 'This build requires signing, but -SkipSign was passed.'
    }
    if ($RequireSigning -and -not $CertificatePath -and -not $CertificateThumbprint) {
        throw 'This build requires a signing certificate. Pass -CertificatePath/-CertificatePassword, -CertificateThumbprint, or -SelfSigned, or drop -RequireSigning.'
    }

    if (-not $SkipSign -and ($CertificatePath -or $CertificateThumbprint)) {
        if ($CertificatePath -and -not (Test-Path $CertificatePath)) {
            throw "Signing certificate not found: $CertificatePath"
        }
        $script:signTool = Resolve-SignTool
        if (-not $script:signTool) {
            throw 'signtool.exe was not found. Install the Windows SDK or pass -SignTool.'
        }
        if ($CertificateThumbprint) {
            $script:certThumbprint = Resolve-SigningThumbprint $CertificateThumbprint
        }
        Invoke-SignFile $exePath
    }
    elseif (-not $SkipSign) {
        Write-Warning 'No signing certificate supplied; stackpilot.exe and the installer will be unsigned. Windows SmartScreen will warn about an unknown publisher. See docs/RELEASE.md.'
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

    $isccArgs = @(
        "/DAppVersion=$Version",
        "/DAppNumericVersion=$numericVersion",
        "/DAppChannel=$Channel"
    )
    if ($payloadFull) {
        $isccArgs += "/DPayloadDir=$payloadFull"
    }

    Write-Host "Packaging with $iscc..." -ForegroundColor Cyan
    & $iscc @isccArgs (Join-Path $root 'installer\stackpilot.iss')
    if ($LASTEXITCODE -ne 0) {
        throw "Inno Setup failed with exit code $LASTEXITCODE."
    }

    $installer = Join-Path $outputDir "StackPilot-$Version-Setup.exe"
    if (-not (Test-Path $installer)) {
        throw "Expected installer was not created at $installer."
    }

    if ($script:signTool) {
        Invoke-SignFile $installer
    }

    $hash = (Get-FileHash -Algorithm SHA256 -Path $installer).Hash.ToLowerInvariant()
    $size = (Get-Item $installer).Length
    $sizeMb = [math]::Round($size / 1MB, 1)
    Write-Host "Installer ready: $installer ($sizeMb MB)" -ForegroundColor Green
    Write-Host "SHA-256: $hash"
    Write-Host "Channel: $Channel"

    # Handy for pasting into the signed update manifest.
    Write-Host "Manifest installer block:"
    Write-Host ('  "url": "https://<host>/StackPilot-{0}-Setup.exe",' -f $Version)
    Write-Host ('  "sha256": "{0}",' -f $hash)
    Write-Host ('  "size": {0}' -f $size)

    if (-not $script:signTool) {
        Write-Warning @'
Unsigned build: Windows SmartScreen shows "Windows protected your PC"
because it cannot verify the publisher. Sign stable releases with a CA-issued
certificate (or Azure Trusted Signing) before publishing. See docs/RELEASE.md.
'@
    }
}
finally {
    Pop-Location
}
