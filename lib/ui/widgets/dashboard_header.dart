import 'package:flutter/material.dart';

import '../../core/stack_layout.dart';

class DashboardHeader extends StatelessWidget {
  const DashboardHeader({
    super.key,
    required this.layout,
    required this.runningServices,
    required this.onStartAll,
    required this.onStopAll,
    required this.onOpenWeb,
    required this.onOpenTerminal,
    required this.onOpenRoot,
    required this.onOpenDatabase,
    required this.onOpenLogs,
    required this.onSettings,
    required this.onChangeStack,
    required this.onRescan,
  });

  final StackLayout layout;
  final int runningServices;
  final VoidCallback? onStartAll;
  final VoidCallback? onStopAll;
  final VoidCallback onOpenWeb;
  final VoidCallback onOpenTerminal;
  final VoidCallback onOpenRoot;
  final VoidCallback onOpenDatabase;
  final VoidCallback onOpenLogs;
  final VoidCallback onSettings;
  final VoidCallback onChangeStack;
  final VoidCallback onRescan;

  @override
  Widget build(BuildContext context) {
    final running = runningServices > 0;
    final badgeColor = running
        ? const Color(0xFFB9F0D3)
        : const Color(0xFFD5DEDA);

    return Container(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 16),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0A3528), Color(0xFF0E7A4A)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Image.asset(
                  'assets/branding/stackpilot_mark.png',
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'StackPilot',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                    ),
                    Text(
                      'Pilot your local dev stack',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.18),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: badgeColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      running ? '$runningServices running' : 'All stopped',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Flexible(
                child: Text(
                  layout.root,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: onChangeStack,
                icon: const Icon(Icons.folder_open, size: 14),
                label: const Text('Change stack'),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white70,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 11.5),
                ),
              ),
              IconButton(
                onPressed: onRescan,
                icon: const Icon(Icons.refresh, size: 16),
                tooltip: 'Rescan stack folder',
                color: Colors.white70,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 26,
                  height: 26,
                ),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _HeaderAction(
                icon: Icons.play_arrow_rounded,
                label: 'Start All',
                onPressed: onStartAll,
                tooltip: 'Start every enabled service',
              ),
              _HeaderAction(
                icon: Icons.stop_rounded,
                label: 'Stop All',
                onPressed: onStopAll,
                tooltip: 'Stop services started by StackPilot',
              ),
              _HeaderAction(
                icon: Icons.language,
                label: 'Web',
                onPressed: onOpenWeb,
              ),
              _HeaderAction(
                icon: Icons.storage,
                label: 'Database',
                onPressed: onOpenDatabase,
                tooltip: 'Open phpMyAdmin, or install it in the web root',
              ),
              _HeaderAction(
                icon: Icons.article_outlined,
                label: 'Logs',
                onPressed: onOpenLogs,
                tooltip:
                    'View Apache, Nginx, MySQL, PostgreSQL, and Redis logs',
              ),
              _HeaderAction(
                icon: Icons.terminal,
                label: 'Terminal',
                onPressed: onOpenTerminal,
              ),
              _HeaderAction(
                icon: Icons.tune,
                label: 'Settings',
                onPressed: onSettings,
                tooltip:
                    'Change versions, ports, document root, and PHP settings',
              ),
              _HeaderAction(
                icon: Icons.folder_open,
                label: 'Root',
                onPressed: onOpenRoot,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeaderAction extends StatelessWidget {
  const _HeaderAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.tooltip,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? label,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          disabledForegroundColor: Colors.white38,
          backgroundColor: Colors.white.withValues(
            alpha: onPressed == null ? 0.04 : 0.10,
          ),
          side: BorderSide(
            color: Colors.white.withValues(
              alpha: onPressed == null ? 0.10 : 0.24,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
      ),
    );
  }
}
