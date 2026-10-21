import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aieco_mesh/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MeshChatService mesh;
  late _TcpOnlyPeer peer;
  int? stalledPort;
  Completer<Socket>? stalledConnection;
  final failNextConnection = <int>{};
  final unavailablePorts = <int>{};

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    peer = await _TcpOnlyPeer.start();
    stalledPort = null;
    stalledConnection = null;
    failNextConnection.clear();
    unavailablePorts.clear();
    mesh = MeshChatService(
      lanBindAddress: InternetAddress.loopbackIPv4,
      enableUdpDiscovery: false,
      connectLanSocket: (host, port) {
        if (port == stalledPort) return stalledConnection!.future;
        if (unavailablePorts.contains(port) ||
            failNextConnection.remove(port)) {
          return Future<Socket>.error(
            const SocketException('Transient failure'),
          );
        }
        return Socket.connect(host, port, timeout: const Duration(seconds: 2));
      },
    );
    await mesh.start();
    expect(mesh.isRunning, isTrue, reason: mesh.status);
    final discovered = _waitForPeer(mesh);
    await peer.sendHello();
    await discovered;
  });

  tearDown(() async {
    await mesh.stop();
    mesh.dispose();
    await peer.close();
  });

  WifiP2pPeer lanPeer({bool isAppPeer = true, int? port}) => WifiP2pPeer(
    name: 'Bonjour Android',
    address: '127.0.0.1:${port ?? peer.server.port}',
    status: 3,
    statusText: '可連接',
    isGroupOwner: false,
    isAppPeer: isAppPeer,
    host: '127.0.0.1',
    port: port ?? peer.server.port,
  );

  test(
    'Bonjour endpoint establishes TCP presence and chat without UDP',
    () async {
      await mesh.stop();
      await mesh.start();
      expect(mesh.peers, isEmpty);

      final discovered = _waitForPeer(mesh);
      await mesh.syncDiscoveredLanPeers([lanPeer()]);
      await discovered;
      expect(mesh.peers.single.id, _TcpOnlyPeer.nodeId);

      final incoming = peer.packets.firstWhere(
        (packet) => packet['kind'] == 'aieco.light.chat.v1',
      );
      expect(await mesh.sendMessage('Bonjour LAN chat'), isTrue);
      expect(
        (await incoming.timeout(const Duration(seconds: 2)))['text'],
        'Bonjour LAN chat',
      );
    },
  );

  test(
    'Bonjour scans require a remote hello and throttle duplicate endpoints',
    () async {
      await mesh.stop();
      await mesh.start();
      peer.respondToHello = false;
      final before = peer.received.length;
      final hello = peer.packets.firstWhere(
        (packet) => packet['kind'] == 'aieco.light.hello.v1',
      );
      await mesh.syncDiscoveredLanPeers([lanPeer(), lanPeer()]);
      await hello.timeout(const Duration(seconds: 2));
      await mesh.syncDiscoveredLanPeers([lanPeer()]);
      expect(mesh.peers, isEmpty);
      expect(peer.received.skip(before), hasLength(1));

      // A transport restart must allow retrying the same advertised endpoint.
      await mesh.stop();
      await mesh.start();
      peer.respondToHello = true;
      final discovered = _waitForPeer(mesh);
      await mesh.syncDiscoveredLanPeers([lanPeer()]);
      await discovered;
    },
  );

  test(
    'Bonjour discovery respects transport readiness and app identity',
    () async {
      await mesh.stop();
      await mesh.start();
      final before = peer.received.length;
      await mesh.syncDiscoveredLanPeers([lanPeer(isAppPeer: false)]);
      await mesh.syncDiscoveredLanPeers([
        lanPeer(port: 0),
        lanPeer(port: 65536),
      ]);
      mesh.setOfflineTransportMode(WifiTransportMode.wifi, ready: false);
      await mesh.syncDiscoveredLanPeers([lanPeer()]);
      mesh.setOfflineTransportMode(WifiTransportMode.bluetooth, ready: true);
      await mesh.syncDiscoveredLanPeers([lanPeer()]);
      await mesh.stop();
      await mesh.syncDiscoveredLanPeers([lanPeer()]);
      expect(peer.received.length, before);
      expect(mesh.isRunning, isFalse);
    },
  );

  test(
    'a stalled Bonjour endpoint does not block a healthy endpoint',
    () async {
      await mesh.stop();
      await mesh.start();
      stalledPort = peer.server.port == 65535 ? 65534 : peer.server.port + 1;
      stalledConnection = Completer<Socket>();
      final discovered = _waitForPeer(mesh);
      final syncing = mesh.syncDiscoveredLanPeers([
        lanPeer(port: stalledPort),
        lanPeer(),
      ]);
      try {
        await discovered.timeout(const Duration(seconds: 2));
        expect(stalledConnection!.isCompleted, isFalse);
      } finally {
        stalledConnection!.completeError(const SocketException('Peer offline'));
        await syncing;
      }
    },
  );

  test('TCP heartbeat restores presence without UDP discovery', () async {
    final stalePeer = mesh.peers.single;
    stalePeer.lastSeen = DateTime.now().subtract(const Duration(seconds: 30));
    expect(mesh.peers, isEmpty);

    final heartbeat = peer.packets.firstWhere(
      (packet) => packet['heartbeat'] == true,
    );
    final restored = _waitForPeer(mesh);
    await mesh.refreshNetworkPresence();

    final packet = await heartbeat.timeout(const Duration(seconds: 5));
    await restored;
    expect(packet['rooms'], isNull);
    expect(packet['activities'], isNull);
    expect(packet['helloReply'], isNull);
    expect(mesh.peers.single.id, _TcpOnlyPeer.nodeId);
    expect(
      stalePeer.lastSeen.isAfter(
        DateTime.now().subtract(const Duration(seconds: 5)),
      ),
      isTrue,
    );
    expect(
      peer.received.every((packet) => packet['kind'] == 'aieco.light.hello.v1'),
      isTrue,
    );
  });

  test('sending a TCP heartbeat alone does not mark a peer online', () async {
    peer.respondToHello = false;
    final stalePeer = mesh.peers.single;
    final oldLastSeen = DateTime.now().subtract(const Duration(seconds: 30));
    stalePeer.lastSeen = oldLastSeen;

    final heartbeat = peer.packets.firstWhere(
      (packet) => packet['heartbeat'] == true,
    );
    await mesh.refreshNetworkPresence();
    await heartbeat.timeout(const Duration(seconds: 5));

    expect(stalePeer.lastSeen, oldLastSeen);
    expect(mesh.peers, isEmpty);
  });

  test(
    'incoming heartbeat gets a compact reply without a state sync',
    () async {
      final reply = peer.packets.firstWhere(
        (packet) => packet['helloReply'] == true,
      );
      await peer.sendHello(reply: false);
      final packet = await reply.timeout(const Duration(seconds: 5));

      expect(packet['heartbeat'], isTrue);
      expect(packet['rooms'], isNull);
      expect(packet['activities'], isNull);
      expect(
        peer.received.every(
          (packet) => packet['kind'] == 'aieco.light.hello.v1',
        ),
        isTrue,
      );
    },
  );

  test('transport rejoin reconnects known TCP endpoints without UDP', () async {
    final hello = peer.packets.firstWhere(
      (packet) =>
          packet['kind'] == 'aieco.light.hello.v1' &&
          packet['heartbeat'] != true,
    );
    await mesh.refreshNetworkPresence(forceRejoin: true);
    await hello.timeout(const Duration(seconds: 5));
    await _waitForPeer(mesh);

    expect(mesh.isRunning, isTrue);
    expect(mesh.peers.single.id, _TcpOnlyPeer.nodeId);
  });

  for (final mode in WifiTransportMode.values) {
    test(
      '$mode delivers chat while an earlier peer is still connecting',
      () async {
        mesh.setOfflineTransportMode(mode, ready: true);
        await peer.sendHello();
        await _waitForPeer(mesh);
        stalledPort = peer.server.port + 1;
        stalledConnection = Completer<Socket>();
        // The stale endpoint is first in insertion order, ahead of the receiver.
        mesh.peers.single.port = stalledPort!;
        await peer.sendHello(id: 'healthy-peer');
        await _waitForPeer(mesh, id: 'healthy-peer');

        final incoming = peer.packets.firstWhere(
          (packet) => packet['kind'] == 'aieco.light.chat.v1',
        );
        final sending = mesh.sendMessage('即時訊息測試');
        try {
          final packet = await incoming.timeout(const Duration(seconds: 1));
          expect(packet['text'], '即時訊息測試');
          expect(stalledConnection!.isCompleted, isFalse);
        } finally {
          stalledConnection!.completeError(
            const SocketException('Peer offline'),
          );
          await sending;
        }
      },
    );
  }

  test('transient chat failure retries before the next history sync', () async {
    final incoming = peer.packets.firstWhere(
      (packet) => packet['kind'] == 'aieco.light.chat.v1',
    );
    failNextConnection.add(peer.server.port);
    final sending = mesh.sendMessage('快速重試測試');
    final packet = await incoming.timeout(const Duration(seconds: 1));
    expect(packet['text'], '快速重試測試');
    expect(await sending, isTrue);
    expect(
      peer.received.where((packet) => packet['kind'] == 'aieco.light.chat.v1'),
      hasLength(1),
    );
  });

  test('manual LAN reconnect preserves negotiated receipt support', () async {
    peer.supportsChatAck = true;
    await _waitForChatAckSupport(mesh, peer);
    await mesh.syncLanEndpoint(
      name: 'Android',
      host: '127.0.0.1',
      port: peer.server.port,
    );
    expect(mesh.peers.single.id, _TcpOnlyPeer.nodeId);
    expect(mesh.peers.single.supportsChatAck, isTrue);
  });

  test('failed chat is retried without a hello or history sync', () async {
    peer.supportsChatAck = true;
    await _waitForChatAckSupport(mesh, peer);
    peer.respondToHello = false;
    unavailablePorts.add(peer.server.port);
    await mesh.sendMessage('Android 傳 iOS 斷線補送');
    final messageId = mesh.messages.last.id;

    final incoming = peer.packets.firstWhere(
      (packet) => packet['messageId'] == messageId,
    );
    unavailablePorts.clear();
    final packet = await incoming.timeout(const Duration(seconds: 3));
    expect(packet['text'], 'Android 傳 iOS 斷線補送');
    expect(packet['chatAckRequested'], isTrue);
  });

  test('a compact heartbeat immediately retries an unconfirmed chat', () async {
    peer.supportsChatAck = true;
    await _waitForChatAckSupport(mesh, peer);
    peer.respondToHello = false;
    peer.dropChatAcks = 2;
    await mesh.sendMessage('兩次確認遺失後補送');
    final messageId = mesh.messages.last.id;
    final incoming = peer.packets.firstWhere(
      (packet) => packet['messageId'] == messageId,
    );
    await peer.sendHello();
    expect(
      (await incoming.timeout(const Duration(milliseconds: 800)))['messageId'],
      messageId,
    );
    // A confirmed delivery must leave the retry queue.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(
      peer.received.where((packet) => packet['messageId'] == messageId),
      hasLength(3),
    );
  });

  test('automatic transport rejoin preserves unconfirmed chat', () async {
    peer.supportsChatAck = true;
    await _waitForChatAckSupport(mesh, peer);
    unavailablePorts.add(peer.server.port);
    await mesh.sendMessage('重接後補送');
    final messageId = mesh.messages.last.id;
    final incoming = peer.packets.firstWhere(
      (packet) => packet['messageId'] == messageId,
    );
    unavailablePorts.clear();
    await mesh.refreshNetworkPresence(forceRejoin: true);
    expect(
      (await incoming.timeout(const Duration(seconds: 2)))['text'],
      '重接後補送',
    );
  });

  test(
    'explicit stop cancels a chat retry across a subsequent start',
    () async {
      stalledPort = peer.server.port;
      stalledConnection = Completer<Socket>();
      final sending = mesh.sendMessage('停止前的未送出訊息');
      await mesh.stop();
      await mesh.start();
      stalledPort = null;
      await peer.sendHello();
      await _waitForPeer(mesh);
      stalledConnection!.completeError(const SocketException('Disconnected'));
      await sending;
      expect(
        peer.received.where(
          (packet) => packet['kind'] == 'aieco.light.chat.v1',
        ),
        isEmpty,
      );
    },
  );

  test('recovery delivers more than the 20-message history window', () async {
    mesh.setOfflineTransportMode(WifiTransportMode.wifi, ready: false);
    for (var index = 0; index < 25; index++) {
      await mesh.sendMessage('離線補送 $index');
    }
    final expectedIds = mesh.messages.map((message) => message.id).toSet();
    final receivedIds = <String>{};
    final allReceived = Completer<void>();
    final subscription = peer.packets.listen((packet) {
      if (expectedIds.contains(packet['messageId'])) {
        receivedIds.add(packet['messageId'] as String);
        if (receivedIds.length == expectedIds.length &&
            !allReceived.isCompleted) {
          allReceived.complete();
        }
      }
    });
    peer.supportsChatAck = true;
    try {
      mesh.setOfflineTransportMode(WifiTransportMode.wifi, ready: true);
      await peer.sendHello();
      await allReceived.future.timeout(const Duration(seconds: 5));
      expect(receivedIds, expectedIds);
    } finally {
      await subscription.cancel();
    }
  });

  test('chat waits for Android receipt on the same TCP connection', () async {
    peer.supportsChatAck = true;
    await _waitForChatAckSupport(mesh, peer);
    peer.holdChatAcks = true;
    final incoming = peer.packets.firstWhere(
      (packet) => packet['kind'] == 'aieco.light.chat.v1',
    );
    var completed = false;
    final sending = mesh.sendMessage('iOS 傳 Android 測試').then((result) {
      completed = true;
      return result;
    });
    final packet = await incoming.timeout(const Duration(seconds: 1));
    expect(packet['chatAckRequested'], isTrue);
    expect(completed, isFalse);
    await peer.releaseChatAcks();
    expect(await sending.timeout(const Duration(seconds: 1)), isTrue);
  });

  test(
    'missing receipt retries instead of waiting 15 seconds for history',
    () async {
      peer.supportsChatAck = true;
      await _waitForChatAckSupport(mesh, peer);
      peer.dropChatAcks = 1;
      final attempts = <Map<String, dynamic>>[];
      final subscription = peer.packets.listen((packet) {
        if (packet['kind'] == 'aieco.light.chat.v1') attempts.add(packet);
      });
      try {
        expect(
          await mesh
              .sendMessage('遺失接收確認測試')
              .timeout(const Duration(seconds: 3)),
          isTrue,
        );
        expect(attempts, hasLength(2));
        expect(attempts[0]['messageId'], attempts[1]['messageId']);
        expect(mesh.status, contains('1 個節點'));
      } finally {
        await subscription.cancel();
      }
    },
  );

  test(
    'old peers still receive chat without waiting for an unsupported receipt',
    () async {
      final incoming = peer.packets.firstWhere(
        (packet) => packet['kind'] == 'aieco.light.chat.v1',
      );
      expect(
        await mesh.sendMessage('舊版相容測試').timeout(const Duration(seconds: 1)),
        isTrue,
      );
      expect((await incoming)['chatAckRequested'], isNull);
    },
  );

  test('unrelated receipts cannot falsely confirm delivery', () async {
    peer.supportsChatAck = true;
    await _waitForChatAckSupport(mesh, peer);
    peer.ackMessageIdOverride = 'different-message';
    await mesh.sendMessage('確認編號測試').timeout(const Duration(seconds: 3));
    final attempts = peer.received
        .where((packet) => packet['kind'] == 'aieco.light.chat.v1')
        .toList();
    expect(attempts, hasLength(2));
    expect(attempts[0]['messageId'], attempts[1]['messageId']);
    expect(mesh.status, contains('正在自動補送'));
  });

  test(
    'receiver acknowledges immediate receipt and deduplicates retries',
    () async {
      final packet = <String, Object?>{
        'kind': 'aieco.light.chat.v1',
        'messageId': 'iphone-chat-1',
        'senderId': _TcpOnlyPeer.nodeId,
        'senderName': 'HK1234567',
        'tcpPort': peer.server.port,
        'text': 'iPhone 即時傳入測試',
        'chatAckRequested': true,
      };
      for (var attempt = 0; attempt < 2; attempt++) {
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
          socket.writeln(jsonEncode(packet));
          await socket.flush();
          final ack =
              jsonDecode(await reply.timeout(const Duration(seconds: 1)))
                  as Map;
          expect(ack['kind'], 'aieco.light.chat_ack.v1');
          expect(ack['messageId'], 'iphone-chat-1');
          expect(mesh.incomingMessageVersion, 1);
          expect(mesh.lastIncomingMessage?.text, 'iPhone 即時傳入測試');
        } finally {
          socket.destroy();
        }
      }
    },
  );

  for (final mode in WifiTransportMode.values) {
    test(
      '$mode heartbeat receives missing chat without a reverse route',
      () async {
        mesh.setOfflineTransportMode(mode, ready: true);
        peer.supportsChatPull = true;
        peer.respondToHello = false;
        final discovered = _waitForPeer(mesh);
        await peer.sendHello();
        await discovered;
        // Allow sendHello to be handled when the peer was already present.
        final supportsPull = Completer<void>();
        void listener() {
          if (mesh.peers.any((peer) => peer.supportsChatPull) &&
              !supportsPull.isCompleted) {
            supportsPull.complete();
          }
        }

        mesh.addListener(listener);
        listener();
        await supportsPull.future.timeout(const Duration(seconds: 1));
        mesh.removeListener(listener);
        for (var index = 0; index < 25; index++) {
          peer.chatPullMessages.add({
            'kind': 'aieco.light.chat.v1',
            'messageId': 'missed-android-$index',
            'senderId': index == 0 ? 'relayed-author' : _TcpOnlyPeer.nodeId,
            'senderName': 'HK1234567',
            'text': '前景補收 $index',
            'hops': 1,
          });
        }
        final received = Completer<void>();
        void onMessages() {
          if (mesh.incomingMessageVersion == 25 && !received.isCompleted) {
            received.complete();
          }
        }

        mesh.addListener(onMessages);
        try {
          await mesh.refreshNetworkPresence();
          await received.future.timeout(
            const Duration(seconds: 6),
            onTimeout: () => fail(
              'Received ${mesh.incomingMessageVersion}; heartbeat requests: '
              '${peer.received.map((packet) => packet.keys.toList()).toList()}',
            ),
          );
          expect(mesh.messages, hasLength(25));
          expect(mesh.peers.single.id, _TcpOnlyPeer.nodeId);
          expect(mesh.peers.single.port, peer.server.port);
          expect(mesh.peers.single.supportsChatPull, isTrue);
          final caughtUp = peer.packets.firstWhere(
            (packet) =>
                packet['knownMessageIds'] is List &&
                (packet['knownMessageIds'] as List).length == 25,
          );
          await caughtUp.timeout(
            const Duration(seconds: 6),
            onTimeout: () =>
                throw StateError('No second pull: ${peer.received}'),
          );
          expect(mesh.incomingMessageVersion, 25);
        } finally {
          mesh.removeListener(onMessages);
        }
      },
    );
  }

  test(
    'chat pull returns only missing messages on the request socket',
    () async {
      peer.respondToHello = false;
      await mesh.sendMessage('已收到');
      final knownId = mesh.messages.last.id;
      for (var index = 0; index < 25; index++) {
        await mesh.sendMessage('待補收 $index');
      }
      for (var attempt = 0; attempt < 2; attempt++) {
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          MeshChatService.tcpPort,
        );
        try {
          final response = socket
              .cast<List<int>>()
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .map((line) => jsonDecode(line) as Map)
              .takeWhile(
                (packet) => packet['kind'] != 'aieco.light.chat_pull_done.v1',
              )
              .toList();
          socket.writeln(
            jsonEncode({
              'kind': 'aieco.light.hello.v1',
              'nodeId': _TcpOnlyPeer.nodeId,
              'name': 'HK1234567',
              'tcpPort': peer.server.port,
              'heartbeat': true,
              'chatPull': true,
              'chatPullRequestId': 'request-$attempt',
              'knownMessageIds': attempt == 0
                  ? [knownId]
                  : mesh.messages.map((message) => message.id).toList(),
            }),
          );
          await socket.flush();
          final packets = await response.timeout(const Duration(seconds: 2));
          expect(packets.first['helloReply'], isTrue);
          final chats = packets.where(
            (packet) => packet['kind'] == 'aieco.light.chat.v1',
          );
          expect(chats, hasLength(attempt == 0 ? 25 : 0));
          expect(
            chats.every((packet) => packet['messageId'] != knownId),
            isTrue,
          );
        } finally {
          socket.destroy();
        }
      }
    },
  );

  test(
    'history sync batches packets and sends chat before bulk data',
    () async {
      peer.respondToHello = false;
      await mesh.sendMessage('歷史訊息一');
      await mesh.sendMessage('歷史訊息二');
      final shared = peer.packets.firstWhere(
        (packet) => packet['kind'] == 'aieco.light.supply.v1',
      );
      mesh.shareSupply(title: '飲用水', quantity: '2 箱', note: '交收測試');
      await shared.timeout(const Duration(seconds: 2));

      final historyConnection = peer.batches.firstWhere(
        (batch) =>
            batch.any((packet) => packet['kind'] == 'aieco.light.chat.v1'),
      );
      await peer.sendHello(heartbeat: false, reply: false);
      final batch = await historyConnection.timeout(const Duration(seconds: 2));
      final kinds = batch.map((packet) => packet['kind']).toList();
      expect(kinds, [
        'aieco.light.room.v1',
        'aieco.light.chat.v1',
        'aieco.light.chat.v1',
        'aieco.light.supply.v1',
      ]);
      expect(batch[1]['text'], '歷史訊息一');
      expect(batch[2]['text'], '歷史訊息二');

      // A second hello immediately afterwards must not repeat the bulk sync.
      final helloHandled = Completer<void>();
      void listener() {
        if (!helloHandled.isCompleted) helloHandled.complete();
      }

      final nextPacket = peer.packets.first;
      mesh.addListener(listener);
      try {
        await peer.sendHello(heartbeat: false, reply: false);
        await helloHandled.future.timeout(const Duration(seconds: 2));
      } finally {
        mesh.removeListener(listener);
      }
      await mesh.sendMessage('新訊息');
      expect((await nextPacket)['kind'], 'aieco.light.chat.v1');
    },
  );
}

