# StackPilot roadmap

This file tracks the stages beyond 1.0. The current stage is **Stage 2:
independence from Laragon**.

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
      through **Add version → ZIP/folder**. A bundled payload is deliberately
      left to Stage 3 if the installer ever needs to work without a network.

### 2d. De-Laragon the details (next)

- [ ] Replace remaining `bin/laragon/laragon.cmd` PATH handling with a
      StackPilot-generated launcher (`bin/stackpilot.cmd`) for native stacks.
- [ ] Generate Apache/Nginx configs from templates instead of patching a
      vendor-supplied config.
- [ ] Native virtual hosts + `hosts` file management owned by StackPilot.
- [ ] Default ports and conflict detection (3306/5432/6379 already in use).
- [ ] Migrate an existing Laragon stack into a StackPilot stack (copy or
      in-place adopt).

## Stage 3 — Distribution and release engineering

- [ ] Optional bundled component payload for fully offline first runs.
- [ ] Auto-update (signed manifest, delta or full package, rollback).
- [ ] Code signing for `stackpilot.exe` and the installer.
- [ ] CI: analyze + tests on push, release build on tag, installer artifact.
- [ ] Crash-safe logging and an in-app "report a problem" bundle.
- [ ] Release channels (stable / preview).

## Stage 4 — Capability expansion

- [ ] One-click app installs (WordPress, Laravel, Symfony, plain PHP).
- [ ] Project environment switcher (per-project PHP version, Node version).
- [ ] Database browser and import/export without phpMyAdmin.
- [ ] Integrated terminal with the stack `PATH` preloaded.
- [ ] HTTPS: local CA, per-site certificates, trust-store installation.
- [ ] Scheduled tasks: backup databases, rotate logs.

## Stage 5 — Hardening

- [ ] Coverage targets for `lib/core` and widget tests for every dialog.
- [ ] Error taxonomy: actionable messages instead of raw `FileSystemException`.
- [ ] Permission and long-path handling (`\\?\` paths, spaces, non-ASCII).
- [ ] Concurrency: one writer per config file, guarded by a lock.
