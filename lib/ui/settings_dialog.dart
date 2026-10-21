import 'dart:io';

import 'package:flutter/material.dart';

import '../core/stack_editor.dart';
import '../core/stack_layout.dart';
import '../core/stack_settings.dart';
import 'windows_dialogs.dart';

const _serviceLabels = {
  StackComponent.apache: 'Apache',
  StackComponent.nginx: 'Nginx',
  StackComponent.mysql: 'MySQL',
  StackComponent.redis: 'Redis',
  StackComponent.memcached: 'Memcached',
  StackComponent.mailpit: 'Mailpit',
};

Future<bool?> showStackSettingsDialog(
  BuildContext context, {
  required StackLayout layout,
  required StackEditor editor,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _StackSettingsDialog(layout: layout, editor: editor),
  );
}

class _StackSettingsDialog extends StatefulWidget {
  const _StackSettingsDialog({required this.layout, required this.editor});

  final StackLayout layout;
  final StackEditor editor;

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

  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _documentRoot.dispose();
    _dataDirectory.dispose();
    _mysqlPort.dispose();
    _memoryLimit.dispose();
    _uploadMax.dispose();
    _postMax.dispose();
    _executionTime.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) {
      return;
    }

    final documentRoot = _documentRoot.text.trim();
    final dataDirectory = _dataDirectory.text.trim();
    final port = int.tryParse(_mysqlPort.text.trim());
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
        Navigator.of(context).pop(true);
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
          length: 4,
          child: Column(
            children: [
              const TabBar(
                tabs: [
                  Tab(text: 'General'),
                  Tab(text: 'Services'),
                  Tab(text: 'MySQL'),
                  Tab(text: 'PHP'),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: TabBarView(
                  children: [
                    _generalTab(),
                    _servicesTab(),
                    _mysqlTab(),
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
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _saving ? null : _save,
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
