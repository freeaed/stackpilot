import 'dart:io';

import '../core/paths.dart';

/// Native Windows pickers used by the install and settings dialogs.
///
/// These run in a short-lived PowerShell process so the app does not need a
/// platform plugin just to browse for a folder or a ZIP file. The dialog is
/// owned by StackPilot's own window, so Windows cannot open it behind the app.
Future<String?> pickFolder(String title) =>
    _showDialog('FolderBrowserDialog', title);

Future<String?> pickZipFile(String title) =>
    _showDialog('OpenFileDialog', title);

Future<String?> _showDialog(String dialogType, String title) async {
  final script = StringBuffer()
    ..writeln('Add-Type -AssemblyName System.Windows.Forms')
    ..writeln(
      r'Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing '
      r'-TypeDefinition @"',
    )
    ..writeln('using System;')
    ..writeln('using System.Runtime.InteropServices;')
    ..writeln(
      'public class StackPilotWindow : System.Windows.Forms.IWin32Window {',
    )
    ..writeln('  public StackPilotWindow(IntPtr handle) { Handle = handle; }')
    ..writeln('  public IntPtr Handle { get; private set; }')
    ..writeln('}')
    ..writeln('public static class StackPilotNative {')
    ..writeln('  [DllImport("user32.dll")]')
    ..writeln('  public static extern IntPtr GetForegroundWindow();')
    ..writeln('  [DllImport("user32.dll", CharSet = CharSet.Unicode)]')
    ..writeln(
      '  public static extern IntPtr FindWindow('
      'string className, string windowName);',
    )
    ..writeln('}')
    ..writeln('"@')
    ..writeln('\$dialog = New-Object System.Windows.Forms.$dialogType')
    ..writeln("\$dialog.Title = '${_psEscape(title)}'")
    ..writeln(r'$dialog.RestoreDirectory = $true');
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
      r'$handle = [StackPilotNative]::FindWindow('
      r"'FLUTTER_RUNNER_WIN32_WINDOW', $null)",
    )
    ..writeln(r'if ($handle -eq [IntPtr]::Zero) { ')
    ..writeln(r'  $handle = [StackPilotNative]::GetForegroundWindow() }')
    ..writeln(r'$owner = New-Object StackPilotWindow ($handle)')
    ..writeln(
      r'if ($owner.Handle -ne [IntPtr]::Zero) { '
      r'$result = $dialog.ShowDialog($owner) } else { '
      r'$result = $dialog.ShowDialog() }',
    )
    ..writeln(
      r'if ($result -eq [System.Windows.Forms.DialogResult]::OK) {',
    );
  if (dialogType == 'OpenFileDialog') {
    script.writeln(r'  [Console]::Out.Write($dialog.FileName)');
  } else {
    script.writeln(r'  [Console]::Out.Write($dialog.SelectedPath)');
  }
  script.writeln('}');

  try {
    final result = await Process.run('powershell.exe', [
      '-STA',
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      script.toString(),
    ]);
    if (result.exitCode != 0) {
      return null;
    }
    final path = result.stdout.toString().trim();
    return path.isEmpty ? null : normalizeWindowsPath(path);
  } on ProcessException {
    return null;
  }
}

String _psEscape(String value) => value.replaceAll("'", "''");
