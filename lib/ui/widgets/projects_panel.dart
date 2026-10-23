import 'package:flutter/material.dart';

import '../../core/site_inventory.dart';
import '../../core/stack_layout.dart';

class ProjectsPanel extends StatelessWidget {
  const ProjectsPanel({
    super.key,
    required this.layout,
    required this.inventory,
    required this.onOpenPath,
    required this.onOpenUrl,
    required this.onGenerate,
  });

  final StackLayout layout;
  final SiteInventory? inventory;
  final ValueChanged<String> onOpenPath;
  final ValueChanged<String> onOpenUrl;
  final VoidCallback? onGenerate;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final sites = inventory?.sites ?? const <ProjectSite>[];
    final missing = inventory?.missingConfigs.length ?? 0;
    final unmapped = inventory?.unmappedHosts.length ?? 0;

    return Container(
      color: Colors.white,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Row(
            children: [
              Text(
                'Projects',
                style: textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Text(
                '${sites.length}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF7A8880),
                ),
              ),
              if ((missing > 0 || unmapped > 0) && onGenerate != null)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: IconButton(
                    tooltip: missing > 0
                        ? 'Generate $missing missing virtual host '
                              '${missing == 1 ? 'config' : 'configs'}'
                        : 'Map $unmapped host '
                              '${unmapped == 1 ? 'entry' : 'entries'} in the '
                              'hosts file',
                    icon: const Icon(Icons.auto_fix_high, size: 19),
                    onPressed: onGenerate,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            layout.documentRoot,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5, color: Color(0xFF7A8880)),
          ),
          const SizedBox(height: 12),
          if (sites.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'No projects found in the document root yet.',
                style: TextStyle(color: Color(0xFF7A8880)),
              ),
            )
          else
            for (final site in sites)
              ListTile(
                contentPadding: EdgeInsets.zero,
                isThreeLine: true,
                leading: CircleAvatar(
                  radius: 18,
                  backgroundColor: const Color(0xFFEAF3EE),
                  child: Icon(
                    Icons.folder_outlined,
                    size: 19,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                title: Text(
                  site.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (layout.autoVirtualHosts)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () => onOpenUrl('http://${site.host}'),
                          icon: const Icon(Icons.open_in_new, size: 12),
                          iconAlignment: IconAlignment.end,
                          label: Text(site.host),
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF0E7A4A),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 2,
                              vertical: 1,
                            ),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            visualDensity: VisualDensity.compact,
                            textStyle: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    Text(
                      site.documentRoot,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF7A8880),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        _SiteChip(
                          label: site.configPresent
                              ? site.configOutdated
                                    ? 'vhost outdated'
                                    : 'vhost'
                              : 'vhost missing',
                          ok: site.configPresent && !site.configOutdated,
                        ),
                        _SiteChip(
                          label: site.hostsMapped ? 'hosts' : 'hosts missing',
                          ok: site.hostsMapped,
                        ),
                        if (site.sslEnabled)
                          const _SiteChip(label: 'SSL', ok: true),
                      ],
                    ),
                  ],
                ),
                trailing: IconButton(
                  tooltip: 'Open folder',
                  icon: const Icon(Icons.open_in_new, size: 18),
                  onPressed: () => onOpenPath(site.directory),
                ),
              ),
        ],
      ),
    );
  }
}

class _SiteChip extends StatelessWidget {
  const _SiteChip({required this.label, required this.ok});

  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final color = ok ? const Color(0xFF0E7A4A) : const Color(0xFF8A6D3B);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
