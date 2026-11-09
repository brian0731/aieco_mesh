import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Both apps use the same directory; codes are assigned by its administrator.
class NetworkPairingClient {
  NetworkPairingClient(this.directoryUrl);
  final String directoryUrl;
  static final codePattern = RegExp(r'^[0-9]{6}$');

  static Uri validateDirectoryUrl(String value) {
    final base = Uri.tryParse(value.trim());
    if (base == null ||
        !{'http', 'https'}.contains(base.scheme) ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment) {
      throw const FormatException('請設定有效的連接碼服務地址。');
    }
    return base.replace(path: base.path.replaceFirst(RegExp(r'/+$'), ''));
  }

  bool get configured {
    try {
      validateDirectoryUrl(directoryUrl);
      return true;
    } on FormatException {
      return false;
    }
  }

  Future<String> codeFor(String relayUrl) async {
    final result = await _get('', {'relay': relayUrl});
    final code = result['code'];
    if (code is! String || !codePattern.hasMatch(code)) {
      throw const FormatException('連接碼服務回應有誤，請稍後再試。');
    }
    return code;
  }

  Future<String> resolve(String code) async {
    if (!codePattern.hasMatch(code)) {
      throw const FormatException('請輸入 6 位數字連接碼。');
    }
    final result = await _get('/$code', {});
    final relay = result['relay'];
    final uri = relay is String ? Uri.tryParse(relay) : null;
    if (uri == null ||
        !{'ws', 'wss'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const FormatException('連接碼服務回應有誤，請稍後再試。');
    }
    return relay as String;
  }

  Future<Map<String, dynamic>> _get(
    String suffix,
    Map<String, String> query,
  ) async {
    final base = validateDirectoryUrl(directoryUrl);
    final uri = base.replace(
      path: '${base.path.replaceFirst(RegExp(r'/+$'), '')}/networks$suffix',
      queryParameters: query.isEmpty ? null : query,
    );
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      return await (() async {
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        final response = await request.close();
        if (response.statusCode == HttpStatus.notFound) {
          throw const FormatException('找不到此光網連接碼，請確認後再試。');
        }
        if (response.statusCode != HttpStatus.ok) {
          throw const FormatException('連接碼服務暫時無法使用，請稍後再試。');
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
          if (bytes.length > 8192) {
            throw const FormatException('連接碼服務回應有誤，請稍後再試。');
          }
        }
        final Object? decoded;
        try {
          decoded = jsonDecode(utf8.decode(bytes));
        } on FormatException {
          throw const FormatException('連接碼服務回應有誤，請稍後再試。');
        }
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('連接碼服務回應有誤，請稍後再試。');
        }
        return decoded;
      })().timeout(const Duration(seconds: 10));
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('無法連接連接碼服務，請檢查網絡後再試。');
    } finally {
      client.close(force: true);
    }
  }
}
