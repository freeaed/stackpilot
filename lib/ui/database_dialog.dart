import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/stack_editor.dart';
import '../core/stack_layout.dart';
import 'windows_dialogs.dart';

/// Official phpMyAdmin release page and a current "all languages" archive.
const phpMyAdminDownloadPage = 'https://www.phpmyadmin.net/downloads/';
const phpMyAdminArchiveUrl =
    'https://files.phpmyadmin.net/phpMyAdmin/5.2.2/'
    'phpMyAdmin-5.2.2-all-languages.zip';

/// Opens the database tools dialog.
///
/// Returns the URL that should be opened in the browser, or null when the
/// dialog was closed without opening anything.
Future<String?> showDatabaseDialog(
  BuildContext context, {
  required StackLayout layout,
  required StackEditor editor,
  required Future<void> Function(String url) openUrl,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) =>
        _DatabaseDialog(layout: layout, editor: editor, openUrl: openUrl),
  );
}

class _DatabaseDialog extends StatefulWidget {
  const _DatabaseDialog({
    required this.layout,
    required this.editor,
    required this.openUrl,
  });

  final StackLayout layout;
  final StackEditor editor;
  final Future<void> Function(String url) openUrl;

  @override
  State<_DatabaseDialog> createState() => _DatabaseDialogState();
}

class _DatabaseDialogState extends State<_DatabaseDialog> {
  final TextEditingController _url = TextEditingController(
    text: phpMyAdminArchiveUrl,
  );

  late String? _installed = widget.layout.phpMyAdminDirectory;
  bool _busy = false;
  String? _error;
  String? _status;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  String get _openUrl {
    final directory = _installed;
    if (directory == null) {
      return 'http://localhost/phpmyadmin/';
    }
    return 'http://localhost/${Uri.encodeComponent(p.basename(directory))}/';
  }

  Future<void> _installFromArchive(String archivePath) async {
    setState(() {
      _busy = true;
      _error = null;
      _status = 'Extracting phpMyAdmin…';
    });
    try {
      final directory = await widget.editor.installPhpMyAdminArchive(
        archivePath,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _installed = directory;
        _status = 'Installed to $directory';
      });
    } on StackEditException catch (error) {
      _fail(error.message);
    } on FileSystemException catch (error) {
      _fail('Could not install phpMyAdmin: ${error.message}');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _downloadAndInstall() async {
    setState(() {
      _busy = true;
      _error = null;
      _status = 'Downloading phpMyAdmin…';
    });
    try {
      final directory = await widget.editor.downloadPhpMyAdmin(_url.text);
      if (!mounted) {
        return;
      }
      setState(() {
        _installed = directory;
        _status = 'Installed to $directory';
      });
    } on StackEditException catch (error) {
      _fail(error.message);
    } on FileSystemException catch (error) {
      _fail('Could not install phpMyAdmin: ${error.message}');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _chooseArchive() async {
    final path = await pickZipFile('Select the phpMyAdmin ZIP archive');
    if (path == null || !mounted) {
      return;
    }
    await _installFromArchive(path);
  }

  void _fail(String message) {
    if (!mounted) {
      return;
    }
    setState(() {
      _error = message;
      _status = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final installed = _installed;
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.storage, size: 20),
          SizedBox(width: 8),
          Text('Database tools'),
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('phpMyAdmin'),
              const SizedBox(height: 10),
              if (installed != null) ..._installedView(installed) else ..._installView(),
              if (_status != null) ...[
                const SizedBox(height: 12),
                Text(
                  _status!,
                  style: const TextStyle(fontSize: 12, color: Color(0xFF7A8880)),
                ),
              ],
              if (_busy) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
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
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : () => Navigator.of(context).pop(_openUrl),
          icon: const Icon(Icons.open_in_new, size: 18),
          label: const Text('Open in browser'),
        ),
      ],
    );
  }

  List<Widget> _installedView(String directory) {
    return [
      Row(
        children: [
          const Icon(Icons.check_circle, color: Color(0xFF0E7A4A), size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Installed in ${p.relative(directory, from: widget.layout.root)}',
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
      const SizedBox(height: 6),
      Text(
        _openUrl,
        style: const TextStyle(fontSize: 12.5, color: Color(0xFF7A8880)),
      ),
      const SizedBox(height: 8),
      const Text(
        'Start Apache and MySQL, then open phpMyAdmin. The generated config '
        'connects to 127.0.0.1 as root with no password, which matches a '
        'default local MySQL install.',
        style: TextStyle(fontSize: 12, color: Color(0xFF7A8880)),
      ),
    ];
  }

  List<Widget> _installView() {
    return [
      Text(
        'phpMyAdmin was not found in ${widget.layout.documentRoot}.',
        style: const TextStyle(fontSize: 13),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _url,
        enabled: !_busy,
        decoration: const InputDecoration(
          labelText: 'Archive URL',
          border: OutlineInputBorder(),
          helperText: 'A phpMyAdmin "all languages" ZIP archive.',
        ),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            onPressed: _busy ? null : _downloadAndInstall,
            icon: const Icon(Icons.download, size: 18),
            label: const Text('Download and install'),
          ),
          OutlinedButton.icon(
            onPressed: _busy ? null : _chooseArchive,
            icon: const Icon(Icons.folder_zip_outlined, size: 18),
            label: const Text('Install from ZIP…'),
          ),
          TextButton.icon(
            onPressed: _busy
                ? null
                : () => widget.openUrl(phpMyAdminDownloadPage),
            icon: const Icon(Icons.link, size: 18),
            label: const Text('Download page'),
          ),
        ],
      ),
      const SizedBox(height: 8),
      const Text(
        'StackPilot installs phpMyAdmin into the document root as '
        '"phpmyadmin" and writes a config for the stack MySQL port. Apache and '
        'MySQL must be running before the page can load.',
        style: TextStyle(fontSize: 12, color: Color(0xFF7A8880)),
      ),
    ];
  }
}
