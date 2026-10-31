# StackPilot — Fix & Improvement Spec

> Hand this file to the coding agent. It is self-contained: every item lists the
> symptom, the confirmed root cause (with file + line), the required change, and
> acceptance criteria. Work through the phases in order; each phase must leave
> `flutter analyze` clean and `flutter test` green.

Project: Flutter Windows desktop app (`lib/`, `test/`, `tool/`, `installer/stackpilot.iss`).
Goal: a Laragon-like local server that works on a **clean Windows machine with no
Laragon installed**, lets the user pick where stacks live, downloads its own
components, and has working logs, terminal and phpMyAdmin.

> **Status (2026-10-31):** Phases 1–7 are implemented. `flutter analyze` is
> clean, 309 tests pass, and `dart run tool/verify_catalog.dart` reports every
> pinned URL and mirror as reachable with the expected size. The remaining item
> is the manual clean-VM QA in the test plan (install → pick a folder → download
> Apache/PHP/MariaDB/phpMyAdmin → start → logs → terminal → move stack).

---

## 0. Evidence collected on the user's PC (2026-10-31)

| Observation | Meaning |
|---|---|
| `C:\laragon` **and** `C:\laragon-wamp` both exist | Startup silently opens the old Laragon stack (see 1.1) — onboarding/setup wizard never appears. |
| `C:\laragon-wamp\bin\apache\…\conf\httpd.conf` contains `DocumentRoot "D:/tackPilot_stacks/www"` | Document root was "moved" to a folder whose name lost its `S` (`D:\StackPilot_stacks` → `D:\tackPilot_stacks`). The new folder has an empty `www`, so every site breaks. |
| `D:\tackPilot_stacks\` only holds `data\mysql`, `data\redis`, `www` (no `bin`, no `usr\stackpilot.ini`) | It is **not** a stack — just a half-copied data/doc root. Changing "stacks root" never actually created/moved a stack. |
| Apache writes `logs\error_log` / `logs\access_log` (no `.log`) and the stack writes `C:\laragon-wamp\logs\mysql-error.log` | The log viewer looks only for `error.log`/`access.log` under each install → finds nothing (see 3). |
| Apache `access_log`: `GET /phpmyadmin/ … 403` until 21:17, when alias still pointed to `C:/laragon-wamp/etc/apps/phpMyAdmin/` | 403 came from a stale/missing alias target + Laragon’s own config; StackPilot’s rewritten alias only applies after a real Apache restart (see 5). |
| `error_log`: `AH00098: pid file … overwritten — Unclean shutdown of previous Apache run?` | Services are stopped with `taskkill /T /F` → unclean shutdowns (see 6). |
| PHP pinned URL `windows.php.net/downloads/releases/php-8.5.12-Win32-vs17-x64.zip` → **404** (moved to `/releases/archives/`) | PHP never downloads (see 2.1). |
| Apache Lounge ZIP now 14,495,691 bytes; catalog pins 14,495,714 + a SHA-256 | Apache download always fails checksum (see 2.1). |

---

## Phase 1 — Stack location & first run (blocker)

### 1.1 Stop auto-falling back to Laragon
- **Root cause:** `lib/core/stack_resolution.dart:10` `legacyStackCandidates = ['C:\laragon-wamp','C:\laragon']`; `resolveInitialStackRoot` returns the first legacy folder when the StackPilot stacks folder is empty, so `lib/app.dart` never shows `OnboardingView`.
- **Change:**
  - Legacy Laragon folders are **never** opened automatically. Resolution order: `preferences.lastStackRoot` (if still a valid stack) → first stack in `preferences.stacksFolder` → **onboarding**.
  - Onboarding shows detected Laragon folders as an *optional* "Import / open existing Laragon stack" card, not as the default.
  - Add `preferences.onboardingCompleted` so onboarding appears exactly once, and a "Run setup again" entry in the app menu.
- **Accept:** On a PC with `C:\laragon` present and no preferences file, the app opens onboarding, not Laragon.

### 1.2 Make "stacks root" actually changeable
- **Root cause:** `lib/ui/settings_dialog.dart` `_save()` (≈line 191–260) never persists `stacksFolder`; only clicking "Use" on an already-detected stack switches roots. There is no "create stack here" or "move stack" action. Changing **Document root** (the field the user actually used) only rewrites `DocumentRoot` in `httpd.conf` / `00-default.conf` (`stack_editor.dart:_updateApacheDocumentRoot` ≈1576) without moving `www`, `data`, `bin`.
- **Change — new "Stacks" settings tab:**
  1. **Stacks folder** (where StackPilot looks for/creates stacks) — Browse button, persisted in `preferences.json` on Save.
  2. List of stacks in that folder with **Open**, **Rename**, **Move…**, **Delete…** (delete asks for confirmation, never deletes `data/` without a second confirm).
  3. **New stack…** → name + location → `StackBootstrap.create()` → opens the Setup wizard (1.3).
  4. **Move stack…** — stop all services, copy the whole stack folder (bin, etc, usr, www, data, logs), regenerate every config that embeds absolute paths (`httpd.conf`, vhosts, alias, `php.ini` extension_dir, `my.ini` datadir, `nginx.conf`, `redis.conf`, `bin/stackpilot.cmd`, PostgreSQL), verify, then switch and offer to delete the old copy.
  - Document root stays a separate per-stack field but must **validate**: folder exists (or offer to create), warn if it is outside the stack, and offer "Move my projects too".
- **Path safety:** add one helper `normalizeWindowsPath()` used everywhere paths enter the app (text fields, dialogs, ini). Add a unit test that `D:\StackPilot_stacks\www` survives text field → ini → httpd.conf → reload unchanged (guards the lost-`S` bug). Investigate the exact place the `\S` was dropped (likely an escape/regex path in the text-field → ini → `_replacePath` flow) and fix it.
- **Accept:** User can pick `D:\StackPilot\stacks`, create a stack there, restart the app and land in it; Move stack relocates a working stack and all services start afterwards.

### 1.3 Installer (Inno Setup) choices
- **Root cause:** `installer/stackpilot.iss` installs the app only; it has no page for the stack location or components. Stack location is only asked in onboarding, which is skipped (1.1).
- **Change in `stackpilot.iss`:**
  - Keep the normal app install-dir page (`DisableDirPage=no`).
  - Add a custom page **"Where should your stacks live?"** (default `%LOCALAPPDATA%\StackPilot\stacks`, Browse, free-space check) and write it to `%APPDATA%\StackPilot\preferences.json` (`stacksFolder`) — or pass it as `--stacks-folder=` on first launch.
  - Add a **Components** page (checkboxes): Apache, Nginx, PHP (version dropdown via `[Types]/[Components]`), MariaDB/MySQL, PostgreSQL, Redis, Node.js, Mailpit, phpMyAdmin, plus a **Download now / Download on first run / Don't download (I'll add ZIPs)** radio.
  - Write the selection to `preferences.json` (`pendingComponents`) and the app's first run opens the Setup wizard pre-filled and starts downloading (with progress), so the installer stays small and does not need network code. Optional: if `-PayloadDir` was used, install bundled ZIPs offline.
- **Accept:** Fresh install → user chooses folder + components → first launch downloads and configures them, no Laragon needed.

### 1.4 In-app Setup wizard improvements (`lib/ui/widgets/stack_setup_dialog.dart`)
- Show **target stack folder** at the top with "Change…".
- Per component: **version dropdown** (from catalog, multiple versions), size, status (installed / will download / failed + reason).
- "Download only missing", "Re-download", "Cancel" (cancels the HTTP stream cleanly).
- After success: auto-generate configs, enable services, offer **Start all**.

---

## Phase 2 — Component downloads (blocker)

### 2.1 Fix broken pins & make downloads resilient
- **Root cause:** `lib/core/component_catalog.dart` hard-pins a single URL + size + SHA-256 per component. PHP 8.5.12 moved to `/downloads/releases/archives/` → 404. Apache Lounge re-uploads builds → size/hash mismatch.
- **Change:**
  - `ComponentRelease` gets `urls: List<String>` (primary + mirrors/archives). PHP: try `releases/` then `releases/archives/`. Apache: Apache Lounge + `archive` fallback.
  - **Remote catalog:** fetch a signed JSON manifest (reuse the update-manifest signing in `tool/publish_manifest.ps1` / `update_keys.dart`) from the project's release host; fall back to the built-in catalog. Lets you fix versions/hashes without shipping a new app.
  - Optional resolvers: PHP via `https://windows.php.net/downloads/releases/releases.json`, Node via `https://nodejs.org/dist/index.json`, nginx/MariaDB from their index pages; when resolved dynamically, verify with the vendor-published SHA-256 (PHP, Node, MariaDB publish them) instead of a pinned one.
  - On checksum mismatch show: expected/actual hash, URL, and buttons **Retry**, **Try mirror**, **Choose ZIP…**. Never fail silently.
  - Real **download cache**: `%LOCALAPPDATA%\StackPilot\cache\downloads\<sha256>.zip` (README/ROADMAP already promise this, but `stack_provisioner.dart:327` uses `createTempSync` and deletes it). Add "Clear cache" in settings.
  - Resume / retry with backoff, proxy support via system proxy (`HttpClient.findProxyFromEnvironment`), and a 30 s connect timeout.
