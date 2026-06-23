import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aieco_mesh/main.dart';

void main() {
  const wifiMeshChannel = MethodChannel('hk.aieco.propagation_light/wifi_mesh');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(wifiMeshChannel, (call) async {
          switch (call.method) {
            case 'setTorch':
              return <String, Object?>{'message': 'OK'};
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(wifiMeshChannel, null);
  });

  test(
    'MeshChatService keeps a locked legacy six digit display name',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'mesh.displayName': '123456',
      });

      final mesh = MeshChatService();
      addTearDown(mesh.dispose);

      expect(mesh.displayName, matches(RegExp(r'^[A-Z]{1,3}\d{7}$')));

      await mesh.loadSavedDisplayName();
      expect(mesh.displayName, '123456');

      mesh.setDisplayName('654321');
      expect(mesh.displayName, '123456');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('mesh.displayName'), '123456');

      mesh.setDisplayName('abc');
      expect(mesh.displayName, '123456');
      expect(prefs.getString('mesh.displayName'), '123456');
    },
  );

  test(
    'MeshChatService saves an initial generated district display name',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});

      final mesh = MeshChatService();
      addTearDown(mesh.dispose);

      final initialName = mesh.displayName;
      expect(initialName, matches(RegExp(r'^HK\d{7}$')));

      await mesh.loadSavedDisplayName();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('mesh.displayName'), initialName);

      mesh.setDisplayName('CW7654321');
      expect(mesh.displayName, initialName);
      expect(prefs.getString('mesh.displayName'), initialName);
    },
  );

  test(
    'MeshChatService updates fallback display name prefix from location',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});

      final mesh = MeshChatService();
      addTearDown(mesh.dispose);
      await mesh.loadSavedDisplayName();

      final initialName = mesh.displayName;
      expect(initialName, matches(RegExp(r'^HK\d{7}$')));

      await mesh.setNetworkMode(MeshNetworkMode.online);
      mesh.updateLocation(
        DeviceLocation(
          latitude: 22.281,
          longitude: 114.158,
          accuracyMeters: 12,
          provider: 'test',
          timestamp: DateTime.fromMillisecondsSinceEpoch(0),
          fromCache: false,
        ),
      );

      expect(mesh.displayName, matches(RegExp(r'^CW\d{7}$')));
      expect(mesh.displayName.substring(2), initialName.substring(2));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('mesh.displayName'), mesh.displayName);
    },
  );

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

  test('MeshChatService enforces chat moderation controls', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final mesh = MeshChatService();
    addTearDown(mesh.dispose);

    expect(mesh.eulaAccepted, isFalse);
    await mesh.acceptEula();
    expect(mesh.eulaAccepted, isTrue);

    final blocked = await mesh.sendMessage('這是色情內容');
    expect(blocked, isFalse);
    expect(mesh.messages, isEmpty);
    expect(mesh.status, contains('安全過濾'));

    final sent = await mesh.sendMessage('安全互助訊息');
    expect(sent, isTrue);
    expect(mesh.messages, hasLength(1));

    final message = mesh.messages.single;
    mesh.reportMessage(message, reason: '其他不當內容');

    expect(mesh.messages, isEmpty);
    expect(mesh.moderationReportCount, 1);
    expect(mesh.status, contains('24 小時'));

    mesh.blockUser('peer-1', userName: '惡意光點');
    expect(mesh.blockedUserIds, contains('peer-1'));

    await mesh.stop();
  });

  test('MeshChatService marks local SOS in users and radar contacts', () async {
    final mesh = MeshChatService();
    addTearDown(mesh.dispose);

    final location = DeviceLocation(
      latitude: 22.3193,
      longitude: 114.1694,
      accuracyMeters: 12,
      provider: 'test',
      timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      fromCache: false,
    );

    await mesh.start();
    mesh.updateLocation(location);
    expect(mesh.onlineUsers.single.isSosActive, isFalse);
    expect(mesh.radarContacts.single.isSosActive, isFalse);

    mesh.setSosActive(true);

    expect(mesh.sosActive, isTrue);
    expect(mesh.onlineUsers.single.isSosActive, isTrue);
    expect(mesh.radarContacts.single.isSosActive, isTrue);
    expect(mesh.status, contains('求救光點'));
    await mesh.stop();
  });

  testWidgets('Propagation Light renders core chat controls', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'mesh.eulaAcceptedAt': DateTime.utc(2026).toIso8601String(),
    });

    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const PropagationLightApp(autoStart: false, enableWebView: false),
    );

    expect(find.text('傳播光'), findsOneWidget);
    expect(find.text('光之身份證'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip && widget.message?.contains('光之身份證') == true,
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            RegExp(r'^[A-Z]{1,3}\d{7}$').hasMatch(widget.data ?? ''),
      ),
      findsWidgets,
    );
    expect(find.text('光之網絡'), findsOneWidget);
    expect(find.text('光之通道'), findsOneWidget);
    expect(find.text('光之雷達'), findsWidgets);
    expect(find.byTooltip('功能介紹'), findsOneWidget);
    expect(find.byTooltip('社區網絡'), findsOneWidget);
    expect(find.text('SOS 燈'), findsOneWidget);
    expect(find.textContaining('MESH 自動連接'), findsOneWidget);
    expect(find.text('掃 P2P 並連接'), findsOneWidget);
    expect(find.textContaining('發出 P2P 連接邀請'), findsOneWidget);
    expect(find.textContaining('請先開啟 WiFi'), findsOneWidget);
    expect(find.textContaining('重新開啟光之網絡'), findsOneWidget);

    await tester.tap(find.byTooltip('啟動離線節點'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(find.text('光之網絡已開啟'), findsOneWidget);
    expect(find.textContaining('傳播光已開啟。'), findsOneWidget);
    expect(find.textContaining('離線使用時，請先開啟 WiFi'), findsOneWidget);
    await tester.tap(find.text('知道'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('停止節點'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(find.text('光之網絡已關閉'), findsOneWidget);
    expect(find.text('傳播光已關閉。'), findsOneWidget);
    await tester.tap(find.text('知道'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('光之通道'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('光之網絡'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('線上'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('啟動線上光網'));
    await tester.pumpAndSettle();

    expect(find.text('光之網絡未能開啟'), findsOneWidget);
    expect(find.textContaining('請先重啟 APP'), findsOneWidget);
    expect(find.textContaining('重新開啟光之網絡'), findsOneWidget);
    await tester.tap(find.text('知道'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('SOS 燈'));
    await tester.pumpAndSettle();

    expect(find.text('啟動 SOS 燈？'), findsOneWidget);
    expect(find.text('確認啟動'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.text('啟動 SOS 燈？'), findsNothing);

    await tester.tap(find.byTooltip('功能介紹'));
    await tester.pumpAndSettle();

    expect(find.text('功能介紹'), findsOneWidget);
    expect(find.textContaining('傳播光是一個線上 / 離線光之網絡聊天工具'), findsOneWidget);
    expect(find.text('SOS'), findsOneWidget);
    expect(find.textContaining('手機閃光燈會持續閃出 SOS 燈號'), findsOneWidget);

    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    await tester.tap(find.text('光之通道'));
    await tester.pumpAndSettle();

    expect(find.text('傳播頻道'), findsWidgets);
    expect(find.text('在線用家'), findsOneWidget);
    expect(find.text('光團'), findsOneWidget);
    expect(find.text('物資'), findsOneWidget);
    expect(find.text('1 人在線'), findsOneWidget);
    expect(find.textContaining('求救'), findsNothing);
    expect(find.text('找人'), findsOneWidget);
    expect(find.text('建立光團'), findsNothing);
    expect(find.text('找物資'), findsNothing);
    expect(find.byIcon(Icons.send), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('online-user-me')));
    await tester.pumpAndSettle();

    final quotedUserInput = tester.widget<TextField>(
      find.byKey(const ValueKey('chat-message-input')),
    );
    expect(
      quotedUserInput.controller?.text,
      matches(RegExp(r'^@[A-Z]{1,3}\d{7} $')),
    );
    quotedUserInput.controller?.clear();

    await tester.tap(find.text('光團'));
    await tester.pumpAndSettle();

    expect(find.text('建立光團'), findsOneWidget);

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

    await tester.tap(find.byKey(const ValueKey('room-list-button')));
    await tester.pumpAndSettle();

    expect(find.text('光團列表'), findsOneWidget);
    expect(find.text('搜尋光團名稱'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('room-search-input')),
      '測試',
    );
    await tester.pumpAndSettle();

    expect(find.text('測試光團'), findsWidgets);
    expect(find.text('傳播頻道'), findsNothing);

    await tester.tap(find.byTooltip('關閉'));
    await tester.pumpAndSettle();

    final activeRoomName = tester.widget<Text>(
      find.byKey(const ValueKey('active-room-name')),
    );
    expect(activeRoomName.data, '測試光團');

    final messageInput = tester.widget<TextField>(
      find.byKey(const ValueKey('chat-message-input')),
    );
    expect(messageInput.decoration?.hintText, '傳送到 測試光團');

    await tester.tap(find.text('物資'));
    await tester.pumpAndSettle();

    expect(find.text('找物資'), findsOneWidget);
    expect(find.text('分享物資'), findsOneWidget);

    await tester.tap(find.text('分享物資'));
    await tester.pumpAndSettle();

    expect(find.text('物資名稱'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('supply-title-input')),
      '電池',
    );
    await tester.enterText(
      find.byKey(const ValueKey('supply-quantity-input')),
      'AA 10粒',
    );
    await tester.enterText(
      find.byKey(const ValueKey('supply-note-input')),
      '中環交收',
    );
    await tester.pump();
    await tester.tap(find.text('分享'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('supply-list-button')));
    await tester.pumpAndSettle();

    expect(find.text('物資列表'), findsOneWidget);
    expect(find.text('搜尋物資、數量、地點或分享者'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('supply-search-input')),
      '中環',
    );
    await tester.pumpAndSettle();

    expect(find.text('電池'), findsOneWidget);
    expect(find.textContaining('中環交收'), findsOneWidget);

    await tester.tap(find.byTooltip('Tag 發起人回覆'));
    await tester.pumpAndSettle();

    final supplyReplyInput = tester.widget<TextField>(
      find.byKey(const ValueKey('chat-message-input')),
    );
    expect(
      supplyReplyInput.controller?.text,
      matches(RegExp(r'^@[A-Z]{1,3}\d{7} $')),
    );
    supplyReplyInput.controller?.clear();

    await tester.tap(find.byKey(const ValueKey('supply-list-button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('關閉'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('光之雷達'));
    await tester.pumpAndSettle();

    expect(find.text('光之雷達'), findsWidgets);
    expect(find.text('離線局部地圖'), findsOneWidget);
    expect(find.text('最近10個光點'), findsOneWidget);
    expect(find.text('請先定位'), findsOneWidget);
    expect(find.text('定位'), findsOneWidget);

    await tester.tap(find.byTooltip('社區網絡'));
    await tester.pumpAndSettle();

    expect(find.text('社區網絡'), findsOneWidget);
    expect(find.text('SOS 燈'), findsNothing);
    expect(find.text('https://www.aieco.hk'), findsOneWidget);
  });
}
