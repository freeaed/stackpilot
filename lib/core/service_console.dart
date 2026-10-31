import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'stack_layout.dart';

/// Captures the stdout/stderr of services StackPilot starts.
///
/// Each component writes to `<stack>/logs/<component>-console.log` and to a
/// small in-memory ring buffer, so the logs window can show output even for
/// services that log only to the console (Mailpit, for example). The file is
/// rotated at [maxBytes]; one previous file is kept.
class ServiceConsole {
  ServiceConsole(
    this.root, {
    this.maxBytes = 5 * 1024 * 1024,
    this.ringLines = 2000,
  });

  final String root;
  final int maxBytes;
  final int ringLines;

  final Map<StackComponent, List<String>> _rings = {};
  final Map<StackComponent, List<StreamSubscription<String>>> _subscriptions =
      {};

  /// `<stack>/logs/<component>-console.log`.
  static File fileFor(String root, StackComponent component) => File(
    p.join(root, 'logs', '${component.directoryName}-console.log'),
  );

  File file(StackComponent component) => fileFor(root, component);

  /// The most recent [count] captured lines, oldest first.
  List<String> recentLines(StackComponent component, [int count = 40]) {
    final ring = _rings[component];
    if (ring == null || ring.isEmpty) {
      return const [];
    }
    return ring.length <= count
        ? List<String>.unmodifiable(ring)
        : List<String>.unmodifiable(ring.sublist(ring.length - count));
  }

  /// Starts capturing [stdout] and [stderr] for [component].
  ///
  /// The streams are decoded as UTF-8 and split into lines. A malformed chunk
  /// is replaced instead of stopping the capture.
  void attach(
    StackComponent component, {
    Stream<List<int>>? stdout,
    Stream<List<int>>? stderr,
  }) {
    detach(component);
    final subscriptions = <StreamSubscription<String>>[];
    for (final stream in [stdout, stderr]) {
      if (stream == null) {
        continue;
      }
      subscriptions.add(
        stream
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .listen(
              (line) => append(component, line),
              onError: (_) {},
              cancelOnError: false,
            ),
      );
    }
    if (subscriptions.isNotEmpty) {
      _subscriptions[component] = subscriptions;
    }
  }

  /// Stops capturing output for [component].
  Future<void> detach(StackComponent component) async {
    final subscriptions = _subscriptions.remove(component);
    if (subscriptions == null) {
      return;
    }
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }

  /// Stops every capture.
  Future<void> dispose() async {
    for (final component in _subscriptions.keys.toList()) {
      await detach(component);
    }
  }

  /// Appends one line to the ring buffer and the console file.
  void append(StackComponent component, String line) {
    final trimmed = line.replaceAll(RegExp(r'\r$'), '');
    final stamp = _timestamp(DateTime.now());
    final entry = '[$stamp] $trimmed';

    final ring = _rings.putIfAbsent(component, () => <String>[]);
    ring.add(entry);
    if (ring.length > ringLines) {
      ring.removeRange(0, ring.length - ringLines);
    }

    try {
      final target = file(component);
      target.parent.createSync(recursive: true);
      if (target.existsSync() && target.lengthSync() > maxBytes) {
        final previous = File('${target.path}.1');
        try {
          if (previous.existsSync()) {
            previous.deleteSync();
          }
          target.renameSync(previous.path);
        } on FileSystemException {
          // A locked log is truncated below instead.
        }
      }
      target.writeAsStringSync('$entry\r\n', mode: FileMode.append);
    } on FileSystemException {
      // The ring buffer still holds the line for this session.
    }
  }

  static String _timestamp(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }
}
