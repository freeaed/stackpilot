import 'dart:io';

import 'package:path/path.dart' as p;

import 'stack_layout.dart';

/// PHP directives exposed by the settings dialog.
class PhpIniSettings {
  const PhpIniSettings({
    required this.memoryLimit,
    required this.uploadMaxFilesize,
    required this.postMaxSize,
    required this.maxExecutionTime,
    required this.displayErrors,
    required this.iniPath,
  });

  const PhpIniSettings.unavailable()
    : memoryLimit = '512M',
      uploadMaxFilesize = '2G',
      postMaxSize = '2G',
      maxExecutionTime = '36000',
      displayErrors = true,
      iniPath = null;

  final String memoryLimit;
  final String uploadMaxFilesize;
  final String postMaxSize;
  final String maxExecutionTime;
  final bool displayErrors;
  final String? iniPath;

  bool get editable => iniPath != null;

  static PhpIniSettings load(StackLayout layout) {
    final install = layout.activeVersion(StackComponent.php);
    if (install == null) {
      return const PhpIniSettings.unavailable();
    }
    final file = File(p.join(install.directory, 'php.ini'));
    if (!file.existsSync()) {
      return const PhpIniSettings.unavailable();
    }

    final String source;
    try {
      source = file.readAsStringSync();
    } on FileSystemException {
      return const PhpIniSettings.unavailable();
    }

    return PhpIniSettings(
      memoryLimit: _directive(source, 'memory_limit', '512M'),
      uploadMaxFilesize: _directive(source, 'upload_max_filesize', '2G'),
      postMaxSize: _directive(source, 'post_max_size', '2G'),
      maxExecutionTime: _directive(source, 'max_execution_time', '36000'),
      displayErrors: _isEnabled(_directive(source, 'display_errors', 'On')),
      iniPath: file.path,
    );
  }

  PhpIniSettings copyWith({
    String? memoryLimit,
    String? uploadMaxFilesize,
    String? postMaxSize,
    String? maxExecutionTime,
    bool? displayErrors,
  }) {
    return PhpIniSettings(
      memoryLimit: memoryLimit ?? this.memoryLimit,
      uploadMaxFilesize: uploadMaxFilesize ?? this.uploadMaxFilesize,
      postMaxSize: postMaxSize ?? this.postMaxSize,
      maxExecutionTime: maxExecutionTime ?? this.maxExecutionTime,
      displayErrors: displayErrors ?? this.displayErrors,
      iniPath: iniPath,
    );
  }

  static String _directive(String source, String key, String fallback) {
    final pattern = RegExp(
      '^[ \\t]*${RegExp.escape(key)}[ \\t]*=[ \\t]*([^\\r\\n;]*)',
      caseSensitive: false,
      multiLine: true,
    );
    final match = pattern.firstMatch(source);
    final value = match?.group(1)?.trim();
    return value == null || value.isEmpty ? fallback : value;
  }

  static bool _isEnabled(String? value) {
    final normalized = value?.trim().toLowerCase();
    return normalized == 'on' || normalized == '1' || normalized == 'true';
  }
}

/// Mutable snapshot of the Laragon settings StackPilot can safely edit.
class StackSettings {
  const StackSettings({
    required this.documentRoot,
    required this.dataDirectory,
    required this.mysqlPort,
    required this.postgresqlPort,
    required this.autoVirtualHosts,
    required this.apacheSsl,
    required this.enabledServices,
    required this.php,
  });

  final String documentRoot;
  final String dataDirectory;
  final int mysqlPort;
  final int postgresqlPort;
  final bool autoVirtualHosts;
  final bool apacheSsl;
  final Set<StackComponent> enabledServices;
  final PhpIniSettings php;

  static StackSettings load(StackLayout layout) {
    return StackSettings(
      documentRoot: layout.documentRoot,
      dataDirectory: layout.dataDirectory,
      mysqlPort: layout.mysqlPort,
      postgresqlPort: layout.postgresqlPort,
      autoVirtualHosts: layout.autoVirtualHosts,
      apacheSsl: _isEnabled(layout.config.value('apache', 'SSLEnabled')),
      enabledServices: {
        for (final component in StackLayout.serviceComponents)
          if (layout.serviceEnabled(component)) component,
      },
      php: PhpIniSettings.load(layout),
    );
  }

  StackSettings copyWith({
    String? documentRoot,
    String? dataDirectory,
    int? mysqlPort,
    int? postgresqlPort,
    bool? autoVirtualHosts,
    bool? apacheSsl,
    Set<StackComponent>? enabledServices,
    PhpIniSettings? php,
  }) {
    return StackSettings(
      documentRoot: documentRoot ?? this.documentRoot,
      dataDirectory: dataDirectory ?? this.dataDirectory,
      mysqlPort: mysqlPort ?? this.mysqlPort,
      postgresqlPort: postgresqlPort ?? this.postgresqlPort,
      autoVirtualHosts: autoVirtualHosts ?? this.autoVirtualHosts,
      apacheSsl: apacheSsl ?? this.apacheSsl,
      enabledServices: enabledServices ?? this.enabledServices,
      php: php ?? this.php,
    );
  }

  static bool _isEnabled(String? value) {
    final normalized = value?.trim();
    return normalized != null &&
        normalized.isNotEmpty &&
        normalized != '0' &&
        normalized.toLowerCase() != 'false';
  }
}
