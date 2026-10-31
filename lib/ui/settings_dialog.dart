import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/app_info.dart';
import '../core/app_log.dart';
import '../core/app_preferences.dart';
import '../core/diagnostics.dart';
import '../core/download_cache.dart';
import '../core/paths.dart';
import '../core/stack_bootstrap.dart';
import '../core/stack_catalog.dart';
import '../core/stack_editor.dart';
import '../core/stack_layout.dart';
import '../core/stack_mover.dart';
import '../core/stack_settings.dart';
import '../core/terminal.dart';
import '../core/update_service.dart';
import 'windows_dialogs.dart';

const _serviceLabels = {
  StackComponent.apache: 'Apache',
  StackComponent.nginx: 'Nginx',
  StackComponent.mysql: 'MySQL',
  StackComponent.postgresql: 'PostgreSQL',
  StackComponent.redis: 'Redis',
  StackComponent.memcached: 'Memcached',
  StackComponent.mailpit: 'Mailpit',
};

/// What the user asked for when the settings dialog closed.
class StackSettingsOutcome {
  const StackSettingsOutcome.saved({
    this.preferences,
    this.openSetup = false,
  }) : stackRoot = null;

  /// Close the dialog and open [stackRoot] instead of the current stack.
  const StackSettingsOutcome.switchTo(
    this.stackRoot, {
    this.preferences,
    this.openSetup = false,
  });

  final String? stackRoot;

  /// Preferences changed in this dialog, when any.
  final AppPreferences? preferences;

  /// Open the setup wizard once the dialog closes.
  final bool openSetup;
}

Future<StackSettingsOutcome?> showStackSettingsDialog(
  BuildContext context, {
  required StackLayout layout,
  required StackEditor editor,
  String? stacksFolder,
  AppPreferences preferences = AppPreferences.empty,
  AppPreferencesStore? preferencesStore,
  Iterable<StackComponent> runningServices = const [],
  int initialTabIndex = 0,
}) {
  return showDialog<StackSettingsOutcome>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _StackSettingsDialog(
      layout: layout,
      editor: editor,
      stacksFolder: stacksFolder,
      preferences: preferences,
      preferencesStore: preferencesStore,
      runningServices: runningServices,
      initialTabIndex: initialTabIndex,
    ),
  );
}

class _StackSettingsDialog extends StatefulWidget {
  const _StackSettingsDialog({
    required this.layout,
    required this.editor,
    this.stacksFolder,
    this.preferences = AppPreferences.empty,
    this.preferencesStore,
    this.runningServices = const [],
    this.initialTabIndex = 0,
  });

  final StackLayout layout;
  final StackEditor editor;
  final String? stacksFolder;
  final AppPreferences preferences;
  final AppPreferencesStore? preferencesStore;
  final Iterable<StackComponent> runningServices;
  final int initialTabIndex;

  @override
  State<_StackSettingsDialog> createState() => _StackSettingsDialogState();
}

class _StackSettingsDialogState extends State<_StackSettingsDialog> {
  late final StackSettings _settings = StackSettings.load(widget.layout);
  late final TextEditingController _documentRoot = TextEditingController(
    text: _settings.documentRoot,
  );
  late final TextEditingController _dataDirectory = TextEditingController(
    text: _settings.dataDirectory,
  );
  late final TextEditingController _mysqlPort = TextEditingController(
    text: '${_settings.mysqlPort}',
  );
  late final TextEditingController _postgresqlPort = TextEditingController(
    text: '${_settings.postgresqlPort}',
  );
  late final TextEditingController _memoryLimit = TextEditingController(
    text: _settings.php.memoryLimit,
  );
  late final TextEditingController _uploadMax = TextEditingController(
    text: _settings.php.uploadMaxFilesize,
  );
  late final TextEditingController _postMax = TextEditingController(
    text: _settings.php.postMaxSize,
  );
  late final TextEditingController _executionTime = TextEditingController(
    text: _settings.php.maxExecutionTime,
  );

  late bool _autoVirtualHosts = _settings.autoVirtualHosts;
  late bool _apacheSsl = _settings.apacheSsl;
  late bool _apacheListenOnLan = _settings.apacheListenOnLan;
  late bool _displayErrors = _settings.php.displayErrors;
  late final Set<StackComponent> _enabledServices = {
    ..._settings.enabledServices,
  };

  late final TextEditingController _stacksFolder = TextEditingController(
    text: normalizeWindowsPath(
      widget.stacksFolder ?? p.dirname(widget.layout.root),
    ),
  );
  late List<String> _detectedStacks = _scanStacks(_stacksFolder.text);
  bool _switching = false;

  /// Text of the modal progress dialog while a stack is copied or deleted.
  String? _busyMessage;

