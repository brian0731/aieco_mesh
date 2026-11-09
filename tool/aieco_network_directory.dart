import 'dart:convert';
import 'dart:io';

import 'network_directory_server.dart';

Future<void> main(List<String> args) async {
  String? config;
  var port = 47891;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--config' && i + 1 < args.length) {
      config = args[++i];
    } else if (args[i] == '--port' && i + 1 < args.length) {
      port = int.parse(args[++i]);
    } else {
      throw ArgumentError('Usage: --config networks.json [--port 47891]');
    }
  }
  if (config == null) throw ArgumentError('--config is required');
  final decoded = jsonDecode(await File(config).readAsString());
  if (decoded is! Map<String, dynamic> ||
      decoded.values.any((v) => v is! String)) {
    throw const FormatException(
      'Expected a JSON object of six-digit code to relay URL.',
    );
  }
  final directory = NetworkDirectoryServer(decoded.cast<String, String>());
  await directory.start(port: port);
  stdout.writeln(
    'LightMesh directory listening on http://127.0.0.1:${directory.port}',
  );
}
