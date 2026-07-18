import 'package:flutter/widgets.dart';

/// 窄屏（compact）断点：手机竖屏、分屏等窄窗口走单栏/折叠布局。
const double kCompactBreakpoint = 720;

/// 中等断点：小平板 / 折叠屏展开，可用双栏但仍收敛部分侧栏宽度。
const double kMediumBreakpoint = 1040;

extension ResponsiveContext on BuildContext {
  /// 当前可用宽度是否属于窄屏（应折叠多栏为单栏）。
  bool get isCompact => MediaQuery.sizeOf(this).width < kCompactBreakpoint;

  /// 中等宽度（窄屏与宽屏之间）。
  bool get isMedium {
    final w = MediaQuery.sizeOf(this).width;
    return w >= kCompactBreakpoint && w < kMediumBreakpoint;
  }

  /// 宽屏（桌面/大平板），保持多栏布局。
  bool get isExpanded => MediaQuery.sizeOf(this).width >= kMediumBreakpoint;
}
