import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/app_preferences.dart';
import '../core/service_manager.dart';
import '../core/site_inventory.dart';
import '../core/stack_editor.dart';
import '../core/stack_layout.dart';
import 'database_dialog.dart';
import 'settings_dialog.dart';
import 'version_dialog.dart';
import 'windows_dialogs.dart';

const _componentLabels = {
  StackComponent.apache: 'Apache',
  StackComponent.nginx: 'Nginx',
  StackComponent.mysql: 'MySQL',
  StackComponent.postgresql: 'PostgreSQL',
  StackComponent.php: 'PHP',
  StackComponent.nodejs: 'Node.js',
  StackComponent.redis: 'Redis',
  StackComponent.memcached: 'Memcached',
  StackComponent.mailpit: 'Mailpit',
};

const _componentIcons = {
  StackComponent.apache: Icons.public,
  StackComponent.nginx: Icons.bolt,
  StackComponent.mysql: Icons.storage,
  StackComponent.postgresql: Icons.dns_outlined,
  StackComponent.php: Icons.code,
  StackComponent.nodejs: Icons.javascript,
  StackComponent.redis: Icons.memory,
  StackComponent.memcached: Icons.cached,
  StackComponent.mailpit: Icons.mail_outline,
};

enum _VersionMenuAction { add }

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

    final path = await pickFolder('Select a Laragon stack folder');
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
        'No Laragon stack found at $root. Expected usr/laragon.ini and bin/.',
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No Laragon-compatible stack found at $root.'),
        ),
      );
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
          'Stop ${_componentLabels[component]} before switching versions.',
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
        '${_componentLabels[component]} ${install.displayVersion} is now '
        'active.$restartNote',
      );
    } on StackEditException catch (error) {
      _showMessage(error.message);
    } on FileSystemException catch (error) {
      _showMessage('Could not switch version: ${error.message}');
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
      componentLabel: _componentLabels[component]!,
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
          '${_componentLabels[component]} ${result.install.displayVersion} was '
          'installed. Stop the service before activating it.',
        );
      } else {
        await _selectVersion(component, result.install);
      }
    } else {
      _showMessage(
        '${_componentLabels[component]} ${result.install.displayVersion} was '
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
        '${_componentLabels[component]}: ${error.message}',
      );
    } finally {
      if (mounted) {
        setState(() => _busy.remove(component));
      }
    }
  }

  Future<void> _generateVhosts() async {
    final inventory = _inventory;
    if (inventory == null || inventory.missingConfigs.isEmpty) {
      return;
    }
    final missing = inventory.missingConfigs;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Generate virtual hosts?'),
        content: Text(
          'Create ${missing.length} config '
          '${missing.length == 1 ? 'file' : 'files'} in '
          '${inventory.sitesEnabledDirectory}:\n\n'
          '${missing.map((site) => site.host).join('\n')}\n\n'
          'Existing config files and hosts entries are left unchanged.',
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
    );
    if (confirmed != true || !mounted) {
      return;
    }

    try {
      final result = inventory.generateMissing();
      setState(() {
        _inventory = SiteInventory.load(inventory.layout);
      });
      _showMessage(
        result.changed
            ? 'Created ${result.created.length} virtual host '
                  '${result.created.length == 1 ? 'file' : 'files'}. '
                  'Restart Apache to apply.'
            : 'Virtual hosts are already up to date.',
      );
    } on FileSystemException catch (error) {
      _showMessage('Could not write virtual hosts: ${error.message}');
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

  void _showMessage(String message) {    if (!mounted) {
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

    return Scaffold(
      body: layout == null
          ? _MissingStackView(
              attemptedRoot: widget.attemptedRoot,
              onRetry: _refresh,
            )
          : Column(
              children: [
                _Header(
                  layout: layout,
                  onStartAll: canStartAll ? _startAll : null,
                  onStopAll: canStopAll ? _stopAll : null,
                  onOpenWeb: () => _openUrl('http://localhost'),
                  onOpenTerminal: _openTerminal,
                  onOpenRoot: () => _openPath(layout.documentRoot),
                  onOpenDatabase: _openDatabase,
                  onSettings: _openSettings,
                  onChangeStack: _changeStack,
                ),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        flex: 3,
                        child: _ServicesPanel(
                          layout: layout,
                          services: services,
                          busy: _busy,
                          bulkBusy: _bulkBusy,
                          onToggle: _toggleService,
                          onSelectVersion: _selectVersion,
                          onAddVersion: _addVersion,
                        ),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(
                        flex: 2,
                        child: _ProjectsPanel(
                          layout: layout,
                          inventory: _inventory,
                          onOpenPath: _openPath,
                          onGenerate:
                              (_inventory?.missingConfigs.isNotEmpty ?? false)
                              ? _generateVhosts
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
                const _Footer(),
              ],
            ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.layout,
    required this.onStartAll,
    required this.onStopAll,
    required this.onOpenWeb,
    required this.onOpenTerminal,
    required this.onOpenRoot,
    required this.onOpenDatabase,
    required this.onSettings,
    required this.onChangeStack,
  });

  final StackLayout layout;
  final VoidCallback? onStartAll;
  final VoidCallback? onStopAll;
  final VoidCallback onOpenWeb;
  final VoidCallback onOpenTerminal;
  final VoidCallback onOpenRoot;
  final VoidCallback onOpenDatabase;
  final VoidCallback onSettings;
  final VoidCallback onChangeStack;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 16),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0A3528), Color(0xFF0E7A4A)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Image.asset(
                  'assets/branding/stackpilot_mark.png',
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'StackPilot',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                    ),
                    Text(
                      'Pilot your local dev stack',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.check_circle_outline,
                      size: 15,
                      color: Colors.white70,
                    ),
                    SizedBox(width: 6),
                    Text(
                      'Detected',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Flexible(
                child: Text(
                  layout.root,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: onChangeStack,
                icon: const Icon(Icons.folder_open, size: 14),
                label: const Text('Change stack'),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white70,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 11.5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _HeaderAction(
                icon: Icons.play_arrow_rounded,
                label: 'Start All',
                onPressed: onStartAll,
                tooltip: 'Start every enabled service',
              ),
              _HeaderAction(
                icon: Icons.stop_rounded,
                label: 'Stop All',
                onPressed: onStopAll,
                tooltip: 'Stop services started by StackPilot',
              ),
              _HeaderAction(
                icon: Icons.language,
                label: 'Web',
                onPressed: onOpenWeb,
              ),
              _HeaderAction(
                icon: Icons.storage,
                label: 'Database',
                onPressed: onOpenDatabase,
                tooltip: 'Open phpMyAdmin, or install it in the web root',
              ),
              _HeaderAction(
                icon: Icons.terminal,
                label: 'Terminal',
                onPressed: onOpenTerminal,
              ),
              _HeaderAction(
                icon: Icons.tune,
                label: 'Settings',
                onPressed: onSettings,
                tooltip:
                    'Change versions, ports, document root, and PHP settings',
              ),
              _HeaderAction(
                icon: Icons.folder_open,
                label: 'Root',
                onPressed: onOpenRoot,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeaderAction extends StatelessWidget {
  const _HeaderAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.tooltip,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? label,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          disabledForegroundColor: Colors.white38,
          backgroundColor: Colors.white.withValues(
            alpha: onPressed == null ? 0.04 : 0.10,
          ),
          side: BorderSide(
            color: Colors.white.withValues(
              alpha: onPressed == null ? 0.10 : 0.24,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
      ),
    );
  }
}

class _ServicesPanel extends StatelessWidget {
  const _ServicesPanel({
    required this.layout,
    required this.services,
    required this.busy,
    required this.bulkBusy,
    required this.onToggle,
    required this.onSelectVersion,
    required this.onAddVersion,
  });

  final StackLayout layout;
  final ServiceManager? services;
  final Set<StackComponent> busy;
  final bool bulkBusy;
  final void Function(StackComponent component, bool start) onToggle;
  final void Function(StackComponent component, StackInstall install)
  onSelectVersion;
  final void Function(StackComponent component) onAddVersion;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Versions & services',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            const _MutedChip(label: 'Click version to switch'),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          'Runtimes',
          style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final component in StackLayout.runtimeComponents)
              _ServiceCard(
                layout: layout,
                component: component,
                isService: false,
                services: services,
                busy: bulkBusy || busy.contains(component),
                onToggle: onToggle,
                onSelectVersion: onSelectVersion,
                onAddVersion: onAddVersion,
              ),
          ],
        ),
        const SizedBox(height: 24),
        Text(
          'Services',
          style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final component in StackLayout.serviceComponents)
              _ServiceCard(
                layout: layout,
                component: component,
                isService: true,
                services: services,
                busy: bulkBusy || busy.contains(component),
                onToggle: onToggle,
                onSelectVersion: onSelectVersion,
                onAddVersion: onAddVersion,
              ),
          ],
        ),
      ],
    );
  }
}

