import 'dart:io';

/// 读取 Windows 系统代理，并据此为应用内所有 HTTP 请求设置代理路由。
///
/// Dart 的 [HttpClient] 默认既不读取 Windows 注册表里的系统代理，
/// 也不会自动使用浏览器/Clash 等设置的代理，导致应用直连境外站点时
/// 可能因网络干扰握手失败（CERTIFICATE_VERIFY_FAILED）。
/// 这里在启动时探测系统代理，并通过 [HttpOverrides] 让请求与浏览器一致地走代理。
class SystemProxy {
  static const _key =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';

  /// 返回当前启用的系统代理（形如 `127.0.0.1:7897`）；未启用或非 Windows 返回 null。
  static Future<String?> detect() async {
    if (!Platform.isWindows) return null;
    final enabled = await _query('ProxyEnable');
    if (_asInt(enabled) != 1) return null;
    final server = await _query('ProxyServer');
    if (server == null || server.isEmpty) return null;
    return _pickHttps(server);
  }

  static int? _asInt(String? v) {
    if (v == null) return null;
    final s = v.trim();
    if (s.toLowerCase().startsWith('0x')) {
      return int.tryParse(s.substring(2), radix: 16);
    }
    return int.tryParse(s);
  }

  /// 通过 `reg query` 读取指定值，返回其字符串内容。
  static Future<String?> _query(String name) async {
    final r = await Process.run('reg', ['query', _key, '/v', name]);
    if (r.exitCode != 0) return null;
    for (final line in (r.stdout as String).split('\n')) {
      final t = line.trim();
      if (!t.startsWith(name)) continue;
      final parts = t.split(RegExp(r'\s{2,}|\t+'));
      if (parts.length >= 3) return parts.last.trim();
    }
    return null;
  }

  /// ProxyServer 可能是 `host:port`，也可能是 `http=h:p;https=h:p;socks=h:p`。
  static String? _pickHttps(String server) {
    if (!server.contains('=')) return server.trim();
    final map = <String, String>{};
    for (final pair in server.split(';')) {
      final i = pair.indexOf('=');
      if (i > 0) {
        map[pair.substring(0, i).trim().toLowerCase()] =
            pair.substring(i + 1).trim();
      }
    }
    return map['https'] ??
        map['http'] ??
        (map.values.isEmpty ? null : map.values.first);
  }
}

/// 让 [HttpClient] 把非回环地址的请求路由到指定代理。
class SystemProxyHttpOverrides extends HttpOverrides {
  SystemProxyHttpOverrides(this.proxy);

  /// 形如 `127.0.0.1:7897`。
  final String proxy;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (uri) {
      final host = uri.host;
      if (host == 'localhost' || host == '127.0.0.1' || host == '::1') {
        return 'DIRECT';
      }
      return 'PROXY $proxy';
    };
    return client;
  }
}
