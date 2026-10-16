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

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    peer = await _TcpOnlyPeer.start();
    mesh = MeshChatService();
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
}

Future<void> _waitForPeer(MeshChatService mesh) async {
  bool present() => mesh.peers.any((peer) => peer.id == _TcpOnlyPeer.nodeId);
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
  final _sockets = <Socket>{};
  final received = <Map<String, dynamic>>[];
  bool respondToHello = true;

  Stream<Map<String, dynamic>> get packets => _packets.stream;

  static Future<_TcpOnlyPeer> start() async {
    final peer = _TcpOnlyPeer(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    peer.server.listen(peer._accept);
    return peer;
  }

  void _accept(Socket socket) {
    _sockets.add(socket);
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) async {
            final packet = jsonDecode(line) as Map<String, dynamic>;
            received.add(packet);
            _packets.add(packet);
            if (respondToHello &&
                packet['kind'] == 'aieco.light.hello.v1' &&
                packet['helloReply'] != true) {
              await sendHello(heartbeat: packet['heartbeat'] == true);
            }
          },
          onDone: () {
            _sockets.remove(socket);
            socket.destroy();
          },
          onError: (Object error) => socket.destroy(),
        );
  }

  Future<void> sendHello({bool heartbeat = true, bool reply = true}) async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      MeshChatService.tcpPort,
      timeout: const Duration(seconds: 2),
    );
    socket.writeln(
      jsonEncode(<String, Object?>{
        'kind': 'aieco.light.hello.v1',
        'app': 'AIECO.HK 傳播光',
        'nodeId': nodeId,
        'name': 'HK1234567',
        'tcpPort': server.port,
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
  }
}
