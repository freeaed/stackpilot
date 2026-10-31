import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/app_catalog.dart';
import '../../core/bundled_payload.dart';
import '../../core/component_catalog.dart';
import '../../core/remote_catalog.dart';
import '../../core/stack_layout.dart';
import '../../core/stack_provisioner.dart';
import '../component_presentation.dart';
import '../windows_dialogs.dart';

/// What the setup dialog did, so the dashboard can refresh once.
class StackSetupResult {
  const StackSetupResult({
    required this.installed,
    required this.failures,
    this.stackRoot,
    this.startAll = false,
    this.cancelled = false,
  });

  final int installed;
  final List<String> failures;

  /// Stack that was set up, when the user changed it in the dialog.
  final String? stackRoot;

  /// The user asked to start every enabled service after setup.
  final bool startAll;

  /// The user stopped the download.
  final bool cancelled;

  bool get changed => installed > 0;
}

/// Offers the pinned starter components and installs the selected ones.
Future<StackSetupResult?> showStackSetupDialog(
  BuildContext context, {
  required StackLayout layout,
  StackProvisioner Function(StackLayout layout)? provisionerFactory,
  BundledPayload? payload,
  List<String> initialSelection = const [],
}) {
  return showDialog<StackSetupResult>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _StackSetupDialog(
      layout: layout,
      provisionerFactory: provisionerFactory,
      payload: payload,
      initialSelection: initialSelection,
    ),
  );
}

class _StackSetupDialog extends StatefulWidget {
  const _StackSetupDialog({
    required this.layout,
    this.provisionerFactory,
    this.payload,
    this.initialSelection = const [],
  });

  final StackLayout layout;
  final StackProvisioner Function(StackLayout layout)? provisionerFactory;
  final BundledPayload? payload;

  /// Components (by directory name) preselected from the installer.
  final List<String> initialSelection;

  @override
  State<_StackSetupDialog> createState() => _StackSetupDialogState();
}

class _StackSetupDialogState extends State<_StackSetupDialog> {
  late StackLayout _layout = widget.layout;
  List<ComponentRelease> _releases = ComponentCatalog.releases;
  List<CatalogApp> _apps = AppCatalog.apps;
  late final Set<String> _selected = _defaultSelection();
  late final BundledPayload? _payload =
      widget.payload ?? BundledPayload.locate();
  final Map<String, ProvisionProgress> _progress = {};
  String? _catalogNotice;

  ProvisionCancellation? _cancellation;
  bool _reinstall = false;
  bool _busy = false;
  bool _done = false;
  bool _cancelled = false;
  int _installed = 0;
  List<String> _failures = const [];
  List<ProvisionFailure> _failedComponents = const [];
  final Set<String> _selectedApps = {};
  final Set<String> _installedApps = {};
  final Map<String, String> _appStatus = {};
  String? _error;

