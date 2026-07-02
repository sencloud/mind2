import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// 与文档页一致的配色。
const _accent = Color(0xFF0D9488);
const _muted = Color(0xFF9B9B9F);
const _line = Color(0xFFD8D8DC);
const _headBg = Color(0xFFF3F4F6);

/// 类 Excel 的工作表表格预览：
/// 1) 单元格文本自动换行（同一行的单元格等高）；
/// 2) 表头右侧可拖动缩放列宽；
/// 3) 支持像 Excel 一样按下拖动多选单元格，Ctrl/Cmd+C 复制（TSV）。
class SheetGrid extends StatefulWidget {
  const SheetGrid({super.key, required this.rows});

  /// 表格数据，首行作表头。每行长度可以不同（会按最宽行补空）。
  final List<List<String>> rows;

  @override
  State<SheetGrid> createState() => _SheetGridState();
}

class _SheetGridState extends State<SheetGrid> {
  final _vertical = ScrollController();
  final _horizontal = ScrollController();
  final _focus = FocusNode();

  List<double> _widths = [];
  int _cols = 0;

  // 选区：锚点(按下处) + 焦点(拖到处)，构成一个矩形。
  int? _anchorRow, _anchorCol, _focusRow, _focusCol;
  bool _selecting = false;

  @override
  void initState() {
    super.initState();
    _initWidths();
  }

  @override
  void didUpdateWidget(covariant SheetGrid old) {
    super.didUpdateWidget(old);
    // 数据变了（重新生成/切换工作表）重置列宽与选区。
    if (!identical(widget.rows, old.rows)) _initWidths();
  }

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 初始化列数、列宽（按表头字数估算，限制在 [90,260]）与清空选区。
  void _initWidths() {
    _cols = widget.rows.fold(1, (m, r) => r.length > m ? r.length : m);
    final head = widget.rows.isEmpty ? const <String>[] : widget.rows.first;
    _widths = List.generate(_cols, (c) {
      final text = c < head.length ? head[c] : '';
      final est = 70.0 + text.length * 14.0;
      return est.clamp(90.0, 260.0);
    });
    _anchorRow = _anchorCol = _focusRow = _focusCol = null;
    _selecting = false;
  }

  String _cell(int r, int c) =>
      c < widget.rows[r].length ? widget.rows[r][c] : '';

  bool _inSelection(int r, int c) {
    if (_anchorRow == null || _focusRow == null) return false;
    final r0 = _anchorRow! < _focusRow! ? _anchorRow! : _focusRow!;
    final r1 = _anchorRow! < _focusRow! ? _focusRow! : _anchorRow!;
    final c0 = _anchorCol! < _focusCol! ? _anchorCol! : _focusCol!;
    final c1 = _anchorCol! < _focusCol! ? _focusCol! : _anchorCol!;
    return r >= r0 && r <= r1 && c >= c0 && c <= c1;
  }

  /// 把当前选区按 TSV（制表符分隔、换行分行）写入剪贴板，方便直接粘进 Excel。
  void _copySelection() {
    if (_anchorRow == null || _focusRow == null) return;
    final r0 = _anchorRow! < _focusRow! ? _anchorRow! : _focusRow!;
    final r1 = _anchorRow! < _focusRow! ? _focusRow! : _anchorRow!;
    final c0 = _anchorCol! < _focusCol! ? _anchorCol! : _focusCol!;
    final c1 = _anchorCol! < _focusCol! ? _focusCol! : _anchorCol!;
    final buf = StringBuffer();
    for (var r = r0; r <= r1; r++) {
      buf.write([for (var c = c0; c <= c1; c++) _cell(r, c)].join('\t'));
      if (r < r1) buf.write('\n');
    }
    Clipboard.setData(ClipboardData(text: buf.toString()));
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.rows;
    if (rows.isEmpty) {
      return const Center(
        child: Text('（本工作表暂无内容）', style: TextStyle(fontSize: 13, color: _muted)),
      );
    }
    return Focus(
      focusNode: _focus,
      onKeyEvent: (node, e) {
        final ctrl = HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed;
        if (e is KeyDownEvent &&
            ctrl &&
            e.logicalKey == LogicalKeyboardKey.keyC) {
          _copySelection();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Scrollbar(
        controller: _vertical,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _vertical,
          scrollDirection: Axis.vertical,
          padding: const EdgeInsets.all(16),
          child: Scrollbar(
            controller: _horizontal,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _horizontal,
              scrollDirection: Axis.horizontal,
              child: Listener(
                onPointerUp: (_) {
                  if (_selecting) setState(() => _selecting = false);
                },
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var r = 0; r < rows.length; r++) _rowWidget(r),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _rowWidget(int r) {
    // IntrinsicHeight + stretch：某个单元格换行变高时，整行等高对齐。
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (var c = 0; c < _cols; c++) _cellWidget(r, c)],
      ),
    );
  }

  Widget _cellWidget(int r, int c) {
    final isHeader = r == 0;
    final selected = !isHeader && _inSelection(r, c);
    final body = MouseRegion(
      onEnter: (e) {
        if (!_selecting) return;
        // 鼠标已松开却移回来时停止扩选（拖到网格外松开的兜底判断）。
        if (e.buttons == 0) {
          setState(() => _selecting = false);
          return;
        }
        setState(() {
          _focusRow = r;
          _focusCol = c;
        });
      },
      child: Listener(
        onPointerDown: (_) {
          _focus.requestFocus();
          setState(() {
            _anchorRow = r;
            _anchorCol = c;
            _focusRow = r;
            _focusCol = c;
            _selecting = true;
          });
        },
        child: Container(
          width: _widths[c],
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: isHeader
                ? _headBg
                : (selected ? _accent.withValues(alpha: 0.16) : Colors.white),
            border: Border(
              right: const BorderSide(color: _line),
              bottom: const BorderSide(color: _line),
              left: c == 0 ? const BorderSide(color: _line) : BorderSide.none,
              top: r == 0 ? const BorderSide(color: _line) : BorderSide.none,
            ),
          ),
          child: Text(
            _cell(r, c),
            softWrap: true,
            style: TextStyle(
              fontSize: isHeader ? 13 : 12.5,
              fontWeight: isHeader ? FontWeight.w700 : FontWeight.w400,
              color: Colors.black,
            ),
          ),
        ),
      ),
    );
    if (!isHeader) return body;
    // 表头：右侧叠一个可横向拖动的手柄，用来缩放列宽。
    return Stack(
      children: [
        body,
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeColumn,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragUpdate: (d) {
                setState(() {
                  _widths[c] = (_widths[c] + d.delta.dx).clamp(60.0, 600.0);
                });
              },
              child: const SizedBox(width: 8),
            ),
          ),
        ),
      ],
    );
  }
}
