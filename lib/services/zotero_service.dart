import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'settings_service.dart';
import 'source_adapters.dart';

/// 与本地运行的 Zotero 桌面端通信：
/// - 读：本地 API `http://127.0.0.1:<port>/api/users/0/...`（无需 Key）；
/// - 写：连接器 `/connector/saveItems` + `/connector/saveAttachment` 两步协议。
///
/// 需在 Zotero「设置 → 高级」勾选「允许其他应用与 Zotero 通信」。
class ZoteroService {
  ZoteroService(this.settings);

  final SettingsService settings;
  final _rng = Random();

  bool get enabled => settings.zoteroEnabled;
  int get _port => settings.zoteroPort;
  String get _apiBase => 'http://127.0.0.1:$_port/api/users/0';
  String get _connBase => 'http://127.0.0.1:$_port/connector';

  /// 探测 Zotero 是否在运行且开放本地通信。
  Future<bool> ping() async {
    try {
      final r = await http
          .get(Uri.parse('$_connBase/ping'))
          .timeout(const Duration(seconds: 4));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 检索用户已有文库，转成统一的检索结果（ext 为空表示已在库、不再下载）。
  Future<List<SourceResult>> search(String query, {int limit = 8}) async {
    try {
      final uri = Uri.parse('$_apiBase/items/top'
          '?q=${Uri.encodeQueryComponent(query)}'
          '&qmode=everything&limit=$limit&format=json');
      final r = await http.get(uri).timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) return [];
      final list = jsonDecode(utf8.decode(r.bodyBytes));
      if (list is! List) return [];
      final out = <SourceResult>[];
      for (final e in list) {
        if (e is! Map) continue;
        final d = e['data'];
        if (d is! Map) continue;
        final title = (d['title'] as String? ?? '').trim();
        if (title.isEmpty) continue;
        final authors = ((d['creators'] as List?) ?? [])
            .map((c) => c is Map
                ? (c['lastName'] ?? c['name'] ?? '').toString().trim()
                : '')
            .where((s) => s.isNotEmpty)
            .take(3)
            .join(', ');
        final date = d['date'] as String? ?? '';
        final year = RegExp(r'\d{4}').firstMatch(date)?.group(0) ?? '';
        final url = (d['url'] as String? ?? '').trim();
        final doi = (d['DOI'] as String? ?? '').trim();
        out.add(SourceResult(
          title: title,
          url: url.isNotEmpty
              ? url
              : (doi.isNotEmpty ? 'https://doi.org/$doi' : 'zotero:${e['key']}'),
          source: SourceId.zotero,
          year: year,
          authors: authors,
          ext: '', // 已在库
          summary: (d['abstractNote'] as String? ?? '').trim(),
          landingUrl: url.isNotEmpty
              ? url
              : (doi.isNotEmpty ? 'https://doi.org/$doi' : null),
        ));
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  /// 写入一个条目，可选携带 PDF 附件。返回是否成功创建条目。
  Future<bool> saveItem({
    required String itemType,
    required String title,
    String authors = '',
    String year = '',
    String doi = '',
    String abstract = '',
    String url = '',
    List<String> tags = const [],
    Uint8List? pdfBytes,
    String? pdfFileName,
  }) async {
    try {
      final sessionId = _randomId();
      final itemId = _randomId();
      final item = <String, dynamic>{
        'id': itemId,
        'itemType': itemType,
        'title': title,
        'creators': _creators(authors),
        'tags': [for (final t in tags) if (t.trim().isNotEmpty) {'tag': t.trim()}],
        if (year.isNotEmpty) 'date': year,
        if (doi.isNotEmpty) 'DOI': doi,
        if (abstract.isNotEmpty) 'abstractNote': abstract,
        if (url.isNotEmpty) 'url': url,
      };
      final r1 = await http
          .post(
            Uri.parse('$_connBase/saveItems'),
            headers: {
              'Content-Type': 'application/json',
              'X-Zotero-Connector-API-Version': '3',
            },
            body: jsonEncode({
              'items': [item],
              'uri': url.isNotEmpty ? url : 'http://localhost',
              'sessionID': sessionId,
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (r1.statusCode != 200 && r1.statusCode != 201) return false;

      if (pdfBytes != null && pdfBytes.isNotEmpty) {
        try {
          await http
              .post(
                Uri.parse('$_connBase/saveAttachment'),
                headers: {
                  'Content-Type': 'application/pdf',
                  'X-Metadata': jsonEncode({
                    'sessionID': sessionId,
                    'parentItemID': itemId,
                    'title': pdfFileName ?? '$title.pdf',
                    'url': url,
                  }),
                },
                body: pdfBytes,
              )
              .timeout(const Duration(seconds: 90));
        } catch (_) {
          // 附件上传失败不影响条目已建。
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  List<Map<String, String>> _creators(String authors) {
    final out = <Map<String, String>>[];
    for (final a in authors.split(RegExp(r'[,;]'))) {
      final name = a.trim();
      if (name.isEmpty) continue;
      final parts = name.split(' ');
      if (parts.length >= 2) {
        out.add({
          'creatorType': 'author',
          'firstName': parts.sublist(0, parts.length - 1).join(' '),
          'lastName': parts.last,
        });
      } else {
        out.add({'creatorType': 'author', 'lastName': name});
      }
    }
    return out;
  }

  String _randomId() {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(16, (_) => chars[_rng.nextInt(chars.length)]).join();
  }
}
