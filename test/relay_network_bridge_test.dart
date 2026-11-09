import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aieco_mesh/main.dart';
import 'package:aieco_mesh/relay_network_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../tool/network_directory_server.dart';

void main() {
  test(
    'connection codes work both ways and reject invalid or same networks',
    () async {
      final code = RelayNetworkBridge.codeFor(
        'wss://example.test/ws/light?key=test',
      );
      expect(
        RelayNetworkBridge.normalizeRelayUrl(code),
        'wss://example.test/ws/light?key=test',
      );
      for (final invalid in [
        'hello',
        'https://example.test',
        'ws://',
        'wss://user:pass@example.test/ws',
        'lightmesh://connect?relay=bad',
      ]) {
        expect(
          () => RelayNetworkBridge.normalizeRelayUrl(invalid),
          throwsFormatException,
        );
      }
      final bridge = RelayNetworkBridge(localRelayUrl: 'wss://example.test');
      addTearDown(bridge.dispose);
      await expectLater(
        bridge.join('wss://example.test/'),
        throwsFormatException,
      );
      expect(bridge.active, isFalse);
    },
  );

  test(
    'one participant joins all users on both relays, including rooms',
    () => HttpOverrides.runWithHttpOverrides(() async {
      SharedPreferences.setMockInitialValues({});
      final a = await _Relay.start();
      final b = await _Relay.start();
      final directory = NetworkDirectoryServer({
        '582193': a.url,
        '704826': b.url,
      });
      await directory.start(port: 0);
      final nodes = [
        for (final relay in [a, a, b, b])
          MeshChatService(
            onlineRelayUrl: relay.url,
            networkConnectionCode: relay == a ? '582193' : '704826',
            networkDirectoryUrl: 'http://127.0.0.1:${directory.port}',
          ),
      ];
      addTearDown(() async {
        for (final node in nodes) {
          await node.stop();
          node.dispose();
        }
        await a.close();
        await b.close();
        await directory.close();
      });
      await Future.wait(nodes.map((node) => node.start()));
      expect(nodes.every((node) => node.onlineConnected), isTrue);
      await nodes[1].sendMessage('A before joining');
      await nodes[3].sendMessage('B before joining');
      await _until(
        () => nodes[0].messages.any((m) => m.text == 'A before joining'),
      );
      expect(await nodes[0].getNetworkConnectionCode(), '582193');
      expect(await nodes[3].getNetworkConnectionCode(), '704826');
      await nodes[0].connectOtherNetwork('704826');
      expect(nodes[0].networkBridge.connected, isTrue);
      await expectLater(
        nodes[0].connectOtherNetwork('582193'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            '這是本網絡的連接碼，請使用另一個 APP 的連接碼。',
          ),
        ),
      );
      expect(nodes[0].networkBridge.connected, isTrue);
      await expectLater(
        nodes[0].connectOtherNetwork('111111'),
        throwsFormatException,
      );
      expect(nodes[0].networkBridge.connected, isTrue);
      await _until(
        () => nodes.every(
          (node) => node.messages.any((m) => m.text == 'B before joining'),
        ),
      );
      await nodes[1].sendMessage('Hello from A');
      await nodes[3].sendMessage('Hello from B');
      await _until(
        () => nodes.every(
          (node) =>
              node.messages.any((m) => m.text == 'Hello from A') &&
              node.messages.any((m) => m.text == 'Hello from B'),
        ),
      );
      expect(nodes[3].createRoom('Connected team'), isTrue);
      final roomId = nodes[3].activeRoom.id;
      await _until(() => nodes[1].rooms.any((room) => room.id == roomId));
      nodes[1].setActiveRoom(roomId);
      await nodes[1].sendMessage('Team room message');
      await _until(
        () => nodes[3].messages.any(
          (m) => m.text == 'Team room message' && m.roomId == roomId,
        ),
      );
      for (final node in nodes) {
        expect(
          node.messages.where((m) => m.text == 'Hello from A'),
          hasLength(1),
        );
        expect(
          node.messages.where((m) => m.text == 'Hello from B'),
          hasLength(1),
        );
      }
      // Stopping the participant closes its bridge; the other local users stay online.
      await nodes[0].stop();
      await _until(() => a.clients.length == 1 && b.clients.length == 2);
      await nodes[1].sendMessage('Only A after disconnect');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        nodes[3].messages.any((m) => m.text == 'Only A after disconnect'),
        isFalse,
      );
      expect(nodes[1].onlineConnected && nodes[3].onlineConnected, isTrue);
    }, _RealHttpOverrides()),
  );

  test(
    'two opposite bridges suppress echoes and enforce hop and size limits',
    () async {
      final a = await _Relay.start();
      final b = await _Relay.start();
      final ab = RelayNetworkBridge(localRelayUrl: a.url);
      final ba = RelayNetworkBridge(localRelayUrl: b.url);
      final sender = await WebSocket.connect(a.url);
      sender.listen((_) {});
      final receiver = await WebSocket.connect(b.url);
      final received = <Map>[];
      receiver.listen(
        (data) => received.add(jsonDecode(data as String) as Map),
      );
      addTearDown(() async {
        ab.dispose();
        ba.dispose();
        await sender.close();
        await receiver.close();
        await a.close();
        await b.close();
      });
      await ab.join(b.url);
      await ba.join(a.url);
      final packet = {
        'kind': 'aieco.light.chat.v1',
        'messageId': 'loop-test',
        'text': 'hi',
      };
      sender.add(jsonEncode(packet));
      await _until(() => received.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      // Two bridges can race the first copy; relay traffic must settle after that.
      final settled = a.packets + b.packets;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(a.packets + b.packets, settled);
      expect(settled, lessThanOrEqualTo(5));
      expect(received.length, lessThanOrEqualTo(2));
      final count = received.length;
      sender.add('not json');
      sender.add(jsonEncode({'kind': 'other.protocol'}));
      sender.add(
        jsonEncode({...packet, 'messageId': 'too-large', 'text': '光' * 30000}),
      );
      sender.add(
        jsonEncode({
          ...packet,
          'messageId': 'too-many-hops',
          '_lightBridgePath': List.generate(8, (i) => 'other-$i'),
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(received, hasLength(count));
    },
  );

  test(
    'lost sockets reconnect; disconnect cancels retries and late connections',
    () async {
      final a = await _Relay.start();
      final b = await _Relay.start();
      final bridge = RelayNetworkBridge(
        localRelayUrl: a.url,
        retryDelay: const Duration(milliseconds: 30),
      );
      addTearDown(() async {
        bridge.dispose();
        await a.close();
        await b.close();
      });
      await bridge.join(b.url);
      expect(bridge.connected, isTrue);
      await _until(
        () => a.clients.length == 1 && b.clients.length == 1,
        'relay acceptance',
      );
      final lost = Completer<void>();
      bridge.addListener(() {
        if (!bridge.connected && !lost.isCompleted) lost.complete();
      });
      for (final socket in b.clients.toList()) {
        await socket.close();
      }
      await lost.future.timeout(const Duration(seconds: 5));
      await _until(
        () => bridge.connected && b.clients.length == 1,
        'reconnect',
      );
      bridge.disconnect();
      await _until(() => a.clients.isEmpty && b.clients.isEmpty, 'disconnect');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(a.clients, isEmpty);
      expect(b.clients, isEmpty);

      final pending = <Completer<WebSocket>>[];
      final delayed = RelayNetworkBridge(
        localRelayUrl: a.url,
        connect: (_) {
          final result = Completer<WebSocket>();
          pending.add(result);
          return result.future;
        },
      );
      addTearDown(delayed.dispose);
      final joining = delayed.join(b.url);
      delayed.disconnect();
      pending[0].complete(await WebSocket.connect(a.url));
      pending[1].complete(await WebSocket.connect(b.url));
      await joining;
      await _until(
        () => a.clients.isEmpty && b.clients.isEmpty,
        'late socket cleanup',
      );
      expect(delayed.active, isFalse);
    },
  );
  for (final width in [320.0, 390.0, 1000.0]) {
    testWidgets('cross APP card sits below network settings at $width', (
      tester,
    ) async {
      final clipboardWrites = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardWrites.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });
      SharedPreferences.setMockInitialValues({
        'mesh.eulaAcceptedAt': DateTime.utc(2026).toIso8601String(),
      });
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const PropagationLightApp(autoStart: false, enableWebView: false),
      );
      await tester.pumpAndSettle();
      final dynamic panel = tester.widget(
        find.byWidgetPredicate(
          (widget) => widget.runtimeType.toString() == '_StatusAndPeersPanel',
        ),
      );
      final mesh = panel.mesh as MeshChatService;
      final bridgePanel = find.byKey(const ValueKey('network-bridge-panel'));
      expect(bridgePanel, findsNothing);
      await mesh.setNetworkMode(MeshNetworkMode.online);
      await tester.pumpAndSettle();
      expect(bridgePanel, findsOneWidget);
      expect(find.text('有網絡時才可對接'), findsOneWidget);
      expect(
        find.ancestor(
          of: bridgePanel,
          matching: find.byWidgetPredicate(
            (widget) => widget.runtimeType.toString() == '_StatusAndPeersPanel',
          ),
        ),
        findsNothing,
      );
      expect(
        tester.getTopLeft(bridgePanel).dy,
        greaterThanOrEqualTo(
          tester
              .getBottomLeft(
                find.byWidgetPredicate(
                  (widget) =>
                      widget.runtimeType.toString() == '_StatusAndPeersPanel',
                ),
              )
              .dy,
        ),
      );
      expect(find.byKey(const ValueKey('other-network-code')), findsNothing);
      await tester.ensureVisible(bridgePanel);
      await tester.tap(find.text('連接另一個 光網APP'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('other-network-code')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('configure-network-directory')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('join-other-network')), findsOneWidget);
      expect(find.text('複製本網絡連接碼'), findsOneWidget);
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const ValueKey('local-network-code')),
            )
            .data,
        '582193',
      );
      final copy = find.byKey(const ValueKey('copy-network-code'));
      await tester.ensureVisible(copy);
      await tester.pumpAndSettle();
      await tester.tap(copy);
      await tester.pumpAndSettle();
      expect(clipboardWrites, ['582193']);
      expect(find.byKey(const ValueKey('paste-network-code')), findsOneWidget);
      final join = tester.widget<FilledButton>(
        find.byKey(const ValueKey('join-other-network')),
      );
      expect(join.onPressed, isNull);
      await tester.ensureVisible(
        find.byKey(const ValueKey('join-other-network')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('連接另一個 光網APP'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('連接另一個 光網APP'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('other-network-code')), findsNothing);
      await mesh.setNetworkMode(MeshNetworkMode.offline);
      await tester.pumpAndSettle();
      expect(bridgePanel, findsNothing);
      await mesh.setNetworkMode(MeshNetworkMode.online);
      await tester.pumpAndSettle();
      expect(bridgePanel, findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

Future<void> _until(
  bool Function() condition, [
  String reason = 'network state',
]) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for $reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

// The socket integration test uses real local HTTP instead of widget-test HTTP.
class _RealHttpOverrides extends HttpOverrides {}

class _Relay {
  _Relay(this.server) {
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      clients.add(socket);
      socket.listen(
        (data) {
          packets++;
          for (final client in clients.toList()) {
            if (client.readyState == WebSocket.open) client.add(data);
          }
        },
        onDone: () => clients.remove(socket),
        onError: (Object _) => clients.remove(socket),
      );
    });
  }
  final HttpServer server;
  final Set<WebSocket> clients = {};
  int packets = 0;
  String get url => 'ws://127.0.0.1:${server.port}/ws/light';
  static Future<_Relay> start() async =>
      _Relay(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
  Future<void> close() async {
    for (final socket in clients.toList()) {
      await socket.close();
    }
    await server.close(force: true);
  }
}
