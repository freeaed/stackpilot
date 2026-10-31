# StackPilot roadmap

This file tracks the stages beyond 1.0. The current stage is **Stage 3:
distribution and release engineering**.

> **2026-10 reliability pass:** the items in Stage 2 were marked done, but a
> real Windows machine with Laragon installed exposed gaps (automatic legacy
> fallback, a stacks root that never changed, dead PHP/Apache download pins, an
> empty log window, a terminal that exited instantly, and phpMyAdmin 403s).
> `docs/FIX_PLAN.md` records the symptoms and the fixes; the list below is now
> genuinely complete and re-verified by the test suite.

## Stage 2 — StackPilot-owned stacks

**Goal:** a clean Windows machine with no Laragon installed can run StackPilot
and get a working local stack. Laragon becomes an optional import source, never
a requirement.

### 2a. Stack identity (done)

- [x] A stack is recognised by `usr/stackpilot.ini` **or** `usr/laragon.ini`.
- [x] `StackLayout` reports its `flavor` and the marker file it read.
- [x] Version/settings writes go to whichever marker the stack uses.
- [x] No UI path says Laragon is required.

### 2b. Create a stack from scratch (done)

- [x] `StackBootstrap.create()` builds `bin/`, `usr/profile/`, `etc/`, `www/`,
      `data/`, `logs/` and writes `usr/stackpilot.ini` plus a default profile.
- [x] First-run onboarding: create a stack at
      `%LOCALAPPDATA%\StackPilot\stacks\default`, choose another folder, or open
      an existing stack.
- [x] Startup resolves the StackPilot stacks folder before any legacy Laragon
      location.

### 2c. Provision the stack with its own binaries (done)

- [x] Component catalog: version, download URL, archive layout, checksum, and
      the config template for each of PHP, Apache, Nginx, MySQL, MariaDB,
      PostgreSQL, Node.js, Redis, Memcached, Mailpit.
      Memcached has no pinned Windows build, so it is import-only for now;
      MariaDB 11.4 is the MySQL-compatible download for the MySQL card.
- [x] Download → verify → extract → place into `bin/<component>/<version>` →
      generate a working config (`httpd.conf`, `php.ini`, `my.ini`,
      `nginx.conf`, `redis.conf`, `initdb` for PostgreSQL).
- [x] "Set up this stack" wizard: pick components and versions, watch progress,
      and see a failure summary. Retrying is a normal re-run; components that
      are already installed are reused.
- [x] Data directories are created and initialised by StackPilot (MySQL system
      tables, PostgreSQL `initdb`), never borrowed from another tool.
- [x] Distribution model: **download on setup** from official sources with
      SHA-256 verification and a local cache. Offline installs stay possible
      through **Add version → ZIP/folder**. Stage 3 adds an optional bundled
      payload (`-PayloadDir`) for first runs without a network.

### 2d. De-Laragon the details (done)

- [x] Replace remaining `bin/laragon/laragon.cmd` PATH handling with a
      StackPilot-generated launcher (`bin/stackpilot.cmd`) for native stacks.
      It prepends the active binaries to `PATH`, sets `OPENSSL_CONF`, and is
      rewritten whenever a version changes.
- [x] Native virtual hosts + `hosts` file management owned by StackPilot.
      Missing configs and a managed `127.0.0.1` block are written together;
      unrelated hosts lines are preserved, and an unwritable hosts file is
      reported with the exact lines to add instead of failing the configs.
- [x] Default ports and conflict detection. Starting a service probes its port
      (Apache/Nginx from their config or the stack marker, MySQL/PostgreSQL/
      Redis/Mailpit/Memcached from the marker), waits for the port to accept
      connections and the process to stay alive, and refuses to start with an
      actionable message. A conflict dialog names the PID and program holding
      the port and can move the service to another one.
- [x] Generate Apache configs from templates instead of patching a
      vendor-supplied config. StackPilot stacks get a complete `httpd.conf`
      (module list, document root, logs, vhosts, optional SSL) and keep the
      Apache Lounge original as `httpd.conf.vendor`. Laragon stacks are still
      patched in place.
