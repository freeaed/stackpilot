import 'app_preferences.dart';
import 'stack_catalog.dart';
import 'stack_layout.dart';

/// Stacks StackPilot looks for on a machine with no saved preference.
const defaultStackCandidates = [r'C:\laragon-wamp', r'C:\laragon'];

/// The stack to open on startup plus the folder to report when none was found.
class StartupStack {
  const StartupStack({required this.layout, required this.attemptedRoot});

  final StackLayout? layout;
  final String attemptedRoot;
}

/// Resolves the stack to open, in falling order of precedence:
///
/// 1. an explicit `--stack-root` argument or environment variable,
/// 2. the stack used last,
/// 3. the first stack inside the saved stacks folder,
/// 4. the well-known install locations.
StartupStack resolveStartupStack({
  String? requestedRoot,
  AppPreferences preferences = AppPreferences.empty,
  List<String> fallbackCandidates = defaultStackCandidates,
}) {
  if (requestedRoot != null && requestedRoot.trim().isNotEmpty) {
    final root = requestedRoot.trim();
    return StartupStack(layout: StackLayout.detect(root), attemptedRoot: root);
  }

  final activeStack = preferences.activeStack;
  if (activeStack != null) {
    final layout = StackLayout.detect(activeStack);
    if (layout != null) {
      return StartupStack(layout: layout, attemptedRoot: activeStack);
    }
  }

  final stacksFolder = preferences.stacksFolder;
  if (stacksFolder != null) {
    for (final root in StackCatalog.scan(stacksFolder)) {
      final layout = StackLayout.detect(root);
      if (layout != null) {
        return StartupStack(layout: layout, attemptedRoot: root);
      }
    }
  }

  for (final candidate in fallbackCandidates) {
    final layout = StackLayout.detect(candidate);
    if (layout != null) {
      return StartupStack(layout: layout, attemptedRoot: candidate);
    }
  }

  return StartupStack(
    layout: null,
    attemptedRoot: activeStack ?? stacksFolder ?? defaultStackCandidates.first,
  );
}
