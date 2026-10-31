import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/app_log.dart';
import '../core/app_preferences.dart';
import '../core/hosts_file.dart';
import '../core/paths.dart';
import '../core/phpmyadmin_health.dart';
import '../core/port_owner.dart';
import '../core/service_logs.dart';
import '../core/service_manager.dart';
import '../core/site_inventory.dart';
import '../core/stack_adoption.dart';
import '../core/stack_bootstrap.dart';
import '../core/stack_conflicts.dart';
import '../core/stack_editor.dart';
import '../core/stack_layout.dart';
import '../core/terminal.dart';
import '../core/update_service.dart';
import 'component_presentation.dart';
import 'database_dialog.dart';
import 'logs_dialog.dart';
import 'settings_dialog.dart';
import 'site_dialog.dart';
import 'version_dialog.dart';
import 'widgets/dashboard_chrome.dart';
import 'widgets/dashboard_header.dart';
import 'widgets/onboarding_view.dart';
import 'widgets/projects_panel.dart';
import 'widgets/services_panel.dart';
import 'widgets/stack_setup_dialog.dart';
import 'widgets/update_banner.dart';
import 'windows_dialogs.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({
    super.key,
    required this.layout,
    required this.attemptedRoot,
    this.serviceManagerFactory,
    this.preferences = AppPreferences.empty,
    this.preferencesStore,
    this.importableStacks = const [],
    this.laragonCheck,
  });

  final StackLayout? layout;
  final String attemptedRoot;
  final ServiceManager Function(StackLayout)? serviceManagerFactory;
  final AppPreferences preferences;
  final AppPreferencesStore? preferencesStore;

  /// Laragon stacks found on this PC, offered by the onboarding screen.
  final List<String> importableStacks;

  /// Reports a running Laragon when it resolves; null skips the check.
  final Future<List<StackConflict>>? laragonCheck;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  late StackLayout? _layout = widget.layout;
  late ServiceManager? _services = _createManager(_layout);
  late SiteInventory? _inventory = _layout == null
      ? null
      : SiteInventory.load(_layout!);
  late AppPreferences _preferences = widget.preferences;
  final Set<StackComponent> _busy = {};
  Timer? _ticker;
  bool _bulkBusy = false;
  UpdateRelease? _availableUpdate;
  bool _updateDismissed = false;

  ServiceManager? _createManager(StackLayout? layout) {
    if (layout == null) {
      return null;
    }
    final factory = widget.serviceManagerFactory;
    final manager = factory == null ? ServiceManager(layout) : factory(layout);
    manager.onServiceExit = _onServiceExit;
    return manager;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_refreshExternal());
      unawaited(_maybeCheckForUpdates());
      unawaited(_maybeRunInstallerSetup());
      final laragonCheck = widget.laragonCheck;
      if (laragonCheck != null) {
        unawaited(_warnIfLaragon(laragonCheck));
      }
    });
  }

  /// Warns once when Laragon is running: it can rewrite the same configs.
  Future<void> _warnIfLaragon(Future<List<StackConflict>> check) async {
    final List<StackConflict> conflicts;
    try {
      conflicts = await check;
    } on Object {
      return;
    }
    if (!mounted || conflicts.isEmpty) {
      return;
    }
    final first = conflicts.first;
    _showMessage(
      'Laragon is running (PID ${first.pid}). Close it before changing '
      'services or versions; it rewrites the same Apache and MySQL config '
      'files.',
    );
  }

  /// Opens the setup wizard with the components chosen in the installer.
  ///
  /// Runs once: the pending list is cleared before the wizard opens so a
  /// restart never shows it again.
  Future<void> _maybeRunInstallerSetup() async {
    final pending = _preferences.pendingComponents;
    if (pending.isEmpty || _layout == null) {
      return;
    }
    final mode = _preferences.pendingDownloadMode;
    _preferences = _preferences.copyWith(
      pendingComponents: const [],
      pendingDownloadMode: null,
    );
    final store = widget.preferencesStore;
    if (store != null) {
      unawaited(store.save(_preferences));
    }
    if (mode == 'manual' || !mounted) {
      return;
    }
    await _openSetup(preselect: pending);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _refreshExternal() async {
    final services = _services;
    if (services == null) {
      return;
    }
    try {
      await services.refreshExternal();
    } on ProcessException catch (error) {
      _showMessage('Could not inspect running services: ${error.message}');
    }
    if (mounted) {
      setState(() {});
    }
  }

  /// Checks the signed manifest once per launch when this build has an update
  /// source and the user left automatic checks enabled.
  Future<void> _maybeCheckForUpdates() async {
    if (!_preferences.autoCheckUpdates) {
      return;
    }
    final service = UpdateService.fromConfig(_preferences);
    if (service == null) {
      return;
    }
    try {
      final result = await service.check();
      if (!mounted || !result.hasUpdate) {
        return;
      }
      setState(() => _availableUpdate = result.release);
    } on UpdateException catch (error) {
      AppLog.warn('Automatic update check failed: ${error.message}');
    } on Object catch (error, stackTrace) {
      AppLog.warn(
        'Automatic update check failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _changeStack() async {
    if (_services?.hasRunningServices == true) {
      _showMessage('Stop all services before switching stacks.');
      return;
    }

    final path = await pickFolder('Select a stack folder');
    if (path == null || !mounted) {
      return;
    }

    await _switchToStack(path);
  }

  /// Opens [root] as the current stack and remembers it for the next launch.
  Future<void> _switchToStack(String root) async {
    if (_services?.hasRunningServices == true) {
      _showMessage('Stop all services before switching stacks.');
      return;
    }

    final layout = StackLayout.detect(root);
    if (layout == null) {
      _showMessage(
        'No stack found at $root. Expected usr\\stackpilot.ini (or '
        'usr\\laragon.ini) and a bin folder.',
      );
      return;
    }

    setState(() {
      _layout = layout;
      _inventory = SiteInventory.load(layout);
      _services = _createManager(layout);
      _busy.clear();
      _bulkBusy = false;
    });
    _rememberStack(layout);
    await _refreshExternal();
    if (mounted) {
      _showMessage('Using ${layout.root}');
    }
    await _maybeRunInstallerSetup();
  }

  /// Creates a StackPilot stack at [root] and opens it.
  ///
  /// Returns an error message for the onboarding screen, or null on success.
  Future<String?> _createStack(String root) async {
    final StackLayout layout;
    try {
      layout = StackBootstrap.create(root: root);
    } on StackBootstrapException catch (error) {
      return error.message;
    }

    if (!mounted) {
      return null;
    }
    setState(() {
      _layout = layout;
      _inventory = SiteInventory.load(layout);
      _services = _createManager(layout);
      _busy.clear();
      _bulkBusy = false;
    });
    _rememberStack(layout);
    await _refreshExternal();
    if (mounted) {
      _showMessage('Created a stack at ${layout.root}');
    }
    await _maybeRunInstallerSetup();
    return null;
  }

  /// Lets the user open an existing stack folder from the onboarding screen.
  ///
  /// Returns an error message, or null when a stack was opened or the picker
  /// was cancelled.
  Future<String?> _openExistingStack() async {
    final path = await pickFolder('Select a stack folder');
    if (path == null || !mounted) {
      return null;
    }
    if (_services?.hasRunningServices == true) {
      return 'Stop all services before switching stacks.';
    }

    final layout = StackLayout.detect(path);
    if (layout == null) {
      return 'No stack found at $path. Expected usr\\stackpilot.ini (or '
          'usr\\laragon.ini) and a bin folder.';
    }

    setState(() {
      _layout = layout;
      _inventory = SiteInventory.load(layout);
      _services = _createManager(layout);
      _busy.clear();
      _bulkBusy = false;
    });
    _rememberStack(layout);
    await _refreshExternal();
    if (mounted) {
      _showMessage('Using ${layout.root}');
    }
    await _maybeRunInstallerSetup();
    return null;
  }

  /// Opens an existing Laragon stack that the user explicitly imported.
  Future<String?> _openLegacyStack(String root) async {
    if (_services?.hasRunningServices == true) {
      return 'Stop all services before switching stacks.';
    }
    if (StackLayout.detect(root) == null) {
      return 'No stack found at $root. Expected usr\\laragon.ini and a bin '
          'folder.';
    }
    await _switchToStack(root);
    return null;
  }

  void _rememberStack(StackLayout layout) {
    final root = p.normalize(layout.root);
    final folder = _preferences.stacksFolder;
    final keepFolder =
        folder != null &&
        p.isWithin(p.normalize(folder), root) &&
        p.normalize(folder) != root;
    _preferences = _preferences.copyWith(
      activeStack: root,
      stacksFolder: keepFolder ? folder : p.dirname(root),
      onboardingCompleted: true,
    );
    final store = widget.preferencesStore;
    if (store != null) {
      unawaited(store.save(_preferences));
    }
  }

  void _ensureTicker() {
    if (_ticker != null) {
      return;
    }
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {});
      final active =
          _busy.isNotEmpty ||
          _bulkBusy ||
          (_services?.hasRunningServices ?? false);
      if (!active) {
        timer.cancel();
        _ticker = null;
      }
    });
  }

  void _refresh() {
    final root = _layout?.root ?? widget.attemptedRoot;
    final layout = StackLayout.detect(root);
    setState(() {
      _layout = layout;
      _services = _createManager(layout);
      _inventory = layout == null ? null : SiteInventory.load(layout);
    });

    if (layout == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('No stack found at $root.')));
    }
  }

  Future<void> _reloadAfterConfigChange() async {
    final layout = StackLayout.detect(_layout?.root ?? widget.attemptedRoot);
    if (layout == null) {
      _showMessage('The stack could not be read after the change.');
      return;
    }

    final services = _services;
    services?.updateLayout(layout);
    if (services != null) {
      try {
        await services.refreshExternal();
      } on ProcessException catch (error) {
        _showMessage('Could not inspect running services: ${error.message}');
      }
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _layout = layout;
      _inventory = SiteInventory.load(layout);
    });
  }

  Future<void> _selectVersion(
    StackComponent component,
    StackInstall install,
  ) async {
    final layout = _layout;
    if (layout == null) {
      return;
    }

    final services = _services;
    if (services != null) {
      try {
        await services.refreshExternal();
      } on ProcessException catch (error) {
        _showMessage('Could not inspect running services: ${error.message}');
      }
      if (!mounted) {
        return;
      }
      if (services.isRunning(component)) {
        _showMessage(
          'Stop ${componentLabels[component]} before switching versions.',
        );
        return;
      }
    }

    try {
      StackEditor(layout).selectVersion(component, install);
      final apacheWasRunning =
          services?.isRunning(StackComponent.apache) ?? false;
      await _reloadAfterConfigChange();
      if (!mounted) {
        return;
      }
      final restartNote = component == StackComponent.php && apacheWasRunning
          ? ' Restart Apache to load it.'
          : '';
      _showMessage(
        '${componentLabels[component]} ${install.displayVersion} is now '
        'active.$restartNote',
      );
    } on StackEditException catch (error) {
      _showMessage(error.message);
    } on FileSystemException catch (error) {
      _showMessage('Could not switch version: ${error.message}');
    }
  }

  /// Opens the starter-stack dialog and refreshes the stack afterwards.
  Future<void> _openSetup({List<String>? preselect}) async {
    final layout = _layout;
    if (layout == null) {
      return;
    }

    final result = await showStackSetupDialog(
      context,
      layout: layout,
      initialSelection: preselect ?? const [],
    );
    if (result == null || !mounted) {
      return;
    }

    final target = result.stackRoot;
    final switched =
        target != null &&
        !sameWindowsPath(target, _layout?.root ?? widget.attemptedRoot);
    if (switched) {
      await _switchToStack(target);
      if (!mounted) {
        return;
      }
    } else if (result.changed) {
      await _reloadAfterConfigChange();
      if (!mounted) {
        return;
      }
    }

    if (result.failures.isNotEmpty) {
      _showMessage(result.failures.join('\n'));
    } else if (result.cancelled) {
      _showMessage('Download cancelled.');
    } else if (result.changed) {
      _showMessage(
        'Installed ${result.installed} '
        '${result.installed == 1 ? 'component' : 'components'}. '
        'Start them from their cards.',
      );
    }

    if (result.startAll) {
      await _startAll();
    }
  }

  Future<void> _adoptStack() async {
    final layout = _layout;
    if (layout == null || layout.flavor != StackFlavor.laragon) {
      return;
    }

    final services = _services;
    if (services != null) {
      try {
        await services.refreshExternal();
      } on ProcessException catch (error) {
        _showMessage('Could not inspect running services: ${error.message}');
        return;
      }
      if (!mounted) {
        return;
      }
      if (services.hasRunningServices) {
        final names = services.runningComponents
            .map((component) => componentLabels[component])
            .join(', ');
        _showMessage('Stop $names before adopting this stack.');
        return;
      }
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Adopt this Laragon stack?'),
        content: const Text(
          'StackPilot takes over this folder in place. It writes '
          'usr\\stackpilot.ini, regenerates the Apache config and the '
          'launcher, and selects the versions Laragon had active.\n\n'
          'Files are not copied or moved. usr\\laragon.ini is kept, so '
          'Laragon can still open the same folder.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Adopt'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    try {
      final result = StackAdoption.adopt(layout.root);
      await _reloadAfterConfigChange();
      if (!mounted) {
        return;
      }

      if (result.warnings.isEmpty) {
        _showMessage('This stack is now managed by StackPilot.');
        return;
      }

      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Stack adopted with notes'),
          content: SingleChildScrollView(
            child: Text(result.warnings.join('\n\n')),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } on StackAdoptionException catch (error) {
      _showMessage(error.message);
    } on FileSystemException catch (error) {
      _showMessage('Could not adopt the stack: ${error.message}');
    }
  }

  Future<void> _addVersion(StackComponent component) async {
    final layout = _layout;
    if (layout == null) {
      return;
    }

    final result = await showAddVersionDialog(
      context,
      editor: StackEditor(layout),
      component: component,
      componentLabel: componentLabels[component]!,
    );
    if (result == null || !mounted) {
      return;
    }

    await _reloadAfterConfigChange();
    if (!mounted) {
      return;
    }

    if (result.activate) {
      final services = _services;
      if (services != null && services.isRunning(component)) {
        _showMessage(
          '${componentLabels[component]} ${result.install.displayVersion} was '
          'installed. Stop the service before activating it.',
        );
      } else {
        await _selectVersion(component, result.install);
      }
    } else {
      _showMessage(
        '${componentLabels[component]} ${result.install.displayVersion} was '
        'installed.',
      );
    }
  }

  Future<void> _openSettings({int initialTabIndex = 0}) async {
    final layout = _layout;
    if (layout == null) {
      return;
    }

    final outcome = await showStackSettingsDialog(
      context,
      layout: layout,
      editor: StackEditor(layout),
      stacksFolder: _preferences.stacksFolder,
      preferences: _preferences,
      preferencesStore: widget.preferencesStore,
      runningServices: _services?.runningComponents ?? const [],
      initialTabIndex: initialTabIndex,
    );
    if (outcome == null || !mounted) {
      return;
    }

    final updated = outcome.preferences;
    if (updated != null) {
      _preferences = updated;
    }

    final target = outcome.stackRoot;
    if (target != null) {
      final hadPendingSetup = _preferences.pendingComponents.isNotEmpty;
      await _switchToStack(target);
      if (!mounted) {
        return;
      }
      // Switching already opened the wizard when the installer left a
      // component list behind.
      if (outcome.openSetup && !hadPendingSetup) {
        await _openSetup();
      }
      return;
    }

    await _reloadAfterConfigChange();
    if (outcome.openSetup) {
      await _openSetup();
      return;
    }
    if (mounted) {
      _showMessage('Settings saved. Restart running services to apply them.');
    }
  }

  Future<void> _startAll() async {
    final services = _services;
    if (services == null || _bulkBusy) {
      return;
    }
    await _refreshExternal();
    if (!mounted) {
      return;
    }
    setState(() => _bulkBusy = true);
    _ensureTicker();
    try {
      final failures = await services.startEnabled();
      if (failures.isNotEmpty) {
        ServiceException? conflict;
        for (final failure in failures) {
          if (failure.port != null && failure.component != null) {
            conflict = failure;
            break;
          }
        }
        if (conflict != null) {
          await _showPortConflict(
            conflict.component!,
            conflict.port!,
            conflict.message,
          );
        } else {
          _showMessage(failures.map((error) => error.message).join('\n'));
        }
      }
    } finally {
      if (mounted) {
        setState(() => _bulkBusy = false);
      }
    }
  }

  Future<void> _stopAll() async {
    final services = _services;
    if (services == null || _bulkBusy) {
      return;
    }
    await _refreshExternal();
    if (!mounted) {
      return;
    }
    setState(() => _bulkBusy = true);
    _ensureTicker();
    try {
      final failures = await services.stopEnabled();
      if (failures.isNotEmpty) {
        _showMessage(failures.map((error) => error.message).join('\n'));
      }
    } finally {
      if (mounted) {
        setState(() => _bulkBusy = false);
      }
    }
  }

  Future<void> _toggleService(StackComponent component, bool start) async {
    final services = _services;
    if (services == null || _busy.contains(component)) {
      return;
    }
    setState(() => _busy.add(component));
    _ensureTicker();
    try {
      if (start) {
        await services.start(component);
      } else {
        await services.stop(component);
      }
    } on ServiceException catch (error) {
      final port = error.port;
      if (port != null) {
        await _showPortConflict(component, port, error.message);
      } else {
        _showMessage(error.message);
      }
    } on ProcessException catch (error) {
      _showMessage(
        'Could not ${start ? 'start' : 'stop'} '
        '${componentLabels[component]}: ${error.message}',
      );
    } finally {
      if (mounted) {
        setState(() => _busy.remove(component));
      }
    }
  }

  /// Shows who holds [port] and offers to move the service to another one.
  Future<void> _showPortConflict(
    StackComponent component,
    int port,
    String message,
  ) async {
    final owner = await findPortOwner(port);
    if (!mounted) {
      return;
    }
    final newPort = await showDialog<int>(
      context: context,
      builder: (context) => _PortConflictDialog(
        componentLabel: componentLabels[component] ?? component.directoryName,
        port: port,
        owner: owner,
        message: message,
      ),
    );
    if (newPort == null || !mounted) {
      return;
    }
    final layout = _layout;
    if (layout == null) {
      return;
    }
    try {
      await StackEditor(layout).changeServicePort(component, newPort);
    } on StackEditException catch (error) {
      _showMessage(error.message);
      return;
    } on FileSystemException catch (error) {
      _showMessage('Could not change the port: ${error.message}');
      return;
    }
    await _reloadAfterConfigChange();
    if (!mounted) {
      return;
    }
    _showMessage(
      '${componentLabels[component]} now uses port $newPort. Restart any '
      'running service that talks to it.',
    );
    await _toggleService(component, true);
  }

  Future<void> _generateVhosts() async {
    final inventory = _inventory;
    if (inventory == null) {
      return;
    }
    final missing = inventory.missingConfigs;
    final unmapped = inventory.unmappedHosts;
    if (missing.isEmpty && unmapped.isEmpty) {
      return;
    }

    // Mapping a host needs administrator rights, so it is opt-in when configs
    // are being created. When only hosts entries are missing, that is the
    // whole point of the action.
    var mapHosts = missing.isEmpty && unmapped.isNotEmpty;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Generate virtual hosts?'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (missing.isNotEmpty) ...[
                  Text(
                    'Create ${missing.length} config '
                    '${missing.length == 1 ? 'file' : 'files'} in '
                    '${inventory.sitesEnabledDirectory}:',
                  ),
                  const SizedBox(height: 6),
                  SelectableText(
                    missing.map((site) => site.host).join('\n'),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
                if (unmapped.isNotEmpty) ...[
                  if (missing.isNotEmpty) const SizedBox(height: 16),
                  Text(
                    '${unmapped.length} host '
                    '${unmapped.length == 1 ? 'is' : 'are'} not mapped in '
                    '${inventory.hostsPath}.',
                  ),
                  CheckboxListTile(
                    value: mapHosts,
                    onChanged: (value) =>
                        setDialogState(() => mapHosts = value ?? false),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('Add hosts entries'),
                    subtitle: const Text(
                      'Writes 127.0.0.1 lines. Windows shows an administrator '
                      'prompt.',
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                const Text(
                  'Existing config files and unrelated hosts lines are left '
                  'unchanged.',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Generate'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    final pending = unmapped.map((site) => site.host).toList();
    final pendingLines = pending.map((host) => '127.0.0.1 $host').toList();
    try {
      final result = inventory.generateMissing(mapHosts: false);
      if (result.created.isNotEmpty) {
        StackEditor(inventory.layout).ensureApacheVhostInclude();
      }

      HostsUpdate? hosts;
      if (mapHosts && pending.isNotEmpty) {
        hosts = await inventory.mapHosts(pending);
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _inventory = SiteInventory.load(inventory.layout);
      });

      final parts = <String>[];
      if (result.created.isNotEmpty) {
        parts.add(
          'Created ${result.created.length} virtual host '
          '${result.created.length == 1 ? 'file' : 'files'}.',
        );
      }
      if (hosts != null && hosts.changed) {
        parts.add(
          'Mapped ${hosts.added.length} '
          '${hosts.added.length == 1 ? 'host' : 'hosts'}.',
        );
      }
      if (result.changed || (hosts?.changed ?? false)) {
        parts.add('Restart Apache to apply.');
      }
      if (hosts != null && !hosts.written) {
        await _showHostsHelp(
          hosts.error ?? '${inventory.hostsPath} could not be updated.',
          pendingLines,
          retry: () => inventory.mapHosts(pending),
        );
        return;
      }
      _showMessage(
        parts.isEmpty
            ? 'Virtual hosts are already up to date.'
            : parts.join(' '),
      );
    } on FileSystemException catch (error) {
      _showMessage('Could not write virtual hosts: ${error.message}');
    }
  }

  Future<void> _addSite() async {
    final layout = _layout;
    final inventory = _inventory;
    if (layout == null || inventory == null) {
      return;
    }
    final request = await showNewSiteDialog(
      context,
      documentRoot: layout.documentRoot,
      existingNames: inventory.sites.map((site) => site.name).toList(),
      existingHosts: inventory.sites.map((site) => site.host).toList(),
    );
    if (request == null || !mounted) {
      return;
    }

    final directory = Directory(p.join(layout.documentRoot, request.name));
    try {
      directory.createSync(recursive: true);
      final result = SiteInventory.load(layout)
          .generateMissing(mapHosts: false);
      if (result.created.isNotEmpty) {
        StackEditor(layout).ensureApacheVhostInclude();
      }
      if (!mounted) {
        return;
      }
      setState(() => _inventory = SiteInventory.load(layout));

      HostsUpdate? hosts;
      if (request.mapHosts) {
        hosts = await _inventory!.mapHosts([request.host]);
      }
      if (!mounted) {
        return;
      }
      setState(() => _inventory = SiteInventory.load(layout));

      if (hosts != null && !hosts.written) {
        await _showHostsHelp(
          hosts.error ?? '${inventory.hostsPath} could not be updated.',
          ['127.0.0.1 ${request.host}'],
          retry: () => _inventory!.mapHosts([request.host]),
        );
        return;
      }

      final parts = <String>['Added ${request.name}.'];
      if (result.created.isNotEmpty) {
        parts.add('Restart Apache to apply.');
      }
      if (hosts != null && hosts.changed) {
        parts.add('Mapped ${request.host}.');
      }
      _showMessage(parts.join(' '));
    } on FileSystemException catch (error) {
      _showMessage('Could not create the site: ${error.message}');
    }
  }

  Future<void> _mapSiteHosts(ProjectSite site) async {
    final inventory = _inventory;
    if (inventory == null) {
      return;
    }
    await _applyHostsUpdate(() => inventory.mapHosts([site.host]), [
      '127.0.0.1 ${site.host}',
    ]);
  }

  Future<void> _applyHostsUpdate(
    Future<HostsUpdate> Function() update,
    List<String> lines,
  ) async {
    final result = await update();
    if (!mounted) {
      return;
    }
    final layout = _layout;
    if (layout != null) {
      setState(() => _inventory = SiteInventory.load(layout));
    }

    if (result.written) {
      _showMessage(
        result.added.isEmpty
            ? 'Hosts file is already up to date.'
            : 'Added ${result.added.length} host '
                  '${result.added.length == 1 ? 'entry' : 'entries'}.',
      );
      return;
    }

    await _showHostsHelp(
      result.error ?? 'The hosts file could not be updated.',
      lines,
      retry: update,
    );
  }

  Future<void> _showHostsHelp(
    String message,
    List<String> lines, {
    Future<HostsUpdate> Function()? retry,
  }) async {
    final action = await showDialog<_HostsAction>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hosts file not updated'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message),
              const SizedBox(height: 12),
              const Text('These lines map the sites to 127.0.0.1:'),
              const SizedBox(height: 6),
              SelectableText(
                lines.join('\n'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              const Text(
                'Retry with administrator rights, open the hosts file in '
                'Notepad, or copy the lines into it yourself.',
                style: TextStyle(fontSize: 12, color: Color(0xFF7A8880)),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _HostsAction.open),
            child: const Text('Open hosts file'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, _HostsAction.copy),
            child: const Text('Copy lines'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          if (retry != null)
            FilledButton(
              onPressed: () => Navigator.pop(context, _HostsAction.retry),
              child: const Text('Retry as administrator'),
            ),
        ],
      ),
    );
    if (!mounted) {
      return;
    }

    switch (action) {
      case _HostsAction.copy:
        await Clipboard.setData(ClipboardData(text: lines.join('\r\n')));
        _showMessage('Hosts lines copied to the clipboard.');
      case _HostsAction.open:
        final path = _inventory?.hostsPath ?? HostsFile.defaultPath;
        final opened = await openHostsFileElevated(path);
        if (!opened && mounted) {
          _showMessage('Could not open $path as administrator.');
        }
      case _HostsAction.retry:
        if (retry != null) {
          await _applyHostsUpdate(retry, lines);
        }
      case null:
        break;
    }
  }

  Future<void> _openPath(String path) async {
    if (!Directory(path).existsSync()) {
      _showMessage('Folder does not exist: $path');
      return;
    }
    await _run('explorer.exe', [path]);
  }

  Future<void> _openUrl(String url) async {
    await _run('rundll32.exe', ['url.dll,FileProtocolHandler', url]);
  }

  Future<void> _openDatabase() async {
    final layout = _layout;
    if (layout == null) {
      return;
    }
    final launch = await showDatabaseDialog(
      context,
      layout: layout,
      editor: StackEditor(layout),
      openUrl: _openUrl,
    );
    if (!mounted || launch == null) {
      return;
    }
    setState(() => _inventory = SiteInventory.load(layout));

    final services = _services;
    final apacheExternal =
        services?.isExternal(StackComponent.apache) ?? false;
    if (launch.restartApache || apacheExternal) {
      if (apacheExternal) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Restart Apache outside StackPilot?'),
            content: Text(
              'Apache is running outside StackPilot, so it still has the old '
              'phpMyAdmin alias. Stop and restart it now? Other sites are '
              'unavailable for a moment.\n\n$launch.url',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Not now'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Restart Apache'),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) {
          return;
        }
      }
      await _restartApache();
      if (!mounted) {
        return;
      }
    }

    final probe = await probePhpMyAdmin(
      url: launch.url,
      retries: 8,
      timeout: const Duration(seconds: 3),
      retryDelay: const Duration(milliseconds: 250),
    );
    if (!mounted) {
      return;
    }
    if (!probe.ok) {
      await _showPhpMyAdminFailure(probe);
      return;
    }
    _showMessage('phpMyAdmin answered ${probe.summary}.');
    await _openUrl(launch.url);
  }

  /// Validates the Apache config, then stops and starts Apache so a freshly
  /// written alias is loaded.
  Future<void> _restartApache() async {
    final layout = _layout;
    final services = _services;
    if (layout == null || services == null) {
      return;
    }

    final check = await StackEditor(layout).verifyApacheConfig();
    if (!mounted) {
      return;
    }
    if (!check.ok) {
      final action = await showDialog<_DatabaseAction>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Apache configuration is not valid'),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'httpd -t reported the following, so Apache was left as it '
                  'is:',
                ),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 240),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0E1A14),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      check.output,
                      style: const TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 11.5,
                        height: 1.4,
                        color: Color(0xFFD8E8DF),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, _DatabaseAction.close),
              child: const Text('Close'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, _DatabaseAction.logs),
              icon: const Icon(Icons.article_outlined, size: 18),
              label: const Text('Open logs'),
            ),
          ],
        ),
      );
      if (action == _DatabaseAction.logs && mounted) {
        await _openLogs();
      }
      return;
    }

    if (services.isRunning(StackComponent.apache)) {
      await _toggleService(StackComponent.apache, false);
      if (!mounted) {
        return;
      }
    }
    await _toggleService(StackComponent.apache, true);
    if (!mounted) {
      return;
    }
    _showMessage('Restarted Apache to load the phpMyAdmin alias.');
  }

  /// Explains a failed phpMyAdmin request and offers the useful next steps.
  Future<void> _showPhpMyAdminFailure(PhpMyAdminProbe probe) async {
    final status = probe.statusCode;
    final String hint;
    if (status == null) {
      hint =
          'Apache did not answer. Start Apache and MySQL from the dashboard, '
          'and check that port 80 is free.';
    } else if (status == 403) {
      hint =
          'Apache refused the request. The alias may still point at an old '
          'folder, or Apache was started before the alias was written. '
          'Restart Apache and try again.';
    } else if (status == 404) {
      hint =
          'The /phpmyadmin alias is not loaded. Restart Apache so it reads '
          'etc\\apache2\\alias.';
    } else if (status >= 500) {
      hint =
          'PHP failed while loading phpMyAdmin. The PHP and Apache logs have '
          'the error; check that the active PHP version loads its modules.';
    } else {
      hint =
          'The page answered ${probe.summary}. Check the Logs window for the '
          'Apache and PHP error that caused it.';
    }

    final action = await showDialog<_DatabaseAction>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('phpMyAdmin did not answer'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                '${probe.url}\n${probe.summary}',
                style: const TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Text(hint, style: const TextStyle(fontSize: 12.5)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _DatabaseAction.close),
            child: const Text('Close'),
          ),
          TextButton.icon(
            onPressed: () => Navigator.pop(context, _DatabaseAction.logs),
            icon: const Icon(Icons.article_outlined, size: 18),
            label: const Text('Open logs'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _DatabaseAction.open),
            child: const Text('Open anyway'),
          ),
        ],
      ),
    );
    if (!mounted) {
      return;
    }
    switch (action) {
      case _DatabaseAction.logs:
        await _openLogs();
      case _DatabaseAction.open:
        await _openUrl(probe.url);
      case null:
      case _DatabaseAction.close:
        break;
    }
  }

  Future<void> _openLogs() async {
    final layout = _layout;
    if (layout == null) {
      return;
    }
    await showServiceLogsDialog(
      context,
      layout: layout,
      onOpenFolder: _openPath,
    );
  }

  void _onServiceExit(ServiceExit exit) {
    unawaited(_showServiceExit(exit));
  }

  /// Reports a service that died within five seconds of starting, with the
  /// last lines it wrote so the failure is visible without opening Logs.
  Future<void> _showServiceExit(ServiceExit exit) async {
    if (!mounted) {
      return;
    }
    final label = componentLabels[exit.component] ?? 'Service';
    final lines = exit.recentLines.isNotEmpty
        ? exit.recentLines
        : _lastLogLines(exit.component, 20);
    final seconds = (exit.after.inMilliseconds / 1000).toStringAsFixed(1);

    final action = await showDialog<_ExitAction>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$label stopped right after starting'),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$label exited with code ${exit.exitCode} after $seconds s. '
                'A port conflict, a missing DLL, or a bad config usually '
                'causes this.',
              ),
              const SizedBox(height: 12),
              if (lines.isEmpty)
                const Text(
                  'No output was captured. Open Logs for the service\'s own '
                  'log file.',
                  style: TextStyle(fontSize: 12.5, color: Color(0xFF7A8880)),
                )
              else
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 260),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0E1A14),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      lines.join('\n'),
                      style: const TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 11.5,
                        height: 1.4,
                        color: Color(0xFFD8E8DF),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _ExitAction.close),
            child: const Text('Close'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, _ExitAction.logs),
            icon: const Icon(Icons.article_outlined, size: 18),
            label: const Text('Open logs'),
          ),
        ],
      ),
    );
    if (action == _ExitAction.logs && mounted) {
      await _openLogs();
    }
  }

  List<String> _lastLogLines(StackComponent component, int count) {
    final layout = _layout;
    if (layout == null) {
      return const [];
    }
    final logs = ServiceLogs(layout);
    for (final file in logs.discover()) {
      if (file.component != component) {
        continue;
      }
      final tail = logs.readTail(file);
      if (!tail.exists || tail.text.isEmpty) {
        continue;
      }
      final lines = tail.text.split('\n');
      return lines.length <= count
          ? lines
          : lines.sublist(lines.length - count);
    }
    return const [];
  }

  Future<void> _openTerminal({String? directory}) async {
    final layout = _layout;
    if (layout == null) {
      return;
    }
    try {
      final launcher = TerminalLauncher(
        layout: layout,
        editor: StackEditor(layout),
        shell: TerminalShell.parse(_preferences.terminalShell),
      );
      await launcher.open(directory: directory);
    } on ProcessException catch (error) {
      _showMessage('Could not open a terminal: ${error.message}');
    } on FileSystemException catch (error) {
      _showMessage('Could not open a terminal: ${error.message}');
    }
  }

  Future<void> _run(String executable, List<String> arguments) async {
    try {
      await Process.run(executable, arguments);
    } on ProcessException catch (error) {
      _showMessage('Could not open target: ${error.message}');
    }
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final layout = _layout;
    final services = _services;
    final canStartAll =
        services != null &&
        !_bulkBusy &&
        StackLayout.serviceComponents.any(
          (component) =>
              layout!.serviceEnabled(component) && services.canStart(component),
        );
    final canStopAll =
        services != null && !_bulkBusy && services.hasRunningServices;
    final runningServices = services?.runningComponents.length ?? 0;

    return Scaffold(
      body: layout == null
          ? OnboardingView(
              attemptedRoot: widget.attemptedRoot,
              defaultRoot: p.join(
                _preferences.stacksFolder ??
                    StackBootstrap.defaultStacksFolder(),
                StackBootstrap.defaultStackName,
              ),
              legacyStacks: widget.importableStacks,
              recovering: _preferences.onboardingCompleted,
              onCreate: _createStack,
              onOpenExisting: _openExistingStack,
              onOpenLegacy: _openLegacyStack,
            )
          : Column(
              children: [
                DashboardHeader(
                  layout: layout,
                  runningServices: runningServices,
                  onStartAll: canStartAll ? _startAll : null,
                  onStopAll: canStopAll ? _stopAll : null,
                  onOpenWeb: () => _openUrl('http://localhost'),
                  onOpenTerminal: _openTerminal,
                  onOpenRoot: () => _openPath(layout.documentRoot),
                  onOpenDatabase: _openDatabase,
                  onOpenLogs: _openLogs,
                  onSettings: _openSettings,
                  onSetup: _openSetup,
                  onChangeStack: _changeStack,
                  onRescan: _refresh,
                ),
                if (_availableUpdate != null && !_updateDismissed)
                  UpdateBanner(
                    release: _availableUpdate!,
                    onInstall: () => _openSettings(initialTabIndex: 6),
                    onDismiss: () => setState(() => _updateDismissed = true),
                  ),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        flex: 3,
                        child: ServicesPanel(
                          layout: layout,
                          services: services,
                          busy: _busy,
                          bulkBusy: _bulkBusy,
                          onToggle: _toggleService,
                          onSelectVersion: _selectVersion,
                          onAddVersion: _addVersion,
                          onSetupStack: _openSetup,
                          onAdopt: _adoptStack,
                        ),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(
                        flex: 2,
                        child: ProjectsPanel(
                          layout: layout,
                          inventory: _inventory,
                          onOpenPath: _openPath,
                          onOpenUrl: _openUrl,
                          onGenerate:
                              ((_inventory?.missingConfigs.isNotEmpty ??
                                      false) ||
                                  (_inventory?.unmappedHosts.isNotEmpty ??
                                      false))
                              ? _generateVhosts
                              : null,
                          onAddSite: _addSite,
                          onMapHosts: _mapSiteHosts,
                          onOpenTerminal: (site) =>
                              _openTerminal(directory: site.directory),
                        ),
                      ),
                    ],
                  ),
                ),
                const DashboardFooter(),
              ],
            ),
    );
  }
}

