import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/service_logs.dart';
import '../core/stack_layout.dart';

const _componentLabels = {
  StackComponent.apache: 'Apache',
  StackComponent.nginx: 'Nginx',
  StackComponent.mysql: 'MySQL',
  StackComponent.postgresql: 'PostgreSQL',
  StackComponent.redis: 'Redis',
};

Future<void> showServiceLogsDialog(
  BuildContext context, {
  required StackLayout layout,
  Future<void> Function(String path)? onOpenFolder,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) =>
        _LogsDialog(layout: layout, onOpenFolder: onOpenFolder),
  );
}

class _LogsDialog extends StatefulWidget {
  const _LogsDialog({required this.layout, this.onOpenFolder});

  final StackLayout layout;
  final Future<void> Function(String path)? onOpenFolder;

  @override
  State<_LogsDialog> createState() => _LogsDialogState();
}

class _LogsDialogState extends State<_LogsDialog> {
  late final ServiceLogs _logs = ServiceLogs(widget.layout);
  late List<ServiceLogFile> _files = _logs.discover();
  late ServiceLogFile? _selected = _files.isEmpty ? null : _files.first;
  late ServiceLogTail _tail = _read();

  final ScrollController _scroll = ScrollController();
  Timer? _timer;
  bool _follow = true;

  @override
  void initState() {
    super.initState();
    _scrollToEnd();
    if (_follow) {
      _startFollowing();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  ServiceLogTail _read() {
    final selected = _selected;
    return selected == null
        ? ServiceLogTail.empty
        : _logs.readTail(selected);
  }

  void _startFollowing() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  void _stopFollowing() {
    _timer?.cancel();
    _timer = null;
  }

  void _refresh() {
    final previous = _selected;
    final files = _logs.discover();
    ServiceLogFile? selected;
    if (previous != null) {
      for (final file in files) {
        if (file == previous) {
          selected = file;
          break;
        }
      }
    }
    selected ??= files.isEmpty ? null : files.first;

    setState(() {
      _files = files;
      _selected = selected;
      _tail = _read();
    });
    _scrollToEnd();
  }

  void _select(ServiceLogFile file) {
    if (file == _selected) {
      return;
    }
    setState(() {
      _selected = file;
      _tail = _read();
    });
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_follow || !_scroll.hasClients) {
        return;
      }
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _setFollow(bool value) {
    setState(() => _follow = value);
    if (value) {
      _refresh();
      _startFollowing();
    } else {
      _stopFollowing();
    }
  }

  Future<void> _openFolder() async {
    final selected = _selected;
    final openFolder = widget.onOpenFolder;
    if (selected == null || openFolder == null) {
      return;
    }
    await openFolder(p.dirname(selected.path));
  }

  Map<StackComponent, List<ServiceLogFile>> _grouped() {
    final groups = <StackComponent, List<ServiceLogFile>>{};
    for (final file in _files) {
      groups.putIfAbsent(file.component, () => []).add(file);
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.article_outlined, size: 20),
          SizedBox(width: 8),
          Text('Service logs'),
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      content: SizedBox(
        width: math.max(560.0, math.min(980.0, screen.width - 160)),
        height: math.max(320.0, math.min(560.0, screen.height - 200)),
        child: _files.isEmpty ? _emptyState() : _logView(context),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _emptyState() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.article_outlined, size: 38, color: Color(0xFF7A8880)),
            const SizedBox(height: 12),
            const Text(
              'No service logs found yet',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            const Text(
              'Start Apache, Nginx, MySQL, PostgreSQL, or Redis and refresh. '
              'StackPilot looks in the active version\'s logs folder and in '
              'the stack data folder.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: Color(0xFF7A8880)),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh, size: 17),
              label: const Text('Refresh'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _logView(BuildContext context) {
    final selected = _selected;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: 220,
          decoration: BoxDecoration(
            color: const Color(0xFFF7FAF8),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          ),
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            children: [
              for (final entry in _grouped().entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
                  child: Text(
                    (_componentLabels[entry.key] ?? entry.key.directoryName)
                        .toUpperCase(),
                    style: const TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.7,
                      color: Color(0xFF7A8880),
                    ),
                  ),
                ),
                for (final file in entry.value)
                  Material(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(7),
                    child: ListTile(
                      dense: true,
                      selected: file == selected,
                      selectedTileColor: const Color(0xFFE3F1E9),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(7),
                      ),
                      title: Text(
                        file.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5),
                      ),
                      onTap: () => _select(file),
                    ),
                  ),
              ],
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 0, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            selected?.label ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            selected?.path ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF7A8880),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Follow',
                          style: TextStyle(fontSize: 12),
                        ),
                        Switch(
                          value: _follow,
                          onChanged: _setFollow,
                        ),
                      ],
                    ),
                    IconButton(
                      tooltip: 'Open log folder',
                      onPressed: widget.onOpenFolder == null
                          ? null
                          : _openFolder,
                      icon: const Icon(Icons.folder_open, size: 19),
                    ),
                    IconButton(
                      tooltip: 'Refresh',
                      onPressed: _refresh,
                      icon: const Icon(Icons.refresh, size: 19),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0E1A14),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: _tail.text.isEmpty
                        ? Center(
                            child: Text(
                              _tail.exists
                                  ? 'This log is empty. New lines appear here '
                                        'when the service writes them.'
                                  : 'This log file is no longer available.',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.white54,
                              ),
                            ),
                          )
                        : Scrollbar(
                            controller: _scroll,
                            thumbVisibility: true,
                            child: SingleChildScrollView(
                              controller: _scroll,
                              child: SelectableText(
                                _tail.text,
                                key: const ValueKey('service-log-text'),
                                style: const TextStyle(
                                  fontFamily: 'Consolas',
                                  fontSize: 12,
                                  height: 1.4,
                                  color: Color(0xFFD8E8DF),
                                ),
                              ),
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _statusText(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF7A8880),
                        ),
                      ),
                    ),
                    if (_follow)
                      const Text(
                        'Following',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF0E7A4A),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _statusText() {
    if (!_tail.exists) {
      return 'The log file is missing.';
    }
    final parts = <String>[
      '${_formatBytes(_tail.bytesShown)} at the end of the file',
      'updated ${_formatTime(_tail.modified!)}',
      if (_tail.truncated) 'earlier lines hidden',
    ];
    return parts.join(' · ');
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _formatTime(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}
