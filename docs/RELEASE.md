# Releasing StackPilot

This document covers the release pipeline: build identity, code signing, the
installer, signed updates, release channels, the offline payload, and CI.

## Release shape

A release is one per-user Inno Setup installer:

```
StackPilot-<version>-Setup.exe
```

The installer contains the Flutter Windows build. It does **not** contain
server binaries by default; those are downloaded by the setup wizard from the
pinned catalog. A release may optionally carry an offline payload folder next
to `stackpilot.exe`.

Installing replaces only the StackPilot application. Stacks, `bin/` versions,
sites, and databases stay where they are.

## Versioning and channels

- `pubspec.yaml` holds the marketing version and build number, for example
  `1.3.0+42`.
- A tag `v1.3.0` is a **stable** release.
- A tag with a pre-release suffix, such as `v1.3.0-preview.1`, is a **preview**
  release.
- `build_installer.ps1` also treats a `-Version` that contains `-` as preview
  unless `-Channel` is passed explicitly.
- Stable builds follow the stable channel. Preview builds follow the preview
  channel, which also accepts a stable release when that is newer.

`AppVersion` compares versions semantically: `1.2.10` is newer than `1.2.9`,
and `2.0.0-beta.1` is older than `2.0.0`. Build metadata after `+` is ignored.

## Build identity

`tool/build_installer.ps1` compiles the release identity into the executable
with `--dart-define`:

| Define | Meaning |
| --- | --- |
| `STACKPILOT_VERSION` | Marketing version, for example `1.3.0` |
| `STACKPILOT_BUILD` | Build number from `pubspec.yaml` |
| `STACKPILOT_CHANNEL` | `stable` or `preview` |
| `STACKPILOT_UPDATE_URL` | HTTPS URL of the signed update manifest |
| `STACKPILOT_UPDATE_PUBLIC_KEY` | Base64 Ed25519 public key |

A build with no update URL or no public key never checks for updates. That is
the normal state for local development.

## Local release build

```powershell
# Unsigned local build (warns, still produces an installer).
powershell -ExecutionPolicy Bypass -File tool\build_installer.ps1 -SkipSign

# Repackage an existing release build.
powershell -ExecutionPolicy Bypass -File tool\build_installer.ps1 -SkipBuild -SkipSign
```

Useful options:

```text
-Version 1.3.0             override the pubspec version
-Channel preview           compile the preview channel
-UpdateUrl https://...     signed manifest URL
-UpdatePublicKey <base64>  Ed25519 public key
-PayloadDir build\payload  include the offline payload
-CertificatePath cert.pfx  sign the exe and installer
-CertificatePassword ...   certificate password
-SignTool C:\...\signtool.exe
-SkipSign                  never sign
```

The script prints the installer SHA-256 and a ready-to-paste `installer` block
for the update manifest.

## Code signing

Published builds should sign both `stackpilot.exe` and the installer. The
script uses `signtool.exe` with SHA-256 and a DigiCert timestamp:

```powershell
$env:STACKPILOT_CERTIFICATE = 'C:\keys\stackpilot.pfx'
$env:STACKPILOT_CERTIFICATE_PASSWORD = '...'
powershell -ExecutionPolicy Bypass -File tool\build_installer.ps1
```

`signtool.exe` is found on `PATH` or in the Windows 10/11 SDK. Without a
certificate the script warns and produces an unsigned installer; use that only
for local testing.

For CI, store the PFX as base64 in the `WINDOWS_CERT_PFX_BASE64` secret and its
password in `WINDOWS_CERT_PASSWORD`.

## Update manifest

The manifest is JSON served over HTTPS. The app fetches the exact bytes and
verifies a detached Ed25519 signature from `<manifest-url>.sig` before parsing
anything.

```json
{
  "schema": 1,
  "generated": "2026-10-23T09:00:00Z",
  "channels": {
    "stable": {
      "version": "1.3.0",
      "notes": "Apache config fixes and faster setup.",
      "published": "2026-10-23T09:00:00Z",
      "installer": {
        "url": "https://github.com/freeaed/stackpilot/releases/download/v1.3.0/StackPilot-1.3.0-Setup.exe",
        "sha256": "<64 lowercase hex characters>",
        "size": 48234496
      }
    },
    "preview": {
      "version": "1.4.0-preview.1",
      "notes": "Preview build.",
      "installer": {
        "url": "https://github.com/freeaed/stackpilot/releases/download/v1.4.0-preview.1/StackPilot-1.4.0-preview.1-Setup.exe",
        "sha256": "<64 lowercase hex characters>",
        "size": 48300000
      }
    }
  }
}
```

Rules the app enforces:

- Only HTTPS manifest and installer URLs.
- Manifest schema must be `1`.
- Every channel must have a valid semantic version and SHA-256.
- The signature must verify against the public key compiled into the build.
- The downloaded installer must match the manifest size (when present) and
  SHA-256 before it is launched.
- Unknown channel names are rejected.

### Generate the signing key

```powershell
dart run tool\update_keys.dart generate build\keys
```

This writes `update-private.key` and `update-public.key`. Keep the private key
offline and out of the repository. Pass the public key to release builds:

```powershell
powershell -ExecutionPolicy Bypass -File tool\build_installer.ps1 `
  -UpdateUrl https://freeaed.github.io/stackpilot/updates/manifest.json `
  -UpdatePublicKey (Get-Content build\keys\update-public.key -Raw).Trim()
