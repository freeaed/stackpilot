import 'dart:io';

import 'package:flutter/material.dart';

import '../core/stack_editor.dart';
import '../core/stack_layout.dart';
import 'windows_dialogs.dart';

enum _VersionSource { folder, archive, url }

class AddVersionResult {
  const AddVersionResult({required this.install, required this.activate});

  final StackInstall install;
  final bool activate;
}

Future<AddVersionResult?> showAddVersionDialog(
  BuildContext context, {
  required StackEditor editor,
  required StackComponent component,
  required String componentLabel,
}) {
  return showDialog<AddVersionResult>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _AddVersionDialog(
      editor: editor,
      component: component,
      componentLabel: componentLabel,
    ),
  );
}

class _AddVersionDialog extends StatefulWidget {
  const _AddVersionDialog({
    required this.editor,
    required this.component,
    required this.componentLabel,
  });

  final StackEditor editor;
  final StackComponent component;
  final String componentLabel;

  @override
  State<_AddVersionDialog> createState() => _AddVersionDialogState();
}

class _AddVersionDialogState extends State<_AddVersionDialog> {
  final _folder = TextEditingController();
  final _archive = TextEditingController();
  final _url = TextEditingController();

  _VersionSource _source = _VersionSource.folder;
  bool _activate = true;
  bool _busy = false;
  String? _error;
  String? _status;
  double? _progress;

  @override
  void dispose() {
    _folder.dispose();
    _archive.dispose();
    _url.dispose();
    super.dispose();
  }

  String get _preparationNote => switch (widget.component) {
    StackComponent.apache =>
      "Apache is pointed at this stack's www and etc folders automatically.",
    StackComponent.php =>
      'PHP reuses the active php.ini and enables common extensions if needed.',
    StackComponent.mysql =>
      'MySQL reuses the active my.ini, including its data directory and port.',
    StackComponent.postgresql =>
      'PostgreSQL reuses this stack data folder and the port in '
          'postgresql.conf.',
    _ => 'The version config is prepared for this stack automatically.',
  };

  String? get _downloadPage => switch (widget.component) {
    StackComponent.php => 'https://windows.php.net/download/',
    StackComponent.mysql => 'https://dev.mysql.com/downloads/mysql/',
    StackComponent.postgresql =>
      'https://www.postgresql.org/download/windows/',
    StackComponent.apache => 'https://www.apachelounge.com/download/',
    StackComponent.nginx => 'https://nginx.org/en/download.html',
    StackComponent.nodejs => 'https://nodejs.org/en/download',
    StackComponent.redis => 'https://github.com/tporadowski/redis/releases',
    StackComponent.memcached => 'https://memcached.org/downloads',
    StackComponent.mailpit => 'https://github.com/axllent/mailpit/releases',
  };

  Future<void> _openDownloadPage() async {
    final url = _downloadPage;
    if (url == null) {
      return;
    }
    try {
      await Process.start('explorer.exe', [
        url,
      ], mode: ProcessStartMode.detached);
    } on ProcessException catch (error) {
      _fail('Could not open the download page: ${error.message}');
    }
  }

