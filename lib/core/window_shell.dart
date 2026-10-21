import 'dart:async';
import 'dart:ui' show Size;

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

const _trayIconAsset = 'assets/branding/tray_icon.png';

/// Keeps StackPilot running in the notification area.
///
/// Minimizing, or closing the window, hides it instead of ending the process so
/// started services keep running. The tray menu can show the window again or
/// exit StackPilot.
///
/// Only [main] constructs this class, which keeps the window and tray plugins
/// out of widget tests.
class WindowShell with WindowListener {
  WindowShell({
    this.minimizeToTray = true,
    WindowManager? windowManager,
  }) : _window = windowManager ?? WindowManager.instance;

  /// Hide the window instead of minimizing or closing it.
  final bool minimizeToTray;

  final WindowManager _window;

  TrayIcon? _trayIcon;
  Menu? _menu;
  final List<MenuItem> _menuItems = <MenuItem>[];
  ListenerId? _trayListenerId;
  bool _quitting = false;

  /// Prepares the window and installs the tray icon.
  ///
  /// Safe to call before [runApp]; the window is shown once Flutter's first
  /// frame is ready. If the tray cannot be created the window keeps its normal
  /// minimize and close behaviour so it can never become unreachable.
  Future<void> start() async {
    await _window.ensureInitialized();
    _window.addListener(this);

    final trayReady = await _createTray();
    if (trayReady && minimizeToTray) {
      await _window.setPreventClose(true);
    }

    unawaited(
      _window.waitUntilReadyToShow(
        const WindowOptions(
          size: Size(1280, 720),
          minimumSize: Size(1024, 640),
          center: true,
        ),
        () async {
          await _window.show();
          await _window.focus();
        },
      ),
    );
  }

  @override
  void onWindowMinimize() {
    if (minimizeToTray) {
      unawaited(_hideToTray());
    }
  }

  @override
  void onWindowClose() {
    if (minimizeToTray) {
      unawaited(_hideToTray());
    }
  }

  Future<bool> _createTray() async {
    try {
      final trayIcon = TrayIcon.create();
      if (trayIcon == null) {
        return false;
      }
      _trayIcon = trayIcon;

      final icon = ImageAsset.fromAsset(_trayIconAsset);
      if (icon == null) {
        throw StateError('Tray icon not found: $_trayIconAsset');
      }
      trayIcon.icon = icon;
      trayIcon.setTooltip('StackPilot');
      trayIcon.setContextMenuTrigger(ContextMenuTrigger.rightClicked);
      _menu = _buildMenu();
      trayIcon.setContextMenu(_menu);
      _trayListenerId = trayIcon.addListener(_onTrayEvent);
      trayIcon.setVisible(true);
      return true;
    } on Object {
      await _disposeTray();
      return false;
    }
  }

  Menu _buildMenu() {
    final menu = Menu.create();
    final show = MenuItem.createWithLabelAndType(
      'Show StackPilot',
      MenuItemType.normal,
    );
    final exit = MenuItem.createWithLabelAndType(
      'Exit StackPilot',
      MenuItemType.normal,
    );
    if (menu == null || show == null || exit == null) {
      throw StateError('Unable to create the tray menu');
    }

    show.addListener((event) {
      if (event is MenuItemClickedEvent) {
        unawaited(showWindow());
      }
    });
    exit.addListener((event) {
      if (event is MenuItemClickedEvent) {
        unawaited(exitApp());
      }
    });

    _menuItems.addAll([show, exit]);
    menu
      ..addItem(show)
      ..addSeparator()
      ..addItem(exit);
    return menu;
  }

  void _onTrayEvent(TrayIconEvent event) {
    if (event is TrayIconClickedEvent || event is TrayIconDoubleClickedEvent) {
      unawaited(showWindow());
    }
  }

  Future<void> _hideToTray() async {
    if (_trayIcon == null || _quitting) {
      return;
    }
    await _window.hide();
  }

  /// Brings the window back from the tray.
  Future<void> showWindow() async {
    if (_quitting) {
      return;
    }
    await _window.setSkipTaskbar(false);
    if (await _window.isMinimized()) {
      await _window.restore();
    }
    await _window.show();
    await _window.focus();
  }

  /// Closes StackPilot. Services owned by StackPilot stop with the process.
  Future<void> exitApp() async {
    if (_quitting) {
      return;
    }
    _quitting = true;
    await _window.setPreventClose(false);
    await _disposeTray();
    await _window.destroy();
  }

  Future<void> _disposeTray() async {
    final trayIcon = _trayIcon;
    _trayIcon = null;
    final listenerId = _trayListenerId;
    _trayListenerId = null;
    if (trayIcon != null) {
      trayIcon.setVisible(false);
      if (listenerId != null) {
        trayIcon.removeListener(listenerId);
      }
      trayIcon.setContextMenu(null);
      trayIcon.dispose();
    }

    _menu?.dispose();
    _menu = null;
    for (final item in _menuItems) {
      item.dispose();
    }
    _menuItems.clear();
    _window.removeListener(this);
  }
}
