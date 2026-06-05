import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aieco_mesh/main.dart';

void main() {
  test('MeshChatService keeps a locked six digit display name', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'mesh.displayName': '123456',
    });

    final mesh = MeshChatService();
    addTearDown(mesh.dispose);

    expect(mesh.displayName, matches(RegExp(r'^\d{6}$')));

    await mesh.loadSavedDisplayName();
    expect(mesh.displayName, '123456');

    mesh.setDisplayName('654321');
    expect(mesh.displayName, '123456');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('mesh.displayName'), '123456');

    mesh.setDisplayName('abc');
    expect(mesh.displayName, '123456');
    expect(prefs.getString('mesh.displayName'), '123456');
  });

  test('MeshChatService saves an initial generated display name', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final mesh = MeshChatService();
    addTearDown(mesh.dispose);

    final initialName = mesh.displayName;
    expect(initialName, matches(RegExp(r'^\d{6}$')));

    await mesh.loadSavedDisplayName();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('mesh.displayName'), initialName);

    mesh.setDisplayName('654321');
    expect(mesh.displayName, initialName);
    expect(prefs.getString('mesh.displayName'), initialName);
  });

  test('MeshChatService reuses the same node id after restart', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final firstMesh = MeshChatService();
    addTearDown(firstMesh.dispose);
    await firstMesh.loadSavedDisplayName();

    final firstNodeId = firstMesh.onlineUsers.single.id;
    expect(firstNodeId, startsWith('node-'));

    final secondMesh = MeshChatService();
    addTearDown(secondMesh.dispose);
    await secondMesh.loadSavedDisplayName();

    expect(secondMesh.onlineUsers.single.id, firstNodeId);
    expect(secondMesh.displayName, firstMesh.displayName);
  });

  test(
    'MeshChatService shares supplies and deduplicates credit likes',
    () async {
      final mesh = MeshChatService();
      addTearDown(mesh.dispose);

      await mesh.start();
      mesh.shareSupply(title: '清水', quantity: '2 箱', note: '東閘交收');

      expect(mesh.supplies, hasLength(1));
      expect(mesh.supplies.single.title, '清水');
      expect(mesh.supplies.single.quantity, '2 箱');
      final supplyId = mesh.supplies.single.id;

      mesh.markSupplyTaken(supplyId);
      expect(mesh.supplies, isEmpty);

      mesh.likeUser('peer-1');
      mesh.likeUser('peer-1');

      expect(mesh.creditScoreFor('peer-1'), 1);
      expect(mesh.hasLikedUser('peer-1'), isTrue);
      await mesh.stop();
    },
  );

  test('MeshChatService exposes online and offline network modes', () async {
    final mesh = MeshChatService();
    addTearDown(mesh.dispose);

    expect(mesh.networkMode, MeshNetworkMode.offline);
    expect(mesh.onlineConfigured, isFalse);

    await mesh.setNetworkMode(MeshNetworkMode.online);

    expect(mesh.networkMode, MeshNetworkMode.online);
    expect(mesh.isRunning, isFalse);
    expect(mesh.status, contains('未設定 relay'));
  });

  testWidgets('Propagation Light renders core chat controls', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const PropagationLightApp(autoStart: false, enableWebView: false),
    );

    expect(find.text('傳播光'), findsOneWidget);
    expect(find.text('AIECO.HK 線上 / 離線光之網絡'), findsOneWidget);
    expect(find.text('光之網絡'), findsOneWidget);
    expect(find.text('光之通道'), findsOneWidget);
    expect(find.text('光之雷達'), findsWidgets);
    expect(find.text('社區網絡'), findsOneWidget);
    expect(find.text('WiFi P2P / 熱點'), findsOneWidget);
    expect(find.text('掃 P2P'), findsOneWidget);
    expect(find.text('開熱點'), findsOneWidget);

    await tester.tap(find.text('光之通道'));
    await tester.pumpAndSettle();

    expect(find.text('傳播頻道'), findsWidgets);
    expect(find.text('在線用家'), findsOneWidget);
    expect(find.text('1 人在線'), findsOneWidget);
    expect(find.text('找人'), findsOneWidget);
    expect(find.text('建立光團'), findsOneWidget);
    expect(find.text('物資分享'), findsOneWidget);
    expect(find.text('分享物資'), findsOneWidget);
    expect(find.byIcon(Icons.send), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('online-user-me')));
    await tester.pumpAndSettle();

    final quotedUserInput = tester.widget<TextField>(
      find.byKey(const ValueKey('chat-message-input')),
    );
    expect(quotedUserInput.controller?.text, matches(RegExp(r'^@\d{6} $')));
    quotedUserInput.controller?.clear();

    await tester.tap(find.text('建立光團'));
    await tester.pumpAndSettle();

    expect(find.text('光團名稱'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('room-name-input')),
      '測試光團',
    );
    await tester.pump();
    await tester.tap(find.text('建立'));
    await tester.pumpAndSettle();

    expect(find.text('測試光團'), findsWidgets);

    final activeRoomName = tester.widget<Text>(
      find.byKey(const ValueKey('active-room-name')),
    );
    expect(activeRoomName.data, '測試光團');

    final messageInput = tester.widget<TextField>(
      find.byKey(const ValueKey('chat-message-input')),
    );
    expect(messageInput.decoration?.hintText, '傳送到 測試光團');

    await tester.tap(find.text('光之雷達'));
    await tester.pumpAndSettle();

    expect(find.text('光之雷達'), findsWidgets);
    expect(find.text('離線局部地圖'), findsOneWidget);
    expect(find.text('最近10個光點'), findsOneWidget);
    expect(find.text('請先定位'), findsOneWidget);
    expect(find.text('定位'), findsOneWidget);

    await tester.tap(find.text('社區網絡'));
    await tester.pumpAndSettle();

    expect(find.text('社區網絡'), findsOneWidget);
    expect(find.text('https://www.aieco.hk'), findsOneWidget);
  });
}
