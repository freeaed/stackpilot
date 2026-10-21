import 'package:flutter/material.dart';

import '../../core/service_manager.dart';
import '../../core/stack_layout.dart';
import '../component_presentation.dart';

enum _VersionMenuAction { add }

class ServicesPanel extends StatelessWidget {
  const ServicesPanel({
    super.key,
    required this.layout,
    required this.services,
    required this.busy,
    required this.bulkBusy,
    required this.onToggle,
    required this.onSelectVersion,
    required this.onAddVersion,
  });

  final StackLayout layout;
  final ServiceManager? services;
  final Set<StackComponent> busy;
  final bool bulkBusy;
  final void Function(StackComponent component, bool start) onToggle;
  final void Function(StackComponent component, StackInstall install)
  onSelectVersion;
  final void Function(StackComponent component) onAddVersion;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Versions & services',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            const _MutedChip(label: 'Click version to switch'),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          'Runtimes',
          style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final component in StackLayout.runtimeComponents)
              _ServiceCard(
                layout: layout,
                component: component,
                isService: false,
                services: services,
                busy: bulkBusy || busy.contains(component),
                onToggle: onToggle,
                onSelectVersion: onSelectVersion,
                onAddVersion: onAddVersion,
              ),
          ],
        ),
        const SizedBox(height: 24),
        Text(
          'Services',
          style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final component in StackLayout.serviceComponents)
              _ServiceCard(
                layout: layout,
                component: component,
                isService: true,
                services: services,
                busy: bulkBusy || busy.contains(component),
                onToggle: onToggle,
                onSelectVersion: onSelectVersion,
                onAddVersion: onAddVersion,
              ),
          ],
        ),
      ],
    );
  }
}

class _ServiceCard extends StatelessWidget {
  const _ServiceCard({
    required this.layout,
    required this.component,
    required this.isService,
    required this.services,
    required this.busy,
    required this.onToggle,
    required this.onSelectVersion,
    required this.onAddVersion,
  });

  final StackLayout layout;
  final StackComponent component;
  final bool isService;
  final ServiceManager? services;
  final bool busy;
  final void Function(StackComponent component, bool start)? onToggle;
  final void Function(StackComponent component, StackInstall install)?
  onSelectVersion;
  final void Function(StackComponent component)? onAddVersion;

  @override
  Widget build(BuildContext context) {
    final installed = layout.installedVersions(component);
    final active = layout.activeVersion(component);
    final displayed =
        active ?? (installed.length == 1 ? installed.single : null);
    final configured = isService && layout.serviceEnabled(component);
    final running = services?.isRunning(component) ?? false;
    final external = services?.isExternal(component) ?? false;
    final canToggle =
        isService && services != null && !busy && (running || configured);
    final colorScheme = Theme.of(context).colorScheme;

    final String versionLabel;
    if (displayed != null) {
      versionLabel = displayed.displayVersion;
    } else if (installed.isEmpty) {
      versionLabel = 'Not installed';
    } else {
      versionLabel = 'Not selected';
    }

    final String statusLabel;
    final Color statusColor;
    if (!isService) {
      statusLabel = active != null ? 'Active' : 'Idle';
      statusColor = active != null
          ? const Color(0xFF0E7A4A)
          : const Color(0xFF8A6D3B);
    } else if (busy) {
      statusLabel = 'Working…';
      statusColor = const Color(0xFF8A6D3B);
    } else if (running) {
      statusLabel = external ? 'Running (external)' : 'Running';
      statusColor = const Color(0xFF0E7A4A);
    } else if (configured) {
      statusLabel = 'Stopped';
      statusColor = const Color(0xFF8A6D3B);
    } else {
      statusLabel = 'Disabled';
      statusColor = const Color(0xFF7A8880);
    }

    return Container(
      width: 218,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: running ? const Color(0xFF8ACFAA) : const Color(0xFFE1E8E4),
        ),
        boxShadow: running
            ? const [
                BoxShadow(
                  color: Color(0x140E7A4A),
                  blurRadius: 14,
                  offset: Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                componentIcons[component],
                size: 20,
                color: colorScheme.primary,
              ),
              const Spacer(),
              if (isService)
                Tooltip(
                  message: running
                      ? external
                            ? 'Stop ${componentLabels[component]} '
                                  '(started outside StackPilot)'
                            : 'Stop ${componentLabels[component]}'
                      : configured
                      ? 'Start ${componentLabels[component]}'
                      : 'Enable ${componentLabels[component]} in laragon.ini first',
                  child: Switch(
                    value: running,
                    onChanged: canToggle
                        ? (value) => onToggle?.call(component, value)
                        : null,
                  ),
                )
              else
                _StatusBadge(label: statusLabel, color: statusColor),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            componentLabels[component]!,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 3),
          if (installed.isEmpty)
            Text(
              versionLabel,
              style: const TextStyle(fontSize: 12.5, color: Color(0xFF44534B)),
            )
          else
            PopupMenuButton<Object>(
              tooltip: 'Change ${componentLabels[component]} version',
              padding: EdgeInsets.zero,
              position: PopupMenuPosition.under,
              onSelected: (value) {
                if (value == _VersionMenuAction.add) {
                  onAddVersion?.call(component);
                } else if (value is StackInstall) {
                  onSelectVersion?.call(component, value);
                }
              },
              itemBuilder: (context) => [
                for (final install in installed)
                  CheckedPopupMenuItem<Object>(
                    value: install,
                    checked:
                        active != null &&
                        install.directory.toLowerCase() ==
                            active.directory.toLowerCase(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(install.displayVersion),
                        Text(
                          install.version,
                          style: const TextStyle(
                            fontSize: 10.5,
                            color: Color(0xFF7A8880),
                          ),
                        ),
                      ],
                    ),
                  ),
                const PopupMenuDivider(),
                const PopupMenuItem<Object>(
                  value: _VersionMenuAction.add,
                  child: Row(
                    children: [
                      Icon(Icons.add, size: 17),
                      SizedBox(width: 8),
                      Text('Add version…'),
                    ],
                  ),
                ),
              ],
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F7F3),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFCFE0D6)),
                ),
                child: Row(
                  children: [
                    const Text(
                      'Version',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: Color(0xFF6B7C73),
                      ),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        versionLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: Color(0xFF2F4238),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 18,
                      color: Color(0xFF52605A),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 2),
          if (installed.isEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: onAddVersion == null
                    ? null
                    : () => onAddVersion!(component),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add version'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(32),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            )
          else
            Text(
              '${installed.length} installed '
              '${installed.length == 1 ? 'version' : 'versions'} · click to '
              'switch',
              style: const TextStyle(fontSize: 11.5, color: Color(0xFF7A8880)),
            ),
          if (isService) ...[
            const SizedBox(height: 8),
            Text(
              statusLabel,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: statusColor,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _MutedChip extends StatelessWidget {
  const _MutedChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFE9EFEB),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 11.5, color: Color(0xFF52605A)),
      ),
    );
  }
}
