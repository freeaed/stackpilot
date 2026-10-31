import 'package:flutter/material.dart';

/// Values collected by [showNewSiteDialog].
class NewSiteRequest {
  const NewSiteRequest({
    required this.name,
    required this.host,
    required this.mapHosts,
  });

  /// Folder name under the document root.
  final String name;

  /// Host name, normally `<name>.test`.
  final String host;

  /// Whether the host should be added to the Windows hosts file.
  final bool mapHosts;
}

/// Asks for a new project folder and the host name that should serve it.
///
/// This is the manual path for sites that are created outside StackPilot: it
/// writes the virtual host and can map the name in the hosts file, including
/// the administrator prompt that Windows needs for it.
Future<NewSiteRequest?> showNewSiteDialog(
  BuildContext context, {
  required String documentRoot,
  required List<String> existingNames,
  required List<String> existingHosts,
}) {
  return showDialog<NewSiteRequest>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _NewSiteDialog(
      documentRoot: documentRoot,
      existingNames: existingNames,
      existingHosts: existingHosts,
    ),
  );
}

class _NewSiteDialog extends StatefulWidget {
  const _NewSiteDialog({
    required this.documentRoot,
    required this.existingNames,
    required this.existingHosts,
  });

  final String documentRoot;
  final List<String> existingNames;
  final List<String> existingHosts;

  @override
  State<_NewSiteDialog> createState() => _NewSiteDialogState();
}

class _NewSiteDialogState extends State<_NewSiteDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _host = TextEditingController();
  bool _mapHosts = true;
  bool _hostEdited = false;
  String? _error;

  static final _namePattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');
  static final _hostPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9.-]*$');

  @override
  void initState() {
    super.initState();
    _name.addListener(_suggestHost);
    _host.addListener(() {
      if (_host.text.trim() != '${_name.text.trim()}.test') {
        _hostEdited = true;
      }
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    super.dispose();
  }

  void _suggestHost() {
    if (_hostEdited) {
      return;
    }
    final name = _name.text.trim();
    final suggestion = name.isEmpty ? '' : '$name.test';
    if (_host.text == suggestion) {
      return;
    }
    _host.value = TextEditingValue(
      text: suggestion,
      selection: TextSelection.collapsed(offset: suggestion.length),
    );
  }

  void _submit() {
    final name = _name.text.trim();
    final host = _host.text.trim().toLowerCase();

    String? problem;
    if (name.isEmpty) {
      problem = 'Enter a folder name.';
    } else if (!_namePattern.hasMatch(name)) {
      problem = 'Use letters, digits, dots, dashes, and underscores only.';
    } else if (const {'phpmyadmin', 'pma'}.contains(name.toLowerCase())) {
      problem = '"$name" is reserved for the phpMyAdmin tool.';
    } else if (widget.existingNames.any(
      (existing) => existing.toLowerCase() == name.toLowerCase(),
    )) {
      problem = 'A project named "$name" already exists.';
    } else if (host.isEmpty) {
      problem = 'Enter a host name, for example $name.test.';
    } else if (!_hostPattern.hasMatch(host) || !host.contains('.')) {
      problem = 'Use a host name such as $name.test.';
    } else if (widget.existingHosts.any(
      (existing) => existing.toLowerCase() == host,
    )) {
      problem = '"$host" is already used by another site.';
    }

    if (problem != null) {
      setState(() => _error = problem);
      return;
    }

    Navigator.of(context)
        .pop(NewSiteRequest(name: name, host: host, mapHosts: _mapHosts));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.create_new_folder_outlined, size: 20),
          SizedBox(width: 8),
          Text('Add site'),
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      content: SizedBox(
        width: 470,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Creates a project folder in ${widget.documentRoot}, a '
                'virtual host, and (optionally) a hosts entry.',
                style: const TextStyle(fontSize: 12.5),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _name,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Project folder',
                  hintText: 'my-site',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _host,
                decoration: const InputDecoration(
                  labelText: 'Host name',
                  hintText: 'my-site.test',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 4),
              CheckboxListTile(
                value: _mapHosts,
                onChanged: (value) => setState(() => _mapHosts = value ?? true),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Add a hosts entry'),
                subtitle: const Text(
                  'Writes 127.0.0.1 <host> to the Windows hosts file. Windows '
                  'shows an administrator prompt the first time.',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
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
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Add site')),
      ],
    );
  }
}