  late final TextEditingController _updateUrl = TextEditingController(
    text: widget.preferences.updateManifestUrl ?? AppInfo.updateManifestUrl,
  );
  late ReleaseChannel _updateChannel = widget.preferences.updateChannel;
  late bool _autoCheckUpdates = widget.preferences.autoCheckUpdates;
  late TerminalShell _terminalShell = TerminalShell.parse(
    widget.preferences.terminalShell,
  );
  bool _checkingUpdate = false;
  bool _installingUpdate = false;
  double? _downloadFraction;
  UpdateCheckResult? _updateResult;
  String? _updateError;
  late final List<CachedInstaller> _cachedInstallers =
      UpdateService.scanCache();
  late final DownloadCache _downloadCache = DownloadCache();
  int _cacheFiles = 0;
  int _cacheBytes = 0;
  String? _bundlePath;
  bool _creatingBundle = false;

  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cacheFiles = _downloadCache.count;
    _cacheBytes = _downloadCache.sizeBytes;
  }

  @override
  void dispose() {
    _documentRoot.dispose();
    _dataDirectory.dispose();
    _mysqlPort.dispose();
    _postgresqlPort.dispose();
    _memoryLimit.dispose();
    _uploadMax.dispose();
    _postMax.dispose();
    _executionTime.dispose();
    _stacksFolder.dispose();
    _updateUrl.dispose();
    super.dispose();
  }

  List<String> _scanStacks(String folder) {
    final normalized = normalizeWindowsPath(folder);
    final discovered = StackCatalog.scan(normalized);
    final current = p.normalize(widget.layout.root);
    if (discovered.any((root) => p.equals(root, current))) {
      return discovered;
    }
    return [current, ...discovered];
  }

  Future<void> _browseStacksFolder() async {
    final path = await pickFolder('Select the folder that contains your stacks');
    if (path == null || !mounted) {
      return;
    }
    final normalized = normalizeWindowsPath(path);
    setState(() {
      _stacksFolder.text = normalized;
      _detectedStacks = _scanStacks(normalized);
    });
  }

  Future<void> _useStack(String root) async {
    if (_switching || _saving) {
      return;
    }
    setState(() => _switching = true);
    if (mounted) {
      Navigator.of(context).pop(
        StackSettingsOutcome.switchTo(
          root,
          preferences: _editedPreferences(),
        ),
      );
    }
  }

  Future<void> _save() async {
    if (_saving) {
      return;
    }

    final documentRoot = normalizeWindowsPath(_documentRoot.text);
    final dataDirectory = normalizeWindowsPath(_dataDirectory.text);
    final stacksFolder = normalizeWindowsPath(_stacksFolder.text);
    final port = int.tryParse(_mysqlPort.text.trim());
    final postgresqlPort = int.tryParse(_postgresqlPort.text.trim());
    if (documentRoot.isEmpty) {
      _fail('Document root cannot be empty.');
      return;
    }
    if (dataDirectory.isEmpty) {
      _fail('Data directory cannot be empty.');
      return;
    }
    if (stacksFolder.isEmpty) {
      _fail('Stacks folder cannot be empty.');
      return;
    }
    if (port == null || port < 1 || port > 65535) {
      _fail('MySQL port must be a number between 1 and 65535.');
      return;
    }
    if (postgresqlPort == null ||
        postgresqlPort < 1 ||
        postgresqlPort > 65535) {
      _fail('PostgreSQL port must be a number between 1 and 65535.');
      return;
    }

    final memoryLimit = _memoryLimit.text.trim();
    final uploadMax = _uploadMax.text.trim();
    final postMax = _postMax.text.trim();
    final executionTime = _executionTime.text.trim();
    if (_settings.php.editable &&
        (memoryLimit.isEmpty ||
            uploadMax.isEmpty ||
            postMax.isEmpty ||
            executionTime.isEmpty)) {
      _fail('PHP values cannot be empty.');
      return;
    }

    final documentRootReady = await _ensureDocumentRoot(documentRoot);
    if (!documentRootReady || !mounted) {
      return;
    }
    await _offerProjectCopy(documentRoot);
    if (!mounted) {
      return;
    }

    setState(() {
      _documentRoot.text = documentRoot;
      _dataDirectory.text = dataDirectory;
      _stacksFolder.text = stacksFolder;
      _saving = true;
      _error = null;
    });

    final settings = StackSettings(
      documentRoot: documentRoot,
      dataDirectory: dataDirectory,
      mysqlPort: port,
      postgresqlPort: postgresqlPort,
      autoVirtualHosts: _autoVirtualHosts,
      apacheSsl: _apacheSsl,
      apacheListenOnLan: _apacheListenOnLan,
      enabledServices: Set<StackComponent>.of(_enabledServices),
      php: _settings.php.copyWith(
        memoryLimit: memoryLimit,
        uploadMaxFilesize: uploadMax,
        postMaxSize: postMax,
        maxExecutionTime: executionTime,
        displayErrors: _displayErrors,
      ),
    );

    try {
      widget.editor.applySettings(settings);
      final updatedPreferences = _editedPreferences().copyWith(
        stacksFolder: stacksFolder,
        onboardingCompleted: true,
      );
      await widget.preferencesStore?.save(updatedPreferences);
      if (mounted) {
        Navigator.of(
          context,
        ).pop(StackSettingsOutcome.saved(preferences: updatedPreferences));
      }
    } on StackEditException catch (error) {
      _fail(error.message);
    } on FileSystemException catch (error) {
      _fail('Could not save settings: ${error.message}');
    } on Object catch (error) {
      _fail('Could not save settings: $error');
    }
  }

  /// Makes sure the document root exists, offering to create it.
  Future<bool> _ensureDocumentRoot(String path) async {
    if (Directory(path).existsSync()) {
      return true;
    }
    final create = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Document root does not exist'),
        content: Text(
          '$path does not exist yet.\n\nCreate it now? Your sites will live '
          'in that folder.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Create folder'),
          ),
        ],
      ),
    );
    if (create != true) {
      _fail('The document root does not exist: $path');
      return false;
    }
    try {
      Directory(path).createSync(recursive: true);
      return true;
    } on FileSystemException catch (error) {
      _fail('Could not create $path: ${error.message}');
      return false;
    }
  }

  /// Warns when the document root leaves the stack and offers to copy the
  /// existing projects there.
  Future<void> _offerProjectCopy(String target) async {
    final current = normalizeWindowsPath(widget.layout.documentRoot);
    if (sameWindowsPath(current, target) ||
        isWithinWindowsPath(widget.layout.root, target)) {
      return;
    }
    final source = Directory(current);
    final hasProjects =
        source.existsSync() &&
        !sameWindowsPath(current, p.join(widget.layout.root, 'www'));
    final copy = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Document root is outside the stack'),
        content: Text(
          'The new document root is not inside ${widget.layout.root}. '
          'StackPilot keeps working, but a stack move will not carry those '
          'projects with it.'
          '${hasProjects ? '\n\nCopy the projects from $current to $target '
                    'now?' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep where they are'),
          ),
          if (hasProjects)
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Copy my projects too'),
            ),
        ],
      ),
    );
    if (copy == true) {
      try {
        _copyTree(source, Directory(target));
      } on FileSystemException catch (error) {
        _fail('Could not copy the projects: ${error.message}');
      }
    }
  }

  static void _copyTree(Directory source, Directory target) {
    if (!source.existsSync()) {
      return;
    }
    target.createSync(recursive: true);
    for (final entry in source.listSync(followLinks: false)) {
      final destination = p.join(target.path, p.basename(entry.path));
      if (entry is Directory) {
        _copyTree(entry, Directory(destination));
      } else if (entry is File && !File(destination).existsSync()) {
        entry.copySync(destination);
      }
    }
  }

  void _fail(String message) {
    if (!mounted) {
      return;
    }
    setState(() {
      _saving = false;
      _error = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.tune, size: 20),
          SizedBox(width: 8),
          Text('Stack settings'),
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      content: SizedBox(
        width: 680,
        height: 500,
        child: DefaultTabController(
          length: 8,
          initialIndex: widget.initialTabIndex,
          child: Column(
            children: [
              const TabBar(
                isScrollable: true,
                tabs: [
                  Tab(text: 'Stacks'),
                  Tab(text: 'General'),
                  Tab(text: 'Services'),
                  Tab(text: 'MySQL'),
                  Tab(text: 'PostgreSQL'),
                  Tab(text: 'PHP'),
                  Tab(text: 'Updates'),
                  Tab(text: 'Diagnostics'),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: TabBarView(
                  children: [
                    _stacksTab(),
                    _generalTab(),
                    _servicesTab(),
                    _mysqlTab(),
                    _postgresqlTab(),
                    _phpTab(),
                    _updatesTab(),
                    _diagnosticsTab(),
                  ],
                ),
              ),
              if (_error != null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFBEAEA),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      color: Color(0xFFA33A3A),
                      fontSize: 12.5,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving || _switching || _busyMessage != null
              ? null
              : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _saving || _switching || _busyMessage != null
              ? null
              : _save,
          icon: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined, size: 18),
          label: Text(_saving ? 'Saving…' : 'Save settings'),
        ),
      ],
    );
  }

  Widget _stacksTab() {
    final currentRoot = p.normalize(widget.layout.root);
    final busy = _saving || _switching || _busyMessage != null;
    return ListView(
      padding: const EdgeInsets.only(top: 4),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _stacksFolder,
                enabled: !busy,
                onSubmitted: (value) =>
                    setState(() => _detectedStacks = _scanStacks(value)),
                decoration: const InputDecoration(
                  labelText: 'Stacks folder',
                  border: OutlineInputBorder(),
                  helperText:
                      'Where StackPilot looks for and creates stacks. Saved '
                      'with the other settings.',
                ),
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: IconButton.filledTonal(
                tooltip: 'Browse…',
                onPressed: busy ? null : _browseStacksFolder,
                icon: const Icon(Icons.folder_open),
              ),
            ),
            const SizedBox(width: 4),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: IconButton.filledTonal(
                tooltip: 'Scan again',
                onPressed: busy
                    ? null
                    : () => setState(
                        () => _detectedStacks = _scanStacks(_stacksFolder.text),
                      ),
                icon: const Icon(Icons.refresh),
              ),
            ),
          ],
        ),
        if (_busyMessage != null) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
          const SizedBox(height: 6),
          Text(
            _busyMessage!,
            style: const TextStyle(fontSize: 12, color: Color(0xFF52605A)),
          ),
        ],
        const SizedBox(height: 14),
        Row(
          children: [
            Text(
              'Stacks in this folder',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: busy ? null : _newStack,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New stack…'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (_detectedStacks.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'No stack was found in that folder. Each stack needs '
              'usr\\stackpilot.ini (or usr\\laragon.ini) and a bin folder.',
              style: TextStyle(fontSize: 12.5, color: Color(0xFF7A8880)),
            ),
          )
        else
          for (final root in _detectedStacks)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.folder_outlined),
              title: Row(
                children: [
                  Flexible(
                    child: Text(
                      p.basename(root),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (p.equals(root, currentRoot)) ...[
                    const SizedBox(width: 8),
                    const Text(
                      'Current',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF0E7A4A),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
              subtitle: Text(root, style: const TextStyle(fontSize: 12)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: busy ? null : () => _useStack(root),
                    child: const Text('Open'),
                  ),
                  PopupMenuButton<_StackAction>(
                    enabled: !busy,
                    tooltip: 'Stack actions',
                    onSelected: (action) => switch (action) {
                      _StackAction.rename => _renameStack(root),
                      _StackAction.move => _moveStack(root),
                      _StackAction.delete => _deleteStack(root),
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: _StackAction.rename,
                        child: Text('Rename…'),
                      ),
                      PopupMenuItem(
                        value: _StackAction.move,
                        child: Text('Move…'),
                      ),
                      PopupMenuItem(
                        value: _StackAction.delete,
                        child: Text('Delete…'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        const SizedBox(height: 8),
        const _Hint(
          'Moving a stack copies bin, usr, etc, www, data and logs, rewrites '
          'every absolute path, then offers to delete the old copy. Stop all '
          'services first.',
        ),
      ],
    );
  }

  Future<void> _newStack() async {
    if (widget.runningServices.isNotEmpty) {
      _fail('Stop all services before creating a stack.');
      return;
    }
    final request = await showDialog<_NewStackRequest>(
      context: context,
      builder: (context) => _NewStackDialog(
        parent: _stacksFolder.text,
        defaultName: _nextStackName(),
      ),
    );
    if (request == null || !mounted) {
      return;
    }

    final parent = normalizeWindowsPath(request.parent);
    final root = normalizeWindowsPath(p.join(parent, request.name));
    setState(() => _busyMessage = 'Creating $root…');
    try {
      final layout = StackBootstrap.create(root: root);
      final preferences = _editedPreferences().copyWith(
        stacksFolder: parent,
        activeStack: layout.root,
        onboardingCompleted: true,
      );
      await widget.preferencesStore?.save(preferences);
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(
        StackSettingsOutcome.switchTo(
          layout.root,
          preferences: preferences,
          openSetup: true,
        ),
      );
    } on StackBootstrapException catch (error) {
      _fail(error.message);
    } on FileSystemException catch (error) {
      _fail('Could not create the stack: ${error.message}');
    } finally {
      if (mounted && _busyMessage != null) {
        setState(() => _busyMessage = null);
      }
    }
  }

  String _nextStackName() {
    final used = {
      for (final root in _detectedStacks) p.basename(root).toLowerCase(),
    };
    if (!used.contains('default')) {
      return 'default';
    }
    for (var index = 2; index < 100; index++) {
      final name = 'stack$index';
      if (!used.contains(name)) {
        return name;
      }
    }
    return 'stack';
  }

  Future<void> _renameStack(String root) async {
    final name = await _promptStackName(
      title: 'Rename ${p.basename(root)}',
      hint: 'Folder name',
      initial: p.basename(root),
    );
    if (name == null || !mounted) {
      return;
    }
    final target = normalizeWindowsPath(p.join(p.dirname(root), name));
    await _moveStackTo(root, target);
  }

  Future<void> _moveStack(String root) async {
    final parent = await pickFolder(
      'Choose the new parent folder for ${p.basename(root)}',
    );
    if (parent == null || !mounted) {
      return;
    }
    final target = normalizeWindowsPath(
      p.join(normalizeWindowsPath(parent), p.basename(root)),
    );
    await _moveStackTo(root, target);
  }

  Future<void> _moveStackTo(String source, String target) async {
    if (widget.runningServices.isNotEmpty) {
      _fail('Stop all services before moving a stack.');
      return;
    }
    if (sameWindowsPath(source, target)) {
      _fail('The stack is already at $target.');
      return;
    }
    if (Directory(target).existsSync() &&
        Directory(target).listSync().isNotEmpty) {
      _fail('$target already contains files.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Move this stack?'),
        content: Text(
          'From: $source\nTo: $target\n\n'
          'StackPilot copies the whole folder, including data and logs, then '
          'rewrites the Apache, PHP, MySQL, Nginx, Redis, PostgreSQL and '
          'launcher paths. It does not move projects kept outside the stack.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Move'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    final isCurrent = sameWindowsPath(source, widget.layout.root);
    setState(() => _busyMessage = 'Copying $source to $target…');
    StackMoveResult result;
    try {
      result = await StackMover.moveInBackground(
        sourceRoot: source,
        targetRoot: target,
      );
    } on StackMoveException catch (error) {
      _fail(error.message);
      return;
    } on Object catch (error) {
      _fail('Could not move the stack: $error');
      return;
    } finally {
      if (mounted) {
        setState(() => _busyMessage = null);
      }
    }
    if (!mounted) {
      return;
    }

    setState(() {
      _detectedStacks = _scanStacks(_stacksFolder.text);
    });

    if (!result.clean) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('The stack was copied with leftover paths'),
          content: SingleChildScrollView(
            child: Text(
              'These files still mention $source:\n\n'
              '${result.leftovers.join('\n')}\n\n'
              'The old copy was kept. Check the files above before switching.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
      return;
    }

    final deleteOld = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stack copied'),
        content: Text(
          'The stack is now at $target and every path points there.\n\n'
          'Delete the old copy at $source? Your projects inside the stack '
          'were copied already.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep the old copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete old copy'),
          ),
        ],
      ),
    );
    if (!mounted) {
      return;
    }
    if (deleteOld == true) {
      try {
        StackMover.deleteSource(source);
      } on StackMoveException catch (error) {
        _fail(error.message);
        return;
      }
    }

    if (isCurrent) {
      final preferences = _editedPreferences().copyWith(
        stacksFolder: normalizeWindowsPath(p.dirname(target)),
        activeStack: result.targetRoot,
        onboardingCompleted: true,
      );
      await widget.preferencesStore?.save(preferences);
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(
        StackSettingsOutcome.switchTo(
          result.targetRoot,
          preferences: preferences,
        ),
      );
      return;
    }

    setState(() => _detectedStacks = _scanStacks(_stacksFolder.text));
    _notify('${p.basename(result.targetRoot)} was moved to ${result.targetRoot}.');
  }

  Future<void> _deleteStack(String root) async {
    if (sameWindowsPath(root, widget.layout.root)) {
      _fail('Switch to another stack before deleting this one.');
      return;
    }
    if (widget.runningServices.isNotEmpty) {
      _fail('Stop all services before deleting a stack.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${p.basename(root)}?'),
        content: Text(
          '$root and everything inside it will be removed from disk. This '
          'cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    final data = Directory(p.join(root, 'data'));
    if (data.existsSync() && data.listSync().isNotEmpty) {
      final dataConfirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete the databases too?'),
          content: Text(
            'The data folder of this stack is not empty. Deleting it removes '
            'every database, table, and service data file.\n\n'
            'Delete $root anyway?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFA33A3A),
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete data and stack'),
            ),
          ],
        ),
      );
      if (dataConfirmed != true || !mounted) {
        return;
      }
    }

    try {
      Directory(root).deleteSync(recursive: true);
      if (!mounted) {
        return;
      }
      setState(
        () => _detectedStacks = _scanStacks(
          _stacksFolder.text,
        ).where((entry) => !sameWindowsPath(entry, root)).toList(),
      );
      _notify('${p.basename(root)} was deleted.');
    } on FileSystemException catch (error) {
      _fail('Could not delete $root: ${error.message}');
    }
  }

  Future<String?> _promptStackName({
    required String title,
    required String hint,
    required String initial,
  }) {
    return showDialog<String>(
      context: context,
      builder: (context) {
        final controller = TextEditingController(text: initial);
        String? error;
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(title),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                labelText: hint,
                border: const OutlineInputBorder(),
                errorText: error,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final name = controller.text.trim();
                  if (!_validStackName(name)) {
                    setDialogState(
                      () => error =
                          'Use a name without \\ / : * ? " < > | and without '
                          'leading or trailing spaces.',
                    );
                    return;
                  }
                  Navigator.pop(context, name);
                },
                child: const Text('OK'),
              ),
            ],
          ),
        );
      },
    );
  }

  static bool _validStackName(String name) {
    if (name.isEmpty || name == '.' || name == '..') {
      return false;
    }
    return !RegExp(r'[\\/:*?"<>|]').hasMatch(name);
  }

  void _notify(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _generalTab() {
    return ListView(
      padding: const EdgeInsets.only(top: 4),
      children: [
        _pathField(
          controller: _documentRoot,
          label: 'Document root',
          dialogTitle: 'Select the document root',
        ),
        const SizedBox(height: 14),
        _pathField(
          controller: _dataDirectory,
          label: 'Data directory',
          dialogTitle: 'Select the data directory',
        ),
        const SizedBox(height: 8),
        const _Hint(
          'The stack uses this as the base folder for service data. Existing '
          'databases and MySQL data are not moved.',
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<TerminalShell>(
          initialValue: _terminalShell,
          decoration: const InputDecoration(
            labelText: 'Terminal',
            border: OutlineInputBorder(),
            helperText:
                'Which terminal the Terminal action opens, with this stack on '
                'PATH.',
          ),
          items: [
            for (final shell in TerminalShell.values)
              DropdownMenuItem(value: shell, child: Text(shell.label)),
          ],
          onChanged: _saving
              ? null
              : (value) {
                  if (value == null) {
                    return;
                  }
                  setState(() => _terminalShell = value);
                },
        ),
        const SizedBox(height: 6),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Automatic virtual hosts'),
          subtitle: const Text(
            'Use <project>.test for folders in the document root.',
          ),
          value: _autoVirtualHosts,
          onChanged: _saving
              ? null
              : (value) => setState(() => _autoVirtualHosts = value),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Apache SSL'),
          subtitle: const Text(
            'Generate HTTPS virtual hosts when certificates exist.',
          ),
          value: _apacheSsl,
          onChanged: _saving
              ? null
              : (value) => setState(() => _apacheSsl = value),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Expose Apache on the LAN'),
          subtitle: const Text(
            'Off binds Apache to 127.0.0.1:80, so phpMyAdmin and your sites '
            'are only reachable from this PC.',
          ),
          value: _apacheListenOnLan,
          onChanged: _saving
              ? null
              : (value) => setState(() => _apacheListenOnLan = value),
        ),
      ],
    );
  }

  Widget _servicesTab() {
    return ListView(
      padding: const EdgeInsets.only(top: 4),
      children: [
        for (final component in StackLayout.serviceComponents)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(_serviceLabels[component]!),
            subtitle: Text('bin/${component.directoryName}'),
            value: _enabledServices.contains(component),
            onChanged: _saving
                ? null
                : (value) => setState(() {
                    if (value) {
                      _enabledServices.add(component);
                    } else {
                      _enabledServices.remove(component);
                    }
                  }),
          ),
        const SizedBox(height: 6),
        const _Hint(
          'Enabled services are started by Start All. Changes apply the next '
          'time a service is started.',
        ),
      ],
    );
  }

  Widget _mysqlTab() {
    return ListView(
      padding: const EdgeInsets.only(top: 4),
      children: [
        TextField(
          controller: _mysqlPort,
          enabled: !_saving,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'MySQL port',
            border: OutlineInputBorder(),
            helperText: 'Written to the stack configuration and my.ini.',
          ),
        ),
        const SizedBox(height: 16),
        const _Hint(
          'Restart MySQL after changing the port. Existing clients that '
          'connect to the old port will need to be updated.',
        ),
      ],
    );
  }

  Widget _postgresqlTab() {
    final layout = widget.layout;
    return ListView(
      padding: const EdgeInsets.only(top: 4),
      children: [
        TextField(
          controller: _postgresqlPort,
          enabled: !_saving,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'PostgreSQL port',
            border: OutlineInputBorder(),
            helperText: 'Written to the stack configuration and postgresql.conf.',
          ),
        ),
        const SizedBox(height: 16),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.folder_outlined),
          title: const Text('Data directory'),
          subtitle: Text(layout.postgresqlDataDirectory),
        ),
        if (!layout.postgresqlInitialized)
          const _Hint(
            'This data folder is not initialized yet. Run initdb once or '
            'start PostgreSQL from the stack before StackPilot can start it.',
          ),
        const _Hint(
          'Restart PostgreSQL after changing the port. Existing clients that '
          'connect to the old port will need to be updated.',
        ),
      ],
    );
  }

  Widget _phpTab() {
    if (!_settings.php.editable) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No php.ini was found for the active PHP version.\n'
            'Add a PHP version and set it as active first.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF7A8880)),
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(top: 4),
      children: [
        _phpField(_memoryLimit, 'memory_limit'),
        const SizedBox(height: 12),
        _phpField(_uploadMax, 'upload_max_filesize'),
        const SizedBox(height: 12),
        _phpField(_postMax, 'post_max_size'),
        const SizedBox(height: 12),
        _phpField(_executionTime, 'max_execution_time'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('display_errors'),
          subtitle: const Text('Show PHP errors in the browser.'),
          value: _displayErrors,
          onChanged: _saving
              ? null
              : (value) => setState(() => _displayErrors = value),
        ),
        const _Hint('Restart Apache after changing PHP settings.'),
      ],
    );
  }

  Widget _updatesTab() {
    final keyConfigured = AppInfo.updatePublicKey.trim().isNotEmpty;
    final url = _updateUrl.text.trim();
    final canCheck =
        keyConfigured &&
        url.isNotEmpty &&
        !_checkingUpdate &&
        !_installingUpdate;
    final result = _updateResult;
    final cached = _cachedInstallers;

    return ListView(
      padding: const EdgeInsets.only(top: 4),
      children: [
        Text(
          'This build is StackPilot ${AppInfo.versionLabel} '
          '(${AppInfo.channel.label}). Updates are signed and their installer '
          'is checked before it runs.',
          style: const TextStyle(fontSize: 12.5, color: Color(0xFF52605A)),
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<ReleaseChannel>(
          initialValue: _updateChannel,
          decoration: const InputDecoration(
            labelText: 'Release channel',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final channel in ReleaseChannel.values)
              DropdownMenuItem(
                value: channel,
                child: Text(channel.label),
              ),
          ],
          onChanged: _checkingUpdate || _installingUpdate
              ? null
              : (value) {
                  if (value == null) {
                    return;
                  }
                  setState(() {
                    _updateChannel = value;
                    _updateResult = null;
                  });
                },
        ),
        const SizedBox(height: 6),
        Text(
          _updateChannel.description,
          style: const TextStyle(fontSize: 11.5, color: Color(0xFF7A8880)),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _updateUrl,
          enabled: !_checkingUpdate && !_installingUpdate,
          onChanged: (_) => setState(() => _updateResult = null),
          decoration: const InputDecoration(
            labelText: 'Update manifest URL',
            border: OutlineInputBorder(),
            helperText:
                'Leave blank to use the URL compiled into this build. The '
                'matching .sig file must be published next to it.',
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Check for updates on startup'),
          subtitle: const Text('Only runs when this build has an update source.'),
          value: _autoCheckUpdates,
          onChanged: _checkingUpdate || _installingUpdate
              ? null
              : (value) => setState(() => _autoCheckUpdates = value),
        ),
        if (!keyConfigured)
          const _Hint(
            'This build has no update signing key, so update checks are '
            'disabled. Release builds pass STACKPILOT_UPDATE_PUBLIC_KEY.',
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton.icon(
              onPressed: canCheck ? _checkForUpdates : null,
              icon: _checkingUpdate
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.system_update_alt, size: 18),
              label: Text(_checkingUpdate ? 'Checking...' : 'Check now'),
            ),
            const SizedBox(width: 10),
            Text(
              _checkingUpdate
                  ? 'Contacting the update server...'
                  : 'Current version: ${AppInfo.versionLabel}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF7A8880)),
            ),
          ],
        ),
        if (_updateError != null) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFFDECEC),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(
              _updateError!,
              style: const TextStyle(fontSize: 12, color: Color(0xFF9B1C1C)),
            ),
          ),
        ],
        if (result != null && !result.hasUpdate) ...[
          const SizedBox(height: 12),
          _Hint('StackPilot is up to date on the ${result.channel.label} channel.'),
        ],
        if (result?.release case final release?) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFEDF7F1),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: const Color(0xFFCFE0D6)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${release.label} is available',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF0E7A4A),
                  ),
                ),
                if (release.notes.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    release.notes,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF2F4238),
                    ),
                  ),
                ],
                if (release.sizeBytes != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Download: '
                    '${(release.sizeBytes! / (1024 * 1024)).toStringAsFixed(1)} MB',
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: Color(0xFF7A8880),
                    ),
                  ),
                ],
                if (_installingUpdate) ...[
                  const SizedBox(height: 10),
                  LinearProgressIndicator(value: _downloadFraction),
                  const SizedBox(height: 4),
                  Text(
                    _downloadFraction == null
                        ? 'Downloading...'
                        : 'Downloading ${(_downloadFraction! * 100).round()}%',
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: Color(0xFF7A8880),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _installingUpdate
                      ? null
                      : () => _installUpdate(release),
                  icon: const Icon(Icons.download, size: 18),
                  label: const Text('Download and install'),
                ),
              ],
            ),
          ),
        ],
        if (cached.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text(
            'Downloaded installers',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const _Hint(
            'Keep an older installer to roll back if a new version does not '
            'work. Installing closes StackPilot.',
          ),
          for (final installer in cached)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.history),
              title: Text(installer.label),
              subtitle: Text(
                '${(installer.sizeBytes / (1024 * 1024)).toStringAsFixed(1)} '
                'MB - ${installer.file.path}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5),
              ),
              trailing: TextButton(
                onPressed: _installingUpdate
                    ? null
                    : () => _installCached(installer),
                child: const Text('Install'),
              ),
            ),
        ],
        const _Hint(
          'Updates only replace the StackPilot application. Your stacks, '
          'binaries, sites, and data stay where they are.',
        ),
      ],
    );
  }

  Widget _diagnosticsTab() {
    final logDirectory = AppLog.directoryPath;
    return ListView(
      padding: const EdgeInsets.only(top: 4),
      children: [
        Text(
          'StackPilot logs errors and important actions locally. Nothing is '
          'sent anywhere automatically.',
          style: const TextStyle(fontSize: 12.5, color: Color(0xFF52605A)),
        ),
        const SizedBox(height: 14),
        Text(
          'Version: ${AppInfo.versionLabel} (${AppInfo.channel.id})',
          style: const TextStyle(fontSize: 12.5),
        ),
        const SizedBox(height: 4),
        Text(
          'Log folder: ${logDirectory ?? 'not available'}',
          style: const TextStyle(fontSize: 12, color: Color(0xFF7A8880)),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: logDirectory == null
                  ? null
                  : () => _openFolder(logDirectory),
              icon: const Icon(Icons.folder_open, size: 18),
              label: const Text('Open logs'),
            ),
            const SizedBox(width: 10),
            FilledButton.icon(
              onPressed: _creatingBundle ? null : _createBundle,
              icon: _creatingBundle
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.archive_outlined, size: 18),
              label: Text(
                _creatingBundle ? 'Creating...' : 'Create report bundle',
              ),
            ),
          ],
        ),
        if (_bundlePath != null) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFEDF7F1),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Report bundle created',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF0E7A4A),
                  ),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  _bundlePath!,
                  style: const TextStyle(fontSize: 11.5),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () => _openFolder(_bundlePath!),
                  icon: const Icon(Icons.folder_open, size: 17),
                  label: const Text('Show in Explorer'),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 16),
        Text(
          'Component download cache',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        Text(
          _cacheFiles == 0
              ? 'Empty'
              : '$_cacheFiles '
                    '${_cacheFiles == 1 ? 'archive' : 'archives'}, '
                    '${_formatBytes(_cacheBytes)}',
          style: const TextStyle(fontSize: 12.5),
        ),
        const SizedBox(height: 2),
        SelectableText(
          _downloadCache.directory.path,
          style: const TextStyle(fontSize: 11.5, color: Color(0xFF7A8880)),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: () {
                _downloadCache.directory.createSync(recursive: true);
                _openFolder(_downloadCache.directory.path);
              },
              icon: const Icon(Icons.folder_open, size: 17),
              label: const Text('Open cache'),
            ),
            const SizedBox(width: 10),
            OutlinedButton.icon(
              onPressed: _cacheFiles == 0 ? null : _clearCache,
              icon: const Icon(Icons.delete_outline, size: 17),
              label: const Text('Clear cache'),
            ),
          ],
        ),
        const _Hint(
          'Archives are cached by SHA-256 so a second stack, or a retry after '
          'a failed extraction, does not download them again.',
        ),
        const SizedBox(height: 8),
        const _Hint(
          'The bundle contains the log files, app and OS version, stack paths, '
          'active component versions, and the stack marker. It does not contain '
          'database data, project files, passwords, or environment variables. '
          'Review it before sharing.',
        ),
      ],
    );
  }

  Future<void> _clearCache() async {
    final removed = _downloadCache.clear();
    if (!mounted) {
      return;
    }
    setState(() {
      _cacheFiles = _downloadCache.count;
      _cacheBytes = _downloadCache.sizeBytes;
    });
    _notify(
      removed == 0
          ? 'The cache is already empty.'
          : 'Removed $removed cached ${removed == 1 ? 'file' : 'files'}.',
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }

  AppPreferences _editedPreferences() {
    final url = _updateUrl.text.trim();
    final stacksFolder = normalizeWindowsPath(_stacksFolder.text);
    return widget.preferences.copyWith(
      updateChannel: _updateChannel,
      updateManifestUrl: url.isEmpty ? null : url,
      autoCheckUpdates: _autoCheckUpdates,
      stacksFolder: stacksFolder.isEmpty ? null : stacksFolder,
      terminalShell: _terminalShell.id,
    );
  }

  UpdateService? _buildUpdateService() {
    final url = _updateUrl.text.trim();
    final key = AppInfo.updatePublicKey.trim();
    if (url.isEmpty || key.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || !uri.hasAuthority) {
      return null;
    }
    return UpdateService(
      manifestUri: uri,
      publicKey: key,
      currentVersion: AppInfo.version,
      channel: _updateChannel,
    );
  }

  Future<void> _checkForUpdates() async {
    final service = _buildUpdateService();
    if (service == null) {
      setState(() {
        _updateError =
            'Enter an HTTPS manifest URL and use a build with an update '
            'signing key.';
      });
      return;
    }
    setState(() {
      _checkingUpdate = true;
      _updateError = null;
      _updateResult = null;
    });
    try {
      final result = await service.check();
      if (!mounted) {
        return;
      }
      setState(() {
        _checkingUpdate = false;
        _updateResult = result;
      });
    } on UpdateException catch (error) {
      if (mounted) {
        setState(() {
          _checkingUpdate = false;
          _updateError = error.message;
        });
      }
    } on Object catch (error) {
      AppLog.error('Update check failed', error: error);
      if (mounted) {
        setState(() {
          _checkingUpdate = false;
          _updateError = 'Could not check for updates: $error';
        });
      }
    }
  }

  Future<void> _installUpdate(UpdateRelease release) async {
    final service = _buildUpdateService();
    if (service == null) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Install ${release.label}?'),
        content: const Text(
          'StackPilot downloads the signed installer, verifies its checksum, '
          'then closes so the installer can replace the app. Your stacks and '
          'data are not touched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Download and install'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    setState(() {
      _installingUpdate = true;
      _downloadFraction = null;
      _updateError = null;
    });
    try {
      final installer = await service.download(
        release,
        onProgress: (received, total) {
          if (!mounted || total == null || total <= 0) {
            return;
          }
          setState(() => _downloadFraction = received / total);
        },
      );
      await service.launchInstaller(installer);
      AppLog.info('Exiting for update to ${release.version}');
      exit(0);
    } on UpdateException catch (error) {
      if (mounted) {
        setState(() {
          _installingUpdate = false;
          _updateError = error.message;
        });
      }
    } on Object catch (error) {
      AppLog.error('Could not install update', error: error);
      if (mounted) {
        setState(() {
          _installingUpdate = false;
          _updateError = 'Could not install the update: $error';
        });
      }
    }
  }

  Future<void> _installCached(CachedInstaller installer) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Install ${installer.label}?'),
        content: const Text(
          'StackPilot closes and runs the cached installer. Use this to roll '
          'back after a problem with a newer version.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Install'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    try {
      await UpdateService.runInstaller(installer.file);
      exit(0);
    } on Object catch (error) {
      if (mounted) {
        setState(() => _updateError = 'Could not start the installer: $error');
      }
    }
  }

  Future<void> _createBundle() async {
    setState(() {
      _creatingBundle = true;
      _error = null;
    });
    try {
      AppLog.flush();
      final bundle = Diagnostics.create(
        preferences: _editedPreferences(),
        layout: widget.layout,
        runningServices: widget.runningServices,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _creatingBundle = false;
        _bundlePath = bundle.file.path;
      });
    } on FileSystemException catch (error) {
      _fail('Could not create the report bundle: ${error.message}');
    } on Object catch (error) {
      AppLog.error('Could not create diagnostics bundle', error: error);
      _fail('Could not create the report bundle: $error');
    }
  }

  Future<void> _openFolder(String path) async {
    try {
      await Process.start('explorer.exe', [path]);
    } on ProcessException catch (error) {
      _fail('Could not open $path: ${error.message}');
    }
  }

  Widget _phpField(TextEditingController controller, String label) {
    return TextField(
      controller: controller,
      enabled: !_saving,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _pathField({
    required TextEditingController controller,
    required String label,
    required String dialogTitle,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            enabled: !_saving,
            decoration: InputDecoration(
              labelText: label,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: IconButton.filledTonal(
            tooltip: 'Browse…',
            onPressed: _saving
                ? null
                : () async {
                    final path = await pickFolder(dialogTitle);
                    if (path != null) {
                      controller.text = path;
                    }
                  },
            icon: const Icon(Icons.folder_open),
          ),
        ),
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(
        text,
        style: const TextStyle(fontSize: 12, color: Color(0xFF7A8880)),
      ),
    );
  }
}

/// Actions offered on a stack row in the Stacks tab.
enum _StackAction { rename, move, delete }

/// What the "New stack…" dialog returned.
class _NewStackRequest {
  const _NewStackRequest({required this.parent, required this.name});

  final String parent;
  final String name;
}

/// Asks for a name and a parent folder for a new stack.
class _NewStackDialog extends StatefulWidget {
  const _NewStackDialog({required this.parent, required this.defaultName});

  final String parent;
  final String defaultName;

  @override
  State<_NewStackDialog> createState() => _NewStackDialogState();
}

class _NewStackDialogState extends State<_NewStackDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.defaultName,
  );
  late final TextEditingController _parent = TextEditingController(
    text: normalizeWindowsPath(widget.parent),
  );
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _parent.dispose();
    super.dispose();
  }

  Future<void> _browse() async {
    final path = await pickFolder('Choose where the new stack should live');
    if (path == null || !mounted) {
      return;
    }
    setState(() {
      _parent.text = normalizeWindowsPath(path);
      _error = null;
    });
  }

  void _submit() {
    final name = _name.text.trim();
    final parent = normalizeWindowsPath(_parent.text);
    if (parent.isEmpty) {
      setState(() => _error = 'Choose a parent folder.');
      return;
    }
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        RegExp(r'[\\/:*?"<>|]').hasMatch(name)) {
      setState(
        () => _error =
            'Use a name without \\ / : * ? " < > | and without leading or '
            'trailing spaces.',
      );
      return;
    }
    Navigator.pop(context, _NewStackRequest(parent: parent, name: name));
  }

  @override
  Widget build(BuildContext context) {
    final parent = normalizeWindowsPath(_parent.text);
    final name = _name.text.trim();
    final preview = parent.isEmpty || name.isEmpty
        ? ''
        : p.join(parent, name);
    return AlertDialog(
      title: const Text('New stack'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name',
                border: OutlineInputBorder(),
                helperText: 'Becomes the stack folder name.',
              ),
              onChanged: (_) => setState(() => _error = null),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _parent,
                    decoration: const InputDecoration(
                      labelText: 'Parent folder',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() => _error = null),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: 'Browse…',
                  onPressed: _browse,
                  icon: const Icon(Icons.folder_open),
                ),
              ],
            ),
            if (preview.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                'Stack folder: $preview',
                style: const TextStyle(fontSize: 12, color: Color(0xFF52605A)),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: const TextStyle(fontSize: 12, color: Color(0xFFA33A3A)),
              ),
            ],
            const SizedBox(height: 10),
            const Text(
              'The new stack gets bin, usr, etc, www, data and logs folders. '
              'The setup wizard opens afterwards so you can download its '
              'components.',
              style: TextStyle(fontSize: 12, color: Color(0xFF7A8880)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Create stack')),
      ],
    );
  }
}
