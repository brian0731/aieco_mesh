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
    'MeshChatService saves editable user name while preserving light point name',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});

      final mesh = MeshChatService();
      addTearDown(mesh.dispose);
      await mesh.loadSavedDisplayName();

      final lightPointName = mesh.displayName;
      expect(mesh.userName, '光之子');
      expect(mesh.identityName, '光之子 · $lightPointName');

      final updated = mesh.setUserName('小明');
      expect(updated, isTrue);
      expect(mesh.userName, '小明');
      expect(mesh.displayName, lightPointName);
      expect(mesh.identityName, '小明 · $lightPointName');

      await Future<void>.delayed(const Duration(milliseconds: 20));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('mesh.userName'), '小明');

      final sent = await mesh.sendMessage('新的身份測試');
      expect(sent, isTrue);
      final message = mesh.messages.single;
      expect(message.senderName, '小明 · $lightPointName');

      final packet = message.toPacket();
      expect(packet['senderName'], lightPointName);
      expect(packet['senderUserName'], '小明');
      await mesh.stop();
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
    'MeshChatService deletes local account data and creates a fresh identity',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'mesh.nodeId': 'node-existing',
        'mesh.displayName': 'HK1234567',
        'mesh.userName': '舊用戶',
        'mesh.eulaAcceptedAt': DateTime.utc(2026).toIso8601String(),
        'mesh.blockedUsers': <String>['peer-1'],
        'mesh.blockedUserNames': '{"peer-1":"惡意光點"}',
        'mesh.hiddenMessages': <String>['msg-old'],
        'mesh.moderationReports': <String>['{}'],
      });

      final mesh = MeshChatService();
      addTearDown(mesh.dispose);

      await mesh.loadSavedDisplayName();
      await mesh.loadModerationPreferences();
      final oldNodeId = mesh.onlineUsers.single.id;
      final oldDisplayName = mesh.displayName;

      expect(oldNodeId, 'node-existing');
      expect(oldDisplayName, 'HK1234567');
      expect(mesh.userName, '舊用戶');
      expect(mesh.eulaAccepted, isTrue);
      expect(mesh.blockedUsers, hasLength(1));

      final sent = await mesh.sendMessage('刪除前本機訊息');
      expect(sent, isTrue);
      expect(mesh.messages, hasLength(1));

      final deleted = await mesh.deleteLocalAccountAndData();

      expect(deleted, isTrue);
      expect(mesh.isRunning, isFalse);
      expect(mesh.onlineUsers.single.id, isNot(oldNodeId));
      expect(mesh.displayName, isNot(oldDisplayName));
      expect(mesh.displayName, matches(RegExp(r'^HK\d{7}$')));
      expect(mesh.eulaAccepted, isFalse);
      expect(mesh.blockedUsers, isEmpty);
      expect(mesh.messages, isEmpty);
      expect(mesh.supplies, isEmpty);
      expect(mesh.moderationReportCount, 0);
      expect(mesh.status, contains('本機帳號與資料已刪除'));

      final prefs = await SharedPreferences.getInstance();
      final newNodeId = mesh.onlineUsers.single.id;
      final newDisplayName = mesh.displayName;
      expect(prefs.getString('mesh.nodeId'), newNodeId);
      expect(prefs.getString('mesh.displayName'), newDisplayName);
      expect(prefs.getString('mesh.userName'), '光之子');
      expect(prefs.getString('mesh.eulaAcceptedAt'), isNull);
      expect(prefs.getStringList('mesh.blockedUsers'), isNull);
      expect(prefs.getString('mesh.blockedUserNames'), isNull);
      expect(prefs.getStringList('mesh.hiddenMessages'), isNull);
      expect(prefs.getStringList('mesh.moderationReports'), isNull);
      expect(prefs.getString('mesh.accountDeletionLastAt'), isNotNull);

      final deletedAgain = await mesh.deleteLocalAccountAndData();

      expect(deletedAgain, isFalse);
      expect(mesh.onlineUsers.single.id, newNodeId);
      expect(mesh.displayName, newDisplayName);
      expect(mesh.status, contains('1 天內只可使用 1 次'));
    },
  );

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
    expect(mesh.blockedUsers.single.name, '惡意光點');

    mesh.unblockUser('peer-1', userName: '惡意光點');
    expect(mesh.blockedUserIds, isNot(contains('peer-1')));
    expect(mesh.blockedUsers, isEmpty);
    expect(mesh.status, contains('解鎖'));

    await Future<void>.delayed(const Duration(milliseconds: 20));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('mesh.blockedUsers'), isEmpty);
    expect(prefs.getString('mesh.blockedUserNames'), '{}');

    await mesh.stop();
  });

  testWidgets('Propagation Light closes when EULA is declined', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    var closed = false;

    await tester.pumpWidget(
      PropagationLightApp(
        enableWebView: false,
        onTermsDeclined: () async {
          closed = true;
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('最終用戶許可協議'), findsOneWidget);
    expect(find.text('不同意並關閉'), findsOneWidget);

    await tester.tap(find.text('不同意並關閉'));
    await tester.pumpAndSettle();

    expect(closed, isTrue);
    expect(find.textContaining('APP 將會關閉'), findsWidgets);
  });

  testWidgets('Account deletion cooldown is shown in a popup', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(
      const PropagationLightApp(autoStart: false, enableWebView: false),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('account-privacy-entry')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey('delete-account-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('delete-account-button')));
    await tester.pumpAndSettle();
    expect(find.text('刪除本機帳號與資料？'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '刪除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('本機帳號與資料已刪除'), findsWidgets);

    await tester.ensureVisible(
      find.byKey(const ValueKey('delete-account-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('delete-account-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '刪除'));
    await tester.pumpAndSettle();

    expect(find.text('暫時不能刪除帳號'), findsOneWidget);
    expect(find.textContaining('1 天內只可使用 1 次'), findsWidgets);
    expect(find.textContaining('後再試'), findsWidgets);
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
    expect(find.byKey(const ValueKey('account-privacy-entry')), findsOneWidget);
    expect(find.byTooltip('社區網絡'), findsNothing);
    expect(find.text('SOS 燈'), findsOneWidget);
    expect(find.textContaining('MESH 自動連接'), findsOneWidget);
    expect(find.text('掃 P2P 並連接'), findsOneWidget);
    expect(find.textContaining('發出 P2P 連接邀請'), findsOneWidget);
    expect(find.textContaining('請先開啟 WiFi'), findsOneWidget);
    expect(find.textContaining('重新開啟光之網絡'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('account-privacy-entry')));
    await tester.pumpAndSettle();

    expect(find.text('帳號與私隱'), findsWidgets);
    expect(find.text('本機匿名帳號'), findsOneWidget);
    expect(find.text('刪除帳號與資料'), findsOneWidget);
    expect(find.textContaining('1 天內只可使用 1 次'), findsOneWidget);
    expect(find.byKey(const ValueKey('delete-account-button')), findsOneWidget);

    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

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

    expect(find.text('更改用戶名稱'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('quick-user-name-input')),
      '守光者',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '儲存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('用戶名稱已更新：守光者'), findsWidgets);

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
      matches(RegExp(r'^@守光者 · [A-Z]{1,3}\d{7} $')),
    );
    supplyReplyInput.controller?.clear();

    await tester.tap(find.byKey(const ValueKey('supply-list-button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('關閉'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('光之雷達'));
    await tester.pumpAndSettle();

    expect(find.text('光之雷達'), findsWidgets);
    expect(find.text('香港18區離線地圖'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('offline-hong-kong-18-district-map')),
      findsOneWidget,
    );
    expect(find.text('最近10個光點'), findsOneWidget);
    expect(find.text('請先定位'), findsOneWidget);
    expect(find.text('定位'), findsOneWidget);

    await tester.tap(find.text('社區資訊'));
    await tester.pumpAndSettle();

    expect(find.text('社區資訊'), findsWidgets);
    expect(find.text('社區救生圈'), findsOneWidget);
    expect(find.text('社區共鳴牆'), findsOneWidget);
    expect(find.text('守望地圖'), findsOneWidget);
    expect(find.text('SOS 燈'), findsOneWidget);
    expect(find.text('https://www.aieco.hk'), findsNothing);
  });
}
