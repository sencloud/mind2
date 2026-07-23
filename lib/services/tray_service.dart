import 'dart:io';

import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'self_learning_service.dart';

/// 系统托盘 + 关闭最小化 + 开机自启的统一封装（仅 Windows 桌面）。
///
/// - 关闭窗口时不退出进程，改为隐藏到托盘，让 [SelfLearningService] 的定时循环
///   在后台继续「始终在线自学习」。
/// - 托盘右键菜单可显示主窗口、启停自学习、切换开机自启动、真正退出。
class TrayService with TrayListener, WindowListener {
  TrayService(this.selfLearning);

  final SelfLearningService selfLearning;

  bool _autoStart = false;
  bool _ready = false;

  Future<void> init() async {
    if (!Platform.isWindows) return;

    // 开机自启：注册表 Run 项指向当前可执行文件。
    final info = await PackageInfo.fromPlatform();
    launchAtStartup.setup(
      appName: info.appName.isEmpty ? 'Mind' : info.appName,
      appPath: Platform.resolvedExecutable,
    );
    _autoStart = await launchAtStartup.isEnabled();

    trayManager.addListener(this);
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);

    await trayManager.setIcon('assets/icon/tray_icon.ico');
    await trayManager.setToolTip('第二大脑');
    await _rebuildMenu();

    selfLearning.addListener(_onLearningChanged);
    _ready = true;
  }

  void _onLearningChanged() {
    if (!_ready) return;
    _rebuildMenu();
    trayManager.setToolTip(_tooltip());
  }

  String _tooltip() {
    if (!selfLearning.config.enabled) return '第二大脑（自学习：关闭）';
    if (selfLearning.running) {
      final t = selfLearning.currentTopic;
      return '第二大脑（学习中${t.isEmpty ? '' : '：$t'}）';
    }
    return '第二大脑（自学习：待命）';
  }

  String _statusLabel() {
    if (!selfLearning.config.enabled) return '状态：已停止';
    if (selfLearning.running) {
      final t = selfLearning.currentTopic;
      return '状态：学习中${t.isEmpty ? '' : '（$t）'}';
    }
    return '状态：待命，已完成 ${selfLearning.cyclesCompleted} 轮';
  }

  Future<void> _rebuildMenu() async {
    final menu = Menu(
      items: [
        MenuItem(key: 'show', label: '显示主窗口'),
        MenuItem.separator(),
        MenuItem.checkbox(
          key: 'toggle_learning',
          label: '知识库自学习',
          checked: selfLearning.config.enabled,
        ),
        MenuItem(key: 'status', label: _statusLabel(), disabled: true),
        MenuItem.separator(),
        MenuItem.checkbox(
          key: 'autostart',
          label: '开机自启动',
          checked: _autoStart,
        ),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: '退出'),
      ],
    );
    await trayManager.setContextMenu(menu);
  }

  // --- TrayListener ---

  @override
  void onTrayIconMouseDown() {
    _showWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show':
        await _showWindow();
        break;
      case 'toggle_learning':
        if (selfLearning.config.enabled) {
          await selfLearning.stop();
        } else {
          await selfLearning.start();
        }
        await _rebuildMenu();
        break;
      case 'autostart':
        _autoStart = !_autoStart;
        if (_autoStart) {
          await launchAtStartup.enable();
        } else {
          await launchAtStartup.disable();
        }
        await _rebuildMenu();
        break;
      case 'exit':
        await _exit();
        break;
    }
  }

  // --- WindowListener ---

  @override
  void onWindowClose() async {
    // 已 setPreventClose(true)：关闭时隐藏到托盘而非退出，后台自学习继续。
    if (await windowManager.isPreventClose()) {
      await windowManager.hide();
    }
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _exit() async {
    await windowManager.setPreventClose(false);
    await trayManager.destroy();
    await windowManager.destroy();
  }

  void dispose() {
    if (!_ready) return;
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    selfLearning.removeListener(_onLearningChanged);
  }
}
