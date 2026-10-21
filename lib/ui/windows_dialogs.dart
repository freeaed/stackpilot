import 'dart:io';

/// Native Windows pickers used by the install and settings dialogs.
///
/// These run in a short-lived PowerShell process so the app does not need a
/// platform plugin just to browse for a folder or a ZIP file.
Future<String?> pickFolder(String title) =>
    _showDialog('FolderBrowserDialog', title);

Future<String?> pickZipFile(String title) =>
    _showDialog('OpenFileDialog', title);

Future<String?> _showDialog(String dialogType, String title) async {
  final script = StringBuffer()
    ..writeln('Add-Type -AssemblyName System.Windows.Forms')
    ..writeln('\$dialog = New-Object System.Windows.Forms.$dialogType')
    ..writeln("\$dialog.Description = '${_psEscape(title)}'");
  if (dialogType == 'OpenFileDialog') {
    script
      ..writeln(
        r"$dialog.Filter = 'Zip archives (*.zip)|*.zip|All files (*.*)|*.*'",
      )
      ..writeln(r'$dialog.CheckFileExists = $true');
  } else {
    script.writeln(r'$dialog.ShowNewFolderButton = $true');
  }
  script
    ..writeln(
      r'if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {',
    )
    ..writeln(r'  [Console]::Out.Write($dialog.SelectedPath)')
    ..writeln('}');

  try {
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      script.toString(),
    ]);
    if (result.exitCode != 0) {
      return null;
    }
    final path = result.stdout.toString().trim();
    return path.isEmpty ? null : path;
  } on ProcessException {
    return null;
  }
}

String _psEscape(String value) => value.replaceAll("'", "''");