- [x] Adopt an existing Laragon stack in place. Adoption writes
      `usr/stackpilot.ini` beside `usr/laragon.ini`, selects the versions
      Laragon had active, regenerates the launcher and Apache config, and keeps
      both markers in sync so Laragon can still open the folder.

### 2e. Reliability pass (done)

- [x] Startup never opens `C:\laragon`/`C:\laragon-wamp` on its own; onboarding
      appears, and detected Laragon folders are an optional **Import** card.
- [x] **Settings → Stacks** persists the stacks folder and can create, rename,
      move, and delete stacks. Moving rewrites every generated path and keeps a
      copy until the user confirms.
- [x] `normalizeWindowsPath()` is used for every path that enters the app, with
      a round-trip test that guards against dropped characters such as the
      `D:\StackPilot_stacks` → `D:\tackPilot_stacks` bug.
- [x] Component pins point at archives that exist again (PHP 8.5.12-1, Apache
      Lounge 2.4.69, Node 26.13 LTS), with mirrors, a SHA-256 download cache,
      resume/retry, proxy support, and a checksum-mismatch recovery card.
- [x] `tool/verify_catalog.dart` HEADs every primary URL and mirror, and CI
      runs it so a moved pin fails before a release.
- [x] Logs read each service's configured files, capture stdout/stderr into
      `<stack>/logs/<service>-console.log`, and offer search, level filtering,
      clearing, and an early-exit dialog.
- [x] Terminal opens a real console window through the generated `.cmd`/`.ps1`
      launchers, with Command Prompt / PowerShell / Windows Terminal choices and
      **Open terminal here** on every project row.
- [x] phpMyAdmin installs into `etc/apps/phpmyadmin`, uses
      `Require all granted`, binds Apache to 127.0.0.1 by default, validates
      with `httpd -t`, restarts Apache (asking for external instances), and
      reports the health-check status.
- [x] nginx stacks get an equivalent `location /phpmyadmin/` block with
      `fastcgi_pass` to php-cgi.

See `docs/FIX_PLAN.md` for the full list of symptoms, causes, and acceptance
criteria.

## Stage 3 — Distribution and release engineering

- [x] Optional bundled component payload for fully offline first runs.
      `tool/build_payload.dart` builds `payload.json` from the catalog URLs and
      checksums; the installer ships it next to `stackpilot.exe`, and the setup
      wizard installs those archives after verifying the catalog SHA-256.
- [x] Auto-update: signed manifest (Ed25519 detached signature), HTTPS-only
      full installer download with size/SHA-256 verification, silent install,
      and rollback by re-running a cached installer.
- [x] Code signing for `stackpilot.exe` and the installer. The release script
      signs both when a PFX is supplied and warns when it is not; CI reads the
      certificate from secrets.
- [x] CI: analyze + tests on push and pull request, release build on a `v*`
      tag, checksum file, installer artifact, and GitHub release.
- [x] Crash-safe logging (synchronous append and flush, 2 MB rotation, three
      files) and an in-app diagnostics bundle with logs, build details, stack
      metadata, and the marker file. No database data, project files,
      passwords, or environment variables.
- [x] Release channels (stable / preview), chosen in settings and compiled into
      the build. A preview build also accepts a newer stable release.

See `docs/RELEASE.md` for the build, signing, manifest, payload, and CI
workflow.

## Stage 4 — Capability expansion

- [ ] One-click app installs (WordPress, Laravel, Symfony, plain PHP).
      phpMyAdmin is already a catalog app; the others are next.
- [ ] Project environment switcher (per-project PHP version, Node version).
- [ ] Database browser and import/export without phpMyAdmin.
- [x] Integrated terminal with the stack `PATH` preloaded (Command Prompt,
      PowerShell, or Windows Terminal, with per-project launch).
- [ ] HTTPS: local CA, per-site certificates, trust-store installation.
- [ ] Scheduled tasks: backup databases, rotate logs.

## Stage 5 — Hardening

- [ ] Coverage targets for `lib/core` and widget tests for every dialog.
- [ ] Error taxonomy: actionable messages instead of raw `FileSystemException`.
- [ ] Permission and long-path handling (`\\?\` paths, spaces, non-ASCII).
- [ ] Concurrency: one writer per config file, guarded by a lock.
