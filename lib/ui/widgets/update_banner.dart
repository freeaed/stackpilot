import 'package:flutter/material.dart';

import '../../core/update_service.dart';

/// Thin strip under the header that announces a signed update.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({
    super.key,
    required this.release,
    required this.onInstall,
    required this.onDismiss,
  });

  final UpdateRelease release;
  final VoidCallback onInstall;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(22, 8, 12, 8),
      decoration: const BoxDecoration(
        color: Color(0xFFEDF7F1),
        border: Border(bottom: BorderSide(color: Color(0xFFCFE0D6))),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.system_update_alt,
            size: 18,
            color: Color(0xFF0E7A4A),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${release.label} is available.',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFF0E7A4A),
              ),
            ),
          ),
          TextButton(onPressed: onInstall, child: const Text('Review update')),
          IconButton(
            tooltip: 'Dismiss',
            onPressed: onDismiss,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }
}