class _ServiceCard extends StatelessWidget {
  const _ServiceCard({
    required this.layout,
    required this.component,
    required this.isService,
    required this.services,
    required this.busy,
    required this.onToggle,
    required this.onSelectVersion,
    required this.onAddVersion,
  });

  final StackLayout layout;
  final StackComponent component;
  final bool isService;
  final ServiceManager? services;
  final bool busy;
  final void Function(StackComponent component, bool start)? onToggle;
  final void Function(StackComponent component, StackInstall install)?
  onSelectVersion;
  final void Function(StackComponent component)? onAddVersion;

  @override
  Widget build(BuildContext context) {
    final installed = layout.installedVersions(component);
    final active = layout.activeVersion(component);
    final displayed =
        active ?? (installed.length == 1 ? installed.single : null);
    final configured = isService && layout.serviceEnabled(component);
    final running = services?.isRunning(component) ?? false;
    final external = services?.isExternal(component) ?? false;
    final canToggle =
        isService && services != null && !busy && (running || configured);
    final colorScheme = Theme.of(context).colorScheme;

    final String versionLabel;
    if (displayed != null) {
      versionLabel = displayed.displayVersion;
    } else if (installed.isEmpty) {
      versionLabel = 'Not installed';
    } else {
      versionLabel = 'Not selected';
    }

    final String statusLabel;
    final Color statusColor;
    if (!isService) {
      statusLabel = active != null ? 'Active' : 'Idle';
      statusColor = active != null
          ? const Color(0xFF0E7A4A)
          : const Color(0xFF8A6D3B);
    } else if (busy) {
      statusLabel = 'Working…';
      statusColor = const Color(0xFF8A6D3B);
    } else if (running) {
      statusLabel = external ? 'Running (external)' : 'Running';
      statusColor = const Color(0xFF0E7A4A);
    } else if (configured) {
      statusLabel = 'Stopped';
      statusColor = const Color(0xFF8A6D3B);
    } else {
      statusLabel = 'Disabled';
      statusColor = const Color(0xFF7A8880);
    }

    return Container(
      width: 218,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE1E8E4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _componentIcons[component],
                size: 20,
                color: colorScheme.primary,
              ),
              const Spacer(),
              if (isService)
                Tooltip(
                  message: running
                      ? external
                            ? 'Stop ${_componentLabels[component]} '
                                  '(started outside StackPilot)'
                            : 'Stop ${_componentLabels[component]}'
                      : configured
                      ? 'Start ${_componentLabels[component]}'
                      : 'Enable ${_componentLabels[component]} in laragon.ini first',
                  child: Switch(
                    value: running,
                    onChanged: canToggle
                        ? (value) => onToggle?.call(component, value)
                        : null,
                  ),
                )
              else
                _StatusBadge(label: statusLabel, color: statusColor),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _componentLabels[component]!,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 3),
          if (installed.isEmpty)
            Text(
              versionLabel,
              style: const TextStyle(fontSize: 12.5, color: Color(0xFF44534B)),
            )
          else
            PopupMenuButton<Object>(
              tooltip: 'Change ${_componentLabels[component]} version',
              padding: EdgeInsets.zero,
              position: PopupMenuPosition.under,
              onSelected: (value) {
                if (value == _VersionMenuAction.add) {
                  onAddVersion?.call(component);
                } else if (value is StackInstall) {
                  onSelectVersion?.call(component, value);
                }
              },
              itemBuilder: (context) => [
                for (final install in installed)
                  CheckedPopupMenuItem<Object>(
                    value: install,
                    checked:
                        active != null &&
                        install.directory.toLowerCase() ==
                            active.directory.toLowerCase(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(install.displayVersion),
                        Text(
                          install.version,
                          style: const TextStyle(
                            fontSize: 10.5,
                            color: Color(0xFF7A8880),
                          ),
                        ),
                      ],
                    ),
                  ),
                const PopupMenuDivider(),
                const PopupMenuItem<Object>(
                  value: _VersionMenuAction.add,
                  child: Row(
                    children: [
                      Icon(Icons.add, size: 17),
                      SizedBox(width: 8),
                      Text('Add version…'),
                    ],
                  ),
                ),
              ],
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F7F3),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFCFE0D6)),
                ),
                child: Row(
                  children: [
                    const Text(
                      'Version',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: Color(0xFF6B7C73),
                      ),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        versionLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: Color(0xFF2F4238),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 18,
                      color: Color(0xFF52605A),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 2),
          if (installed.isEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: onAddVersion == null
                    ? null
                    : () => onAddVersion!(component),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add version'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(32),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            )
          else
            Text(
              '${installed.length} installed '
              '${installed.length == 1 ? 'version' : 'versions'} · click to '
              'switch',
              style: const TextStyle(fontSize: 11.5, color: Color(0xFF7A8880)),
            ),
          if (isService) ...[
            const SizedBox(height: 8),
            Text(
              statusLabel,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: statusColor,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _MutedChip extends StatelessWidget {
  const _MutedChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFE9EFEB),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 11.5, color: Color(0xFF52605A)),
      ),
    );
  }
}