  /// Components that are offered on a fresh install and are still missing.
  Set<String> _defaultSelection() {
    if (widget.initialSelection.isNotEmpty) {
      final chosen = widget.initialSelection
          .map((name) => name.toLowerCase())
          .toSet();
      return {
        for (final release in _releases)
          if (chosen.contains(release.component.directoryName) &&
              !ComponentCatalog.isInstalled(_layout, release))
            release.id,
      };
    }
    final recommended = {
      for (final release in ComponentCatalog.recommended)
        release.component.directoryName,
    };
    return {
      for (final release in _releases)
        if (recommended.contains(release.component.directoryName) &&
            !ComponentCatalog.isInstalled(_layout, release))
          release.id,
    };
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadRemoteCatalog());
  }

  /// Replaces the compiled-in catalog with the signed one when the build has
  /// a catalog URL. A failure keeps the built-in pins and says why.
  Future<void> _loadRemoteCatalog() async {
    final remote = RemoteCatalog.fromConfig();
    if (remote == null) {
      return;
    }
    try {
      final snapshot = await remote.fetch().timeout(
        const Duration(seconds: 15),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _releases = snapshot.components;
        _apps = snapshot.apps.isEmpty ? AppCatalog.apps : snapshot.apps;
        _selected
          ..clear()
          ..addAll(_defaultSelection());
        _catalogNotice = null;
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(
        () => _catalogNotice =
            'Using the built-in component catalog: $error',
      );
    }
  }

  List<ComponentRelease> get _missing => [
    for (final release in _releases)
      if (!ComponentCatalog.isInstalled(_layout, release)) release,
  ];

  List<ComponentRelease> get _chosen => [
    for (final release in _releases)
      if (_selected.contains(release.id)) release,
  ];

  List<ComponentRelease> _versionsOf(StackComponent component) => [
    for (final release in _releases)
      if (release.component == component) release,
  ];

  Future<void> _changeStack() async {
    if (_busy) {
      return;
    }
    final path = await pickFolder('Select the stack to set up');
    if (path == null || !mounted) {
      return;
    }
    final layout = StackLayout.detect(path);
    if (layout == null) {
      setState(
        () => _error =
            'No stack found at $path. Expected usr\\stackpilot.ini (or '
            'usr\\laragon.ini) and a bin folder.',
      );
      return;
    }
    setState(() {
      _layout = layout;
      _error = null;
      _done = false;
      _cancelled = false;
      _installed = 0;
      _failures = const [];
      _failedComponents = const [];
      _appStatus.clear();
      _installedApps.clear();
      _progress.clear();
      _selected
        ..clear()
        ..addAll(_defaultSelection());
      _selectedApps.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return AlertDialog(
      title: const Text('Set up this stack'),
      content: SizedBox(
        width: 620,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 520),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F7F3),
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: const Color(0xFFCFE0D6)),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.folder_outlined,
                        size: 18,
                        color: Color(0xFF0E7A4A),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Target stack folder',
                              style: TextStyle(
                                fontSize: 11,
                                color: Color(0xFF7A8880),
                              ),
                            ),
                            Text(
                              _layout.root,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF2F4238),
                              ),
                            ),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: _busy ? null : _changeStack,
                        child: const Text('Change…'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'StackPilot downloads official builds into this stack and '
                  'configures them for its own folders and ports. Nothing is '
                  'shared with another tool.',
                  style: textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF52605A),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F7F3),
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: const Color(0xFFCFE0D6)),
                  ),
                  child: const Row(
                    children: [
                      Icon(
                        Icons.verified_user_outlined,
                        size: 17,
                        color: Color(0xFF0E7A4A),
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Every archive is checked against its published '
                          'SHA-256 digest before it is unpacked.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF2F4238),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                if (_payload != null) ...[
                  _MessageBox(
                    color: const Color(0xFFEDF7F1),
                    textColor: const Color(0xFF0E7A4A),
                    text:
                        'Offline payload found: ${_payload.count} '
                        '${_payload.count == 1 ? 'component' : 'components'} '
                        'will install from disk when available. Everything '
                        'else downloads as usual.',
                  ),
                  const SizedBox(height: 10),
                ],
                if (_catalogNotice != null) ...[
                  _MessageBox(
                    color: const Color(0xFFF6F2E7),
                    textColor: const Color(0xFF7A6537),
                    text: _catalogNotice!,
                  ),
                  const SizedBox(height: 10),
                ],
                Text(
                  'Components',
                  style: textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Wrap(
                  spacing: 4,
                  children: [
                    TextButton(
                      onPressed: _busy || _done
                          ? null
                          : () => setState(() {
                              _selected
                                ..clear()
                                ..addAll(_defaultSelection());
                              _reinstall = false;
                            }),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      child: const Text('Recommended'),
                    ),
                    TextButton(
                      onPressed: _busy || _done
                          ? null
                          : () => setState(() {
                              _selected
                                ..clear()
                                ..addAll(
                                  _missing.map((release) => release.id),
                                );
                              _reinstall = false;
                            }),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      child: const Text('Download only missing'),
                    ),
                    TextButton(
                      onPressed: _busy || _done
                          ? null
                          : () => setState(() {
                              _selected
                                ..clear()
                                ..addAll(
                                  _releases.map(
                                    (release) => release.id,
                                  ),
                                );
                              _reinstall = true;
                            }),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      child: const Text('Re-download'),
                    ),
                    TextButton(
                      onPressed: _busy || _done
                          ? null
                          : () => setState(() {
                              _selected.clear();
                              _reinstall = false;
                            }),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      child: const Text('Clear'),
                    ),
                  ],
                ),
                const Divider(height: 1),
                for (final release in _releases)
                  _ReleaseTile(
                    release: release,
                    installed: ComponentCatalog.isInstalled(_layout, release),
                    selected: _selected.contains(release.id),
                    progress: _progress[release.id],
                    enabled: !_busy && !_done,
                    reinstall: _reinstall,
                    versions: _versionsOf(release.component),
                    onVersionChanged: (chosen) => setState(() {
                      _selected.remove(release.id);
                      _selected.add(chosen.id);
                    }),
                    onChanged: (value) => setState(() {
                      if (value) {
                        _selected.add(release.id);
                      } else {
                        _selected.remove(release.id);
                      }
                    }),
                  ),
                const Divider(height: 1),
                const SizedBox(height: 8),
                Text(
                  'Applications',
                  style: textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                for (final app in _apps) _appTile(app),
                if (_missing.isEmpty && !_reinstall)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'Every pinned component is already installed. Use the '
                      'version menu on a card to add another build.',
                      style: TextStyle(fontSize: 12.5, color: Color(0xFF52605A)),
                    ),
                  ),
                const SizedBox(height: 8),
                Text(
                  'No internet? Use "Add version…" on a service card and '
                  'choose ZIP file or folder to install a build you already '
                  'have.',
                  style: textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF7A8880),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  _MessageBox(
                    color: const Color(0xFFFBEAEA),
                    textColor: const Color(0xFFA33A3A),
                    text: _error!,
                  ),
                ],
                if (_done) ...[
                  const SizedBox(height: 12),
                  _MessageBox(
                    color: _cancelled
                        ? const Color(0xFFF6F2E7)
                        : const Color(0xFFEDF7F1),
                    textColor: _cancelled
                        ? const Color(0xFF7A6537)
                        : const Color(0xFF0E7A4A),
                    text: _cancelled
                        ? 'Download cancelled. Installed components were kept.'
                        : _installed == 0
                        ? 'Nothing new was installed.'
                        : 'Installed $_installed '
                              '${_installed == 1 ? 'component' : 'components'}. '
                              'Their configuration is written and the services '
                              'are enabled.',
                  ),
                if (_failures.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  for (final failure in _failedComponents)
                    _ProvisionFailureCard(
                      failure: failure,
                      busy: _busy || _done,
                      onRetry: () => _fixFailure(failure, _FixMode.retry),
                      onMirror: () => _fixFailure(failure, _FixMode.mirror),
                      onChooseZip: () => _fixFailure(failure, _FixMode.zip),
                    ),
                  for (final message in _failures.where(
                    (message) => !_failedComponents.any(
                      (failure) => message.contains(failure.message),
                    ),
                  ))
                    _MessageBox(
                      color: const Color(0xFFFBEAEA),
                      textColor: const Color(0xFFA33A3A),
                      text: message,
                    ),
                ],
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        if (!_done)
          TextButton(
            onPressed: _busy ? _cancel : () => Navigator.of(context).pop(),
            child: Text(_busy ? 'Cancel download' : 'Cancel'),
          ),
        if (!_done)
          FilledButton.icon(
            onPressed: _busy || (_chosen.isEmpty && _chosenApps.isEmpty)
                ? null
                : _start,
            icon: const Icon(Icons.download, size: 18),
            label: Text(
              _busy
                  ? 'Downloading…'
                  : _chosen.isEmpty && _chosenApps.isEmpty
                  ? 'Install'
                  : 'Install ${_chosen.length + _chosenApps.length} '
                        '${_chosen.length + _chosenApps.length == 1 ? 'component' : 'components'}',
            ),
          ),
        if (_done) ...[
          if (_installed > 0)
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(
                StackSetupResult(
                  installed: _installed,
                  failures: _failures,
                  stackRoot: _layout.root,
                  startAll: true,
                  cancelled: _cancelled,
                ),
              ),
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: const Text('Start all'),
            ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(
              StackSetupResult(
                installed: _installed,
                failures: _failures,
                stackRoot: _layout.root,
                cancelled: _cancelled,
              ),
            ),
            child: const Text('Done'),
          ),
        ],
      ],
    );
  }

  void _cancel() {
    _cancellation?.cancel();
  }

  Widget _appTile(CatalogApp app) {
    final installed = _layout.phpMyAdminDirectory != null;
    final progress = _appStatus[app.id];
    final busy = _busy && _selectedApps.contains(app.id) && progress != null;
    return CheckboxListTile(
      value: installed || _selectedApps.contains(app.id),
      onChanged: installed || _busy || _done
          ? null
          : (value) => setState(() {
              if (value ?? false) {
                _selectedApps.add(app.id);
              } else {
                _selectedApps.remove(app.id);
              }
            }),
      controlAffinity: ListTileControlAffinity.leading,
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 2),
      secondary: Icon(
        Icons.apps,
        size: 20,
        color: installed
            ? const Color(0xFF0E7A4A)
            : Theme.of(context).colorScheme.primary,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              app.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          _Tag(
            label: installed ? 'Installed' : 'Optional',
            color: installed
                ? const Color(0xFF52605A)
                : const Color(0xFF7A6537),
          ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            installed
                ? 'Served from ${_layout.phpMyAdminDirectory}'
                : '${app.sizeLabel} · ${app.notes ?? ''}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5, color: Color(0xFF7A8880)),
          ),
          if (busy) ...[
            const SizedBox(height: 4),
            Text(
              progress,
              style: const TextStyle(
                fontSize: 11.5,
                color: Color(0xFF2F4238),
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<CatalogApp> get _chosenApps => [
    for (final app in _apps)
      if (_selectedApps.contains(app.id)) app,
  ];

  Future<void> _start() async {
    final chosen = _chosen;
    final apps = _chosenApps;
    final cancellation = ProvisionCancellation();
    setState(() {
      _busy = true;
      _error = null;
      _cancelled = false;
      _progress.clear();
      _failedComponents = const [];
      _failures = const [];
      _cancellation = cancellation;
    });

    try {
      final provisioner =
          widget.provisionerFactory?.call(_layout) ??
          StackProvisioner(
            _layout,
            payload: _payload,
            cancellation: cancellation,
          );
      var installed = 0;
      final failures = <ProvisionFailure>[];
      final appFailures = <String>[];
      var cancelled = false;
      if (chosen.isNotEmpty) {
        final report = await provisioner.installAll(
          chosen,
          reinstall: _reinstall,
          onProgress: (progress) {
            if (!mounted) {
              return;
            }
            setState(() => _progress[progress.release.id] = progress);
          },
        );
        installed = report.installed
            .where((component) => !component.alreadyInstalled)
            .length;
        failures.addAll(report.failures);
        cancelled = report.cancelled;
      }

      for (final app in apps) {
        if (cancellation.isCancelled) {
          cancelled = true;
          break;
        }
        if (!mounted) {
          return;
        }
        setState(() => _appStatus[app.id] = 'Downloading…');
        try {
          await provisioner.installApp(
            app,
            onProgress: (received, total) {
              if (!mounted) {
                return;
              }
              setState(
                () => _appStatus[app.id] = total == null
                    ? 'Downloading ${_bytes(received)}…'
                    : 'Downloading ${_bytes(received)} of '
                          '${_bytes(total)}…',
              );
            },
          );
          if (!mounted) {
            return;
          }
          setState(() {
            _appStatus[app.id] = 'Installed';
            _installedApps.add(app.id);
          });
          installed++;
        } on ProvisionCancelled {
          cancelled = true;
          break;
        } on ProvisionException catch (error) {
          appFailures.add('${app.label}: ${error.message}');
        } on Object catch (error) {
          appFailures.add('${app.label}: $error');
        }
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _done = true;
        _cancelled = cancelled;
        _installed = installed;
        _failedComponents = failures;
        _failures = [
          for (final failure in failures) failure.toString(),
          ...appFailures,
        ];
        _cancellation = null;
      });
    } on ProvisionException catch (error) {
      _fail(error.message);
    } on Object catch (error) {
      _fail('Could not set up the stack: $error');
    }
  }

  /// Retries a failed component, optionally through its mirror or from a ZIP
  /// the user already downloaded.
  Future<void> _fixFailure(ProvisionFailure failure, _FixMode mode) async {
    if (_busy) {
      return;
    }
    if (mode == _FixMode.zip) {
      final path = await pickZipFile('Select the ${failure.release.label} ZIP');
      if (path == null || !mounted) {
        return;
      }
      await _installFromFile(failure, File(path));
      return;
    }

    final cancellation = ProvisionCancellation();
    setState(() {
      _busy = true;
      _error = null;
      _cancellation = cancellation;
    });
    try {
      final provisioner =
          widget.provisionerFactory?.call(_layout) ??
          StackProvisioner(
            _layout,
            payload: _payload,
            cancellation: cancellation,
          );
      await provisioner.install(
        failure.release,
        preferMirror: mode == _FixMode.mirror,
        reinstall: true,
        onProgress: (progress) {
          if (!mounted) {
            return;
          }
          setState(() => _progress[progress.release.id] = progress);
        },
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _cancellation = null;
        _failedComponents = [
          for (final item in _failedComponents)
            if (item.release != failure.release) item,
        ];
        _failures = [for (final item in _failedComponents) item.toString()];
        _installed = _installed + 1;
      });
    } on ProvisionException catch (error) {
      _fail(error.message);
    } on Object catch (error) {
      _fail('Could not install ${failure.release.label}: $error');
    }
  }

  Future<void> _installFromFile(
    ProvisionFailure failure,
    File archive,
  ) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final provisioner =
          widget.provisionerFactory?.call(_layout) ??
          StackProvisioner(_layout, payload: _payload);
      await provisioner.installFromArchive(failure.release, archive);
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _failedComponents = [
          for (final item in _failedComponents)
            if (item.release != failure.release) item,
        ];
        _failures = [for (final item in _failedComponents) item.toString()];
        _installed = _installed + 1;
      });
    } on ProvisionException catch (error) {
      _fail(error.message);
    } on Object catch (error) {
      _fail('Could not install ${failure.release.label}: $error');
    }
  }

  static String _bytes(int bytes) {
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

  void _fail(String message) {
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = false;
      _cancellation = null;
      _error = message;
    });
  }
}

