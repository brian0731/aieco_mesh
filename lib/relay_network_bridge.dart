import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// A single active phone can join two otherwise independent broadcast relays.
/// Both sockets are separate from the phone's normal chat connection.
class RelayNetworkBridge extends ChangeNotifier {
  RelayNetworkBridge({
    required this.localRelayUrl,
    this.onConnected,
    this.retryDelay = const Duration(seconds: 5),
    Future<WebSocket> Function(String)? connect,
  }) : _connect = connect ?? WebSocket.connect;

  final String localRelayUrl;
  final VoidCallback? onConnected;
  final Duration retryDelay;
  final Future<WebSocket> Function(String) _connect;
  final String _id =
      'bridge-${DateTime.now().microsecondsSinceEpoch}-'
      '${Random.secure().nextInt(1 << 32)}';
  final List<WebSocket?> _sockets = [null, null];
  final List<bool> _connecting = [false, false];
  final List<Timer?> _retries = [null, null];
  final LinkedHashMap<String, DateTime> _seen = LinkedHashMap();
  static const _pathKey = '_lightBridgePath';
  static const _maxBytes = 64 * 1024;
  static const _maxHops = 8;
  static const _maxSeen = 1024;
  static const _kinds = {
    'aieco.light.hello.v1',
    'aieco.light.bye.v1',
    'aieco.light.chat.v1',
    'aieco.light.room.v1',
    'aieco.light.location.v1',
    'aieco.light.activity.v1',
    'aieco.light.help.v1',
    'aieco.light.supply.v1',
    'aieco.light.credit.v1',
    'aieco.light.admin.v1',
  };
  int _generation = 0;
  bool _disposed = false;
  bool _active = false;
  String? _remoteRelayUrl;
  String? _error;

  bool get active => _active;
  bool get connected =>
      _active &&
      _sockets.every((socket) => socket?.readyState == WebSocket.open);
  String? get remoteRelayUrl => _remoteRelayUrl;
  String? get error => _error;
  String get connectionCode => codeFor(localRelayUrl);

  static String codeFor(String relayUrl) => Uri(
    scheme: 'lightmesh',
    host: 'connect',
    queryParameters: {'relay': normalizeRelayUrl(relayUrl)},
  ).toString();

  static String normalizeRelayUrl(String input) {
    var uri = Uri.tryParse(input.trim());
    if (uri?.scheme == 'lightmesh' && uri?.host == 'connect') {
      uri = Uri.tryParse(uri!.queryParameters['relay'] ?? '');
    }
    if (uri == null ||
        !{'ws', 'wss'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const FormatException('請貼上有效的光網連接碼。');
    }
    return uri.replace(path: uri.path.isEmpty ? '/' : uri.path).toString();
  }

  Future<void> join(String code) async {
    // Validate before replacing a working connection.
    final remote = normalizeRelayUrl(code);
    final local = normalizeRelayUrl(localRelayUrl);
    if (remote == local) {
      throw const FormatException('這是本網絡的連接碼，請使用另一個 APP 的連接碼。');
    }
    if (_disposed) return;
    disconnect();
    _remoteRelayUrl = remote;
    _active = true;
    final generation = _generation;
    notifyListeners();
    await Future.wait([
      _open(0, local, generation),
      _open(1, remote, generation),
    ]);
  }

  Future<void> _open(int side, String url, int generation) async {
    if (!_current(generation) || _connecting[side] || _sockets[side] != null) {
      return;
    }
    _connecting[side] = true;
    var timedOut = false;
    try {
      final socket = await _connect(url)
          .then((socket) {
            if (timedOut) _discard(socket);
            return socket;
          })
          .timeout(
            const Duration(seconds: 12),
            onTimeout: () {
              timedOut = true;
              throw const SocketException('connection timeout');
            },
          );
      if (!_current(generation)) {
        _discard(socket);
        return;
      }
      _sockets[side] = socket;
      socket.pingInterval = const Duration(seconds: 20);
      socket.listen(
        (data) => _receive(side, data),
        onDone: () => _lost(side, socket, url, generation),
        onError: (Object _) => _lost(side, socket, url, generation),
        cancelOnError: true,
      );
      _error = null;
      notifyListeners();
      if (connected) onConnected?.call();
    } on Object {
      if (_current(generation)) {
        _error = '暫時未能連接另一個光網，正在自動重試。';
        _retry(side, url, generation);
        notifyListeners();
      }
    } finally {
      if (_current(generation)) _connecting[side] = false;
    }
  }

  bool _current(int generation) =>
      !_disposed && _active && generation == _generation;

  static void _discard(WebSocket socket) {
    // Drain late handshakes too, so close frames are consumed and TCP is freed.
    socket.listen((_) {}, onError: (Object _) {}, cancelOnError: true);
    unawaited(socket.close());
  }

  void _lost(int side, WebSocket socket, String url, int generation) {
    if (!_current(generation) || !identical(_sockets[side], socket)) return;
    _sockets[side] = null;
    unawaited(socket.close());
    _error = '光網連接中斷，正在自動重試。';
    _retry(side, url, generation);
    notifyListeners();
  }

  void _retry(int side, String url, int generation) {
    if (_retries[side] != null || !_current(generation)) return;
    _retries[side] = Timer(retryDelay, () {
      _retries[side] = null;
      unawaited(_open(side, url, generation));
    });
  }

  void _receive(int side, Object? data) {
    if (!connected) return;
    try {
      final String text;
      if (data is String) {
        if (data.length > _maxBytes) return;
        text = data;
      } else if (data is List<int> && data.length <= _maxBytes) {
        text = utf8.decode(data);
      } else {
        return;
      }
      if (utf8.encode(text).length > _maxBytes) return;
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic> ||
          !_kinds.contains(decoded['kind'])) {
        return;
      }
      final rawPath = decoded.remove(_pathKey);
      if (rawPath != null &&
          (rawPath is! List || rawPath.any((id) => id is! String))) {
        return;
      }
      final path = rawPath is List ? rawPath.cast<String>() : <String>[];
      if (path.contains(_id) || path.length >= _maxHops) return;

      // Canonical JSON also catches echoes from relays that reorder object keys.
      final signature = jsonEncode(_canonical(decoded));
      final now = DateTime.now();
      while (_seen.isNotEmpty &&
          now.difference(_seen.values.first) > const Duration(minutes: 2)) {
        _seen.remove(_seen.keys.first);
      }
      if (_seen.containsKey(signature)) return;
      _seen[signature] = now;
      while (_seen.length > _maxSeen) {
        _seen.remove(_seen.keys.first);
      }
      decoded[_pathKey] = [...path, _id];
      final outgoing = jsonEncode(decoded);
      if (utf8.encode(outgoing).length > _maxBytes) return;
      _sockets[1 - side]!.add(outgoing);
    } on Object {
      // Invalid packets never take down a network bridge.
    }
  }

  static Object? _canonical(Object? value) {
    if (value is Map<String, dynamic>) {
      return {
        for (final key in value.keys.toList()..sort())
          key: _canonical(value[key]),
      };
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }

  void disconnect() {
    _generation++;
    _active = false;
    _remoteRelayUrl = null;
    _error = null;
    for (var side = 0; side < 2; side++) {
      _retries[side]?.cancel();
      _retries[side] = null;
      final socket = _sockets[side];
      _sockets[side] = null;
      _connecting[side] = false;
      if (socket != null) unawaited(socket.close());
    }
    _seen.clear();
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    disconnect();
    super.dispose();
  }
}
