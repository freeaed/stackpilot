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
  A Laragon folder can be **adopted in place**: StackPilot writes
  `usr/stackpilot.ini` beside `usr/laragon.ini`, selects the versions Laragon
  had active, and regenerates its own configs. Files are not copied or moved,
  and Laragon can still open the folder.
- **Set up this stack** – a new stack has no server binaries yet. The **Set up
  stack** button (or the banner on the services panel) opens a wizard that
  downloads the official builds for Apache, PHP, MariaDB, Mailpit, Nginx,
  Node.js, Redis, and PostgreSQL, verifies every archive against a pinned
  SHA-256 checksum, installs it under `bin/<component>/<version>`, and writes a
  working config for the stack. MySQL-compatible databases come from MariaDB
  (drop-in `mysqld.exe`); a specific MySQL build can still be added by URL.
  Data folders and system tables are initialised by StackPilot itself.
- **Service control** - start and stop Apache, Nginx, MySQL, PostgreSQL, Redis,
  Memcached, and Mailpit. Services started by StackPilot are owned and stopped
  with the app; services started elsewhere are adopted only when their
  executable lives inside the current stack. Stops are graceful first
  (`httpd -k stop`, `nginx -s quit`, `mysqladmin shutdown`, `pg_ctl stop -m
  fast`, `redis-cli shutdown`) and force-kill only after 10 seconds. A start
  waits for the port to accept connections and for the process to stay alive
  before the card shows Running. When a port is taken, the dialog names the PID
  and program holding it and offers to move the service to another port.
  A running `Laragon.exe` triggers a warning because it rewrites the same
  Apache/MySQL config files.
- **Version switching** – click the **Version** control on any PHP, MySQL,
  PostgreSQL, Apache, Nginx, Node.js, Redis, Memcached, or Mailpit card, then
  choose an installed version. StackPilot updates `usr/profile/default.ini` and
  the stack marker (`usr/stackpilot.ini`, or `usr/laragon.ini` on Laragon
  stacks), regenerates `bin/stackpilot.cmd` for its own stacks (Laragon stacks
  keep `bin/laragon/laragon.cmd`), Apache's `mod_php.conf`, the active `php.ini`
  extension directory, the MySQL and PostgreSQL ports, and the PHP/Apache
  module DLL names. The menu lists versions already present under `bin/php`,
  `bin/mysql`, etc., and offers **Add version…** even when a component has no
  versions yet.
- **Add versions** – import an extracted version folder, install from a local
  ZIP, or download and install from a URL. Use this when the version you want
  (for example PHP 8.1 or 8.4, or another MySQL release) is not in the menu yet.
  The dialog links to the official download pages. Stock Apache downloads are
  pointed at this stack's `www` and `etc/apache2` folders, and PHP/MySQL versions
  get a working `php.ini`/`my.ini` when one is missing. A new PHP `php.ini`
  enables the extensions Laragon turns on by default.
- **Native launcher** – every StackPilot stack gets `bin\stackpilot.cmd` and a
  `bin\stackpilot.ps1` companion. They put the active PHP, Node.js, Apache,
  MySQL, PostgreSQL, Redis, Memcached, and Mailpit binaries on `PATH`
  (`OPENSSL_CONF` is set too) and are regenerated whenever you switch versions.
- **Terminal** – the **Terminal** action opens a real console window with the
  launcher applied, so `php -v`, `mysql --version`, and `node -v` resolve to
  this stack. Choose Command Prompt, PowerShell, or Windows Terminal in
  **Settings → General**; Automatic prefers Windows Terminal when installed.
  Each project row has its own **Open terminal here** button that starts in
  that project's folder.
- **Apache config from a template** – StackPilot writes a complete `httpd.conf`
  for its own stacks: `ServerRoot`, `Listen`, `ServerName`, the module set,
  document root, log paths, vhost includes, and optional SSL. The Apache Lounge
  original is kept next to it as `conf\httpd.conf.vendor`. Laragon stacks keep
  their vendor config and are patched in place.
- **Switch stacks at runtime** – use **Change stack** in the header to point the
  app at another stack folder. The version menus immediately reflect that
  stack's installed versions.
- **Stacks folder** – open **Settings → Stacks** to set the parent folder that
  contains your stacks. StackPilot lists every stack it finds there and can
  **Open**, **Rename**, **Move**, **Delete**, or create a new one. The folder
  and the last stack are remembered in `%APPDATA%\StackPilot\preferences.json`,
  so the next launch opens the same stack.