```

### Sign the manifest

```powershell
dart run tool\update_keys.dart sign build\update-manifest.json `
  build\keys\update-private.key
# writes build\update-manifest.json.sig
```

Publish the manifest bytes exactly as signed:

```
https://freeaed.github.io/stackpilot/updates/manifest.json
https://freeaed.github.io/stackpilot/updates/manifest.json.sig
```

Do not reformat or re-encode the manifest after signing; the signature covers
the exact bytes.

## Hosting

StackPilot uses two GitHub surfaces, both free and versioned with the project:

| Artifact | Host | URL |
| --- | --- | --- |
| Installer and `SHA256SUMS.txt` | GitHub Releases | `https://github.com/freeaed/stackpilot/releases/download/<tag>/<file>` |
| `manifest.json` and `.sig` | GitHub Pages | `https://freeaed.github.io/stackpilot/updates/manifest.json` |

Release assets are per tag, so their URLs change with every release. That is
fine for the `installer.url` inside the manifest, which is rewritten each time.
The manifest URL is different: it is compiled into every build and must never
change, so it lives on Pages, which serves the `gh-pages` branch.

Pages is configured as *branch: `gh-pages`, folder: `/`*. The `updates/`
folder in that branch holds exactly two files, copied byte for byte.

Publishing the manifest after signing:

```powershell
powershell -ExecutionPolicy Bypass -File tool\publish_manifest.ps1 `
  -ManifestPath build\update-manifest.json
```

The script refuses a manifest that is not valid JSON, is not schema `1`, or
lists no channels. It then commits `updates/manifest.json` and
`updates/manifest.json.sig` to `gh-pages` and pushes. Pages rebuilds in under a
minute. Use `-SkipPush` to inspect the commit first.

Because signing needs the offline private key, the manifest is published from a
maintainer machine, never from CI.

### How an update runs

1. On startup (when enabled) or from **Settings → Updates**, the app fetches
   and verifies the manifest.
2. It compares the offered version with its own and picks the channel's
   release.
3. **Download and install** fetches the installer into
   `%LOCALAPPDATA%\StackPilot\updates`, verifies the checksum, launches the
   installer silently, and exits.
4. The installer replaces the app. Stacks are untouched.

### Rollback

Downloaded installers are kept in `%LOCALAPPDATA%\StackPilot\updates`.
**Settings → Updates → Downloaded installers** lists them newest first and can
run an older one. That is the supported rollback path; the previous two older
installers are pruned automatically.

## Offline payload

A release can include the pinned component archives so a first run works
without a network connection.

```powershell
dart run tool\build_payload.dart --output build\payload
powershell -ExecutionPolicy Bypass -File tool\build_installer.ps1 `
  -PayloadDir build\payload -SkipSign
```

`build_payload.dart` downloads every catalog release, verifies the catalog
SHA-256, and writes `payload.json`:

```json
{
  "schema": 1,
  "generated": "2026-10-23T09:00:00Z",
  "components": [
    {
      "id": "php-8.5.12",
      "file": "php-8.5.12-Win32-vs17-x64.zip",
      "sha256": "660f...",
      "size": 36446352
    }
  ]
}
```

Options: `--only php,apache,mysql-11.4.13`, `--keep` (reuse archives that still
match), `--output <dir>`.

The payload is installed to `<install dir>\payload`. The setup wizard detects
it automatically (or from `STACKPILOT_PAYLOAD`) and shows how many components
are available offline. Trust is decided by the catalog, not the payload: an
archive is used only when its SHA-256 matches the pinned release, and the
checksum is verified again before extraction. A stale or tampered payload is
ignored and the component downloads normally.

## CI

`.github/workflows/ci.yml` runs on Windows:

- Push and pull request: `flutter pub get`, `flutter analyze`, `flutter test`.
- Tag `v*`: the same checks, then `tool/build_installer.ps1`, a
  `SHA256SUMS.txt`, an installer artifact, and a GitHub release.

Repository variables:

| Name | Purpose |
| --- | --- |
| `STACKPILOT_UPDATE_URL` | Manifest URL compiled into release builds |
| `STACKPILOT_UPDATE_PUBLIC_KEY` | Base64 Ed25519 public key |
| `STACKPILOT_INCLUDE_PAYLOAD` | `true` to build and bundle the payload |

Repository secrets:

| Name | Purpose |
| --- | --- |
| `WINDOWS_CERT_PFX_BASE64` | Base64 PFX for code signing |
| `WINDOWS_CERT_PASSWORD` | PFX password |

With no certificate secret the release job still succeeds and uploads an
unsigned installer, which is useful for previews but not for public stable
releases.

## Release checklist

1. Update `pubspec.yaml` (`version: X.Y.Z+N`) and the catalog if needed.
2. `flutter analyze` and `flutter test` are clean.
3. Build the payload if this release ships offline (`build_payload.dart`).
4. Build and sign with the update URL and public key.
5. Smoke-test on a clean Windows profile: install, create a stack, set up the
   starter components, start Apache/PHP/MySQL, open a site.
6. Publish the installer, update `manifest.json`, sign it, and publish it with
   `tool\publish_manifest.ps1`.
7. Tag the commit (`vX.Y.Z` or `vX.Y.Z-preview.N`) and let CI publish the
   artifacts.
