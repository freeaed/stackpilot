import 'package:flutter/material.dart';

import '../../core/bundled_payload.dart';
import '../../core/component_catalog.dart';
import '../../core/stack_layout.dart';
import '../../core/stack_provisioner.dart';
import '../component_presentation.dart';

/// What the setup dialog did, so the dashboard can refresh once.
class StackSetupResult {
  const StackSetupResult({
    required this.installed,
    required this.failures,
  });

  final int installed;
  final List<String> failures;

  bool get changed => installed > 0;
}

/// Offers the pinned starter components and installs the selected ones.
Future<StackSetupResult?> showStackSetupDialog(
  BuildContext context, {
  required StackLayout layout,
  StackProvisioner Function(StackLayout layout)? provisionerFactory,
  BundledPayload? payload,
}) {
  return showDialog<StackSetupResult>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _StackSetupDialog(
      layout: layout,
      provisionerFactory: provisionerFactory,
      payload: payload,
    ),
  );
}

class _StackSetupDialog extends StatefulWidget {
  const _StackSetupDialog({
    required this.layout,
    this.provisionerFactory,
    this.payload,
  });

  final StackLayout layout;
  final StackProvisioner Function(StackLayout layout)? provisionerFactory;
  final BundledPayload? payload;

  @override
  State<_StackSetupDialog> createState() => _StackSetupDialogState();
}

class _StackSetupDialogState extends State<_StackSetupDialog> {
  late final Set<String> _selected = {
    for (final release in ComponentCatalog.recommended)
      if (!ComponentCatalog.isInstalled(widget.layout, release)) release.id,
  };
  late final BundledPayload? _payload =
      widget.payload ?? BundledPayload.locate();
  final Map<String, ProvisionProgress> _progress = {};

  bool _busy = false;
  bool _done = false;
  int _installed = 0;
  List<String> _failures = const [];
  String? _error;

  List<ComponentRelease> get _missing =>
      ComponentCatalog.missingFrom(widget.layout);

  List<ComponentRelease> get _chosen => [
    for (final release in ComponentCatalog.releases)
      if (_selected.contains(release.id)) release,
  ];

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
                Row(
                  children: [
                    Text(
                      'Components',
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                              _selected
                                ..clear()
                                ..addAll(
                                  ComponentCatalog.recommended
                                      .where(
                                        (release) => !ComponentCatalog
                                            .isInstalled(
                                              widget.layout,
                                              release,
                                            ),
                                      )
                                      .map((release) => release.id),
                                );
                            }),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      child: const Text('Recommended'),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(_selected.clear),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      child: const Text('Clear'),
                    ),
                  ],
                ),
                const Divider(height: 1),
                for (final release in ComponentCatalog.releases)
                  _ReleaseTile(
                    release: release,
                    installed: ComponentCatalog.isInstalled(
                      widget.layout,
                      release,
                    ),
                    selected: _selected.contains(release.id),
                    progress: _progress[release.id],
                    enabled: !_busy && !_done,
                    onChanged: (value) => setState(() {
                      if (value) {
                        _selected.add(release.id);
                      } else {
                        _selected.remove(release.id);
                      }
                    }),
                  ),
                if (_missing.isEmpty)
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
                    color: const Color(0xFFEDF7F1),
                    textColor: const Color(0xFF0E7A4A),
                    text: _installed == 0
                        ? 'Nothing new was installed.'
                        : 'Installed $_installed '
                              '${_installed == 1 ? 'component' : 'components'}. '
                              'Start them from their cards.',
                  ),
                  if (_failures.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _MessageBox(
                      color: const Color(0xFFFBEAEA),
                      textColor: const Color(0xFFA33A3A),
                      text: _failures.join('\n'),
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
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        if (!_done)
          FilledButton.icon(
            onPressed: _busy || _chosen.isEmpty ? null : _start,
            icon: const Icon(Icons.download, size: 18),
            label: Text(
              _chosen.isEmpty
                  ? 'Install'
                  : 'Install ${_chosen.length} '
                        '${_chosen.length == 1 ? 'component' : 'components'}',
            ),
          ),
        if (_done)
          FilledButton(
            onPressed: () => Navigator.of(context).pop(
              StackSetupResult(installed: _installed, failures: _failures),
            ),
            child: const Text('Done'),
          ),
      ],
    );
  }

  Future<void> _start() async {
    final chosen = _chosen;
    setState(() {
      _busy = true;
      _error = null;
      _progress.clear();
    });

    try {
      final provisioner =
          widget.provisionerFactory?.call(widget.layout) ??
          StackProvisioner(widget.layout, payload: _payload);
      final report = await provisioner.installAll(
        chosen,
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
        _done = true;
        _installed = report.installed
            .where((component) => !component.alreadyInstalled)
            .length;
        _failures = [for (final failure in report.failures) failure.toString()];
      });
    } on ProvisionException catch (error) {
      _fail(error.message);
    } on Object catch (error) {
      _fail('Could not set up the stack: $error');
    }
  }

  void _fail(String message) {
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = false;
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
    required this.onChanged,
  });

  final ComponentRelease release;
  final bool installed;
  final bool selected;
  final ProvisionProgress? progress;
  final bool enabled;
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
      onChanged: installed || !enabled ? null : (value) => onChanged(value ?? false),
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
          if (release.isRecommended && !installed) ...[
            const SizedBox(width: 8),
            const _Tag(label: 'Recommended', color: Color(0xFF0E7A4A)),
          ],
          if (installed) ...[
            const SizedBox(width: 8),
            const _Tag(label: 'Installed', color: Color(0xFF52605A)),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            installed
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