/// Buttons offered when the hosts file could not be updated.
enum _HostsAction { retry, open, copy }

/// Asks for a free port after a conflict, showing who holds the old one.
class _PortConflictDialog extends StatefulWidget {
  const _PortConflictDialog({
    required this.componentLabel,
    required this.port,
    required this.owner,
    required this.message,
  });

  final String componentLabel;
  final int port;
  final PortOwner? owner;
  final String message;

  @override
  State<_PortConflictDialog> createState() => _PortConflictDialogState();
}

class _PortConflictDialogState extends State<_PortConflictDialog> {
  late final TextEditingController _port = TextEditingController(
    text: '${widget.port == 8080 ? 8081 : widget.port + 1}',
  );
  String? _error;

  @override
  void dispose() {
    _port.dispose();
    super.dispose();
  }

  void _submit() {
    final value = int.tryParse(_port.text.trim());
    if (value == null || value < 1 || value > 65535) {
      setState(() => _error = 'Enter a port between 1 and 65535.');
      return;
    }
    if (value == widget.port) {
      setState(() => _error = 'That is the port that is already in use.');
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    final owner = widget.owner;
    return AlertDialog(
      title: Text('Port ${widget.port} is already in use'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.message),
            const SizedBox(height: 12),
            Text(
              owner == null
                  ? 'The program holding the port could not be identified. '
                        'Close it, or move ${widget.componentLabel} to another '
                        'port:'
                  : 'Port ${widget.port} is held by ${owner.description}. '
                        'Move ${widget.componentLabel} to another port:',
              style: const TextStyle(fontSize: 12.5),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _port,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'New port',
                border: const OutlineInputBorder(),
                errorText: _error,
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 10),
            const Text(
              'The service configuration is updated for you, and the service '
              'is started again on the new port.',
              style: TextStyle(fontSize: 11.5, color: Color(0xFF7A8880)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Use this port'),
        ),
      ],
    );
  }
}

/// What the user chose after a service exited early.
enum _ExitAction { close, logs }

/// What the user chose after a phpMyAdmin request failed.
enum _DatabaseAction { open, logs, close }