- **Stack settings** – change the document root, data directory, automatic
  virtual hosts, Apache SSL, enabled services, MySQL and PostgreSQL ports, and
  common PHP `php.ini` limits in one dialog.
- **Projects and virtual hosts** – list projects under the document root,
  detect missing/outdated vhost configs and hosts entries, and generate missing
  `auto.<project>.test.conf` files. **Add site** creates a folder, a vhost, and
  a hosts entry in one step for a project that was set up by hand. **Add hosts
  entries** writes a managed `127.0.0.1` block to the hosts file and leaves
  unrelated lines alone; Windows shows one administrator prompt for the write,
  and if it is declined StackPilot shows the exact lines to paste instead.
- **phpMyAdmin** - the **Database** action installs the pinned phpMyAdmin ZIP
  into `etc/apps/phpmyadmin`, outside the web root, and serves it at
  `http://127.0.0.1/phpmyadmin/` through an Apache alias (and an nginx
  `location`, when nginx is the server). The generated config matches the stack
  MySQL port and a passwordless local root user. The alias uses
  `Require all granted` and replaces Laragon's vendor alias that points at a
  missing `etc/apps/phpMyAdmin` folder. Apache binds to `127.0.0.1:80` by
  default (change it under **Settings → General → Expose Apache on the LAN**).
  Opening phpMyAdmin validates the config with `httpd -t`, restarts Apache
  (asking first when it was started outside StackPilot), then requests the page
  and reports the HTTP status. An incomplete folder left by an older install is
  replaced instead of reported as installed. Tool folders such as
  `phpmyadmin` are not listed as projects.
- **Tray and window behaviour** – minimizing or closing StackPilot hides it to
  the notification area so started services keep running. Click the tray icon
  (or choose **Show StackPilot**) to bring the window back, and choose
  **Exit StackPilot** to quit. Exiting stops the services StackPilot owns.
- **Service logs** – the **Logs** action opens the current stack's service logs.
  Paths come from each service's own config (`ErrorLog`/`CustomLog`,
  `log-error`, nginx `error_log`/`access_log`, Redis `logfile`,
  PostgreSQL `log_directory`, PHP `error_log`), with fallbacks for Laragon and
  StackPilot layouts. StackPilot also captures every service's stdout/stderr
  into `<stack>/logs/<service>-console.log` (rotated at 5 MB), so Mailpit and
  early crashes are visible too. The viewer follows the file, searches lines,
  filters by level, clears a file, and opens its folder. A service that exits
  within five seconds of starting opens a dialog with its last lines.
- **Local only** – no telemetry, no donation prompts.

- **Updates** – release builds check a signed update manifest, verify the
  installer's SHA-256, and can install a newer version in place. Choose the
  **Stable** or **Preview** channel in **Settings → Updates**. Downloaded
  installers are kept so an older version can be reinstalled if a new one
  misbehaves. Updates never touch stacks or data.
- **Offline payload** – a release can ship the pinned component archives next
  to the app. The setup wizard uses them automatically and falls back to
  downloading anything the payload does not carry. Archives are still checked
  against the catalog SHA-256, so a stale payload is ignored.
- **Logging and diagnostics** – StackPilot appends to
  `%LOCALAPPDATA%\StackPilot\logs\stackpilot.log`, flushes every line so the
  last entries survive a crash, and rotates at 2 MB. **Settings →
  Diagnostics** creates a ZIP report with logs, build and OS details, stack
  paths, component versions, and the stack marker. It contains no database
  data, project files, passwords, or environment variables.

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

The installer writes `%APPDATA%\StackPilot\preferences.json` with the folder
chosen on its **Where should your stacks live?** page. For a manual launch,
`--stacks-folder=D:\StackPilot` overrides the saved folder for that run.

On first launch, with no saved stack, StackPilot shows a welcome screen. Choose
**Create stack** to build one at `<stacks folder>\default` (or browse to another
folder), or **Open existing stack…** to use a folder that is already a
StackPilot or Laragon stack. Laragon folders found on the PC appear as an
optional **Import** card; they are never opened automatically.

