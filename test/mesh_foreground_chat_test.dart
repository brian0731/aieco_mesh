import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aieco_mesh/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('foreground chat shows incoming LAN messages without reopening', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'mesh.eulaAcceptedAt': DateTime.utc(2026).toIso8601String(),
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const PropagationLightApp(autoStart: false, enableWebView: false),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('光之通道'));
    await tester.pumpAndSettle();
    final dynamic panel = tester.widget(
      find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_ChatPanel',
      ),
    );
    final mesh = panel.mesh as MeshChatService;
    await tester.runAsync(mesh.start);
    expect(mesh.isRunning, isTrue, reason: mesh.status);
    try {
      await tester.runAsync(() => _sendChat(0));
      await tester.pumpAndSettle();
      expect(mesh.incomingMessageVersion, 1);
      expect(find.text(_messageText(0)), findsOneWidget);
      for (var index = 1; index <= 35; index++) {
        await tester.runAsync(() => _sendChat(index));
        await tester.pumpAndSettle();
        expect(find.text(_messageText(index)), findsOneWidget);
        final lastBubble = tester.getRect(find.text(_messageText(index)));
        final messageList = tester.getRect(find.byType(ListView).last);
        expect(lastBubble.bottom, lessThanOrEqualTo(messageList.bottom));
        expect(tester.takeException(), isNull);
      }
    } finally {
      await tester.runAsync(mesh.stop);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets(
    'foreground chat displays messages pulled over its own connection',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'mesh.eulaAcceptedAt': DateTime.utc(2026).toIso8601String(),
      });
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const PropagationLightApp(autoStart: false, enableWebView: false),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('光之通道'));
      await tester.pumpAndSettle();
      final dynamic panel = tester.widget(
        find.byWidgetPredicate(
          (widget) => widget.runtimeType.toString() == '_ChatPanel',
        ),
      );
      final mesh = panel.mesh as MeshChatService;
      final sockets = <Socket>{};
      ServerSocket? android;
      await tester.runAsync(() async {
        android = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        android!.listen((socket) {
          sockets.add(socket);
          socket
              .cast<List<int>>()
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen(
                (line) async {
                  final request = jsonDecode(line) as Map;
                  if (request['chatPullRequestId'] == null) return;
                  socket.writeln(
                    jsonEncode({
                      'kind': 'aieco.light.hello.v1',
                      'nodeId': 'android-foreground-peer',
                      'name': 'HK1234567',
                      'tcpPort': android!.port,
                      'helloReply': true,
                      'heartbeat': true,
                      'chatPull': true,
                    }),
                  );
                  socket.writeln(jsonEncode({..._chatPacket(100), 'hops': 1}));
                  socket.writeln(
                    jsonEncode({
                      'kind': 'aieco.light.chat_pull_done.v1',
                      'requestId': request['chatPullRequestId'],
                    }),
                  );
                  await socket.flush();
                },
                onDone: socket.destroy,
                onError: (Object _) => socket.destroy(),
              );
        });
        await mesh.start();
      });
      try {
        await tester.runAsync(() async {
          final discovered = Completer<void>();
          final received = Completer<void>();
          void listener() {
            if (mesh.peers.any((peer) => peer.supportsChatPull) &&
                !discovered.isCompleted) {
              discovered.complete();
            }
            if (mesh.incomingMessageVersion == 1 && !received.isCompleted) {
              received.complete();
            }
          }

          mesh.addListener(listener);
          try {
            final discovery = await Socket.connect(
              InternetAddress.loopbackIPv4,
              MeshChatService.tcpPort,
            );
            discovery.writeln(
              jsonEncode({
                'kind': 'aieco.light.hello.v1',
                'nodeId': 'android-foreground-peer',
                'name': 'HK1234567',
                'tcpPort': android!.port,
                'helloReply': true,
                'heartbeat': true,
                'chatPull': true,
              }),
            );
            await discovery.flush();
            await discovery.close();
            await discovered.future.timeout(const Duration(seconds: 1));
            await mesh.refreshNetworkPresence();
            await received.future.timeout(const Duration(seconds: 1));
          } finally {
            mesh.removeListener(listener);
          }
        });
        await tester.pumpAndSettle();
        expect(find.text(_messageText(100)), findsOneWidget);
        expect(mesh.incomingMessageVersion, 1);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.runAsync(() async {
          await mesh.stop();
          await android?.close();
          for (final socket in sockets) {
            socket.destroy();
          }
        });
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );
}

String _messageText(int index) =>
    'Android 前景訊息 $index\n${List.filled(index % 5 + 1, '無網 mesh 即時接收測試').join('\n')}';

Map<String, Object?> _chatPacket(int index) => {
  'kind': 'aieco.light.chat.v1',
  'messageId': 'android-foreground-$index',
  'senderId': 'android-foreground-peer',
  'senderName': 'HK1234567',
  'text': _messageText(index),
  'chatAckRequested': true,
};

Future<void> _sendChat(int index) async {
  final socket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    MeshChatService.tcpPort,
  );
  try {
    final reply = socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
    socket.writeln(jsonEncode(_chatPacket(index)));
    await socket.flush();
    final ack =
        jsonDecode(await reply.timeout(const Duration(seconds: 1))) as Map;
    expect(ack['messageId'], 'android-foreground-$index');
  } finally {
    socket.destroy();
  }
}
