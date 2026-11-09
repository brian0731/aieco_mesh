import 'dart:convert';
import 'dart:io';

/// Read-only registry: no public registration or overwriting another network.
class NetworkDirectoryServer {
  NetworkDirectoryServer(Map<String, String> networks) {
    for (final entry in networks.entries) {
      if (!RegExp(r'^[0-9]{6}$').hasMatch(entry.key)) {
        throw FormatException(
          'Network code must have six digits: ${entry.key}',
        );
      }
      final relay = _normalize(entry.value);
      if (_codes.containsKey(relay)) {
        throw const FormatException('Each relay must have exactly one code.');
      }
      _networks[entry.key] = relay;
      _codes[relay] = entry.key;
    }
  }
  final Map<String, String> _networks = {};
  final Map<String, String> _codes = {};
  HttpServer? _server;
  int get port => _server!.port;

  static String _normalize(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !{'ws', 'wss'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const FormatException('Invalid relay URL.');
    }
    return uri.replace(path: uri.path.isEmpty ? '/' : uri.path).toString();
  }

  Future<void> start({InternetAddress? address, int port = 47891}) async {
    _server = await HttpServer.bind(
      address ?? InternetAddress.loopbackIPv4,
      port,
    );
    _server!.listen((request) async {
      final response = request.response;
      response.headers.contentType = ContentType.json;
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      var status = HttpStatus.notFound;
      Map<String, Object?> body = {'error': 'not_found'};
      if (request.method != 'GET') {
        status = HttpStatus.methodNotAllowed;
        response.headers.set(HttpHeaders.allowHeader, 'GET');
        body = {'error': 'method_not_allowed'};
      } else if (request.uri.path == '/networks') {
        try {
          final code =
              _codes[_normalize(request.uri.queryParameters['relay'] ?? '')];
          if (code != null) {
            status = HttpStatus.ok;
            body = {'code': code};
          }
        } on FormatException {
          status = HttpStatus.badRequest;
          body = {'error': 'invalid_relay'};
        }
      } else if (RegExp(r'^/networks/[0-9]{6}$').hasMatch(request.uri.path)) {
        final code = request.uri.pathSegments.last;
        final relay = _networks[code];
        if (relay != null) {
          status = HttpStatus.ok;
          body = {'code': code, 'relay': relay};
        }
      } else if (request.uri.path == '/health') {
        status = HttpStatus.ok;
        body = {'ok': true, 'service': 'lightmesh-network-directory'};
      }
      try {
        response.statusCode = status;
        response.write(jsonEncode(body));
        await response.close();
      } on Object {
        // A disconnected HTTP client must not stop the directory.
      }
    });
  }

  Future<void> close() async => _server?.close(force: true);
}
