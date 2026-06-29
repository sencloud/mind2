import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:path/path.dart' as p;
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/styles/github.dart';

// 常见语言的高亮 Mode（按需导入，未覆盖的扩展名走纯文本，仍可编辑）。
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/csharp.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/scala.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/powershell.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/lua.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/scss.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/markdown.dart';

/// 由扩展名推断高亮语言；返回单条 languages 映射（命中才高亮，否则空映射=纯文本）。
Map<String, CodeHighlightThemeMode> _languagesFor(String path) {
  final mode = switch (p.extension(path).toLowerCase()) {
    '.dart' => langDart,
    '.py' => langPython,
    '.js' || '.jsx' || '.mjs' || '.cjs' => langJavascript,
    '.ts' || '.tsx' => langTypescript,
    '.java' => langJava,
    '.kt' || '.kts' => langKotlin,
    '.go' => langGo,
    '.rs' => langRust,
    '.c' || '.h' => langC,
    '.cc' || '.cpp' || '.hpp' || '.cxx' => langCpp,
    '.cs' => langCsharp,
    '.rb' => langRuby,
    '.php' => langPhp,
    '.swift' => langSwift,
    '.scala' => langScala,
    '.sh' || '.bash' => langBash,
    '.ps1' => langPowershell,
    '.sql' => langSql,
    '.lua' => langLua,
    '.yaml' || '.yml' => langYaml,
    '.toml' || '.ini' => langIni,
    '.xml' || '.html' || '.vue' || '.svelte' => langXml,
    '.css' || '.less' => langCss,
    '.scss' => langScss,
    '.json' => langJson,
    '.md' || '.markdown' => langMarkdown,
    _ => null,
  };
  return mode == null ? const {} : {'lang': CodeHighlightThemeMode(mode: mode)};
}

/// 可编辑的代码/文本查看器：语法高亮 + 编辑 + 保存（Ctrl+S）。
/// 背景统一为白色，避免与外层混杂。
/// [markdownPreview] 为 true 时（.md 文件），额外提供「预览 / 编辑」两个 tab。
class EditableCodeView extends StatefulWidget {
  const EditableCodeView({
    super.key,
    required this.absPath,
    this.markdownPreview = false,
  });

  final String absPath;
  final bool markdownPreview;

  @override
  State<EditableCodeView> createState() => _EditableCodeViewState();
}

class _EditableCodeViewState extends State<EditableCodeView>
    with SingleTickerProviderStateMixin {
  final _controller = CodeLineEditingController();
  // 仅 markdown 需要「预览/编辑」两个 tab；用显式控制器以便切到预览时刷新渲染。
  TabController? _tab;
  bool _loaded = false;
  bool _dirty = false;
  bool _saving = false;
  String _error = '';
  String _saved = '';

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    if (widget.markdownPreview) {
      _tab = TabController(length: 2, vsync: this);
      // 切换 tab 完成时重建：从编辑器最新文本重新渲染预览。
      _tab!.addListener(() {
        if (!_tab!.indexIsChanging && mounted) setState(() {});
      });
    }
    _load();
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _tab?.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final text = await File(widget.absPath).readAsString();
      _saved = text;
      _controller.text = text;
      if (mounted) setState(() => _loaded = true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loaded = true;
          _error = '无法以文本打开该文件（可能为二进制）：$e';
        });
      }
    }
  }

  void _onChanged() {
    final dirty = _controller.text != _saved;
    if (dirty != _dirty) setState(() => _dirty = dirty);
  }

  Future<void> _save() async {
    if (_saving || !_dirty) return;
    setState(() => _saving = true);
    try {
      final text = _controller.text;
      await File(widget.absPath).writeAsString(text);
      _saved = text;
      if (mounted) setState(() => _dirty = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已保存'), duration: Duration(seconds: 1)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    if (_error.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error,
              style: const TextStyle(fontSize: 13, color: Color(0xFF9B9B9F))),
        ),
      );
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
      },
      child: widget.markdownPreview ? _buildWithPreview() : _buildEditorPane(),
    );
  }

  /// 普通文本/代码：工具条（保存）+ 编辑器。
  Widget _buildEditorPane() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(),
        const Divider(height: 1),
        Expanded(child: _editor()),
      ],
    );
  }

  /// Markdown：工具条 + 「预览 / 编辑」tab。
  /// 预览读取编辑器当前文本；切到预览 tab 时会重建以反映最新编辑。
  Widget _buildWithPreview() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(
          leading: TabBar(
            controller: _tab,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelColor: const Color(0xFF0D9488),
            unselectedLabelColor: const Color(0xFF8A8A92),
            indicatorColor: const Color(0xFF0D9488),
            labelStyle:
                const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
            tabs: const [Tab(height: 34, text: '预览'), Tab(height: 34, text: '编辑')],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: TabBarView(
            controller: _tab,
            children: [
              Markdown(
                data: _controller.text,
                padding: const EdgeInsets.all(22),
                styleSheet: MarkdownStyleSheet(
                  p: const TextStyle(fontSize: 14, height: 1.7),
                  h1: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  h2: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  h3: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  code: const TextStyle(
                      fontSize: 12.5,
                      fontFamily: 'Consolas',
                      backgroundColor: Color(0xFFEFF1F4)),
                  a: const TextStyle(color: Color(0xFF0D9488)),
                ),
              ),
              _editor(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _toolbar({Widget? leading}) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      color: Colors.white,
      child: Row(
        children: [
          if (leading != null) Expanded(child: leading) else const Spacer(),
          if (_dirty)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Text('● 未保存',
                  style: TextStyle(fontSize: 11.5, color: Color(0xFFD9534F))),
            ),
          TextButton.icon(
            onPressed: (_dirty && !_saving) ? _save : null,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            icon: const Icon(Icons.save_outlined, size: 15),
            label: const Text('保存', style: TextStyle(fontSize: 12.5)),
          ),
        ],
      ),
    );
  }

  Widget _editor() {
    return CodeEditor(
      controller: _controller,
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      wordWrap: false,
      style: CodeEditorStyle(
        fontSize: 12.5,
        fontFamily: 'Consolas',
        backgroundColor: Colors.white,
        codeTheme: CodeHighlightTheme(
          languages: _languagesFor(widget.absPath),
          theme: githubTheme,
        ),
      ),
      indicatorBuilder:
          (context, editingController, chunkController, notifier) {
        return Row(
          children: [
            DefaultCodeLineNumber(
                controller: editingController, notifier: notifier),
            DefaultCodeChunkIndicator(
                width: 20, controller: chunkController, notifier: notifier),
          ],
        );
      },
    );
  }
}
