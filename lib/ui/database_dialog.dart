import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/app_catalog.dart';
import '../core/stack_editor.dart';
import '../core/stack_layout.dart';
import '../core/stack_provisioner.dart';
import 'windows_dialogs.dart';

/// Official phpMyAdmin release page.
const phpMyAdminDownloadPage = 'https://www.phpmyadmin.net/downloads/';

/// Result of the database dialog: the URL to open and whether Apache must be
/// restarted so a freshly written `/phpmyadmin` alias is loaded.
class DatabaseLaunch {
  const DatabaseLaunch(this.url, {this.restartApache = false});

  final String url;
  final bool restartApache;
}

/// Opens the database tools dialog.
///
/// Returns the page that should be opened in the browser, or null when the
/// dialog was closed without opening anything.
Future<DatabaseLaunch?> showDatabaseDialog(
  BuildContext context, {
  required StackLayout layout,
  required StackEditor editor,
  required Future<void> Function(String url) openUrl,
  StackProvisioner Function(StackLayout layout)? provisionerFactory,
}) {
  return showDialog<DatabaseLaunch>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _DatabaseDialog(
      layout: layout,
      editor: editor,
      openUrl: openUrl,
      provisionerFactory: provisionerFactory,
    ),
  );
}

class _DatabaseDialog extends StatefulWidget {
  const _DatabaseDialog({
    required this.layout,
    required this.editor,
    required this.openUrl,
    this.provisionerFactory,
  });

  final StackLayout layout;
  final StackEditor editor;
  final Future<void> Function(String url) openUrl;
  final StackProvisioner Function(StackLayout layout)? provisionerFactory;

  @override
  State<_DatabaseDialog> createState() => _DatabaseDialogState();
}

class _DatabaseDialogState extends State<_DatabaseDialog> {
  late String? _installed = widget.layout.phpMyAdminDirectory;
  bool _busy = false;
  String? _error;
  String? _status;

  static final _app = AppCatalog.phpMyAdmin;

  @override
  void dispose() {
    super.dispose();
  }

  /// A leftover folder from an older build that cannot serve phpMyAdmin.
  bool get _needsRepair {
    for (final candidate in [
      p.join(widget.layout.documentRoot, 'phpmyadmin'),
      p.join(widget.layout.root, 'etc', 'apps', 'phpmyadmin'),
    ]) {
      if (Directory(candidate).existsSync() &&
          !StackLayout.isPhpMyAdminDirectory(candidate)) {
        return true;
      }
    }
    return false;
  }

  bool get _phpAvailable =>
      widget.layout.activeVersion(StackComponent.php) != null;

  String get _openUrl =>
      widget.layout.phpMyAdminUrl ?? 'http://127.0.0.1/phpmyadmin/';

  Future<void> _openInBrowser() async {
    if (!_phpAvailable) {
      _fail(
        'Install PHP first: Apache cannot run phpMyAdmin\'s index.php '
        'without an active PHP version.',
      );
      return;
    }
    PhpMyAdminServing? serving;
    try {
      serving = widget.editor.ensurePhpMyAdminServing();
    } on FileSystemException catch (error) {
      _fail('Could not prepare the phpMyAdmin alias: ${error.message}');
      return;
    }
    if (!mounted) {
      return;
    }
    if (serving == null) {
      _fail('phpMyAdmin is not installed yet.');
      return;
    }
    Navigator.of(
      context,
    ).pop(DatabaseLaunch(serving.url, restartApache: serving.changed));
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
        _status = _installedMessage(directory);
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

  /// Downloads the pinned, checksum-verified phpMyAdmin build.
  Future<void> _downloadFromCatalog() async {
    setState(() {
      _busy = true;
      _error = null;
      _status = 'Downloading ${_app.label}…';
    });
    try {
      final provisioner =
          widget.provisionerFactory?.call(widget.layout) ??
          StackProvisioner(widget.layout);
      final directory = await provisioner.installApp(
        _app,
        onProgress: (received, total) {
          if (!mounted) {
            return;
          }
          final fraction = total == null || total <= 0
              ? null
              : received / total;
          setState(
            () => _status =
                'Downloading ${_app.label}'
                '${fraction == null ? '…' : ' (${(fraction * 100).round()}%)'}',
          );
        },
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _installed = directory;
        _status = _installedMessage(directory);
      });
    } on ProvisionException catch (error) {
      _fail(error.message);
    } on FileSystemException catch (error) {
      _fail('Could not install phpMyAdmin: ${error.message}');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  String _installedMessage(String directory) {
    if (!_phpAvailable) {
      return 'Installed to $directory. Install PHP before opening it.';
    }
    return 'Installed to $directory. Apache will be restarted to load the '
        'alias.';
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
              if (!_phpAvailable) ...[
                _MessageBox(
                  color: const Color(0xFFFFF4E5),
                  textColor: const Color(0xFF8A6D3B),
                  child: const Text(
                    'No PHP version is active in this stack. Install PHP first '
                    'from the PHP service card; Apache cannot execute '
                    'phpMyAdmin without it.',
                    style: TextStyle(fontSize: 12.5),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              if (installed != null)
                ..._installedView(installed)
              else
                ..._installView(),
              if (_status != null) ...[
                const SizedBox(height: 12),
                Text(
                  _status!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF7A8880),
                  ),
                ),
              ],
              if (_busy) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                _MessageBox(
                  color: const Color(0xFFFBEAEA),
                  textColor: const Color(0xFFA33A3A),
                  child: Text(
                    _error!,
                    style: const TextStyle(fontSize: 12.5),
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
          onPressed: _busy || installed == null ? null : _openInBrowser,
          icon: const Icon(Icons.open_in_new, size: 18),
          label: const Text('Open phpMyAdmin'),
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
      SelectableText(
        _openUrl,
        style: const TextStyle(fontSize: 12.5, color: Color(0xFF7A8880)),
      ),
      const SizedBox(height: 8),
      const Text(
        'The generated config connects to 127.0.0.1 as root with no password, '
        'which matches a default local MySQL install. Opening phpMyAdmin also '
        'checks that Apache answers, restarts it if the alias changed, and '
        'reports the HTTP status.',
        style: TextStyle(fontSize: 12, color: Color(0xFF7A8880)),
      ),
    ];
  }

  List<Widget> _installView() {
    return [
      Text(
        'phpMyAdmin was not found in this stack.',
        style: const TextStyle(fontSize: 13),
      ),
      if (_needsRepair) ...[
        const SizedBox(height: 8),
        _MessageBox(
          color: const Color(0xFFFFF4E5),
          textColor: const Color(0xFF8A6D3B),
          child: const Text(
            'An existing phpmyadmin folder is incomplete, so Apache cannot '
            'serve it. Installing again replaces it.',
            style: TextStyle(fontSize: 12),
          ),
        ),
      ],
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            onPressed: _busy ? null : _downloadFromCatalog,
            icon: const Icon(Icons.download, size: 18),
            label: Text('Download ${_app.label}'),
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
      const SizedBox(height: 10),
      const Text(
        'StackPilot installs phpMyAdmin into '
        'etc\\apps\\phpmyadmin, outside the web root, and serves it at '
        '/phpmyadmin through an Apache alias. Apache and MySQL must be '
        'running before the page can load.',
        style: TextStyle(fontSize: 12, color: Color(0xFF7A8880)),
      ),
    ];
  }
}

class _MessageBox extends StatelessWidget {
  const _MessageBox({
    required this.color,
    required this.textColor,
    required this.child,
  });

  final Color color;
  final Color textColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: textColor),
        child: child,
      ),
    );
  }
}