Future<void> _waitForChatAckSupport(
  MeshChatService mesh,
  _TcpOnlyPeer peer,
) async {
  final ready = Completer<void>();
  void listener() {
    if (mesh.peers.any((peer) => peer.supportsChatAck) && !ready.isCompleted) {
      ready.complete();
    }
  }

  mesh.addListener(listener);
  try {
    await peer.sendHello();
    await ready.future.timeout(const Duration(seconds: 1));
  } finally {
    mesh.removeListener(listener);
  }
}

Future<void> _waitForPeer(
  MeshChatService mesh, {
  String id = _TcpOnlyPeer.nodeId,
}) async {
  bool present() => mesh.peers.any((peer) => peer.id == id);
  if (present()) return;
  final ready = Completer<void>();
  void listener() {
    if (present() && !ready.isCompleted) ready.complete();
  }

  mesh.addListener(listener);
  try {
    await ready.future.timeout(const Duration(seconds: 5));
  } finally {
    mesh.removeListener(listener);
  }
}

// This peer deliberately has no UDP socket: all discovery and replies use TCP.
class _TcpOnlyPeer {
  _TcpOnlyPeer(this.server);

  static const nodeId = 'tcp-only-android-peer';
  final ServerSocket server;
  final _packets = StreamController<Map<String, dynamic>>.broadcast();
  final _batches = StreamController<List<Map<String, dynamic>>>.broadcast();
  final _sockets = <Socket>{};
  final received = <Map<String, dynamic>>[];
  bool respondToHello = true;
  bool supportsChatAck = false;
  bool supportsChatPull = false;
  final chatPullMessages = <Map<String, Object?>>[];
  bool holdChatAcks = false;
  int dropChatAcks = 0;
  String? ackMessageIdOverride;
  final _heldChatAcks = <Socket, String>{};