- **Add a CI/dev check:** `tool/verify_catalog.dart` that HEADs every URL and compares size → fails the build when a pin breaks.
- **Accept:** `tool/verify_catalog.dart` passes; Setup wizard downloads PHP + Apache + MariaDB on a clean VM.

### 2.2 phpMyAdmin & friends as catalog items
- Add phpMyAdmin (and optionally Adminer, Composer) to the catalog with the same download/verify/cache path, installed into `<stack>\etc\apps\phpmyadmin` (Laragon-compatible location, outside `www`).

---

## Phase 3 — Logs (major)

- **Root cause:** `lib/core/service_logs.dart:157` only probes `<install>/logs/error.log` and `access.log`. Real files are:
  - Apache: `logs/error_log`, `logs/access_log` (Laragon/legacy config) **or** `<stack>/logs/default-error.log` (StackPilot template).
  - MySQL/MariaDB: `<stack>/logs/mysql-error.log` (from `my.ini log-error`) or `<datadir>/<host>.err`.
  - Nginx: `<stack>/logs/nginx-error.log`, `nginx-access.log`.
  - Redis: `<stack>/logs/redis.log`. PostgreSQL: `<data>/log/*.log`. Mailpit: stdout only.
  - PHP: `error_log` from `php.ini`.
  - Process stdout/stderr is **discarded**: `lib/core/service_manager.dart:524-525` `drain()`.
