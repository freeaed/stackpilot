/// Minimal INI reader/writer for stack configuration files.
///
/// Keys and section names are matched case-insensitively, values are kept
/// verbatim (including Windows paths), and comments are ignored.
/// Line-preserving INI editor used when StackPilot has to change a value in a
/// file that may contain comments or formatting worth keeping.
///
/// Reading is still done with [IniDocument]; this class only rewrites the
/// affected key and leaves every other line untouched.
class IniEditor {
  IniEditor.parse(String source) {
    _eol = _detectLineEnding(source);
    _trailingNewline = source.endsWith('\n') || source.endsWith('\r');
    var content = source;
    if (_trailingNewline) {
      content = content.endsWith('\r\n')
          ? content.substring(0, content.length - 2)
          : content.substring(0, content.length - 1);
    }
    _lines = content.isEmpty
        ? <String>[]
        : content.split(RegExp(r'\r\n|\n|\r'));
  }

  late final String _eol;
  late final bool _trailingNewline;
  late final List<String> _lines;

  /// Sets [key] inside [sectionName], creating the section when needed.
  void setValue(String sectionName, String key, String value) {
    final range = _sectionRange(sectionName);
    if (range == null) {
      if (_lines.isNotEmpty && _lines.last.trim().isNotEmpty) {
        _lines.add('');
      }
      _lines
        ..add('[$sectionName]')
        ..add('$key=$value');
      return;
    }

    for (var index = range.start + 1; index < range.end; index++) {
      final line = _lines[index];
      final trimmed = line.trim();
      if (trimmed.isEmpty ||
          trimmed.startsWith(';') ||
          trimmed.startsWith('#')) {
        continue;
      }
      final separator = line.indexOf('=');
      if (separator < 0) {
        continue;
      }
      if (line.substring(0, separator).trim().toLowerCase() !=
          key.toLowerCase()) {
        continue;
      }
      _lines[index] = '${line.substring(0, separator + 1)}$value';
      return;
    }

    var insertAt = range.start + 1;
    for (var index = range.end - 1; index > range.start; index--) {
      if (_lines[index].trim().isNotEmpty) {
        insertAt = index + 1;
        break;
      }
    }
    _lines.insert(insertAt, '$key=$value');
  }

  String serialize() {
    final text = _lines.join(_eol);
    return _trailingNewline && text.isNotEmpty ? '$text$_eol' : text;
  }

  ({int start, int end})? _sectionRange(String name) {
    int? start;
    for (var index = 0; index < _lines.length; index++) {
      final trimmed = _lines[index].trim();
      if (!trimmed.startsWith('[') || !trimmed.endsWith(']')) {
        continue;
      }
      if (start != null) {
        return (start: start, end: index);
      }
      final sectionName = trimmed.substring(1, trimmed.length - 1).trim();
      if (sectionName.toLowerCase() == name.toLowerCase()) {
        start = index;
      }
    }
    return start == null ? null : (start: start, end: _lines.length);
  }

  static String _detectLineEnding(String source) {
    if (source.contains('\r\n')) {
      return '\r\n';
    }
    if (source.contains('\n')) {
      return '\n';
    }
    if (source.contains('\r')) {
      return '\r';
    }
    return '\r\n';
  }
}

/// Replaces a directive such as `memory_limit = 512M` while preserving the
/// rest of the file, including comments.
///
/// When [all] is true every matching directive is replaced (useful for files
/// such as `my.ini` that repeat `port` in more than one section).
String setIniDirective(
  String source,
  String key,
  String value, {
  bool all = false,
}) {
  final pattern = RegExp(
    '^([ \\t]*${RegExp.escape(key)}[ \\t]*=[ \\t]*)([^\\r\\n]*)',
    caseSensitive: false,
    multiLine: true,
  );

  if (pattern.hasMatch(source)) {
    return all
        ? source.replaceAllMapped(pattern, (match) => '${match.group(1)}$value')
        : source.replaceFirstMapped(
            pattern,
            (match) => '${match.group(1)}$value',
          );
  }

  final eol = source.contains('\r\n')
      ? '\r\n'
      : source.contains('\n')
      ? '\n'
      : '\r\n';
  final needsEol = source.isNotEmpty && !source.endsWith('\n');
  return '$source${needsEol ? eol : ''}$key=$value$eol';
}

class IniDocument {
  IniDocument._(this.sections);

  factory IniDocument.parse(String source) {
    final sections = <IniSection>[];
    IniSection? current;
    final content = source.startsWith('\uFEFF') ? source.substring(1) : source;

    for (final rawLine in content.split(RegExp(r'\r\n|\n|\r'))) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith(';') || line.startsWith('#')) {
        continue;
      }

      if (line.startsWith('[') && line.endsWith(']')) {
        final name = line.substring(1, line.length - 1).trim();
        if (name.isEmpty) {
          continue;
        }
        current = _findOrCreateSection(sections, name);
        continue;
      }

      final separator = line.indexOf('=');
      if (separator <= 0) {
        continue;
      }

      final key = line.substring(0, separator).trim();
      final value = line.substring(separator + 1).trim();
      if (key.isEmpty) {
        continue;
      }

      current ??= _findOrCreateSection(sections, '');
      current.setValue(key, value);
    }

    return IniDocument._(sections);
  }

  factory IniDocument.empty() => IniDocument._(<IniSection>[]);

  final List<IniSection> sections;

  IniSection? section(String name) {
    for (final candidate in sections) {
      if (candidate.name.toLowerCase() == name.toLowerCase()) {
        return candidate;
      }
    }
    return null;
  }

  String? value(String sectionName, String key) =>
      section(sectionName)?.value(key);

  void setValue(String sectionName, String key, String value) {
    final target = _findOrCreateSection(sections, sectionName);
    target.setValue(key, value);
  }

  String serialize() {
    final buffer = StringBuffer();
    for (final section in sections) {
      if (section.name.isNotEmpty) {
        buffer.writeln('[${section.name}]');
      }
      for (final entry in section.entries) {
        buffer.writeln('${entry.key}=${entry.value}');
      }
      buffer.writeln();
    }
    return buffer.toString();
  }

  static IniSection _findOrCreateSection(
    List<IniSection> sections,
    String name,
  ) {
    for (final candidate in sections) {
      if (candidate.name.toLowerCase() == name.toLowerCase()) {
        return candidate;
      }
    }
    final created = IniSection(name);
    sections.add(created);
    return created;
  }
}

class IniSection {
  IniSection(this.name);

  final String name;
  final List<IniEntry> entries = <IniEntry>[];

  String? value(String key) {
    for (final entry in entries.reversed) {
      if (entry.key.toLowerCase() == key.toLowerCase()) {
        return entry.value;
      }
    }
    return null;
  }

  void setValue(String key, String value) {
    for (final entry in entries.reversed) {
      if (entry.key.toLowerCase() == key.toLowerCase()) {
        entry.value = value;
        return;
      }
    }
    entries.add(IniEntry(key, value));
  }
}

class IniEntry {
  IniEntry(this.key, this.value);

  final String key;
  String value;
}
