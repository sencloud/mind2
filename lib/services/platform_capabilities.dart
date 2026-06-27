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
}