- **Change:**
  1. Resolve log paths **from the actual config** (parse `ErrorLog`/`CustomLog` in httpd.conf incl. relative-to-ServerRoot, `log-error` in my.ini, `error_log` in nginx.conf/php.ini, `logfile` in redis.conf) with fallbacks to the names above + `<stack>/logs/*.log`.
  2. Capture each owned process' stdout/stderr into `<stack>/logs/<service>-console.log` (rotating, 5 MB) and an in-memory ring buffer shown live.
  3. Logs window: service selector, file selector, live tail (file watcher), search, level filter, "Open folder", "Clear".
  4. If a service exits within 5 s of start, show a toast with the last 20 lines of its console/error log.
- **Accept:** Starting MariaDB with a bad port shows the real error in the Logs window; Apache's `error_log` is visible for Laragon stacks.

---

## Phase 4 — Terminal (major)

- **Root cause:** `lib/ui/dashboard.dart:≈1013` `Process.start('cmd.exe', [...], mode: ProcessStartMode.detached)`. From a GUI process, Dart's detached mode uses `DETACHED_PROCESS`, so cmd.exe gets **no console** and exits immediately — nothing appears. It also never runs `bin/stackpilot.cmd`, so PATH would not contain the stack binaries anyway.
- **Change:**
  - Launch via `Process.start('cmd.exe', ['/c','start','"StackPilot"','/D', <docRoot>, 'cmd.exe','/k', <launcher>], runInShell: false, mode: ProcessStartMode.detached)` — `start` creates a new console window.
  - `<launcher>` = `bin\stackpilot.cmd` for native stacks, `bin\laragon\laragon.cmd` for Laragon stacks; regenerate it if missing.
  - Preference "Terminal": Windows Terminal (`wt.exe -d <dir> cmd /k <launcher>`) if installed, cmd, or PowerShell (`powershell -NoExit -Command ". '<launcher.ps1>'"` — also generate a `.ps1` launcher).
  - Add "Open terminal here" on each site row.
- **Accept:** Clicking Terminal opens a window in the document root where `php -v`, `mysql --version`, `node -v`, `composer -V` resolve to the active stack versions.

---

## Phase 5 — phpMyAdmin 403 (major)

- **Root causes:**
  1. Laragon stacks: alias pointed to `C:/laragon-wamp/etc/apps/phpMyAdmin/` which does not exist → Apache 403 (`access_log` evidence).
  2. StackPilot installs phpMyAdmin into `www\phpmyadmin` and rewrites `etc/apache2/alias/phpmyadmin.conf` with `Require local` (`stack_editor.dart:≈235-237`), but the alias only takes effect after a **real** Apache restart; Apache started by Laragon/outside StackPilot is not restarted.
  3. If PHP is missing (download failed, 2.1) `mod_php.conf` is not included → `index.php` is never executed.
  4. `Require local` fails when the browser reaches Apache via a LAN IP or a `.test` host mapped to another address.
