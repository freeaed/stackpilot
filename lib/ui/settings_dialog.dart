import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/stack_catalog.dart';
import '../core/stack_editor.dart';
import '../core/stack_layout.dart';
import '../core/stack_settings.dart';
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
  const StackSettingsOutcome.saved() : stackRoot = null;

  /// Close the dialog and open [stackRoot] instead of the current stack.
  const StackSettingsOutcome.switchTo(this.stackRoot);

  final String? stackRoot;
}

Future<StackSettingsOutcome?> showStackSettingsDialog(
  BuildContext context, {
  required StackLayout layout,
  required StackEditor editor,
  String? stacksFolder,
}) {
  return showDialog<StackSettingsOutcome>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _StackSettingsDialog(
      layout: layout,
      editor: editor,
      stacksFolder: stacksFolder,
    ),
  );
}

class _StackSettingsDialog extends StatefulWidget {
  const _StackSettingsDialog({
    required this.layout,
    required this.editor,
    this.stacksFolder,
  });

  final StackLayout layout;
  final StackEditor editor;
  final String? stacksFolder;

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
      if (mounted) {
        Navigator.of(context).pop(const StackSettingsOutcome.saved());
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
        width: 620,
        height: 470,
        child: DefaultTabController(
          length: 6,
          child: Column(
            children: [
              const TabBar(
                tabs: [
                  Tab(text: 'Stacks'),
                  Tab(text: 'General'),
                  Tab(text: 'Services'),
                  Tab(text: 'MySQL'),
                  Tab(text: 'PostgreSQL'),
                  Tab(text: 'PHP'),
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
                      'Parent folder that contains your Laragon stacks, for '
                      'example C:\\ or D:\\dev\\stacks.',
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
              'No Laragon stack was found in that folder. Each stack needs '
              'usr\\laragon.ini and a bin folder.',
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
          'Laragon uses this as the base folder for new data. Existing '
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
            helperText: 'Written to laragon.ini and the active my.ini.',
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
            helperText: 'Written to laragon.ini and the active postgresql.conf.',
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
            'start PostgreSQL from Laragon before StackPilot can start it.',
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