  Stream<Map<String, dynamic>> get packets => _packets.stream;
  Stream<List<Map<String, dynamic>>> get batches => _batches.stream;

  static Future<_TcpOnlyPeer> start() async {
    final peer = _TcpOnlyPeer(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    peer.server.listen(peer._accept);
    return peer;
  }

  void _accept(Socket socket) {
    _sockets.add(socket);
    final batch = <Map<String, dynamic>>[];
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) async {
            final packet = jsonDecode(line) as Map<String, dynamic>;
            batch.add(packet);
            received.add(packet);
            _packets.add(packet);
            if (supportsChatPull && packet['chatPullRequestId'] != null) {
              socket.writeln(
                jsonEncode({
                  'kind': 'aieco.light.hello.v1',
                  'nodeId': nodeId,
                  'name': 'HK1234567',
                  'tcpPort': server.port,
                  'helloReply': true,
                  'heartbeat': true,
                  'chatPull': true,
                  if (supportsChatAck) 'chatAck': true,
                }),
              );
              final knownIds = (packet['knownMessageIds'] as List).toSet();
              for (final message in chatPullMessages) {
                if (!knownIds.contains(message['messageId'])) {
                  socket.writeln(jsonEncode(message));
                }
              }
              socket.writeln(
                jsonEncode({
                  'kind': 'aieco.light.chat_pull_done.v1',
                  'requestId': packet['chatPullRequestId'],
                }),
              );
              await socket.flush();
              return;
            }
            if (packet['kind'] == 'aieco.light.chat.v1' &&
                packet['chatAckRequested'] == true) {
              if (dropChatAcks > 0) {
                dropChatAcks--;
              } else if (holdChatAcks) {
                _heldChatAcks[socket] = packet['messageId'] as String;
              } else {
                await _acknowledgeChat(socket, packet['messageId'] as String);
              }
            }
            if (respondToHello &&
                packet['kind'] == 'aieco.light.hello.v1' &&
                packet['helloReply'] != true) {
              await sendHello(heartbeat: packet['heartbeat'] == true);
            }
          },
          onDone: () {
            _batches.add(batch);
            _sockets.remove(socket);
            socket.destroy();
          },
          onError: (Object error) => socket.destroy(),
        );
  }

  Future<void> _acknowledgeChat(Socket socket, String messageId) async {
    socket.writeln(
      jsonEncode({
        'kind': 'aieco.light.chat_ack.v1',
        'messageId': ackMessageIdOverride ?? messageId,
      }),
    );
    await socket.flush();
  }

  Future<void> releaseChatAcks() async {
    holdChatAcks = false;
    for (final entry in _heldChatAcks.entries.toList()) {
      await _acknowledgeChat(entry.key, entry.value);
    }
    _heldChatAcks.clear();
  }

  Future<void> sendHello({
    bool heartbeat = true,
    bool reply = true,
    String id = nodeId,
  }) async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      MeshChatService.tcpPort,
      timeout: const Duration(seconds: 2),
    );
    socket.writeln(
      jsonEncode(<String, Object?>{
        'kind': 'aieco.light.hello.v1',
        'app': 'AIECO.HK 傳播光',
        'nodeId': id,
        'name': 'HK1234567',
        'tcpPort': server.port,
        if (supportsChatAck) 'chatAck': true,
        if (supportsChatPull) 'chatPull': true,
        if (reply) 'helloReply': true,
        if (heartbeat) 'heartbeat': true,
      }),
    );
    await socket.flush();
    await socket.close();
  }

  Future<void> close() async {
    await server.close();
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    await _packets.close();
    await _batches.close();
  }
}
