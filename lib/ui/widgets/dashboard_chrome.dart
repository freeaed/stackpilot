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
