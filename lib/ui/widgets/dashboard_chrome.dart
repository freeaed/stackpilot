import 'package:flutter/material.dart';

class DashboardFooter extends StatelessWidget {
  const DashboardFooter({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 9),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE1E8E4))),
      ),
      child: const Row(
        children: [
          Expanded(
            child: Text(
              'Local only  •  No telemetry  •  No donation prompts',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: Color(0xFF7A8880)),
            ),
          ),
          SizedBox(width: 12),
          Text(
            'Managed locally',
            style: TextStyle(fontSize: 11, color: Color(0xFF7A8880)),
          ),
        ],
      ),
    );
  }
}

class MissingStackView extends StatelessWidget {
  const MissingStackView({
    super.key,
    required this.attemptedRoot,
    required this.onRetry,
  });

  final String attemptedRoot;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Card(
          margin: const EdgeInsets.all(24),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.folder_off_outlined,
                  size: 40,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 14),
                const Text(
                  'Stack not found',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                const Text(
                  'StackPilot looked for a Laragon-compatible stack at:',
                ),
                const SizedBox(height: 6),
                SelectableText(
                  attemptedRoot,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Start StackPilot with --stack-root=C:\\path\\to\\laragon '
                  'or set STACKPILOT_STACK_ROOT.',
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
