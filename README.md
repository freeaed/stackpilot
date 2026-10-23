# StackPilot

Pilot your local dev stack. StackPilot is a Windows desktop manager for local
web stacks. It creates and owns its own stack folder (`bin/`, `usr/`, `etc/`,
`www/`, `data/`), so it works on a clean machine with no Laragon install. An
existing Laragon folder can still be opened and managed, but it is optional.
The real Apache/Nginx, PHP, MySQL, and Node binaries underneath stay ordinary
Windows executables.

## Features

- **Your own stack** – on first run StackPilot offers to create a stack in
  `%LOCALAPPDATA%\StackPilot\stacks\default` (or any folder you choose). It
  writes `usr/stackpilot.ini`, a default profile, and the `bin/`, `etc/`,
  `www/`, `data/`, and `logs/` folders, so nothing else has to be installed
  first. **Open existing stack…** opens a StackPilot folder or a Laragon one.
- **Set up this stack** – a new stack has no server binaries yet. The **Set up
  stack** button (or the banner on the services panel) opens a wizard that
  downloads the official builds for Apache, PHP, MariaDB, Mailpit, Nginx,
  Node.js, Redis, and PostgreSQL, verifies every archive against a pinned
  SHA-256 checksum, installs it under `bin/<component>/<version>`, and writes a
  working config for the stack. MySQL-compatible databases come from MariaDB
  (drop-in `mysqld.exe`); a specific MySQL build can still be added by URL.
  Data folders and system tables are initialised by StackPilot itself.
- **Service control** – start and stop Apache, Nginx, MySQL, PostgreSQL, Redis,
  Memcached, and Mailpit. Services started by StackPilot are owned and stopped
  with the app; services started elsewhere are adopted only when their
  executable lives inside the current stack.
- **Version switching** – click the **Version** control on any PHP, MySQL,
  PostgreSQL, Apache, Nginx, Node.js, Redis, Memcached, or Mailpit card, then
  choose an installed version. StackPilot updates `usr/profile/default.ini` and
  the stack marker (`usr/stackpilot.ini`, or `usr/laragon.ini` on Laragon
  stacks), plus `bin/laragon/laragon.cmd` PATH entries when that file exists,
  Apache's `mod_php.conf`, the active `php.ini` extension directory, the MySQL
  and PostgreSQL ports, and the PHP/Apache module DLL names. The menu lists
  versions already present under `bin/php`, `bin/mysql`, etc., and offers
  **Add version…** even when a component has no versions yet.
- **Add versions** – import an extracted version folder, install from a local
  ZIP, or download and install from a URL. Use this when the version you want
  (for example PHP 8.1 or 8.4, or another MySQL release) is not in the menu yet.
  The dialog links to the official download pages. Stock Apache downloads are
  pointed at this stack's `www` and `etc/apache2` folders, and PHP/MySQL versions
  get a working `php.ini`/`my.ini` when one is missing. A new PHP `php.ini`
  enables the extensions Laragon turns on by default.
- **Switch stacks at runtime** – use **Change stack** in the header to point the
  app at another stack folder. The version menus immediately reflect that
  stack's installed versions.
- **Stacks folder** – open **Settings → Stacks** to set the parent folder that
  contains your stacks. StackPilot lists every stack it finds there and switches
  with **Use**. The folder and the last stack are remembered in
  `%APPDATA%\StackPilot\preferences.json`, so the next launch opens the same
  stack.
- **Stack settings** – change the document root, data directory, automatic
  virtual hosts, Apache SSL, enabled services, MySQL and PostgreSQL ports, and
  common PHP `php.ini` limits in one dialog.
- **Projects and virtual hosts** – list projects under the document root,
  detect missing/outdated vhost configs and hosts entries, and generate missing
  `auto.<project>.test.conf` files.
- **phpMyAdmin** – the **Database** action opens phpMyAdmin when it is already
  in the document root. Otherwise it installs the official "all languages" ZIP
  into `www/phpmyadmin` and writes a config that matches the stack MySQL port
  and a passwordless local root user. Tool folders such as `phpmyadmin` are
  not listed as projects.
- **Tray and window behaviour** – minimizing or closing StackPilot hides it to
  the notification area so started services keep running. Click the tray icon
  (or choose **Show StackPilot**) to bring the window back, and choose
  **Exit StackPilot** to quit. Exiting stops the services StackPilot owns.
