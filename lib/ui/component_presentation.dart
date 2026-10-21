import 'package:flutter/material.dart';

import '../core/stack_layout.dart';

const componentLabels = {
  StackComponent.apache: 'Apache',
  StackComponent.nginx: 'Nginx',
  StackComponent.mysql: 'MySQL',
  StackComponent.postgresql: 'PostgreSQL',
  StackComponent.php: 'PHP',
  StackComponent.nodejs: 'Node.js',
  StackComponent.redis: 'Redis',
  StackComponent.memcached: 'Memcached',
  StackComponent.mailpit: 'Mailpit',
};

const componentIcons = {
  StackComponent.apache: Icons.public,
  StackComponent.nginx: Icons.bolt,
  StackComponent.mysql: Icons.storage,
  StackComponent.postgresql: Icons.dns_outlined,
  StackComponent.php: Icons.code,
  StackComponent.nodejs: Icons.javascript,
  StackComponent.redis: Icons.memory,
  StackComponent.memcached: Icons.cached,
  StackComponent.mailpit: Icons.mail_outline,
};
