import 'app_preferences.dart';
import 'stack_bootstrap.dart';
import 'stack_catalog.dart';
import 'stack_layout.dart';

/// Well-known Laragon install locations.
///
/// StackPilot never opens these on its own: a machine that already has Laragon
/// must still start with StackPilot's own onboarding. The folders are only
/// offered as an optional "import an existing stack" card.
const legacyStackCandidates = [r'C:\laragon-wamp', r'C:\laragon'];

/// Stacks that already exist in the well-known Laragon folders.
///
/// Used by the onboarding screen so a user can import one explicitly instead
/// of StackPilot guessing.
List<String> detectLegacyStacks({
  List<String> candidates = legacyStackCandidates,
}) {
  final found = <String>[];
  for (final candidate in candidates) {
    final layout = StackLayout.detect(candidate);
    if (layout != null && !found.contains(layout.root)) {
      found.add(layout.root);
    }
  }
  return found;
}

/// The stack to open on startup plus the folder to report when none was found.
class StartupStack {
  const StartupStack({
    required this.layout,
    required this.attemptedRoot,
    this.importable = const [],
  });

  final StackLayout? layout;
  final String attemptedRoot;

  /// Existing Laragon stacks the onboarding screen can offer to open.
  final List<String> importable;

  /// True when the first-run/recovery screen has to be shown.
  bool get needsOnboarding => layout == null;
}

/// Resolves the stack to open, in falling order of precedence:
///
/// 1. an explicit `--stack-root` argument or environment variable,
/// 2. the stack that was used last,
/// 3. the first stack inside the saved stacks folder,
/// 4. the first stack inside StackPilot's own stacks folder,
/// 5. **onboarding** — Laragon folders are never opened automatically.
///
/// Legacy Laragon installs are reported through [StartupStack.importable] so
/// the onboarding screen can offer them as an optional import.
StartupStack resolveStartupStack({
  String? requestedRoot,
  AppPreferences preferences = AppPreferences.empty,
  String? defaultStacksFolder,
  List<String> legacyCandidates = legacyStackCandidates,
}) {
  final importable = detectLegacyStacks(candidates: legacyCandidates);
  final ownFolder = defaultStacksFolder ?? StackBootstrap.defaultStacksFolder();

  StartupStack found(StackLayout layout, String root) => StartupStack(
    layout: layout,
    attemptedRoot: root,
    importable: importable,
  );

  if (requestedRoot != null && requestedRoot.trim().isNotEmpty) {
    final root = requestedRoot.trim();
    final layout = StackLayout.detect(root);
    return layout == null
        ? StartupStack(
            layout: null,
            attemptedRoot: root,
            importable: importable,
          )
        : found(layout, root);
  }

  final activeStack = preferences.activeStack;
  if (activeStack != null) {
    final layout = StackLayout.detect(activeStack);
    if (layout != null) {
      return found(layout, activeStack);
    }
  }

  final folders = <String>{
    if (preferences.stacksFolder != null) preferences.stacksFolder!,
    ownFolder,
  };
  for (final folder in folders) {
    for (final root in StackCatalog.scan(folder)) {
      final layout = StackLayout.detect(root);
      if (layout != null) {
        return found(layout, root);
      }
    }
  }

  return StartupStack(
    layout: null,
    attemptedRoot: activeStack ?? preferences.stacksFolder ?? ownFolder,
    importable: importable,
  );
}
