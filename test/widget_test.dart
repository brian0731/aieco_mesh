import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
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

  test('MeshChatService tracks whether presence should be visible', () {
    final mesh = MeshChatService();
    addTearDown(mesh.dispose);

    expect(mesh.presenceVisible, isTrue);

    mesh.setPresenceVisible(false);
    expect(mesh.presenceVisible, isFalse);

    mesh.setPresenceVisible(true);
    expect(mesh.presenceVisible, isTrue);
  });

  test('admin actions delete content and toggle user mute', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final mesh = MeshChatService();
    addTearDown(mesh.dispose);
    await mesh.setNetworkMode(MeshNetworkMode.online);

    expect(MeshChatService.adminPasswordForNow(), endsWith('1314'));
    expect(MeshChatService.adminPasswordForNow(), hasLength(12));

    expect(mesh.createRoom('Admin 測試光團'), isTrue);
    final roomId = mesh.activeRoom.id;
    expect(
      mesh.shareSupply(title: 'Admin 測試物資', quantity: '1', note: ''),
      isTrue,
    );
    final supplyId = mesh.supplies.single.id;
    mesh.updateLocation(
      DeviceLocation(
        latitude: 22.3412,
        longitude: 114.1932,
        accuracyMeters: 8,
        provider: 'test',
        timestamp: DateTime.now(),
        fromCache: false,
      ),
    );
    expect(
      await mesh.createRadarActivity(
        title: 'Admin 測試活動',
        details: '測試集合點',
        type: MeshRadarActivity.mutualAidType,
      ),
      isTrue,
    );
    final activityId = mesh.radarActivities.single.id;
    await mesh.sendMessage('Admin 測試留言');
    final messageId = mesh.messages.single.id;

    mesh.adminDeleteMessage(messageId);
    mesh.adminDeleteRoom(roomId);
    mesh.adminDeleteSupply(supplyId);
    mesh.adminDeleteActivity(activityId);
    mesh.adminSetUserMuted('peer-admin-test', muted: true);

    expect(mesh.messages, isEmpty);
    expect(mesh.rooms.any((room) => room.id == roomId), isFalse);
    expect(mesh.supplies, isEmpty);
    expect(mesh.radarActivities, isEmpty);
    expect(mesh.isUserMuted('peer-admin-test'), isTrue);

    mesh.adminSetUserMuted('peer-admin-test', muted: false);
    expect(mesh.isUserMuted('peer-admin-test'), isFalse);
    await mesh.stop();
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

  testWidgets('account privacy title unlocks admin after seven taps', (
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
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('account-privacy-entry')));
    await tester.pumpAndSettle();

    for (var index = 0; index < 7; index += 1) {
      await tester.tap(find.byKey(const ValueKey('account-privacy-title')));
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(find.text('Admin 驗證'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('admin-password-input')),
      MeshChatService.adminPasswordForNow(),
    );
    await tester.tap(find.byKey(const ValueKey('admin-login-button')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('admin-messages-section')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('admin-rooms-section')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('admin-supplies-section')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('admin-activities-section')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('admin-users-section')), findsOneWidget);
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

  test('MeshChatService manages SOS-prioritized help requests', () async {
    final mesh = MeshChatService();
    addTearDown(mesh.dispose);
    await mesh.setNetworkMode(MeshNetworkMode.online);

    expect(mesh.createHelpRequest(title: '需要急救用品', details: '黃大仙站外'), isTrue);
    expect(mesh.helpRequests, hasLength(1));
    expect(mesh.helpRequests.single.isSosActive, isFalse);

    mesh.setSosActive(true);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(mesh.helpRequests.single.isSosActive, isTrue);
    expect(mesh.helpRequests.single.title, '需要急救用品');

    mesh.markHelpRequestResolved(mesh.helpRequests.single.id);
    expect(mesh.helpRequests, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await mesh.stop();
  });

  test('MeshChatService stores exchange supply details', () async {
    final mesh = MeshChatService();
    addTearDown(mesh.dispose);
    await mesh.setNetworkMode(MeshNetworkMode.online);

    expect(
      mesh.shareSupply(
        title: '電池',
        quantity: 'AA 10粒',
        note: '中環交收',
        type: MeshSupply.exchangeType,
        exchangeFor: '飲用水',
      ),
      isTrue,
    );

    final supply = mesh.supplies.single;
    expect(supply.isExchange, isTrue);
    expect(supply.exchangeFor, '飲用水');
    expect(MeshSupply.fromMap(supply.toMap())?.isExchange, isTrue);
    await mesh.stop();
  });

  test(
    'MeshChatService limits radar activity creates and keeps only the latest',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final mesh = MeshChatService();
      addTearDown(mesh.dispose);
      await mesh.setNetworkMode(MeshNetworkMode.online);
      mesh.updateLocation(
        DeviceLocation(
          latitude: 22.3412,
          longitude: 114.1932,
          accuracyMeters: 8,
          provider: 'test',
          timestamp: DateTime.now(),
          fromCache: false,
        ),
      );

      expect(await mesh.activityCreatesRemainingToday(), 3);
      for (final entry in <(String, String)>[
        (MeshRadarActivity.mutualAidType, '鄰里互助'),
        (MeshRadarActivity.sharingType, '物資分享'),
        (MeshRadarActivity.medicalType, '健康支援'),
      ]) {
        expect(
          await mesh.createRadarActivity(
            title: entry.$2,
            details: '黃大仙集合',
            type: entry.$1,
          ),
          isTrue,
        );
      }

      expect(mesh.radarActivities, hasLength(1));
      expect(mesh.radarActivities.single.title, '健康支援');
      final localHostId = mesh.onlineUsers.single.id;
      expect(mesh.radarActivitiesForHost(localHostId), hasLength(1));
      expect(mesh.radarActivitiesForHost('unknown-host'), isEmpty);
      expect(await mesh.activityCreatesRemainingToday(), 0);
      expect(
        await mesh.createRadarActivity(
          title: '第四個活動',
          details: '',
          type: MeshRadarActivity.spiritualType,
        ),
        isFalse,
      );
      expect(mesh.status, contains('今天已建立 3 次活動'));

      final encoded = mesh.radarActivities.first.toMap();
      final decoded = MeshRadarActivity.fromMap(encoded);
      expect(decoded?.title, mesh.radarActivities.first.title);
      expect(decoded?.location.latitude, 22.3412);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('mesh.activityDailyCount'), 3);
      await mesh.stop();

      final restartedMesh = MeshChatService();
      addTearDown(restartedMesh.dispose);
      expect(await restartedMesh.activityCreatesRemainingToday(), 0);
      expect(MeshRadarActivity.supportedTypes, <String>[
        MeshRadarActivity.mutualAidType,
        MeshRadarActivity.sharingType,
        MeshRadarActivity.medicalType,
        MeshRadarActivity.spiritualType,
      ]);
    },
  );

  testWidgets('language menu switches the main UI and saves the choice', (
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
    await tester.pumpAndSettle();

    await tester.tap(find.text('社區資訊'));
    await tester.pumpAndSettle();
    expect(find.text('緊急電話'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('language-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();

    expect(find.text('Propagation Light'), findsOneWidget);
    expect(find.text('Network'), findsOneWidget);
    expect(find.text('Community'), findsOneWidget);
    expect(find.byTooltip('Language'), findsOneWidget);
    expect(find.text('emergency phone'), findsOneWidget);
    expect(find.text('community lifebuoy'), findsOneWidget);
    expect(find.text('緊急電話'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('language-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('简体中文'));
    await tester.pumpAndSettle();

    expect(find.text('紧急电话'), findsOneWidget);
    expect(find.text('社区救生圈'), findsOneWidget);
    expect(find.text('emergency phone'), findsNothing);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('app.language'), 'zh-Hans');
  });

  testWidgets('saved simplified Chinese localizes full page content', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'app.language': 'zh-Hans',
      'mesh.eulaAcceptedAt': DateTime.utc(2026).toIso8601String(),
    });
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const PropagationLightApp(autoStart: false, enableWebView: false),
    );
    await tester.pumpAndSettle();

    expect(find.text('传播光'), findsOneWidget);
    expect(find.text('光之网络'), findsOneWidget);
    expect(
      find.textContaining('MESH 自动连接会扫 Wi‑Fi Direct app peers'),
      findsOneWidget,
    );
    expect(find.byTooltip('语言'), findsOneWidget);

    await tester.tap(find.text('社区资讯'));
    await tester.pumpAndSettle();
    expect(find.text('紧急电话'), findsOneWidget);
    expect(find.text('社区救生圈'), findsOneWidget);
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
    expect(find.text('在線'), findsOneWidget);
    expect(find.text('求助'), findsOneWidget);
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

    final activeRoomName = tester.widget<LocalizedText>(
      find.byKey(const ValueKey('active-room-name')),
    );
    expect(activeRoomName.data, '測試光團');

    final messageInput = tester.widget<TextField>(
      find.byKey(const ValueKey('chat-message-input')),
    );
    expect(messageInput.decoration?.hintText, '傳送到 測試光團');

    await tester.enterText(
      find.byKey(const ValueKey('chat-message-input')),
      '可複製留言',
    );
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate(
        (widget) => widget is SelectableText && widget.data == '可複製留言',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('求助'));
    await tester.pumpAndSettle();

    expect(find.text('尋找求助'), findsOneWidget);
    expect(find.text('新增求助'), findsOneWidget);

    await tester.tap(find.text('新增求助'));
    await tester.pumpAndSettle();

    expect(find.text('需要甚麼協助'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('help-title-input')),
      '需要輪椅協助',
    );
    await tester.enterText(
      find.byKey(const ValueKey('help-details-input')),
      '黃大仙站 A 出口',
    );
    await tester.tap(find.text('發布求助'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('help-list-button')));
    await tester.pumpAndSettle();

    expect(find.text('求助列表'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('help-search-input')),
      '輪椅',
    );
    await tester.pumpAndSettle();
    expect(find.text('需要輪椅協助'), findsOneWidget);
    expect(find.textContaining('黃大仙站 A 出口'), findsOneWidget);

    await tester.tap(find.byTooltip('關閉'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('物資'));
    await tester.pumpAndSettle();

    expect(find.text('找物資'), findsOneWidget);
    expect(find.text('分享 / 交換'), findsOneWidget);

    await tester.tap(find.text('分享 / 交換'));
    await tester.pumpAndSettle();

    expect(find.text('物資名稱'), findsOneWidget);
    expect(find.text('免費分享'), findsOneWidget);
    expect(find.text('交換物資'), findsOneWidget);

    await tester.tap(find.text('交換物資'));
    await tester.pumpAndSettle();
    expect(find.text('希望交換物資'), findsOneWidget);

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
    await tester.enterText(
      find.byKey(const ValueKey('supply-exchange-for-input')),
      '飲用水',
    );
    await tester.pump();
    await tester.tap(find.text('發布交換'));
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
    expect(find.textContaining('希望交換：飲用水'), findsOneWidget);

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
    expect(
      find.byKey(const ValueKey('create-radar-activity-button')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('create-radar-activity-button')),
    );
    await tester.pumpAndSettle();
    expect(find.text('正在定位，定位完成後請再開活動。'), findsOneWidget);

    await tester.tap(find.text('社區資訊'));
    await tester.pumpAndSettle();

    expect(find.text('社區資訊'), findsWidgets);
    expect(find.text('社區救生圈'), findsOneWidget);
    expect(find.text('社區共鳴牆'), findsOneWidget);
    expect(find.text('守望地圖'), findsOneWidget);
    expect(find.text('SOS 燈'), findsOneWidget);
    expect(find.text('https://www.aieco.hk'), findsNothing);
  });

  testWidgets('network page exposes four user support links', (
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
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('network-user-support')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('whatsapp-support-button')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('line-support-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('whatsapp-group-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('qq-channel-button')), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is FaIcon && widget.icon == FontAwesomeIcons.qq.data,
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('WhatsApp 查詢'), findsOneWidget);
    expect(find.byTooltip('LINE 聯絡'), findsOneWidget);
    expect(find.byTooltip('WhatsApp 群組'), findsOneWidget);
    expect(find.byTooltip('QQ 頻道'), findsOneWidget);

    expect(
      whatsAppSupportUrl,
      'https://wa.me/+85262112160?text=%E6%83%B3%E6%9F%A5%E8%A9%A2%E5%85%89%E7%B6%B2%E6%94%AF%E6%8F%B4',
    );
    expect(lineSupportUrl, 'https://line.me/ti/p/7elEusTH6q');
    expect(
      whatsAppGroupUrl,
      'https://chat.whatsapp.com/IfrUPp6JksiGPKboEplvgm?s=cl&p=a&ilr=0',
    );
    expect(qqChannelUrl, 'https://pd.qq.com/s/fasn44zz5?b=5');
  });

  testWidgets('chat and radar tools fit a narrow phone layout', (
    WidgetTester tester,
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

    expect(find.text('求助'), findsOneWidget);
    await tester.tap(find.text('求助'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('create-help-button')), findsOneWidget);

    final toolTabs =
        tester.widget(find.byKey(const ValueKey('chat-tools-tabs')))
            as SegmentedButton;
    expect(toolTabs.style?.textStyle?.resolve(<WidgetState>{})?.fontSize, 11);

    await tester.tap(find.text('光之雷達').first);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('create-radar-activity-button')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('English chat tool tabs fit a narrow phone layout', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'app.language': 'en',
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
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Channel'));
    await tester.pumpAndSettle();

    expect(find.text('Online'), findsOneWidget);
    expect(find.text('Help'), findsOneWidget);
    expect(find.text('Groups'), findsOneWidget);
    expect(find.text('Supplies'), findsOneWidget);
    expect(find.text('Find'), findsOneWidget);
    final toolTabs =
        tester.widget(find.byKey(const ValueKey('chat-tools-tabs')))
            as SegmentedButton;
    expect(toolTabs.style?.textStyle?.resolve(<WidgetState>{})?.fontSize, 9);
    expect(tester.takeException(), isNull);
  });
}