- **Service logs** – the **Logs** action opens the current stack's service logs:
  Apache and Nginx access/error logs, MySQL `.err` and slow-query logs,
  PostgreSQL collector logs, and Redis logs. The viewer follows the file while
  it grows, shows only the newest lines of a large log, and can open the log
  folder.
- **Local only** – no telemetry, no donation prompts.

## Configuration safety

Every file StackPilot rewrites is backed up once as
`<file>.stackpilot.bak`. Existing files are updated in place and unrelated
comments/formatting are preserved. Older `.laraserver.bak` backups are also
recognized so an existing backup is never overwritten. Version changes for
running services are blocked; stop the service first so the new version can
start cleanly. StackPilot only writes inside the stack folder it was given.

## Running

```powershell
flutter run -d windows -- --stack-root=D:\stacks\default
```

Or set the stack root through the environment:

```powershell
$env:STACKPILOT_STACK_ROOT = 'D:\stacks\default'
flutter run -d windows
```

On first launch, with no saved stack, StackPilot shows a welcome screen. Choose
**Create stack** to build one at `%LOCALAPPDATA%\StackPilot\stacks\default` (or
browse to another folder), or **Open existing stack…** to use a folder that is
already a StackPilot or Laragon stack.

Without either option, StackPilot opens the stack used last, then the first
stack inside the saved stacks folder, then the first stack inside
`%LOCALAPPDATA%\StackPilot\stacks`. The old `C:\laragon-wamp` and `C:\laragon`
locations are only checked when nothing else was found. You can also click
**Change stack** in the header to browse to a stack folder while the app is
running, or set the stacks folder in **Settings → Stacks**. Stop running
services first so the next stack starts cleanly.

The **Version** menus only show builds that are physically installed in the
selected stack. To use a PHP or MySQL version that is not listed, choose
**Add version…** from the menu (folder, ZIP, or URL), or switch to the stack
that already contains it.

### Setting up a stack

A freshly created stack is empty: it has the folder layout but no binaries.
Press **Set up stack** in the services panel, keep the recommended components
(Apache, PHP, MariaDB, Mailpit), and confirm. StackPilot downloads each build
from its official source, checks the SHA-256 digest, installs it into
`bin/<component>/<version>`, generates the config, and initialises the data
folder (`data/mysql` system tables, `data/postgres` via `initdb`). Progress is
shown per component; a failed download does not stop the rest, and running the
wizard again reuses what is already installed.

Everything is cached locally, so after the first run the stack works offline.
For a machine without network access, copy the archive or an extracted folder
in through **Add version…**.

Where things live inside a stack:

```
<stack>/bin/<component>/<version>/   installed binaries
<stack>/etc/apache2/, etc/nginx/     generated server configs
<stack>/data/                        MySQL/PostgreSQL/Redis data
<stack>/www/                         document root
<stack>/logs/                        service logs
<stack>/usr/stackpilot.ini           stack marker and active versions
```

## Roadmap

`docs/ROADMAP.md` tracks the next stages. Stage 2 (independence from Laragon)
is complete through self-provisioning; the next stage removes the remaining
Laragon-specific details such as the launcher script and config patching.

## Branding

The app icon and in-app mark live in `assets/branding/`, and the Windows icon is
`windows/runner/resources/app_icon.ico`. Regenerate them with:

```powershell
python tool/generate_branding.py
```

## Tests

```powershell
flutter analyze
flutter test
```

Build the Windows executable with:

```powershell
flutter build windows --release
# build\windows\x64\runner\Release\stackpilot.exe
```

Use `--debug` if you want the debug build at
`build\windows\x64\runner\Debug\stackpilot.exe`.

## Installer

Build the release app and package it with Inno Setup:

```powershell
powershell -ExecutionPolicy Bypass -File tool\build_installer.ps1
# build\installer\StackPilot-<version>-Setup.exe
```

The script reads the version from `pubspec.yaml`, or accepts
`-Version 1.2.0`. Pass `-SkipBuild` to repackage an existing release build.
Inno Setup 6 is required; install it with
`winget install --id JRSoftware.InnoSetup --exact`. A local copy under
`.tools\InnoSetup` is also picked up automatically.

The installer is per-user, has no UAC prompt, and installs to
`%LOCALAPPDATA%\Programs\StackPilot`. It can optionally create a desktop
shortcut. StackPilot does not bundle Laragon or any server binaries: on first
launch it creates its own stack and downloads the components you pick, so the
machine needs a network connection once.

