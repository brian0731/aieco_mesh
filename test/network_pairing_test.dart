import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:aieco_mesh/main.dart';
import 'package:aieco_mesh/network_pairing_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../tool/network_directory_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    HttpOverrides.global = _RealHttpOverrides();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => HttpOverrides.global = null);

  test('uses the fixed local code and ignores old phone settings', () async {
    SharedPreferences.setMockInitialValues({
      'mesh.networkDirectoryUrl': 'https://obsolete.invalid',
    });
    final directory = NetworkDirectoryServer({
      '582193': 'wss://a.example/ws/light',
    });
    await directory.start(port: 0);
    addTearDown(directory.close);
    final mesh = MeshChatService(
      onlineRelayUrl: 'wss://a.example/ws/light',
      networkDirectoryUrl: 'http://127.0.0.1:${directory.port}',
    );
    addTearDown(mesh.dispose);
    expect(await mesh.getNetworkConnectionCode(), '582193');
  });

  for (final ownCode in ['582193', '001234']) {
    test(
      'rejects own code $ownCode before querying the other network',
      () async {
        final directory = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        addTearDown(() => directory.close(force: true));
        final requests = <Uri>[];
        directory.listen((request) async {
          requests.add(request.uri);
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        });
        final mesh = MeshChatService(
          onlineRelayUrl: 'wss://a.example/ws/light',
          networkDirectoryUrl: 'http://127.0.0.1:${directory.port}',
          networkConnectionCode: ownCode,
        );
        addTearDown(mesh.dispose);
        expect(await mesh.getNetworkConnectionCode(), ownCode);
        final selfConnectionError = throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            '這是本網絡的連接碼，請使用另一個 APP 的連接碼。',
          ),
        );
        await expectLater(
          mesh.connectOtherNetwork(' $ownCode '),
          selfConnectionError,
        );
        // Sharing and self-code validation do not depend on the directory.
        await expectLater(
          mesh.connectOtherNetwork(ownCode),
          selfConnectionError,
        );
        expect(requests, isEmpty);
        expect(mesh.isRunning, isFalse);
        expect(mesh.networkBridge.active, isFalse);
      },
    );
  }

  test('cancel while resolving a code does not start a late bridge', () async {
    final directory = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => directory.close(force: true));
    final received = Completer<HttpRequest>();
    directory.listen(received.complete);
    final mesh = MeshChatService(
      onlineRelayUrl: 'ws://127.0.0.1:1/local',
      networkDirectoryUrl: 'http://127.0.0.1:${directory.port}',
    );
    addTearDown(mesh.dispose);
    final joining = mesh.connectOtherNetwork('123456');
    final request = await received.future.timeout(const Duration(seconds: 2));
    expect(request.uri.path, '/networks/123456');
    mesh.disconnectOtherNetwork();
    request.response.write(
      jsonEncode({'code': '123456', 'relay': 'ws://127.0.0.1:1/remote'}),
    );
    await request.response.close();
    await joining;
    expect(mesh.isRunning, isFalse);
    expect(mesh.networkBridge.active, isFalse);
  });

  test(
    'six digit directory preserves leading zeros and resolves both networks',
    () async {
      final server = NetworkDirectoryServer({
        '001234': 'wss://a.example/ws/light',
        '582193': 'wss://b.example/ws/light',
      });
      await server.start(port: 0);
      addTearDown(server.close);
      final client = NetworkPairingClient('http://127.0.0.1:${server.port}/');
      expect(await client.codeFor('wss://a.example/ws/light'), '001234');
      expect(await client.resolve('001234'), 'wss://a.example/ws/light');
      expect(await client.resolve('582193'), 'wss://b.example/ws/light');
      await expectLater(client.resolve('999999'), throwsFormatException);
      await expectLater(
        client.codeFor('wss://unknown.example'),
        throwsFormatException,
      );
      for (final code in ['12345', '1234567', 'abcdef', '１２３４５６']) {
        await expectLater(client.resolve(code), throwsFormatException);
      }
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      final request = await http.postUrl(
        Uri.parse('http://127.0.0.1:${server.port}/networks/001234'),
      );
      request.write(jsonEncode({'relay': 'wss://impostor.example'}));
      final response = await request.close();
      expect(response.statusCode, HttpStatus.methodNotAllowed);
      await response.drain<void>();
      expect(await client.resolve('001234'), 'wss://a.example/ws/light');
    },
  );

  test('directory rejects invalid codes and duplicate relay assignments', () {
    expect(
      () => NetworkDirectoryServer({'123': 'wss://a.example'}),
      throwsFormatException,
    );
    expect(
      () => NetworkDirectoryServer({'123456': 'https://a.example'}),
      throwsFormatException,
    );
    expect(
      () => NetworkDirectoryServer({
        '123456': 'wss://a.example',
        '234567': 'wss://a.example/',
      }),
      throwsFormatException,
    );
  });

  test(
    'client reports unconfigured and malformed directory responses',
    () async {
      await expectLater(
        NetworkPairingClient('').resolve('123456'),
        throwsFormatException,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.write(
          jsonEncode({'code': 'bad', 'relay': 'file:///invalid'}),
        );
        await request.response.close();
      });
      final client = NetworkPairingClient('http://127.0.0.1:${server.port}');
      await expectLater(
        client.codeFor('wss://a.example'),
        throwsFormatException,
      );
      await expectLater(client.resolve('123456'), throwsFormatException);
    },
  );
}

class _RealHttpOverrides extends HttpOverrides {}
