import 'package:flutter/material.dart';

import '../windows_dialogs.dart';

/// First-run screen shown when StackPilot could not find a stack.
///
/// The user either creates a stack that StackPilot owns from then on, or opens
/// an existing StackPilot/Laragon folder. Nothing is written until the user
/// confirms a location.
class OnboardingView extends StatefulWidget {
  const OnboardingView({
    super.key,
    required this.attemptedRoot,
    required this.defaultRoot,
    required this.onCreate,
    required this.onOpenExisting,
  });

  /// Folder that was inspected before this screen was shown.
  final String attemptedRoot;

  /// Folder proposed for a new stack.
  final String defaultRoot;

  /// Creates a stack at the given folder. Returns an error message, or null
  /// when the stack was created and opened.
  final Future<String?> Function(String root) onCreate;

  /// Lets the user pick an existing stack folder. Returns an error message, or
  /// null when a stack was opened or the picker was cancelled.
  final Future<String?> Function() onOpenExisting;

  @override
  State<OnboardingView> createState() => _OnboardingViewState();
}

class _OnboardingViewState extends State<OnboardingView> {
  late final TextEditingController _folder = TextEditingController(
    text: widget.defaultRoot,
  );
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _folder.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final message = await widget.onCreate(_folder.text.trim());
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = false;
      _error = message;
    });
  }

  Future<void> _openExisting() async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final message = await widget.onOpenExisting();
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = false;
      _error = message;
    });
  }

  Future<void> _browse() async {
    final path = await pickFolder('Choose a folder for the new stack');
    if (path == null || !mounted) {
      return;
    }
    setState(() {
      _folder.text = path;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 660),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(30),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.flight_takeoff,
                        size: 36,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Welcome to StackPilot',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              'Your local web stack, managed by StackPilot. '
                              'No other tool is required.',
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  TextField(
                    controller: _folder,
                    enabled: !_busy,
                    decoration: InputDecoration(
                      labelText: 'Stack folder',
                      helperText:
                          'Created if it does not exist. Keep it somewhere '
                          'you can back up.',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        tooltip: 'Browse…',
                        onPressed: _busy ? null : _browse,
                        icon: const Icon(Icons.folder_open),
                      ),
                    ),
                    onSubmitted: (_) => _create(),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'A new stack gets bin/, usr/, etc/, www/, data/ and logs/ '
                    'folders plus its own configuration file. Add PHP, Apache, '
                    'MySQL and other versions afterwards from the service '
                    'cards.',
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: Color(0xFF7A8880),
                      height: 1.45,
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(11),
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
                  const SizedBox(height: 20),
                  if (_busy) ...[
                    const LinearProgressIndicator(),
                    const SizedBox(height: 14),
                  ],
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton.icon(
                        onPressed: _busy ? null : _create,
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Create stack'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _openExisting,
                        icon: const Icon(Icons.folder_off_outlined, size: 18),
                        label: const Text('Open existing stack…'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  const Divider(height: 1),
                  const SizedBox(height: 12),
                  Text(
                    'No stack was found at ${widget.attemptedRoot}',
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: Color(0xFF7A8880),
                    ),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'A stack needs a bin folder and usr\\stackpilot.ini '
                    '(Laragon stacks with usr\\laragon.ini also open).',
                    style: TextStyle(fontSize: 11.5, color: Color(0xFF7A8880)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