class _ReleaseTile extends StatelessWidget {
  const _ReleaseTile({
    required this.release,
    required this.installed,
    required this.selected,
    required this.progress,
    required this.enabled,
    required this.reinstall,
    required this.versions,
    required this.onVersionChanged,
    required this.onChanged,
  });

  final ComponentRelease release;
  final bool installed;
  final bool selected;
  final ProvisionProgress? progress;
  final bool enabled;
  final bool reinstall;

  /// Every pinned build of this component; more than one shows a dropdown.
  final List<ComponentRelease> versions;
  final ValueChanged<ComponentRelease> onVersionChanged;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final progress = this.progress;
    final busy =
        progress != null &&
        progress.phase != ProvisionPhase.done &&
        progress.phase != ProvisionPhase.failed;
    final failed = progress?.phase == ProvisionPhase.failed;
    final completed = progress?.phase == ProvisionPhase.done || installed;

    return CheckboxListTile(
      value: completed || selected,
      onChanged: (installed && !reinstall) || !enabled
          ? null
          : (value) => onChanged(value ?? false),
      controlAffinity: ListTileControlAffinity.leading,
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 2),
      secondary: Icon(
        componentIcons[release.component],
        size: 20,
        color: completed
            ? const Color(0xFF0E7A4A)
            : Theme.of(context).colorScheme.primary,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              release.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (versions.length > 1) ...[
            const SizedBox(width: 8),
            DropdownButton<String>(
              value: release.id,
              isDense: true,
              underline: const SizedBox.shrink(),
              style: const TextStyle(fontSize: 11.5),
              items: [
                for (final version in versions)
                  DropdownMenuItem(
                    value: version.id,
                    child: Text(version.version),
                  ),
              ],
              onChanged: enabled
                  ? (id) {
                      final chosen = versions.firstWhere(
                        (version) => version.id == id,
                      );
                      onVersionChanged(chosen);
                    }
                  : null,
            ),
          ],
          if (release.isRecommended && !installed) ...[
            const SizedBox(width: 8),
            const _Tag(label: 'Recommended', color: Color(0xFF0E7A4A)),
          ],
          if (installed) ...[
            const SizedBox(width: 8),
            _Tag(
              label: reinstall ? 'Will re-download' : 'Installed',
              color: reinstall
                  ? const Color(0xFF7A6537)
                  : const Color(0xFF52605A),
            ),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            installed && !reinstall
                ? 'Already in this stack'
                : '${release.sizeLabel} · ${release.notes ?? ''}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5, color: Color(0xFF7A8880)),
          ),
          if (progress != null && (busy || failed)) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: progress.phase == ProvisionPhase.downloading
                  ? progress.fraction
                  : null,
              minHeight: 4,
              color: failed ? const Color(0xFFA33A3A) : null,
            ),
            const SizedBox(height: 4),
            Text(
              _phaseLabel(progress),
              style: TextStyle(
                fontSize: 11.5,
                color: failed
                    ? const Color(0xFFA33A3A)
                    : const Color(0xFF2F4238),
              ),
            ),
          ] else if (selected && !completed) ...[
            const SizedBox(height: 2),
            Text(
              reinstall ? 'Will download again' : 'Will download',
              style: const TextStyle(
                fontSize: 11,
                color: Color(0xFF0E7A4A),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _phaseLabel(ProvisionProgress progress) {
    return switch (progress.phase) {
      ProvisionPhase.queued => 'Waiting…',
      ProvisionPhase.downloading =>
        progress.total == null
            ? 'Downloading ${_bytes(progress.received)}…'
            : 'Downloading ${_bytes(progress.received)} of '
                  '${_bytes(progress.total!)}…',
      ProvisionPhase.verifying => 'Verifying the SHA-256 checksum…',
      ProvisionPhase.installing => 'Extracting into the stack…',
      ProvisionPhase.configuring => 'Configuring for this stack…',
      ProvisionPhase.done => 'Installed',
      ProvisionPhase.failed => progress.message ?? 'Failed',
    };
  }

  static String _bytes(int bytes) {
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
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

/// Recovery actions offered for a failed component.
enum _FixMode { retry, mirror, zip }

/// One failed component with its digest details and recovery buttons.
class _ProvisionFailureCard extends StatelessWidget {
  const _ProvisionFailureCard({
    required this.failure,
    required this.busy,
    required this.onRetry,
    required this.onMirror,
    required this.onChooseZip,
  });

  final ProvisionFailure failure;
  final bool busy;
  final VoidCallback onRetry;
  final VoidCallback onMirror;
  final VoidCallback onChooseZip;

  @override
  Widget build(BuildContext context) {
    final mismatch = failure.isChecksumMismatch;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFBEAEA),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            failure.message,
            style: const TextStyle(
              fontSize: 12.5,
              color: Color(0xFFA33A3A),
            ),
          ),
          if (mismatch) ...[
            const SizedBox(height: 6),
            SelectableText(
              'Expected: ${failure.expectedSha256}\n'
              'Received: ${failure.actualSha256}\n'
              'URL: ${failure.url ?? 'unknown'}',
              style: const TextStyle(
                fontSize: 11,
                color: Color(0xFF7A3A3A),
                fontFamily: 'Consolas',
              ),
            ),
          ],
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            children: [
              TextButton.icon(
                onPressed: busy ? null : onRetry,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Retry'),
              ),
              if (failure.release.hasFallback)
                TextButton.icon(
                  onPressed: busy ? null : onMirror,
                  icon: const Icon(Icons.swap_horiz, size: 16),
                  label: const Text('Try mirror'),
                ),
              TextButton.icon(
                onPressed: busy ? null : onChooseZip,
                icon: const Icon(Icons.folder_zip_outlined, size: 16),
                label: const Text('Choose ZIP…'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MessageBox extends StatelessWidget {
  const _MessageBox({
    required this.color,
    required this.textColor,
    required this.text,
  });

  final Color color;
  final Color textColor;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(color: textColor, fontSize: 12.5),
      ),
    );
  }
}
