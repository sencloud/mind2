import 'dart:io';

class PlatformCapabilities {
  const PlatformCapabilities._();

  static bool get isAndroid => Platform.isAndroid;
  static bool get isIos => Platform.isIOS;
  static bool get isMobile => Platform.isAndroid || Platform.isIOS;
  static bool get isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  static bool get supportsDesktopWindow => isDesktop;
  static bool get supportsPlaywright => isDesktop;
  static bool get supportsZotero => isDesktop;
  static bool get supportsProjectDev => isDesktop;
  static bool get supportsExperiment => isDesktop;

  /// PDF 导出（依赖 xelatex / pandoc / 无头 Chrome，均为桌面外部工具链）。
  static bool get supportsPdfExport => isDesktop;

  /// 本地外部工具链（LaTeX、pandoc、python 等子进程）。
  static bool get supportsLocalTooling => isDesktop;

  /// 论文/文档图表生成（依赖 python + matplotlib）。
  static bool get supportsFigures => isDesktop;

  /// 代码检索/工程解读（依赖捆绑 ripgrep，安卓无 rg 二进制）。
  static bool get supportsCodeSearch => isDesktop;

  /// 无头浏览器渲染（HTML→PDF、Mermaid 截图，依赖本机 Chrome/Edge）。
  static bool get supportsHeadlessBrowser => isDesktop;
}
