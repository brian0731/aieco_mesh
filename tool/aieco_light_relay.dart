import 'dart:async';
import 'dart:convert';
import 'dart:io';

const int _defaultPort = 47890;

Future<void> main(List<String> args) async {
  final port = _parsePort(args) ?? _defaultPort;
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  final clients = <WebSocket>{};

  stdout.writeln('AIECO Light relay listening on ws://0.0.0.0:$port');

  await for (final request in server) {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.text
        ..write('AIECO Light relay');
      await request.response.close();
      continue;
    }

    unawaited(_acceptClient(request, clients));
  }
}

Future<void> _acceptClient(HttpRequest request, Set<WebSocket> clients) async {
  final socket = await WebSocketTransformer.upgrade(request);
  clients.add(socket);

  socket.listen(
    (data) => _broadcast(data, clients),
    onDone: () => clients.remove(socket),
    onError: (_) => clients.remove(socket),
    cancelOnError: true,
  );
}

void _broadcast(Object? data, Set<WebSocket> clients) {
  final text = _packetText(data);
  if (text == null || !_isLightPacket(text)) {
    return;
  }

  for (final client in List<WebSocket>.of(clients)) {
    if (client.readyState == WebSocket.open) {
      client.add(text);
    } else {
      clients.remove(client);
    }
  }
}

String? _packetText(Object? data) {
  if (data is String) {
    return data;
  }
  if (data is List<int>) {
    return utf8.decode(data, allowMalformed: true);
  }
  return null;
}

bool _isLightPacket(String text) {
  try {
    final decoded = jsonDecode(text.trim());
    if (decoded is! Map) {
      return false;
    }
    final kind = decoded['kind'];
    return kind is String && kind.startsWith('aieco.light.');
  } on Object {
    return false;
  }
}

int? _parsePort(List<String> args) {
  for (var index = 0; index < args.length; index += 1) {
    final arg = args[index];
    if (arg == '--port' && index + 1 < args.length) {
      return int.tryParse(args[index + 1]);
    }
    if (arg.startsWith('--port=')) {
      return int.tryParse(arg.substring('--port='.length));
    }
  }
  return int.tryParse(Platform.environment['PORT'] ?? '');
}