class _ProjectsPanel extends StatelessWidget {
  const _ProjectsPanel({
    required this.layout,
    required this.inventory,
    required this.onOpenPath,
    required this.onGenerate,
  });

  final StackLayout layout;
  final SiteInventory? inventory;
  final ValueChanged<String> onOpenPath;
  final VoidCallback? onGenerate;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final sites = inventory?.sites ?? const <ProjectSite>[];
    final missing = inventory?.missingConfigs.length ?? 0;

    return Container(
      color: Colors.white,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Row(
            children: [
              Text(
                'Projects',
                style: textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Text(
                '${sites.length}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF7A8880),
                ),
              ),
              if (missing > 0 && onGenerate != null)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: IconButton(
                    tooltip:
                        'Generate $missing missing virtual host '
                        '${missing == 1 ? 'config' : 'configs'}',
                    icon: const Icon(Icons.auto_fix_high, size: 19),
                    onPressed: onGenerate,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            layout.documentRoot,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5, color: Color(0xFF7A8880)),
          ),
          const SizedBox(height: 12),
          if (sites.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'No projects found in the document root yet.',
                style: TextStyle(color: Color(0xFF7A8880)),
              ),
            )
          else
            for (final site in sites)
              ListTile(
                contentPadding: EdgeInsets.zero,
                isThreeLine: true,
                leading: CircleAvatar(
                  radius: 18,
                  backgroundColor: const Color(0xFFEAF3EE),
                  child: Icon(
                    Icons.folder_outlined,
                    size: 19,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                title: Text(
                  site.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (layout.autoVirtualHosts)
                      Text(
                        site.host,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: Color(0xFF0E7A4A),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    Text(
                      site.documentRoot,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF7A8880),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        _SiteChip(
                          label: site.configPresent
                              ? site.configOutdated
                                    ? 'vhost outdated'
                                    : 'vhost'
                              : 'vhost missing',
                          ok: site.configPresent && !site.configOutdated,
                        ),
                        _SiteChip(
                          label: site.hostsMapped ? 'hosts' : 'hosts missing',
                          ok: site.hostsMapped,
                        ),
                        if (site.sslEnabled)
                          const _SiteChip(label: 'SSL', ok: true),
                      ],
                    ),
                  ],
                ),
                trailing: IconButton(
                  tooltip: 'Open folder',
                  icon: const Icon(Icons.open_in_new, size: 18),
                  onPressed: () => onOpenPath(site.directory),
                ),
              ),
        ],
      ),
    );
  }
}

class _SiteChip extends StatelessWidget {
  const _SiteChip({required this.label, required this.ok});

  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final color = ok ? const Color(0xFF0E7A4A) : const Color(0xFF8A6D3B);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 9),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE1E8E4))),
      ),
      child: const Row(
        children: [
          Expanded(
            child: Text(
              'Local only  •  No telemetry  •  No donation prompts',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: Color(0xFF7A8880)),
            ),
          ),
          SizedBox(width: 12),
          Text(
            'Managed locally',
            style: TextStyle(fontSize: 11, color: Color(0xFF7A8880)),
          ),
        ],
      ),
    );
  }
}

class _MissingStackView extends StatelessWidget {
  const _MissingStackView({required this.attemptedRoot, required this.onRetry});

  final String attemptedRoot;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Card(
          margin: const EdgeInsets.all(24),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.folder_off_outlined,
                  size: 40,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 14),
                const Text(
                  'Stack not found',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                const Text(
                  'StackPilot looked for a Laragon-compatible stack at:',
                ),
                const SizedBox(height: 6),
                SelectableText(
                  attemptedRoot,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Start StackPilot with --stack-root=C:\\path\\to\\laragon '
                  'or set STACKPILOT_STACK_ROOT.',
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