Without either option, StackPilot opens the stack used last, then the first
stack inside the saved stacks folder, then the first stack inside
`%LOCALAPPDATA%\StackPilot\stacks`, and otherwise shows the welcome screen. You
can also click **Change stack** in the header to browse to a stack folder while
the app is running, or set the stacks folder in **Settings → Stacks**, where a
stack can also be created, renamed, moved, or deleted. Stop running services
before moving or switching a stack.

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

Everything is cached locally in
`%LOCALAPPDATA%\StackPilot\cache\downloads\<sha256>.zip`, so installing the same
build into another stack, or retrying after a failed extraction, does not
download it again. **Settings → Diagnostics** shows the cache and can clear it.
If the release includes an offline payload, the wizard says how many components
are available on disk and installs those first. For a machine without network
access and without a payload, copy the archive or an extracted folder in
through **Add version…**.

Downloads try the primary URL, then every mirror, resume a partial file when
the server supports it, retry dropped connections, and use the system proxy.
A checksum mismatch shows the expected and received digests and offers
**Retry**, **Try mirror**, or **Choose ZIP…** so a build can be installed from
a file that was downloaded elsewhere. Release builds can also fetch a signed
`components.json` catalog, which lets a maintainer fix a moved URL or a new
digest without shipping a new app; without one StackPilot uses the catalog
compiled into the binary.

**phpMyAdmin** is an optional ready-made app in the setup wizard. It installs
into `etc/apps/phpmyadmin` (outside the web root) and is served at
`http://127.0.0.1/phpmyadmin/` through an Apache alias.

Where things live inside a stack:

```
<stack>/bin/<component>/<version>/   installed binaries
<stack>/etc/apache2/, etc/nginx/     generated server configs
<stack>/etc/apps/phpmyadmin/         optional phpMyAdmin install
<stack>/data/                        MySQL/PostgreSQL/Redis data
<stack>/www/                         document root
<stack>/logs/                        service logs and <service>-console.log
<stack>/usr/stackpilot.ini           stack marker and active versions
```

The download cache lives outside the stack at
`%LOCALAPPDATA%\StackPilot\cache\downloads\<sha256>.zip`; StackPilot's own log
is `%LOCALAPPDATA%\StackPilot\logs\stackpilot.log`.

## Roadmap

`docs/ROADMAP.md` tracks the next stages. Stage 2 (independence from Laragon)
is complete: StackPilot owns its launcher, Apache config, hosts entries, ports,
and can adopt an existing Laragon folder in place. Stage 3 (packaging,
updates, logging, and release engineering) is complete as well; see
`docs/RELEASE.md` for how a release is built, signed, and published.
`docs/FIX_PLAN.md` records the 2026-10 reliability pass that closed the gaps
found on a machine with Laragon installed.

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
dart run tool/verify_catalog.dart   # HEADs every catalog URL and mirror
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
shortcut. It also asks two questions the app used to ask later: **where the
stacks should live** (with a free-space check) and **which components to get**
(Apache, PHP, MariaDB, Mailpit, Nginx, Node.js, Redis, PostgreSQL) with
*download now / ask on first launch / don't download*. The answers go to
`%APPDATA%\StackPilot\preferences.json`, and the first launch opens the setup
wizard pre-filled. StackPilot does not bundle Laragon or any server binaries by
default: on first launch it creates its own stack and downloads the components
you pick, so the machine needs a network connection once. Pass `-PayloadDir` to
include an offline payload, `-UpdateUrl`/`-UpdatePublicKey` to enable signed
updates, `-ComponentCatalogUrl` to use a signed component catalog, and
`-CertificatePath` to sign the executable and installer. See `docs/RELEASE.md`
for the full release, signing, manifest, payload, and CI workflow.

Add `-RequireSigning` to a stable release so an unsigned installer fails the
build instead of shipping. Unsigned builds make Windows Defender SmartScreen
show "Windows protected your PC" because it cannot verify the publisher;
`docs/RELEASE.md` explains the certificate options and why a self-signed
certificate does not remove that prompt.

The signed updater metadata publishes to GitHub Pages with
`tool\publish_manifest.ps1 -ManifestPath build\update-manifest.json
-CatalogPath build\components.json`. Add
`-InstallerPath build\installer\<file>.exe` to serve the binary from
`https://<user>.github.io/<repo>/downloads/` as well; the script checks it
against the manifest size and SHA-256 first. The updater accepts either a Pages
or a Releases URL.