- **Change:**
  - Install phpMyAdmin to `<stack>\etc\apps\phpmyadmin` (via catalog, 2.2) and always (re)write the alias:
    ```apache
    Alias /phpmyadmin "<stack>/etc/apps/phpmyadmin/"
    <Directory "<stack>/etc/apps/phpmyadmin/">
        Options FollowSymLinks
        DirectoryIndex index.php
        AllowOverride All
        Require all granted   # dev server; bound to 127.0.0.1 by default
    </Directory>
    ```
    and make Apache `Listen 127.0.0.1:80` by default (setting to expose on LAN).
  - Nginx equivalent `location /phpmyadmin` with `fastcgi_pass` to php-cgi.
  - Generate `config.inc.php` (blowfish secret, `host=127.0.0.1`, port from settings, `AllowNoPassword=true` for root with empty password).
  - Before enabling: verify PHP is installed and `mod_php.conf`/php-cgi is active; otherwise show "Install PHP first".
  - After install: run `httpd -t`; if OK, **graceful restart** Apache (including externally-started Apache, after confirming), then HTTP GET `http://127.0.0.1/phpmyadmin/` and report the status code to the user.
  - Add a "Database → Open phpMyAdmin" button that does the same health check.
- **Accept:** Fresh stack → install phpMyAdmin → button opens the login page (HTTP 200), on both native and Laragon stacks.

---

## Phase 6 — Service lifecycle quality

- Graceful stop instead of `taskkill /T /F` (`service_manager.dart:539`): Apache `httpd -k stop` / CTRL_BREAK via job object, MariaDB `mysqladmin shutdown`, nginx `-s quit`, PostgreSQL `pg_ctl stop -m fast`, Redis `redis-cli shutdown`; force-kill only after a 10 s timeout. Removes the "Unclean shutdown" warnings.
- Health check after start (port open + process alive for 3 s) before showing "Running".
- Detect and warn when **Laragon.exe** is running against the same stack (it rewrites configs).
- Port conflict dialog: show which PID/app holds the port, offer "Use another port".

---

## Phase 7 — Clean-up & docs

- `lib/ui/windows_dialogs.dart`:
  - `pickZipFile` reads `$dialog.SelectedPath` (line 31) — OpenFileDialog has `FileName`, so it always returns empty → "Add version → ZIP" is broken. Fix.
  - `$dialog.Description` is invalid on OpenFileDialog (line 17). Use `Title`.
  - Pass the app's HWND as dialog owner (or use `file_selector` / `filepicker_windows` package) so dialogs don't open behind the window.
- Update `docs/ROADMAP.md`: items 2b/2c/2d are marked done but fail in practice (fallback, cache, wizard choices). Re-open them and link this spec.
- README: document stack folder, components, logs location, terminal, phpMyAdmin URL.

---

## Test plan (each phase adds tests in `test/core` / `test/ui`)

1. `stack_resolution_test`: legacy folders present + no prefs → returns "onboarding", not `C:\laragon`.
2. `settings_dialog_test`: changing Stacks folder persists to preferences.json.
3. `path_roundtrip_test`: `D:\StackPilot_stacks\www` round-trips through ini/httpd.conf unchanged.
4. `stack_move_test`: move a fixture stack, all generated configs contain the new path, none contain the old.
5. `component_catalog_test`: every release has ≥2 URLs or a resolver; `tool/verify_catalog.dart` network check in CI.
6. `service_logs_test`: discovers `error_log`, `<stack>/logs/mysql-error.log`, console capture.
7. `terminal_command_test`: built command line uses `start` + launcher.
8. `phpmyadmin_alias_test`: generated alias, `config.inc.php`, nginx location.
9. Manual QA on a clean Windows 11 VM **without** Laragon: install → choose `D:\StackPilot` → download Apache+PHP+MariaDB+phpMyAdmin → start all → open `http://localhost`, `http://localhost/phpmyadmin`, open Terminal, view logs, move stack, restart app.

## Priority summary

| # | Issue | Severity | Phase |
|---|---|---|---|
| 1 | Auto-opens old Laragon, skips onboarding | Blocker | 1.1 |
| 2 | Cannot change stacks root / doc-root move breaks sites | Blocker | 1.2 |
| 3 | PHP 404 + Apache checksum mismatch → nothing downloads | Blocker | 2.1 |
| 4 | Installer has no location/components choice | High | 1.3 |
| 5 | Logs window empty | High | 3 |
| 6 | Terminal does nothing | High | 4 |
| 7 | phpMyAdmin 403 | High | 5 |
| 8 | Unclean shutdowns, ZIP picker broken | Medium | 6, 7 |
