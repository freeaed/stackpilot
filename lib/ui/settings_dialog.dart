import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/app_info.dart';
import '../core/app_log.dart';
import '../core/app_preferences.dart';
import '../core/diagnostics.dart';
import '../core/stack_catalog.dart';
import '../core/stack_editor.dart';
import '../core/stack_layout.dart';
import '../core/stack_settings.dart';
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
  const StackSettingsOutcome.saved({this.preferences}) : stackRoot = null;

  /// Close the dialog and open [stackRoot] instead of the current stack.
  const StackSettingsOutcome.switchTo(this.stackRoot) : preferences = null;

  final String? stackRoot;

  /// Preferences changed in this dialog, when any.
  final AppPreferences? preferences;
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
  late bool _displayErrors = _settings.php.displayErrors;
  late final Set<StackComponent> _enabledServices = {
    ..._settings.enabledServices,
  };

  late final TextEditingController _stacksFolder = TextEditingController(
    text: widget.stacksFolder ?? p.dirname(widget.layout.root),
  );
  late List<String> _detectedStacks = _scanStacks(_stacksFolder.text);
  bool _switching = false;

  late final TextEditingController _updateUrl = TextEditingController(
    text: widget.preferences.updateManifestUrl ?? AppInfo.updateManifestUrl,
  );
  late ReleaseChannel _updateChannel = widget.preferences.updateChannel;
  late bool _autoCheckUpdates = widget.preferences.autoCheckUpdates;
  bool _checkingUpdate = false;
  bool _installingUpdate = false;
  double? _downloadFraction;
  UpdateCheckResult? _updateResult;
  String? _updateError;
  late final List<CachedInstaller> _cachedInstallers =
      UpdateService.scanCache();
  String? _bundlePath;
  bool _creatingBundle = false;

  bool _saving = false;
  String? _error;

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
    final discovered = StackCatalog.scan(folder.trim());
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
    setState(() {
      _stacksFolder.text = path;
      _detectedStacks = _scanStacks(path);
    });
  }

  Future<void> _useStack(String root) async {
    if (_switching || _saving) {
      return;
    }
    setState(() => _switching = true);
    if (mounted) {
      Navigator.of(context).pop(StackSettingsOutcome.switchTo(root));
    }
  }

  Future<void> _save() async {
    if (_saving) {
      return;
    }

    final documentRoot = _documentRoot.text.trim();
    final dataDirectory = _dataDirectory.text.trim();
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

    setState(() {
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
      final url = _updateUrl.text.trim();
      final updatedPreferences = widget.preferences.copyWith(
        updateChannel: _updateChannel,
        updateManifestUrl: url.isEmpty ? null : url,
        autoCheckUpdates: _autoCheckUpdates,
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
          onPressed: _saving || _switching
              ? null
              : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _saving || _switching ? null : _save,
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
    return ListView(
      padding: const EdgeInsets.only(top: 4),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _stacksFolder,
                enabled: !_saving && !_switching,
                onSubmitted: (value) =>
                    setState(() => _detectedStacks = _scanStacks(value)),
                decoration: const InputDecoration(
                  labelText: 'Stacks folder',
                  border: OutlineInputBorder(),
                  helperText:
                      'Parent folder that contains your stacks, for example '
                      'C:\\ or D:\\dev\\stacks.',
                ),
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: IconButton.filledTonal(
                tooltip: 'Browse…',
                onPressed: _saving || _switching ? null : _browseStacksFolder,
                icon: const Icon(Icons.folder_open),
              ),
            ),
            const SizedBox(width: 4),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: IconButton.filledTonal(
                tooltip: 'Scan again',
                onPressed: _saving || _switching
                    ? null
                    : () => setState(
                        () => _detectedStacks = _scanStacks(_stacksFolder.text),
                      ),
                icon: const Icon(Icons.refresh),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text('Stacks in this folder', style: Theme.of(context).textTheme.titleSmall),
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
              title: Text(p.basename(root)),
              subtitle: Text(root, style: const TextStyle(fontSize: 12)),
              trailing: p.equals(root, currentRoot)
                  ? const Text(
                      'Current',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF0E7A4A),
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  : TextButton(
                      onPressed: _saving || _switching
                          ? null
                          : () => _useStack(root),
                      child: const Text('Use'),
                    ),
            ),
        const SizedBox(height: 8),
        const _Hint(
          'Switching stacks closes this dialog and keeps running services '
          'untouched, so stop them first.',
        ),
      ],
    );
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
        const _Hint(
          'The bundle contains the log files, app and OS version, stack paths, '
          'active component versions, and the stack marker. It does not contain '
          'database data, project files, passwords, or environment variables. '
          'Review it before sharing.',
        ),
      ],
    );
  }

  AppPreferences _editedPreferences() {
    final url = _updateUrl.text.trim();
    return widget.preferences.copyWith(
      updateChannel: _updateChannel,
      updateManifestUrl: url.isEmpty ? null : url,
      autoCheckUpdates: _autoCheckUpdates,
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
