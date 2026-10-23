import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/app_preferences.dart';
import '../core/service_manager.dart';
import '../core/site_inventory.dart';
import '../core/stack_adoption.dart';
import '../core/stack_bootstrap.dart';
import '../core/stack_editor.dart';
import '../core/stack_layout.dart';
import 'component_presentation.dart';
import 'database_dialog.dart';
import 'logs_dialog.dart';
import 'settings_dialog.dart';
import 'version_dialog.dart';
import 'widgets/dashboard_chrome.dart';
import 'widgets/dashboard_header.dart';
import 'widgets/onboarding_view.dart';
import 'widgets/projects_panel.dart';
import 'widgets/services_panel.dart';
import 'widgets/stack_setup_dialog.dart';
import 'windows_dialogs.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({
    super.key,
    required this.layout,
    required this.attemptedRoot,
    this.serviceManagerFactory,
    this.preferences = AppPreferences.empty,
    this.preferencesStore,
  });

  final StackLayout? layout;
  final String attemptedRoot;
  final ServiceManager Function(StackLayout)? serviceManagerFactory;
  final AppPreferences preferences;
  final AppPreferencesStore? preferencesStore;

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

  ServiceManager? _createManager(StackLayout? layout) {
    if (layout == null) {
      return null;
    }
    final factory = widget.serviceManagerFactory;
    return factory == null ? ServiceManager(layout) : factory(layout);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_refreshExternal());
    });
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
  Future<void> _openSetup() async {
    final layout = _layout;
    if (layout == null) {
      return;
    }

    final result = await showStackSetupDialog(context, layout: layout);
    if (result == null || !mounted) {
      return;
    }

    if (result.changed) {
      await _reloadAfterConfigChange();
      if (!mounted) {
        return;
      }
    }

    if (result.failures.isNotEmpty) {
      _showMessage(result.failures.join('\n'));
    } else if (result.changed) {
      _showMessage(
        'Installed ${result.installed} '
        '${result.installed == 1 ? 'component' : 'components'}. '
        'Start them from their cards.',
      );
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

  Future<void> _openSettings() async {
    final layout = _layout;
    if (layout == null) {
      return;
    }

    final outcome = await showStackSettingsDialog(
      context,
      layout: layout,
      editor: StackEditor(layout),
      stacksFolder: _preferences.stacksFolder,
    );
    if (outcome == null || !mounted) {
      return;
    }

    final target = outcome.stackRoot;
    if (target != null) {
      await _switchToStack(target);
      return;
    }

    await _reloadAfterConfigChange();
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
        _showMessage(failures.map((error) => error.message).join('\n'));
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
      _showMessage(error.message);
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
                      'Writes 127.0.0.1 lines. Windows may ask for '
                      'administrator rights.',
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

    try {
      final result = inventory.generateMissing(mapHosts: mapHosts);
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
      if (result.mappedHosts.isNotEmpty) {
        parts.add(
          'Mapped ${result.mappedHosts.length} '
          '${result.mappedHosts.length == 1 ? 'host' : 'hosts'}.',
        );
      }
      if (result.changed) {
        parts.add('Restart Apache to apply.');
      }
      if (result.hostsError != null) {
        await _showHostsHelp(
          'The virtual-host configs were written, but ${inventory.hostsPath} '
          'could not be updated: ${result.hostsError}',
          unmapped.map((site) => '127.0.0.1 ${site.host}').toList(),
        );
      } else {
        _showMessage(
          parts.isEmpty
              ? 'Virtual hosts are already up to date.'
              : parts.join(' '),
        );
      }
    } on FileSystemException catch (error) {
      _showMessage('Could not write virtual hosts: ${error.message}');
    }
  }

  Future<void> _showHostsHelp(String message, List<String> lines) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hosts file not updated'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message),
            const SizedBox(height: 12),
            const Text('Add these lines as an administrator:'),
            const SizedBox(height: 6),
            SelectableText(
              lines.join('\n'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
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
    final url = await showDatabaseDialog(
      context,
      layout: layout,
      editor: StackEditor(layout),
      openUrl: _openUrl,
    );
    if (!mounted) {
      return;
    }
    setState(() => _inventory = SiteInventory.load(layout));
    if (url != null) {
      await _openUrl(url);
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

  Future<void> _openTerminal() async {
    final layout = _layout;
    if (layout == null) {
      return;
    }
    try {
      await Process.start(
        'cmd.exe',
        const [],
        workingDirectory: layout.root,
        mode: ProcessStartMode.detached,
      );
    } on ProcessException catch (error) {
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
              defaultRoot: StackBootstrap.defaultRoot(),
              onCreate: _createStack,
              onOpenExisting: _openExistingStack,
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
                  onChangeStack: _changeStack,
                  onRescan: _refresh,
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