  Future<void> _install() async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _progress = null;
      _status = switch (_source) {
        _VersionSource.folder => 'Copying version files…',
        _VersionSource.archive => 'Extracting archive…',
        _VersionSource.url => 'Starting download…',
      };
    });

    try {
      late final StackInstall install;
      switch (_source) {
        case _VersionSource.folder:
          final path = _folder.text.trim();
          if (path.isEmpty) {
            throw const StackEditException('Choose a version folder first.');
          }
          install = await widget.editor.importFolder(widget.component, path);
        case _VersionSource.archive:
          final path = _archive.text.trim();
          if (path.isEmpty) {
            throw const StackEditException('Choose a ZIP file first.');
          }
          install = await widget.editor.installArchive(widget.component, path);
        case _VersionSource.url:
          final url = _url.text.trim();
          if (url.isEmpty) {
            throw const StackEditException('Enter a download link first.');
          }
          install = await widget.editor.downloadAndInstall(
            widget.component,
            url,
            onProgress: (received, total) {
              if (!mounted) {
                return;
              }
              setState(() {
                _progress = total == null || total <= 0
                    ? null
                    : received / total;
                _status =
                    'Downloading ${_formatBytes(received)}'
                    '${total == null ? '' : ' of ${_formatBytes(total)}'}';
              });
            },
          );
      }

      if (!mounted) {
        return;
      }
      Navigator.of(context)
          .pop(AddVersionResult(install: install, activate: _activate));
    } on StackEditException catch (error) {
      _fail(error.message);
    } on FileSystemException catch (error) {
      _fail('Could not install the version: ${error.message}');
    } on Object catch (error) {
      _fail('Could not install the version: $error');
    }
  }

  void _fail(String message) {
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = false;
      _status = null;
      _progress = null;
      _error = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Add ${widget.componentLabel} version'),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<_VersionSource>(
                segments: const [
                  ButtonSegment(
                    value: _VersionSource.folder,
                    label: Text('Folder'),
                    icon: Icon(Icons.folder_open, size: 17),
                  ),
                  ButtonSegment(
                    value: _VersionSource.archive,
                    label: Text('ZIP file'),
                    icon: Icon(Icons.archive_outlined, size: 17),
                  ),
                  ButtonSegment(
                    value: _VersionSource.url,
                    label: Text('Download'),
                    icon: Icon(Icons.download, size: 17),
                  ),
                ],
                selected: {_source},
                onSelectionChanged: _busy
                    ? null
                    : (selection) => setState(() {
                        _source = selection.first;
                        _error = null;
                      }),
              ),
              const SizedBox(height: 18),
              switch (_source) {
                _VersionSource.folder => _pathField(
                  controller: _folder,
                  label: 'Extracted version folder',
                  hint: r'C:\laragon\bin\php\php-8.4.26-Win32-vs17-x64',
                  onBrowse: () async {
                    final path = await pickFolder(
                      'Select a ${widget.componentLabel} version folder',
                    );
                    if (path != null) {
                      _folder.text = path;
                    }
                  },
                ),
                _VersionSource.archive => _pathField(
                  controller: _archive,
                  label: 'ZIP archive',
                  hint: r'C:\Downloads\php-8.4.26-Win32-vs17-x64.zip',
                  onBrowse: () async {
                    final path = await pickZipFile(
                      'Select a ${widget.componentLabel} ZIP archive',
                    );
                    if (path != null) {
                      _archive.text = path;
                    }
                  },
                ),
                _VersionSource.url => TextField(
                  controller: _url,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    labelText: 'Download link (.zip)',
                    hintText: 'https://…/php-8.4.26-Win32-vs17-x64.zip',
                    border: OutlineInputBorder(),
                  ),
                ),
              },
              const SizedBox(height: 12),
              Text(
                '$_preparationNote The version is copied into the stack and can '
                'be selected without reinstalling it later.',
                style: const TextStyle(fontSize: 12, color: Color(0xFF7A8880)),
              ),
              const SizedBox(height: 2),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _busy ? null : _openDownloadPage,
                  icon: const Icon(Icons.open_in_new, size: 15),
                  label: Text('Get ${widget.componentLabel} builds'),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Set as active version'),
                value: _activate,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _activate = value),
              ),
              if (_busy) ...[
                const SizedBox(height: 10),
                LinearProgressIndicator(value: _progress),
                const SizedBox(height: 6),
                Text(
                  _status ?? 'Working…',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF52605A),
                  ),
                ),
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
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _install,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Install'),
        ),
      ],
    );
  }

  Widget _pathField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required Future<void> Function() onBrowse,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            enabled: !_busy,
            decoration: InputDecoration(
              labelText: label,
              hintText: hint,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: IconButton.filledTonal(
            tooltip: 'Browse…',
            onPressed: _busy ? null : onBrowse,
            icon: const Icon(Icons.folder_open),
          ),
        ),
      ],
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }
}
