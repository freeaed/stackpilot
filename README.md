# StackPilot

Pilot your local dev stack. StackPilot is a Windows desktop manager for
Laragon-compatible stacks (`bin/`, `usr/`, `etc/`, `www/`), built with Flutter.
It gives you a focused UI for the things you change most without replacing the
real Apache/Nginx, PHP, MySQL, and Node binaries underneath.

## Features

- **Service control** – start and stop Apache, Nginx, MySQL, Redis, Memcached,
  and Mailpit. Services started by StackPilot are owned and stopped with the
  app; services started by Laragon can be adopted and stopped too.
- **Version switching** – click the **Version** control on any PHP, MySQL,
  Apache, Nginx, Node.js, Redis, Memcached, or Mailpit card, then choose an
  installed version. StackPilot updates `usr/profile/default.ini` (or
  `usr/laragon.ini` on older stacks), `bin/laragon/laragon.cmd` PATH entries,
  Apache's `mod_php.conf`, the active `php.ini` extension directory, and the
  PHP/Apache module DLL names. The menu lists versions already present under
  `bin/php`, `bin/mysql`, etc.
- **Add versions** – import an extracted version folder, install from a local
  ZIP, or download and install from a URL. Use this when the version you want
  (for example PHP 8.1 or 8.4, or another MySQL release) is not in the menu yet.
  The dialog links to the official download pages. Stock Apache downloads are
  pointed at this stack's `www` and `etc/apache2` folders, and PHP/MySQL versions
  get a working `php.ini`/`my.ini` when one is missing. A new PHP `php.ini`
  enables the extensions Laragon turns on by default.
- **Switch stacks at runtime** – use **Change stack** in the header to point the
  app at another Laragon-compatible folder, such as `C:\laragon` instead of
  `C:\laragon-wamp`. The version menus immediately reflect that stack's
  installed versions.
- **Stack settings** – change the document root, Laragon data directory,
  automatic virtual hosts, Apache SSL, enabled services, MySQL port, and
  common PHP `php.ini` limits in one dialog.
- **Projects and virtual hosts** – list projects under the document root,
  detect missing/outdated vhost configs and hosts entries, and generate missing
  `auto.<project>.test.conf` files.
- **Local only** – no telemetry, no donation prompts.

## Configuration safety

Every file StackPilot rewrites is backed up once as
`<file>.stackpilot.bak`. Existing files are updated in place and unrelated
comments/formatting are preserved. Older `.laraserver.bak` backups are also
recognized so an existing backup is never overwritten. Version changes for
running services are blocked; stop the service first so the new version can
start cleanly.

## Running

```powershell
flutter run -d windows -- --stack-root=C:\laragon
```

Or set the stack root through the environment:

```powershell
$env:STACKPILOT_STACK_ROOT = 'C:\laragon'
flutter run -d windows
```

Without either option, StackPilot looks in `C:\laragon-wamp` and `C:\laragon`.
You can also click **Change stack** in the header to browse to a stack folder
while the app is running. Stop running services first so the next stack starts
cleanly.

The **Version** menus only show builds that are physically installed in the
selected stack. To use a PHP or MySQL version that is not listed, choose
**Add version…** from the menu (folder, ZIP, or URL), or switch to the stack
that already contains it.

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
