// LightNetwork: Connect
// LightChannel: Communicate
// LightRadar: Locate

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

const String _aiecoWebUrl = 'https://www.aieco.hk';
const String _launchImageAsset = 'assets/images/launch_fullscreen.png';
const String _googleMapsApiKey = String.fromEnvironment('GOOGLE_MAPS_API_KEY');
const String _googleMapsMapId = String.fromEnvironment('GOOGLE_MAPS_MAP_ID');
const String _onlineRelayUrl = String.fromEnvironment('AIECO_ONLINE_RELAY_URL');
const Duration _launchScreenDuration = Duration(milliseconds: 900);
const double _nearbyRadarMeters = 5;
const String _nearbyRadarLabel = '5 米內';
const Duration _radarTrackingInterval = Duration(seconds: 12);
const double _radarLocationUpdateThresholdMeters = 8;
const double _radarAccuracyUpdateThresholdMeters = 20;
const Duration _wirelessStatusInterval = Duration(seconds: 6);
const double _hongKongCenterLatitude = 22.3193;
const double _hongKongCenterLongitude = 114.1694;

enum MeshNetworkMode { online, offline }

void main() {
  runApp(const PropagationLightApp(showLaunchScreen: true));
}

class PropagationLightApp extends StatelessWidget {
  const PropagationLightApp({
    super.key,
    this.autoStart = true,
    this.enableWebView = true,
    this.showLaunchScreen = false,
  });

  final bool autoStart;
  final bool enableWebView;
  final bool showLaunchScreen;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF0D7C66);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '傳播光 AIECO.HK',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF7F8F4),
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          elevation: 0,
          backgroundColor: Color(0xFFF7F8F4),
          foregroundColor: Color(0xFF17211E),
        ),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Color(0xFFE0E5DE)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFFD7DED7)),
          ),
        ),
        useMaterial3: true,
      ),
      home: showLaunchScreen
          ? _LaunchGate(
              child: PropagationLightHome(
                autoStart: autoStart,
                enableWebView: enableWebView,
              ),
            )
          : PropagationLightHome(
              autoStart: autoStart,
              enableWebView: enableWebView,
            ),
    );
  }
}

class _LaunchGate extends StatefulWidget {
  const _LaunchGate({required this.child});

  final Widget child;

  @override
  State<_LaunchGate> createState() => _LaunchGateState();
}

class _LaunchGateState extends State<_LaunchGate> {
  var _showLaunchScreen = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_launchScreenDuration, () {
      if (mounted) {
        setState(() => _showLaunchScreen = false);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _showLaunchScreen ? const _LaunchScreen() : widget.child;
  }
}

class _LaunchScreen extends StatelessWidget {
  const _LaunchScreen();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Colors.black,
      child: SizedBox.expand(
        child: Image(image: AssetImage(_launchImageAsset), fit: BoxFit.cover),
      ),
    );
  }
}

class PropagationLightHome extends StatefulWidget {
  const PropagationLightHome({
    super.key,
    required this.autoStart,
    required this.enableWebView,
  });

  final bool autoStart;
  final bool enableWebView;

  @override
  State<PropagationLightHome> createState() => _PropagationLightHomeState();
}

class _PropagationLightHomeState extends State<PropagationLightHome>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final MeshChatService _mesh;
  late final WifiMeshController _wifiMesh;
  late final LightRadarController _radar;
  late final TabController _tabController;
  final _sosLight = _SosLightController();
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _messagesScrollController = ScrollController();
  Timer? _radarTrackingTimer;
  Timer? _wirelessStatusTimer;
  bool _radarTrackingBusy = false;
  bool _wirelessStatusBusy = false;
  bool _startupPermissionsRequested = false;
  String? _lastWirelessStatusSignature;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _mesh = MeshChatService();
    _wifiMesh = WifiMeshController();
    _radar = LightRadarController();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(_handleTabChange);
    _sosLight.addListener(_handleSosLightChange);

    unawaited(_initializeMesh());
  }

  Future<void> _initializeMesh() async {
    await _mesh.loadSavedDisplayName();

    if (!mounted) {
      return;
    }

    if (widget.autoStart) {
      _scheduleStartupPermissionsRequest();
      unawaited(_mesh.start());
      unawaited(_wifiMesh.refreshStatus());
      _startWirelessStatusTracking();
      _scheduleAutomaticRadarLocation(delay: const Duration(seconds: 4));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _mesh.dispose();
    _wifiMesh.dispose();
    _radar.dispose();
    _sosLight.removeListener(_handleSosLightChange);
    _sosLight.dispose();
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    _radarTrackingTimer?.cancel();
    _wirelessStatusTimer?.cancel();
    _messageController.dispose();
    _messagesScrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.autoStart) {
      unawaited(_refreshWirelessStatusAndRejoin(forceRejoin: true));
      unawaited(_locateRadar());
    }
  }

  void _handleSosLightChange() {
    final active = _sosLight.active;
    if (_mesh.sosActive == active) {
      return;
    }

    _mesh.setSosActive(active);
    if (active) {
      unawaited(_locateRadar());
    }
  }

  void _handleTabChange() {
    if (!widget.autoStart) {
      return;
    }
    if (_tabController.index == 2) {
      unawaited(_locateRadar());
    }
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) {
      return;
    }

    _messageController.clear();
    await _mesh.sendMessage(text);
    _scrollMessagesToEnd();
  }

  Future<void> _createRoom() async {
    final roomName = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        var draftName = '';

        return StatefulBuilder(
          builder: (context, setDialogState) {
            final cleanName = draftName.trim();
            final canCreate = cleanName.isNotEmpty;

            void submit(String value) {
              final clean = value.trim();
              if (clean.isEmpty) {
                return;
              }
              Navigator.of(dialogContext).pop(clean);
            }

            return AlertDialog(
              title: const Text('建立光團'),
              content: TextField(
                key: const ValueKey('room-name-input'),
                autofocus: true,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: '光團名稱',
                  prefixIcon: Icon(Icons.groups_outlined),
                ),
                onChanged: (value) => setDialogState(() => draftName = value),
                onSubmitted: submit,
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
                FilledButton.icon(
                  onPressed: canCreate ? () => submit(cleanName) : null,
                  icon: const Icon(Icons.add),
                  label: const Text('建立'),
                ),
              ],
            );
          },
        );
      },
    );

    if (roomName == null) {
      return;
    }

    _mesh.createRoom(roomName);
    _scrollMessagesToEnd();
  }

  Future<void> _shareSupply() async {
    final draft = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) {
        var title = '';
        var quantity = '';
        var note = '';

        return StatefulBuilder(
          builder: (context, setDialogState) {
            final cleanTitle = title.trim();
            final canShare = cleanTitle.isNotEmpty;

            void submit() {
              if (!canShare) {
                return;
              }
              Navigator.of(dialogContext).pop(<String, String>{
                'title': cleanTitle,
                'quantity': quantity.trim(),
                'note': note.trim(),
              });
            }

            return AlertDialog(
              title: const Text('分享物資'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    key: const ValueKey('supply-title-input'),
                    autofocus: true,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: '物資名稱',
                      prefixIcon: Icon(Icons.inventory_2_outlined),
                    ),
                    onChanged: (value) => setDialogState(() => title = value),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    key: const ValueKey('supply-quantity-input'),
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: '數量 / 狀態',
                      prefixIcon: Icon(Icons.format_list_numbered),
                    ),
                    onChanged: (value) =>
                        setDialogState(() => quantity = value),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    key: const ValueKey('supply-note-input'),
                    minLines: 2,
                    maxLines: 3,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      labelText: '備註 / 交收位置',
                      prefixIcon: Icon(Icons.place_outlined),
                    ),
                    onChanged: (value) => setDialogState(() => note = value),
                    onSubmitted: (_) => submit(),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
                FilledButton.icon(
                  onPressed: canShare ? submit : null,
                  icon: const Icon(Icons.volunteer_activism_outlined),
                  label: const Text('分享'),
                ),
              ],
            );
          },
        );
      },
    );

    if (draft == null) {
      return;
    }

    _mesh.shareSupply(
      title: draft['title'] ?? '',
      quantity: draft['quantity'] ?? '',
      note: draft['note'] ?? '',
    );
  }

  Future<void> _wakeMeshAfterWifiReady() async {
    if (_mesh.networkMode != MeshNetworkMode.offline) {
      await _mesh.setNetworkMode(MeshNetworkMode.offline);
    }
    await _mesh.refreshNetworkPresence(forceRejoin: true);
    for (final delay in const [
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
    ]) {
      unawaited(
        Future<void>.delayed(delay).then((_) {
          if (!mounted) {
            return;
          }
          unawaited(_mesh.refreshNetworkPresence());
        }),
      );
    }
  }

  Future<void> _wakeMeshAfterPeerReady(WifiP2pPeer peer) async {
    await _wakeMeshAfterWifiReady();
    if (peer.hasLanEndpoint) {
      await _mesh.syncLanPeer(peer);
    }
  }

  void _scheduleStartupPermissionsRequest() {
    if (_startupPermissionsRequested) {
      return;
    }

    _startupPermissionsRequested = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.autoStart) {
        return;
      }
      unawaited(_requestStartupPermissions());
    });
  }

  Future<void> _requestStartupPermissions() async {
    await _wifiMesh.requestPermissions(automatic: true);

    for (final delay in const [
      Duration(milliseconds: 800),
      Duration(seconds: 3),
      Duration(seconds: 7),
    ]) {
      unawaited(
        Future<void>.delayed(delay).then((_) {
          if (!mounted || !widget.autoStart) {
            return;
          }
          unawaited(_refreshWirelessStatusAndRejoin(forceRejoin: true));
        }),
      );
    }
  }

  void _startWirelessStatusTracking() {
    if (_wirelessStatusTimer != null) {
      return;
    }

    unawaited(_refreshWirelessStatusAndRejoin());
    _wirelessStatusTimer = Timer.periodic(_wirelessStatusInterval, (_) {
      if (mounted) {
        unawaited(_refreshWirelessStatusAndRejoin());
      }
    });
  }

  Future<void> _refreshWirelessStatusAndRejoin({
    bool forceRejoin = false,
  }) async {
    if (_wirelessStatusBusy || !widget.autoStart) {
      return;
    }

    _wirelessStatusBusy = true;
    try {
      final previousSignature = _lastWirelessStatusSignature;
      await _wifiMesh.refreshStatus(quiet: true);
      final nextSignature = _wirelessStatusSignature();
      _lastWirelessStatusSignature = nextSignature;

      final wirelessReady =
          _wifiMesh.boundToWifi ||
          _wifiMesh.boundToBluetooth ||
          _wifiMesh.connection?.groupFormed == true ||
          _wifiMesh.hotspot != null;
      final networkChanged =
          previousSignature != null && previousSignature != nextSignature;

      if (forceRejoin || (wirelessReady && networkChanged)) {
        await _mesh.refreshNetworkPresence(forceRejoin: true);
      } else if (wirelessReady && _mesh.isRunning) {
        await _mesh.refreshNetworkPresence();
      }
    } finally {
      _wirelessStatusBusy = false;
    }
  }

  String _wirelessStatusSignature() {
    final connection = _wifiMesh.connection;
    final group = _wifiMesh.group;
    final hotspot = _wifiMesh.hotspot;
    return [
      _wifiMesh.wifiEnabled,
      _wifiMesh.bluetoothEnabled,
      _wifiMesh.boundToWifi,
      _wifiMesh.boundToBluetooth,
      _wifiMesh.networkGeneration,
      connection?.groupFormed ?? false,
      connection?.isGroupOwner ?? false,
      connection?.groupOwnerAddress ?? '',
      group?.networkName ?? '',
      hotspot?.ssid ?? '',
    ].join('|');
  }

  void _scheduleAutomaticRadarLocation({Duration delay = Duration.zero}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.autoStart) {
        return;
      }
      if (delay > Duration.zero) {
        unawaited(
          Future<void>.delayed(delay).then((_) {
            if (!mounted || !widget.autoStart) {
              return;
            }
            unawaited(_locateRadar());
          }),
        );
        return;
      }
      unawaited(_locateRadar());
    });
  }

  Future<void> _locateRadar() async {
    final location = await _refreshRadarLocation();
    if (location != null) {
      _startRadarTracking();
    }
  }

  void _startRadarTracking() {
    if (_radarTrackingTimer != null) {
      return;
    }

    _radarTrackingTimer = Timer.periodic(_radarTrackingInterval, (_) {
      if (mounted) {
        unawaited(_refreshRadarLocation(quiet: true));
      }
    });
  }

  Future<DeviceLocation?> _refreshRadarLocation({bool quiet = false}) async {
    if (_radarTrackingBusy) {
      return null;
    }

    _radarTrackingBusy = true;
    try {
      final location = await _radar.locate(_mesh.displayName, quiet: quiet);
      if (location != null &&
          _shouldReplaceLocation(_mesh.myLocation, location)) {
        _mesh.updateLocation(location);
      }
      return location;
    } finally {
      _radarTrackingBusy = false;
    }
  }

  void _scrollMessagesToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_messagesScrollController.hasClients) {
        return;
      }

      _messagesScrollController.animateTo(
        _messagesScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  void _quoteContactNameForChat(String contactName) {
    final mention = '@$contactName ';
    final currentText = _messageController.text;
    final separator =
        currentText.isEmpty || RegExp(r'\s$').hasMatch(currentText) ? '' : ' ';
    final nextText = '$currentText$separator$mention';

    _messageController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextText.length),
    );
    _tabController.animateTo(1);
    _scrollMessagesToEnd();
  }

  void _openCommunityNetwork() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CommunityNetworkPage(enabled: widget.enableWebView),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_mesh, _wifiMesh, _radar]),
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '傳播光',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                ),
                Text(
                  'AIECO.HK 線上 / 離線光之網絡',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: _mesh.isRunning
                    ? '停止節點'
                    : _mesh.networkMode == MeshNetworkMode.online
                    ? '啟動線上光網'
                    : '啟動離線節點',
                onPressed: () {
                  if (_mesh.isRunning) {
                    _mesh.stop();
                  } else {
                    unawaited(_mesh.start());
                  }
                },
                icon: Icon(
                  _mesh.isRunning
                      ? Icons.power_settings_new
                      : _mesh.networkMode == MeshNetworkMode.online
                      ? Icons.public
                      : Icons.wifi,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: TextButton.icon(
                  onPressed: _openCommunityNetwork,
                  icon: const Icon(Icons.language_outlined, size: 18),
                  label: const Text(
                    '社區網絡',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF17211E),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 40),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _SosLightButton(controller: _sosLight),
              ),
            ],
            bottom: TabBar(
              controller: _tabController,
              tabs: const [
                Tab(icon: Icon(Icons.hub_outlined), text: '光之網絡'),
                Tab(icon: Icon(Icons.forum_outlined), text: '光之通道'),
                Tab(icon: Icon(Icons.radar), text: '光之雷達'),
              ],
            ),
          ),
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isNetworkWide = constraints.maxWidth >= 860;
                final sidePanel = _StatusAndPeersPanel(mesh: _mesh);
                final wifiPanel = _WifiMeshPanel(
                  controller: _wifiMesh,
                  onNetworkReady: _wakeMeshAfterWifiReady,
                  onPeerReady: _wakeMeshAfterPeerReady,
                  scrollInternally: isNetworkWide,
                );
                final chatPanel = _ChatPanel(
                  mesh: _mesh,
                  messageController: _messageController,
                  scrollController: _messagesScrollController,
                  onSend: _sendMessage,
                  onCreateRoom: _createRoom,
                  onShareSupply: _shareSupply,
                  onQuoteUserName: _quoteContactNameForChat,
                );
                final radarPanel = _LightRadarPanel(
                  mesh: _mesh,
                  radar: _radar,
                  enableWebView: widget.enableWebView,
                  onLocate: () => unawaited(_locateRadar()),
                  onQuoteContactName: _quoteContactNameForChat,
                );

                return TabBarView(
                  controller: _tabController,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    _NetworkTabPage(
                      sidePanel: sidePanel,
                      wifiPanel: wifiPanel,
                      maxWidth: constraints.maxWidth,
                    ),
                    _ChatTabPage(chatPanel: chatPanel),
                    _RadarTabPage(radarPanel: radarPanel),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _NetworkTabPage extends StatelessWidget {
  const _NetworkTabPage({
    required this.sidePanel,
    required this.wifiPanel,
    required this.maxWidth,
  });

  final Widget sidePanel;
  final Widget wifiPanel;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final isWide = maxWidth >= 860;

    if (isWide) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Row(
          children: [
            SizedBox(width: 320, child: sidePanel),
            const SizedBox(width: 16),
            Expanded(child: wifiPanel),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: ListView(
        children: [sidePanel, const SizedBox(height: 12), wifiPanel],
      ),
    );
  }
}

class _ChatTabPage extends StatelessWidget {
  const _ChatTabPage({required this.chatPanel});

  final Widget chatPanel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: chatPanel,
    );
  }
}

class _RadarTabPage extends StatelessWidget {
  const _RadarTabPage({required this.radarPanel});

  final Widget radarPanel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: radarPanel,
    );
  }
}

class _LightRadarPanel extends StatefulWidget {
  const _LightRadarPanel({
    required this.mesh,
    required this.radar,
    required this.enableWebView,
    required this.onLocate,
    required this.onQuoteContactName,
  });

  final MeshChatService mesh;
  final LightRadarController radar;
  final bool enableWebView;
  final VoidCallback onLocate;
  final ValueChanged<String> onQuoteContactName;

  @override
  State<_LightRadarPanel> createState() => _LightRadarPanelState();
}

enum _RadarMapMode { online, offline }

class _LightRadarPanelState extends State<_LightRadarPanel> {
  String? _selectedContactId;
  var _selectedContactFocusVersion = 0;
  var _mapMode = _googleMapsApiKey.isEmpty
      ? _RadarMapMode.offline
      : _RadarMapMode.online;

  void _selectContact(String? contactId) {
    setState(() {
      _selectedContactId = contactId;
      if (contactId != null) {
        _selectedContactFocusVersion += 1;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final location = widget.radar.location;
    final contacts = widget.mesh.radarContacts;
    final contactIds = contacts.map((contact) => contact.id).toSet();
    final selectedContactId = contactIds.contains(_selectedContactId)
        ? _selectedContactId
        : null;
    final effectiveMapMode =
        _mapMode == _RadarMapMode.online && widget.enableWebView
        ? _RadarMapMode.online
        : _RadarMapMode.offline;
    final nearbyContacts = widget.mesh.radarContactsWithin(_nearbyRadarMeters);
    final nearbyContactIds = nearbyContacts
        .map((contact) => contact.id)
        .toSet();
    final sosContacts =
        contacts.where((contact) => contact.isSosActive).toList()..sort((a, b) {
          if (a.isMe == b.isMe) {
            return a.name.compareTo(b.name);
          }
          return a.isMe ? -1 : 1;
        });
    final closestContacts = _closestRadarContacts(
      contacts: contacts,
      currentLocation: widget.mesh.myLocation,
      limit: 10,
    );
    final nearbyCount = nearbyContacts.length;
    final radarMapSignature = _radarMapSignature(
      location: location,
      contacts: contacts,
      nearbyContactIds: nearbyContactIds,
      selectedContactId: selectedContactId,
    );

    return Card(
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFFE0E5DE))),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.radar, color: Color(0xFF0D7C66)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '光之雷達',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          Text(
                            sosContacts.isNotEmpty
                                ? '求救光點 ${sosContacts.length} 個'
                                : nearbyCount == 0
                                ? effectiveMapMode == _RadarMapMode.online
                                      ? '線上 Google Map'
                                      : '離線局部地圖'
                                : '$_nearbyRadarLabel $nearbyCount 個光點',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: sosContacts.isNotEmpty
                                      ? const Color(0xFFB00020)
                                      : const Color(0xFF66756D),
                                  fontWeight: sosContacts.isNotEmpty
                                      ? FontWeight.w800
                                      : null,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Chip(
                      avatar: const Icon(Icons.person_pin_circle, size: 16),
                      label: Text(widget.mesh.displayName),
                      side: const BorderSide(color: Color(0xFFD7DED7)),
                      backgroundColor: const Color(0xFFE0F2E9),
                      visualDensity: VisualDensity.compact,
                    ),
                    SegmentedButton<_RadarMapMode>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment<_RadarMapMode>(
                          value: _RadarMapMode.online,
                          icon: Icon(Icons.public, size: 16),
                          label: Text('線上'),
                        ),
                        ButtonSegment<_RadarMapMode>(
                          value: _RadarMapMode.offline,
                          icon: Icon(Icons.map_outlined, size: 16),
                          label: Text('離線'),
                        ),
                      ],
                      selected: {_mapMode},
                      onSelectionChanged: (selection) {
                        final mode = selection.single;
                        setState(() => _mapMode = mode);
                      },
                    ),
                    FilledButton.icon(
                      onPressed: widget.radar.busy ? null : widget.onLocate,
                      icon: widget.radar.busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.my_location),
                      label: const Text('定位'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: effectiveMapMode == _RadarMapMode.online
                  ? _OnlineGoogleRadarMap(
                      enabled: widget.enableWebView,
                      apiKey: _googleMapsApiKey,
                      mapId: _googleMapsMapId,
                      displayName: widget.mesh.displayName,
                      location: location,
                      contacts: contacts,
                      nearbyContactIds: nearbyContactIds,
                      selectedContactId: selectedContactId,
                      selectedContactFocusVersion: _selectedContactFocusVersion,
                      onSelectedContactChanged: _selectContact,
                      onQuoteContactName: widget.onQuoteContactName,
                    )
                  : _OfflineHongKongMap(
                      location: location,
                      contacts: contacts,
                      nearbyContactIds: nearbyContactIds,
                      refreshSignature: radarMapSignature,
                      selectedContactId: selectedContactId,
                      selectedContactFocusVersion: _selectedContactFocusVersion,
                      onSelectedContactChanged: _selectContact,
                      onQuoteContactName: widget.onQuoteContactName,
                    ),
            ),
          ),
          _ClosestRadarStrip(
            contacts: closestContacts,
            currentLocation: widget.mesh.myLocation,
            selectedContactId: selectedContactId,
            onSelectedContact: _selectContact,
            onQuoteContactName: widget.onQuoteContactName,
          ),
          _SosRadarStrip(
            contacts: sosContacts,
            currentLocation: widget.mesh.myLocation,
            selectedContactId: selectedContactId,
            onSelectedContact: _selectContact,
            onQuoteContactName: widget.onQuoteContactName,
          ),
          _DistrictRadarReport(
            contacts: contacts,
            currentLocation: widget.mesh.myLocation,
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: _RadarStatus(
              location: location,
              message: widget.radar.message,
            ),
          ),
        ],
      ),
    );
  }
}

class _RadarStatus extends StatelessWidget {
  const _RadarStatus({required this.location, required this.message});

  final DeviceLocation? location;
  final String message;

  @override
  Widget build(BuildContext context) {
    final text = location == null
        ? message
        : '$message · ${_formatCoordinate(location!.latitude)}, '
              '${_formatCoordinate(location!.longitude)}'
              ' · +/- ${location!.accuracyMeters.round()}m';

    return Row(
      children: [
        const Icon(Icons.satellite_alt_outlined, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: const Color(0xFF4B5F56)),
          ),
        ),
      ],
    );
  }

  static String _formatCoordinate(double value) {
    return value.toStringAsFixed(5);
  }
}

class _ClosestRadarStrip extends StatelessWidget {
  const _ClosestRadarStrip({
    required this.contacts,
    required this.currentLocation,
    required this.selectedContactId,
    required this.onSelectedContact,
    required this.onQuoteContactName,
  });

  final List<RadarContact> contacts;
  final DeviceLocation? currentLocation;
  final String? selectedContactId;
  final ValueChanged<String> onSelectedContact;
  final ValueChanged<String> onQuoteContactName;

  @override
  Widget build(BuildContext context) {
    final location = currentLocation;
    const label = '最近10個光點';

    return Container(
      height: 50,
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      child: Row(
        children: [
          Chip(
            avatar: const Icon(Icons.near_me_outlined, size: 16),
            label: Text(label),
            side: const BorderSide(color: Color(0xFFD7DED7)),
            backgroundColor: const Color(0xFFFAFBF7),
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: contacts.isEmpty
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      location == null ? '定位後顯示最近光點' : '未見其他光點',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF66756D),
                      ),
                    ),
                  )
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: contacts.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, index) {
                      final contact = contacts[index];
                      final distance = location == null
                          ? 0.0
                          : contact.distanceFrom(location);
                      final isSelected = contact.id == selectedContactId;

                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ActionChip(
                            avatar: Icon(
                              Icons.person_pin_circle,
                              size: 16,
                              color: isSelected
                                  ? const Color(0xFF0D7C66)
                                  : null,
                            ),
                            label: Text(
                              '${contact.name} ${distance.toStringAsFixed(1)}m',
                            ),
                            side: BorderSide(
                              color: isSelected
                                  ? const Color(0xFF0D7C66)
                                  : const Color(0xFFE0B8AE),
                            ),
                            backgroundColor: isSelected
                                ? const Color(0xFFE0F2E9)
                                : const Color(0xFFFFEEE9),
                            visualDensity: VisualDensity.compact,
                            onPressed: () => onSelectedContact(contact.id),
                          ),
                          const SizedBox(width: 4),
                          Tooltip(
                            message: '引用光點名稱聊天',
                            child: IconButton.filledTonal(
                              onPressed: () => onQuoteContactName(contact.name),
                              icon: const Icon(Icons.format_quote, size: 18),
                              style: IconButton.styleFrom(
                                fixedSize: const Size(32, 32),
                                minimumSize: const Size(32, 32),
                                padding: EdgeInsets.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _SosRadarStrip extends StatelessWidget {
  const _SosRadarStrip({
    required this.contacts,
    required this.currentLocation,
    required this.selectedContactId,
    required this.onSelectedContact,
    required this.onQuoteContactName,
  });

  final List<RadarContact> contacts;
  final DeviceLocation? currentLocation;
  final String? selectedContactId;
  final ValueChanged<String> onSelectedContact;
  final ValueChanged<String> onQuoteContactName;

  @override
  Widget build(BuildContext context) {
    if (contacts.isEmpty) {
      return const SizedBox.shrink();
    }

    final location = currentLocation;

    return Container(
      height: 50,
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      child: Row(
        children: [
          const Chip(
            avatar: Icon(Icons.warning_amber, size: 16),
            label: Text('求救光點'),
            side: BorderSide(color: Color(0xFFE0B8AE)),
            backgroundColor: Color(0xFFFFEEE9),
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: contacts.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final contact = contacts[index];
                final distance = location == null
                    ? null
                    : contact.distanceFrom(location);
                final isSelected = contact.id == selectedContactId;
                final label = distance == null
                    ? contact.isMe
                          ? '${contact.name}（你）'
                          : contact.name
                    : '${contact.isMe ? '${contact.name}（你）' : contact.name} ${distance.toStringAsFixed(1)}m';

                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ActionChip(
                      avatar: const Icon(Icons.warning_amber, size: 16),
                      label: Text(label),
                      side: BorderSide(
                        color: isSelected
                            ? const Color(0xFFB00020)
                            : const Color(0xFFE0B8AE),
                      ),
                      backgroundColor: isSelected
                          ? const Color(0xFFFFDAD6)
                          : const Color(0xFFFFEEE9),
                      visualDensity: VisualDensity.compact,
                      tooltip: '選取求救光點',
                      onPressed: () => onSelectedContact(contact.id),
                    ),
                    if (!contact.isMe) ...[
                      const SizedBox(width: 4),
                      Tooltip(
                        message: '引用求救光點名稱聊天',
                        child: IconButton.filledTonal(
                          onPressed: () => onQuoteContactName(contact.name),
                          icon: const Icon(Icons.format_quote, size: 18),
                          style: IconButton.styleFrom(
                            fixedSize: const Size(32, 32),
                            minimumSize: const Size(32, 32),
                            padding: EdgeInsets.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _DistrictRadarReport extends StatelessWidget {
  const _DistrictRadarReport({
    required this.contacts,
    required this.currentLocation,
  });

  final List<RadarContact> contacts;
  final DeviceLocation? currentLocation;

  @override
  Widget build(BuildContext context) {
    final report = _DistrictCrowdReport.from(
      contacts: contacts,
      currentLocation: currentLocation,
    );
    final currentDistrict = report.currentDistrictName;
    final textTheme = Theme.of(context).textTheme;
    final summary = currentLocation == null
        ? '請先定位'
        : currentDistrict == null
        ? '位置在 18 區範圍外'
        : report.sameDistrictPeerCount == 0
        ? '同區未見其他人'
        : '同區其他 ${report.sameDistrictPeerCount} 人';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFE7ECE5))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(
                Icons.stacked_bar_chart_outlined,
                size: 18,
                color: Color(0xFF0D7C66),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  currentDistrict == null ? '同區人數' : '同區人數 · $currentDistrict',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF17211E),
                  ),
                ),
              ),
              Text(
                summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF66756D),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 30,
            child: report.districtCounts.isEmpty
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '暫未收到區域人數',
                      style: textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF66756D),
                      ),
                    ),
                  )
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: report.districtCounts.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, index) {
                      final entry = report.districtCounts.entries.elementAt(
                        index,
                      );
                      final isCurrentDistrict =
                          entry.key == report.currentDistrictName;

                      return Chip(
                        avatar: Icon(
                          isCurrentDistrict
                              ? Icons.my_location
                              : Icons.person_pin_circle_outlined,
                          size: 16,
                        ),
                        label: Text('${entry.key} ${entry.value} 人'),
                        side: BorderSide(
                          color: isCurrentDistrict
                              ? const Color(0xFF0D7C66)
                              : const Color(0xFFD7DED7),
                        ),
                        backgroundColor: isCurrentDistrict
                            ? const Color(0xFFE0F2E9)
                            : const Color(0xFFFAFBF7),
                        visualDensity: VisualDensity.compact,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _DistrictCrowdReport {
  const _DistrictCrowdReport({
    required this.currentDistrictName,
    required this.sameDistrictPeerCount,
    required this.districtCounts,
  });

  factory _DistrictCrowdReport.from({
    required List<RadarContact> contacts,
    required DeviceLocation? currentLocation,
  }) {
    final currentDistrictName = currentLocation == null
        ? null
        : _districtNameForLocation(currentLocation);
    final counts = <String, int>{};
    var sameDistrictPeerCount = 0;

    for (final contact in contacts) {
      final districtName = _districtNameForLocation(contact.location);
      if (districtName == null) {
        continue;
      }

      counts[districtName] = (counts[districtName] ?? 0) + 1;
      if (!contact.isMe && districtName == currentDistrictName) {
        sameDistrictPeerCount += 1;
      }
    }

    final orderedEntries = counts.entries.toList()
      ..sort((a, b) {
        if (a.key == currentDistrictName && b.key != currentDistrictName) {
          return -1;
        }
        if (b.key == currentDistrictName && a.key != currentDistrictName) {
          return 1;
        }

        final countCompare = b.value.compareTo(a.value);
        if (countCompare != 0) {
          return countCompare;
        }

        return _districtOrder(a.key).compareTo(_districtOrder(b.key));
      });

    return _DistrictCrowdReport(
      currentDistrictName: currentDistrictName,
      sameDistrictPeerCount: sameDistrictPeerCount,
      districtCounts: Map.unmodifiable(Map.fromEntries(orderedEntries)),
    );
  }

  final String? currentDistrictName;
  final int sameDistrictPeerCount;
  final Map<String, int> districtCounts;
}

List<RadarContact> _closestRadarContacts({
  required List<RadarContact> contacts,
  required DeviceLocation? currentLocation,
  required int limit,
}) {
  if (currentLocation == null) {
    return const <RadarContact>[];
  }

  final closestContacts = contacts.where((contact) => !contact.isMe).toList()
    ..sort((a, b) {
      final distanceCompare = a
          .distanceFrom(currentLocation)
          .compareTo(b.distanceFrom(currentLocation));
      if (distanceCompare != 0) {
        return distanceCompare;
      }
      return a.name.compareTo(b.name);
    });

  return List.unmodifiable(closestContacts.take(limit));
}

String _radarMapSignature({
  required DeviceLocation? location,
  required List<RadarContact> contacts,
  required Set<String> nearbyContactIds,
  required String? selectedContactId,
}) {
  final buffer = StringBuffer();
  buffer.write('selected=');
  buffer.write(selectedContactId ?? '');
  buffer.write('|me=');
  _writeLocationSignature(buffer, location);

  final sortedNearbyIds = nearbyContactIds.toList()..sort();
  buffer.write('|near=');
  buffer.write(sortedNearbyIds.join(','));

  final sortedContacts = contacts.toList()
    ..sort((left, right) => left.id.compareTo(right.id));
  for (final contact in sortedContacts) {
    buffer
      ..write('|contact=')
      ..write(contact.id)
      ..write(':')
      ..write(contact.name)
      ..write(':')
      ..write(contact.isMe ? '1' : '0')
      ..write(':')
      ..write(contact.isSosActive ? '1' : '0')
      ..write(':')
      ..write(nearbyContactIds.contains(contact.id) ? '1' : '0')
      ..write(':');
    _writeLocationSignature(buffer, contact.location);
  }

  return buffer.toString();
}

void _writeLocationSignature(StringBuffer buffer, DeviceLocation? location) {
  if (location == null) {
    buffer.write('none');
    return;
  }

  buffer
    ..write(location.latitude.toStringAsFixed(6))
    ..write(',')
    ..write(location.longitude.toStringAsFixed(6))
    ..write(',')
    ..write(location.accuracyMeters.toStringAsFixed(1));
}

class _OfflineHongKongMap extends StatefulWidget {
  const _OfflineHongKongMap({
    required this.location,
    required this.contacts,
    required this.nearbyContactIds,
    required this.refreshSignature,
    required this.selectedContactId,
    required this.selectedContactFocusVersion,
    required this.onSelectedContactChanged,
    required this.onQuoteContactName,
  });

  final DeviceLocation? location;
  final List<RadarContact> contacts;
  final Set<String> nearbyContactIds;
  final String refreshSignature;
  final String? selectedContactId;
  final int selectedContactFocusVersion;
  final ValueChanged<String?> onSelectedContactChanged;
  final ValueChanged<String> onQuoteContactName;

  @override
  State<_OfflineHongKongMap> createState() => _OfflineHongKongMapState();
}

class _OfflineHongKongMapState extends State<_OfflineHongKongMap> {
  final TransformationController _transformationController =
      TransformationController();
  String? _selectedDistrictName;
  String? _mapScopeKey;

  @override
  void didUpdateWidget(covariant _OfflineHongKongMap oldWidget) {
    super.didUpdateWidget(oldWidget);

    final selectedContactId = widget.selectedContactId;
    final nextDistrictName = widget.location == null
        ? null
        : _districtNameForLocation(widget.location!);
    final oldDistrictName = oldWidget.location == null
        ? null
        : _districtNameForLocation(oldWidget.location!);
    if (nextDistrictName != oldDistrictName) {
      _selectedDistrictName = null;
      _mapScopeKey = null;
    }

    if (selectedContactId == null) {
      return;
    }

    final stillVisible = widget.contacts.any(
      (contact) => contact.id == selectedContactId,
    );
    if (!stillVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          widget.onSelectedContactChanged(null);
        }
      });
    }
  }

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  void _handleMapTap(
    Offset viewportPoint,
    Size mapSize,
    _MapBounds mapBounds,
    List<_DistrictShape> visibleDistricts,
  ) {
    final scenePoint = _transformationController.toScene(viewportPoint);
    final mapRect = _fitMapRect((Offset.zero & mapSize).deflate(10), mapBounds);
    final contact = _contactAt(scenePoint, mapRect, mapBounds);
    if (contact != null) {
      widget.onSelectedContactChanged(contact.id);
      return;
    }

    final districtName = _districtAt(scenePoint, mapRect, mapBounds);
    final visibleDistrictNames = visibleDistricts
        .map((district) => district.name)
        .toSet();
    if (districtName != null) {
      if (!visibleDistrictNames.contains(districtName)) {
        widget.onSelectedContactChanged(null);
        return;
      }
      widget.onSelectedContactChanged(null);
      setState(() {
        _selectedDistrictName = districtName;
        _mapScopeKey = null;
      });
      return;
    }

    widget.onSelectedContactChanged(null);
  }

  RadarContact? _contactAt(
    Offset scenePoint,
    Rect mapRect,
    _MapBounds mapBounds,
  ) {
    final contacts = widget.contacts;
    if (contacts.isEmpty) {
      return null;
    }

    final scale = max(1.0, _transformationController.value.getMaxScaleOnAxis());
    final hitRadius = max(12.0, 34.0 / scale);
    RadarContact? nearest;
    var nearestDistance = double.infinity;

    for (final contact in contacts) {
      if (!mapBounds.containsLocation(contact.location)) {
        continue;
      }
      final point = _projectLocationToMap(contact.location, mapRect, mapBounds);
      final distance = (point - scenePoint).distance;
      if (distance <= hitRadius && distance < nearestDistance) {
        nearest = contact;
        nearestDistance = distance;
      }
    }

    return nearest;
  }

  String? _districtAt(Offset scenePoint, Rect mapRect, _MapBounds mapBounds) {
    if (!mapRect.contains(scenePoint)) {
      return null;
    }

    return _districtNameForPoint(
      _unprojectMapPoint(scenePoint, mapRect, mapBounds),
    );
  }

  RadarContact? _contactById(String contactId) {
    for (final contact in widget.contacts) {
      if (contact.id == contactId) {
        return contact;
      }
    }
    return null;
  }

  RadarContact? get _selectedContact {
    final selectedContactId = widget.selectedContactId;
    if (selectedContactId == null) {
      return null;
    }
    return _contactById(selectedContactId);
  }

  void _scheduleMapScopeReset(String nextScopeKey) {
    if (_mapScopeKey == nextScopeKey) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _mapScopeKey == nextScopeKey) {
        return;
      }
      _transformationController.value = Matrix4.identity();
      _mapScopeKey = nextScopeKey;
    });
  }

  @override
  Widget build(BuildContext context) {
    final currentDistrictName = widget.location == null
        ? null
        : _districtNameForLocation(widget.location!);
    final activeDistrictName = _selectedDistrictName ?? currentDistrictName;
    final visibleDistricts = _visibleDistrictsForRadar(
      activeDistrictName: activeDistrictName,
      contacts: widget.contacts,
    );
    final mapBounds =
        _mapBoundsForDistricts(visibleDistricts) ?? _MapBounds.hongKong;
    final mapScopeKey = visibleDistricts.isEmpty
        ? 'none'
        : visibleDistricts.map((district) => district.name).join('|');

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final viewportSize = Size(
            constraints.maxWidth,
            constraints.maxHeight,
          );
          final mapSize = viewportSize;
          _scheduleMapScopeReset(mapScopeKey);

          final selectedContact = _selectedContact;

          return Stack(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (details) => _handleMapTap(
                  details.localPosition,
                  mapSize,
                  mapBounds,
                  visibleDistricts,
                ),
                child: InteractiveViewer(
                  transformationController: _transformationController,
                  minScale: 1,
                  maxScale: 24,
                  boundaryMargin: const EdgeInsets.all(1600),
                  constrained: false,
                  child: SizedBox(
                    width: mapSize.width,
                    height: mapSize.height,
                    child: CustomPaint(
                      painter: _HongKongMapPainter(
                        location: widget.location,
                        contacts: widget.contacts,
                        nearbyContactIds: widget.nearbyContactIds,
                        refreshSignature: widget.refreshSignature,
                        selectedContactId: widget.selectedContactId,
                        currentDistrictName: activeDistrictName,
                        visibleDistricts: visibleDistricts,
                        mapBounds: mapBounds,
                        textScaler: MediaQuery.textScalerOf(context),
                      ),
                    ),
                  ),
                ),
              ),
              if (activeDistrictName != null)
                Positioned(
                  top: 8,
                  left: 8,
                  right: 8,
                  child: IgnorePointer(
                    child: _MapDistrictFocusBanner(
                      currentDistrictName: activeDistrictName,
                    ),
                  ),
                ),
              if (selectedContact != null &&
                  !selectedContact.isMe &&
                  mapBounds.containsLocation(selectedContact.location))
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: _MapContactQuoteAction(
                    contact: selectedContact,
                    onQuoteContactName: widget.onQuoteContactName,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _OnlineGoogleRadarMap extends StatefulWidget {
  const _OnlineGoogleRadarMap({
    required this.enabled,
    required this.apiKey,
    required this.mapId,
    required this.displayName,
    required this.location,
    required this.contacts,
    required this.nearbyContactIds,
    required this.selectedContactId,
    required this.selectedContactFocusVersion,
    required this.onSelectedContactChanged,
    required this.onQuoteContactName,
  });

  final bool enabled;
  final String apiKey;
  final String mapId;
  final String displayName;
  final DeviceLocation? location;
  final List<RadarContact> contacts;
  final Set<String> nearbyContactIds;
  final String? selectedContactId;
  final int selectedContactFocusVersion;
  final ValueChanged<String?> onSelectedContactChanged;
  final ValueChanged<String> onQuoteContactName;

  @override
  State<_OnlineGoogleRadarMap> createState() => _OnlineGoogleRadarMapState();
}

class _OnlineGoogleRadarMapState extends State<_OnlineGoogleRadarMap> {
  WebViewController? _controller;
  var _progress = 0;
  var _pageReady = false;

  @override
  void initState() {
    super.initState();
    _configureController();
  }

  @override
  void didUpdateWidget(covariant _OnlineGoogleRadarMap oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.enabled != widget.enabled ||
        oldWidget.apiKey != widget.apiKey ||
        oldWidget.mapId != widget.mapId) {
      _configureController();
      return;
    }

    _pushRadarState();
  }

  void _configureController() {
    _pageReady = false;
    _progress = 0;

    if (!_canUseWebView || widget.apiKey.isEmpty) {
      _controller = null;
      return;
    }

    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'RadarBridge',
        onMessageReceived: (message) {
          _handleRadarBridgeMessage(message.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (mounted) {
              setState(() => _progress = progress);
            }
          },
          onPageFinished: (_) {
            _pageReady = true;
            if (mounted) {
              setState(() => _progress = 100);
            }
            _pushRadarState();
          },
        ),
      );

    _controller = controller;
    unawaited(
      controller.loadHtmlString(
        _googleRadarMapHtml(
          apiKey: widget.apiKey,
          mapId: widget.mapId,
          initialStateJson: _radarStateJson(),
        ),
        baseUrl: _aiecoWebUrl,
      ),
    );
  }

  void _handleRadarBridgeMessage(String payload) {
    final trimmed = payload.trim();
    if (trimmed.isEmpty) {
      widget.onSelectedContactChanged(null);
      return;
    }

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        final action = decoded['action']?.toString();
        final contactId = decoded['contactId']?.toString() ?? '';
        switch (action) {
          case 'quote':
            final contact = _contactById(contactId);
            if (contact != null && !contact.isMe) {
              widget.onQuoteContactName(contact.name);
            }
            return;
          case 'select':
            widget.onSelectedContactChanged(
              contactId.isEmpty ? null : contactId,
            );
            return;
        }
      }
    } on Object {
      // Older WebView messages used the raw contact id.
    }

    widget.onSelectedContactChanged(trimmed);
  }

  bool get _canUseWebView {
    return widget.enabled && (Platform.isAndroid || Platform.isIOS);
  }

  void _pushRadarState() {
    final controller = _controller;
    if (!_pageReady || controller == null) {
      return;
    }

    final stateJson = _radarStateJson();
    unawaited(controller.runJavaScript('window.setRadarState($stateJson);'));
  }

  String _radarStateJson() {
    return jsonEncode(_radarState());
  }

  Map<String, Object?> _radarState() {
    final contacts = widget.contacts
        .map((contact) => _contactToMap(contact))
        .toList();
    final hasMe = contacts.any((contact) => contact['isMe'] == true);
    final location = widget.location;
    if (!hasMe && location != null) {
      contacts.insert(0, _locationToMap(location));
    }

    final center = location == null
        ? const <String, double>{
            'lat': _hongKongCenterLatitude,
            'lng': _hongKongCenterLongitude,
          }
        : <String, double>{'lat': location.latitude, 'lng': location.longitude};

    return <String, Object?>{
      'center': center,
      'contacts': contacts,
      'selectedContactId': widget.selectedContactId,
      'selectedContactFocusVersion': widget.selectedContactFocusVersion,
    };
  }

  Map<String, Object?> _contactToMap(RadarContact contact) {
    return <String, Object?>{
      'id': contact.id,
      'name': contact.isMe ? '${contact.name}（我）' : contact.name,
      'lat': contact.location.latitude,
      'lng': contact.location.longitude,
      'accuracyMeters': contact.location.accuracyMeters,
      'isMe': contact.isMe,
      'isSosActive': contact.isSosActive,
      'isNearby': widget.nearbyContactIds.contains(contact.id),
      'district': _districtNameForLocation(contact.location),
    };
  }

  Map<String, Object?> _locationToMap(DeviceLocation location) {
    return <String, Object?>{
      'id': 'current-device',
      'name': '${widget.displayName}（我）',
      'lat': location.latitude,
      'lng': location.longitude,
      'accuracyMeters': location.accuracyMeters,
      'isMe': true,
      'isSosActive': false,
      'isNearby': false,
      'district': _districtNameForLocation(location),
    };
  }

  RadarContact? _contactById(String selectedContactId) {
    for (final contact in widget.contacts) {
      if (contact.id == selectedContactId) {
        return contact;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.apiKey.isEmpty) {
      return const _GoogleMapUnavailable(
        icon: Icons.key_outlined,
        title: '未設定 Google Maps API key',
        message: '用 --dart-define=GOOGLE_MAPS_API_KEY=你的_key 建置後可使用線上地圖。',
      );
    }

    if (!_canUseWebView) {
      return const _GoogleMapUnavailable(
        icon: Icons.public_off,
        title: '線上地圖未啟用',
        message: '目前平台或測試建置未開啟 WebView，請使用離線地圖。',
      );
    }

    final controller = _controller;
    if (controller == null) {
      return const _GoogleMapUnavailable(
        icon: Icons.map_outlined,
        title: '正在準備線上地圖',
        message: 'Google Map 初始化中。',
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        children: [
          Positioned.fill(child: WebViewWidget(controller: controller)),
          if (_progress < 100)
            Positioned(
              left: 0,
              top: 0,
              right: 0,
              child: LinearProgressIndicator(
                value: _progress == 0 ? null : _progress / 100,
              ),
            ),
        ],
      ),
    );
  }
}

class _MapContactQuoteAction extends StatelessWidget {
  const _MapContactQuoteAction({
    required this.contact,
    required this.onQuoteContactName,
  });

  final RadarContact contact;
  final ValueChanged<String> onQuoteContactName;

  @override
  Widget build(BuildContext context) {
    final districtName = _districtNameForLocation(contact.location);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xF7FFFFFF),
        border: Border.all(color: const Color(0xFFD7DED7)),
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 230),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.person_pin_circle, size: 18),
              const SizedBox(width: 6),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      contact.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: const Color(0xFF17211E),
                      ),
                    ),
                    if (districtName != null)
                      Text(
                        districtName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: const Color(0xFF66756D),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: '引用光點名稱聊天',
                child: IconButton.filledTonal(
                  onPressed: () => onQuoteContactName(contact.name),
                  icon: const Icon(Icons.format_quote, size: 18),
                  style: IconButton.styleFrom(
                    fixedSize: const Size(34, 34),
                    minimumSize: const Size(34, 34),
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GoogleMapUnavailable extends StatelessWidget {
  const _GoogleMapUnavailable({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFF7F8F4),
        border: Border.all(color: const Color(0xFFD7DED7)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: const Color(0xFF0D7C66), size: 34),
              const SizedBox(height: 10),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFF17211E),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF66756D),
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _googleRadarMapHtml({
  required String apiKey,
  required String mapId,
  required String initialStateJson,
}) {
  final encodedKey = Uri.encodeQueryComponent(apiKey);
  final mapIdOption = mapId.isEmpty ? '' : ', mapId: ${jsonEncode(mapId)}';

  return '''
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
  <style>
    html, body, #map {
      width: 100%;
      height: 100%;
      margin: 0;
      padding: 0;
      overflow: hidden;
      background: #edf3ef;
      font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    #loading {
      position: absolute;
      inset: 0;
      display: grid;
      place-items: center;
      background: #f7f8f4;
      color: #17211e;
      font-size: 14px;
      font-weight: 700;
    }
    .gm-style .gm-style-iw-c {
      padding: 8px !important;
      border-radius: 8px !important;
    }
    .gm-style .gm-style-iw-d {
      overflow: hidden !important;
    }
    .gm-ui-hover-effect {
      width: 24px !important;
      height: 24px !important;
    }
    .gm-ui-hover-effect > span {
      width: 12px !important;
      height: 12px !important;
      margin: 6px !important;
    }
    .info {
      max-width: 176px;
      color: #17211e;
      line-height: 1.25;
      font-size: 12px;
    }
    .info-title {
      font-weight: 800;
      margin-bottom: 3px;
      max-width: 142px;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .info-meta {
      color: #66756d;
      font-size: 11px;
      max-width: 142px;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .info-row {
      display: flex;
      align-items: center;
      gap: 7px;
    }
    .info-copy {
      min-width: 30px;
      height: 26px;
      border: 0;
      border-radius: 7px;
      background: #e0f2e9;
      color: #0d7c66;
      font-size: 11px;
      font-weight: 800;
      padding: 0 7px;
      cursor: pointer;
    }
  </style>
</head>
<body>
  <div id="map"></div>
  <div id="loading">載入 Google Map</div>
  <script>
    window.__RADAR_STATE__ = $initialStateJson;

    let map;
    let infoWindow;
    let markers = {};
    let accuracyCircles = {};
    let markerContacts = {};
    let lastFocusVersion = -1;
    let lastCenterKey = '';

    const hongKongCenter = {
      lat: $_hongKongCenterLatitude,
      lng: $_hongKongCenterLongitude
    };

    function initRadarMap() {
      const state = window.__RADAR_STATE__ || {};
      const center = normalizePosition(state.center) || hongKongCenter;
      map = new google.maps.Map(document.getElementById('map'), {
        center,
        zoom: 11,
        clickableIcons: false,
        fullscreenControl: false,
        mapTypeControl: false,
        streetViewControl: false,
        gestureHandling: 'greedy'$mapIdOption
      });
      infoWindow = new google.maps.InfoWindow({ maxWidth: 190 });
      map.addListener('click', () => postSelection(''));
      google.maps.event.addListenerOnce(map, 'tilesloaded', () => {
        const loading = document.getElementById('loading');
        if (loading) {
          loading.style.display = 'none';
        }
      });
      window.setRadarState(state);
    }

    window.initRadarMap = initRadarMap;

    window.setRadarState = function(state) {
      window.__RADAR_STATE__ = state || {};
      if (!map || !window.google || !google.maps) {
        return;
      }
      renderRadarState(window.__RADAR_STATE__);
    };

    function renderRadarState(state) {
      const contacts = Array.isArray(state.contacts) ? state.contacts : [];
      const nextIds = new Set();
      contacts.forEach((contact) => {
        const id = addOrUpdateContactMarker(contact);
        if (id) {
          nextIds.add(id);
        }
      });
      removeMissingMarkers(nextIds);

      const selectedId = state.selectedContactId
        ? String(state.selectedContactId)
        : '';
      const selectedMarker = selectedId ? markers[selectedId] : null;
      if (selectedMarker) {
        const focusVersion = Number(state.selectedContactFocusVersion || 0);
        if (lastFocusVersion !== focusVersion) {
          map.panTo(selectedMarker.getPosition());
          map.setZoom(Math.max(map.getZoom() || 11, 16));
          lastFocusVersion = focusVersion;
        }
        openInfo(selectedMarker, markerContacts[selectedId]);
        return;
      }

      const center = normalizePosition(state.center);
      if (center) {
        const centerKey = center.lat.toFixed(6) + ',' + center.lng.toFixed(6);
        if (centerKey !== lastCenterKey) {
          map.setCenter(center);
          lastCenterKey = centerKey;
        }
        if ((map.getZoom() || 0) > 13) {
          map.setZoom(11);
        }
      }
      infoWindow.close();
    }

    function clearMarkers() {
      Object.values(markers).forEach((marker) => marker.setMap(null));
      Object.values(accuracyCircles).forEach((circle) => circle.setMap(null));
      markers = {};
      accuracyCircles = {};
      markerContacts = {};
    }

    function removeMissingMarkers(nextIds) {
      Object.keys(markers).forEach((id) => {
        if (nextIds.has(id)) {
          return;
        }
        markers[id].setMap(null);
        delete markers[id];
        delete markerContacts[id];
        if (accuracyCircles[id]) {
          accuracyCircles[id].setMap(null);
          delete accuracyCircles[id];
        }
      });
    }

    function markerOptions(contact, position) {
      const isMe = contact.isMe === true;
      const isNearby = contact.isNearby === true;
      const isSosActive = contact.isSosActive === true;
      return {
        map,
        position,
        title: isSosActive
          ? '求救 · ' + String(contact.name || '光點')
          : String(contact.name || '光點'),
        label: isSosActive
          ? { text: 'SOS', color: '#ffffff', fontWeight: '900' }
          : isMe
          ? { text: '我', color: '#ffffff', fontWeight: '800' }
          : isNearby
            ? { text: '近', color: '#ffffff', fontWeight: '800' }
            : null,
        icon: {
          path: google.maps.SymbolPath.CIRCLE,
          scale: isSosActive ? 13 : isMe ? 12 : 9,
          fillColor: isSosActive
            ? '#b00020'
            : isMe ? '#0d7c66' : isNearby ? '#d73535' : '#1f6feb',
          fillOpacity: 1,
          strokeColor: isSosActive ? '#ffdad6' : '#ffffff',
          strokeWeight: isSosActive ? 4 : 3
        },
        zIndex: isSosActive ? 30 : isMe ? 20 : isNearby ? 15 : 10
      };
    }

    function addOrUpdateContactMarker(contact) {
      const id = String(contact.id || '');
      const position = normalizePosition({
        lat: contact.lat,
        lng: contact.lng
      });
      if (!id || !position) {
        return '';
      }

      const isMe = contact.isMe === true;
      let marker = markers[id];
      if (marker) {
        marker.setOptions(markerOptions(contact, position));
      } else {
        marker = new google.maps.Marker(markerOptions(contact, position));
        marker.addListener('click', () => {
          openInfo(marker, markerContacts[id]);
          postSelection(id);
        });
        markers[id] = marker;
      }

      markerContacts[id] = contact;

      const accuracy = Number(contact.accuracyMeters || 0);
      if (isMe && Number.isFinite(accuracy) && accuracy > 0) {
        if (accuracyCircles[id]) {
          accuracyCircles[id].setOptions({
            center: position,
            radius: accuracy
          });
        } else {
          accuracyCircles[id] = new google.maps.Circle({
            map,
            center: position,
            radius: accuracy,
            strokeColor: '#0d7c66',
            strokeOpacity: 0.36,
            strokeWeight: 1,
            fillColor: '#0d7c66',
            fillOpacity: 0.12
          });
        }
      } else if (accuracyCircles[id]) {
        accuracyCircles[id].setMap(null);
        delete accuracyCircles[id];
      }

      return id;
    }

    function openInfo(marker, contact) {
      if (!contact) {
        return;
      }
      const name = String(contact.name || '光點');
      const isSosActive = contact.isSosActive === true;
      const district = contact.district ? String(contact.district) : '未知區域';
      const accuracy = Math.round(Number(contact.accuracyMeters || 0));
      const meta = accuracy > 0
        ? district + ' · +/- ' + accuracy + 'm'
        : district;

      const container = document.createElement('div');
      container.className = 'info';

      const row = document.createElement('div');
      row.className = 'info-row';

      const text = document.createElement('div');
      text.style.minWidth = '0';

      const title = document.createElement('div');
      title.className = 'info-title';
      title.textContent = isSosActive ? '求救 · ' + name : name;
      if (isSosActive) {
        title.style.color = '#b00020';
      }

      const metaLine = document.createElement('div');
      metaLine.className = 'info-meta';
      metaLine.textContent = meta;

      text.appendChild(title);
      text.appendChild(metaLine);
      row.appendChild(text);

      if (contact.isMe !== true) {
        const quoteButton = document.createElement('button');
        quoteButton.type = 'button';
        quoteButton.className = 'info-copy';
        quoteButton.textContent = '引用';
        quoteButton.addEventListener('click', (event) => {
          event.preventDefault();
          event.stopPropagation();
          postQuote(contact.id || '');
        });
        row.appendChild(quoteButton);
      }

      container.appendChild(row);
      infoWindow.setContent(container);
      infoWindow.open({ map, anchor: marker });
    }

    function normalizePosition(value) {
      if (!value) {
        return null;
      }
      const lat = Number(value.lat);
      const lng = Number(value.lng);
      if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
        return null;
      }
      return { lat, lng };
    }

    function postSelection(contactId) {
      if (window.RadarBridge && window.RadarBridge.postMessage) {
        window.RadarBridge.postMessage(JSON.stringify({
          action: 'select',
          contactId: String(contactId || '')
        }));
      }
    }

    function postQuote(contactId) {
      if (window.RadarBridge && window.RadarBridge.postMessage) {
        window.RadarBridge.postMessage(JSON.stringify({
          action: 'quote',
          contactId: String(contactId || '')
        }));
      }
    }
  </script>
  <script async defer src="https://maps.googleapis.com/maps/api/js?key=$encodedKey&v=weekly&callback=initRadarMap"></script>
</body>
</html>
''';
}

class _MapDistrictFocusBanner extends StatelessWidget {
  const _MapDistrictFocusBanner({required this.currentDistrictName});

  final String currentDistrictName;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topLeft,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xEFFFFFFF),
          border: Border.all(color: const Color(0xFFD7DED7)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.explore_outlined, size: 16),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  currentDistrictName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF17211E),
                    fontWeight: FontWeight.w800,
                    height: 1.15,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HongKongMapPainter extends CustomPainter {
  const _HongKongMapPainter({
    required this.location,
    required this.contacts,
    required this.nearbyContactIds,
    required this.refreshSignature,
    required this.selectedContactId,
    required this.currentDistrictName,
    required this.visibleDistricts,
    required this.mapBounds,
    required this.textScaler,
  });

  static const double _minLatitude = 22.13;
  static const double _maxLatitude = 22.57;
  static const double _minLongitude = 113.82;
  static const double _maxLongitude = 114.43;

  final DeviceLocation? location;
  final List<RadarContact> contacts;
  final Set<String> nearbyContactIds;
  final String refreshSignature;
  final String? selectedContactId;
  final String? currentDistrictName;
  final List<_DistrictShape> visibleDistricts;
  final _MapBounds mapBounds;
  final TextScaler textScaler;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final mapRect = _fitMapRect(rect.deflate(10), mapBounds);
    final seaPaint = Paint()..color = const Color(0xFFD8EEF1);
    final gridPaint = Paint()
      ..color = const Color(0x55FFFFFF)
      ..strokeWidth = 1;

    canvas.drawRect(rect, seaPaint);
    _drawGrid(canvas, mapRect, gridPaint);
    _drawDistrictAreas(canvas, mapRect);

    _drawScaleCaption(canvas, mapRect);

    final currentLocation = location;
    final visibleContacts = contacts
        .where((contact) => mapBounds.containsLocation(contact.location))
        .toList();
    if (visibleContacts.isNotEmpty) {
      _drawContacts(canvas, mapRect, visibleContacts);
    } else if (currentLocation != null &&
        mapBounds.containsLocation(currentLocation)) {
      _drawLocation(canvas, mapRect, currentLocation);
    } else {
      _drawEmptyHint(canvas, mapRect);
    }

    _drawDistrictLabels(canvas, mapRect);
    _drawSelectedContactLabel(canvas, mapRect);
  }

  void _drawGrid(Canvas canvas, Rect rect, Paint paint) {
    for (var i = 1; i < 4; i += 1) {
      final x = rect.left + rect.width * i / 4;
      canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), paint);
    }
    for (var i = 1; i < 4; i += 1) {
      final y = rect.top + rect.height * i / 4;
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), paint);
    }
  }

  void _drawDistrictAreas(Canvas canvas, Rect rect) {
    final outlinePaint = Paint()
      ..color = const Color(0x995D5F5A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.15;

    for (final district in visibleDistricts) {
      _drawLand(
        canvas,
        rect,
        Paint()..color = district.color,
        outlinePaint,
        district.points,
      );
    }

    if (visibleDistricts.isNotEmpty) {
      for (final island in _islands) {
        if (mapBounds.containsPoint(island.center)) {
          _drawIsland(canvas, rect, island.center, island.width, island.height);
        }
      }
    }

    _drawFocusedDistricts(canvas, rect);
  }

  void _drawFocusedDistricts(Canvas canvas, Rect rect) {
    final focusedName = currentDistrictName;
    if (focusedName == null) {
      return;
    }

    for (final district in visibleDistricts) {
      if (district.name != focusedName) {
        continue;
      }

      final fillPaint = Paint()..color = const Color(0x55FFF1A6);
      final outlinePaint = Paint()
        ..color = const Color(0xFF0D7C66)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3;

      _drawLand(canvas, rect, fillPaint, outlinePaint, district.points);
    }
  }

  void _drawDistrictLabels(Canvas canvas, Rect rect) {
    for (final district in visibleDistricts) {
      _drawLabel(canvas, rect, district.name, district.labelPoint);
    }
  }

  void _drawLand(
    Canvas canvas,
    Rect rect,
    Paint fill,
    Paint outline,
    List<_MapPoint> points,
  ) {
    final path = Path();
    for (var i = 0; i < points.length; i += 1) {
      final point = _project(points[i], rect);
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    path.close();
    canvas.drawPath(path, fill);
    canvas.drawPath(path, outline);
  }

  void _drawIsland(
    Canvas canvas,
    Rect rect,
    _MapPoint center,
    double width,
    double height,
  ) {
    final paint = Paint()..color = const Color(0xFFE7C86D);
    final outline = Paint()
      ..color = const Color(0xFF5D6F68)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1;
    final projected = _project(center, rect);
    final islandRect = Rect.fromCenter(
      center: projected,
      width: width,
      height: height,
    );
    canvas.drawOval(islandRect, paint);
    canvas.drawOval(islandRect, outline);
  }

  void _drawLabel(Canvas canvas, Rect rect, String label, _MapPoint point) {
    final offset = _project(point, rect);
    final fontSize = textScaler.scale(12);
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: const Color(0xFF26332F),
          fontWeight: FontWeight.w800,
          fontSize: fontSize,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final labelRect = Rect.fromCenter(
      center: offset,
      width: painter.width + 10,
      height: painter.height + 5,
    );
    final background = RRect.fromRectAndRadius(
      labelRect,
      Radius.circular(max(4, fontSize * 0.35)),
    );
    canvas.drawRRect(background, Paint()..color = const Color(0xDDF9FBF7));
    painter.paint(canvas, labelRect.topLeft + const Offset(5, 2.5));
  }

  void _drawScaleCaption(Canvas canvas, Rect rect) {
    final painter = TextPainter(
      text: TextSpan(
        text: '香港離線雷達',
        style: TextStyle(
          color: const Color(0xFF345B58),
          fontWeight: FontWeight.w800,
          fontSize: textScaler.scale(12),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: rect.width);
    painter.paint(canvas, Offset(rect.left + 8, rect.top + 8));
  }

  void _drawEmptyHint(Canvas canvas, Rect rect) {
    final painter = TextPainter(
      text: TextSpan(
        text: '按「定位」在地圖顯示你的光點',
        style: TextStyle(
          color: const Color(0xFF4B5F56),
          fontWeight: FontWeight.w700,
          fontSize: textScaler.scale(13),
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout(maxWidth: rect.width - 24);
    final offset = rect.center - Offset(painter.width / 2, painter.height / 2);
    painter.paint(canvas, offset);
  }

  void _drawContacts(Canvas canvas, Rect rect, List<RadarContact> contacts) {
    final sorted = contacts.toList()
      ..sort((a, b) {
        if (a.isSosActive != b.isSosActive) {
          return a.isSosActive ? 1 : -1;
        }
        if (a.isMe == b.isMe) {
          return a.name.compareTo(b.name);
        }
        return a.isMe ? 1 : -1;
      });

    for (final contact in sorted) {
      _drawRadarContact(canvas, rect, contact);
    }
  }

  void _drawLocation(Canvas canvas, Rect rect, DeviceLocation location) {
    _drawMarker(
      canvas,
      rect,
      location,
      isMe: true,
      isSelected: selectedContactId == null,
      accuracyMeters: location.accuracyMeters,
    );
  }

  void _drawRadarContact(Canvas canvas, Rect rect, RadarContact contact) {
    final isNearby = nearbyContactIds.contains(contact.id);
    final isSelected = selectedContactId == contact.id;
    _drawMarker(
      canvas,
      rect,
      contact.location,
      isMe: contact.isMe,
      isSosActive: contact.isSosActive,
      isNearby: isNearby,
      isSelected: isSelected,
      accuracyMeters: contact.location.accuracyMeters,
    );
  }

  void _drawMarker(
    Canvas canvas,
    Rect rect,
    DeviceLocation location, {
    required bool isMe,
    bool isSosActive = false,
    bool isNearby = false,
    bool isSelected = false,
    required double accuracyMeters,
  }) {
    final visiblePoint = _project(
      mapBounds.clampPoint(_MapPoint(location.latitude, location.longitude)),
      rect,
    );
    final accuracyRadius = max(10.0, min(44.0, accuracyMeters / 20));
    final accuracyPaint = Paint()
      ..color = isSosActive
          ? const Color(0x55FF3B30)
          : isMe
          ? const Color(0x3341B6E6)
          : isNearby
          ? const Color(0x66FF3B30)
          : const Color(0x33FF6B6B);
    final ringPaint = Paint()
      ..color = isSosActive
          ? const Color(0xFFB00020)
          : isMe
          ? const Color(0xFF0D7C66)
          : isNearby
          ? const Color(0xFFFF3B30)
          : const Color(0xFFC4512C)
      ..style = PaintingStyle.stroke
      ..strokeWidth = isSelected
          ? 4
          : isSosActive
          ? 3.5
          : isNearby
          ? 3
          : 2;
    final dotPaint = Paint()
      ..color = isSosActive
          ? const Color(0xFFFFDAD6)
          : isMe
          ? const Color(0xFFFFC857)
          : isNearby
          ? const Color(0xFFFFF0A6)
          : const Color(0xFFFFFFFF);

    canvas.drawCircle(visiblePoint, accuracyRadius, accuracyPaint);
    canvas.drawCircle(
      visiblePoint,
      isSelected
          ? 14
          : isSosActive
          ? 13
          : isNearby
          ? 11
          : 8,
      ringPaint,
    );
    canvas.drawCircle(
      visiblePoint,
      isSelected
          ? 7
          : isSosActive
          ? 6.5
          : isNearby
          ? 6
          : 4.5,
      dotPaint,
    );
    if (isSosActive) {
      final labelPainter = TextPainter(
        text: TextSpan(
          text: 'SOS',
          style: TextStyle(
            color: const Color(0xFFB00020),
            fontSize: textScaler.scale(9),
            fontWeight: FontWeight.w900,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final labelOffset = Offset(
        visiblePoint.dx - labelPainter.width / 2,
        visiblePoint.dy + 15,
      );
      final labelRect = Rect.fromLTWH(
        labelOffset.dx - 4,
        labelOffset.dy - 2,
        labelPainter.width + 8,
        labelPainter.height + 4,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(labelRect, const Radius.circular(5)),
        Paint()..color = const Color(0xEEFFFFFF),
      );
      labelPainter.paint(canvas, labelOffset);
    }
  }

  void _drawSelectedContactLabel(Canvas canvas, Rect rect) {
    final selectedContact = _selectedContact();
    if (selectedContact == null) {
      return;
    }
    if (!mapBounds.containsLocation(selectedContact.location)) {
      return;
    }

    final visiblePoint = _project(
      mapBounds.clampPoint(
        _MapPoint(
          selectedContact.location.latitude,
          selectedContact.location.longitude,
        ),
      ),
      rect,
    );
    final districtName = _districtNameForLocation(selectedContact.location);
    final name = selectedContact.isSosActive
        ? '求救 · ${selectedContact.name}'
        : selectedContact.name;
    final label = districtName == null ? name : '$name · $districtName';

    _drawLocationLabel(
      canvas,
      rect,
      visiblePoint,
      label,
      isMe: selectedContact.isMe,
      isSosActive: selectedContact.isSosActive,
      isNearby: nearbyContactIds.contains(selectedContact.id),
    );
  }

  RadarContact? _selectedContact() {
    final selectedId = selectedContactId;
    if (selectedId == null) {
      return null;
    }

    for (final contact in contacts) {
      if (contact.id == selectedId) {
        return contact;
      }
    }
    return null;
  }

  void _drawLocationLabel(
    Canvas canvas,
    Rect rect,
    Offset point,
    String label, {
    required bool isMe,
    bool isSosActive = false,
    bool isNearby = false,
  }) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: Colors.white,
          fontSize: textScaler.scale(13),
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final bubbleSize = Size(textPainter.width + 20, textPainter.height + 10);
    final left = (point.dx - bubbleSize.width / 2).clamp(
      rect.left + 4,
      rect.right - bubbleSize.width - 4,
    );
    final top = max(rect.top + 4, point.dy - bubbleSize.height - 18);
    final bubble = RRect.fromRectAndRadius(
      Rect.fromLTWH(left, top, bubbleSize.width, bubbleSize.height),
      const Radius.circular(8),
    );
    final bubblePaint = Paint()
      ..color = isSosActive
          ? const Color(0xFFB00020)
          : isMe
          ? const Color(0xFF17211E)
          : isNearby
          ? const Color(0xFFB00020)
          : const Color(0xFF7A2E22);
    final pointerPath = Path()
      ..moveTo(point.dx, top + bubbleSize.height + 8)
      ..lineTo(point.dx - 6, top + bubbleSize.height - 1)
      ..lineTo(point.dx + 6, top + bubbleSize.height - 1)
      ..close();

    canvas.drawRRect(bubble, bubblePaint);
    canvas.drawPath(pointerPath, bubblePaint);
    textPainter.paint(
      canvas,
      Offset(
        left + (bubbleSize.width - textPainter.width) / 2,
        top + (bubbleSize.height - textPainter.height) / 2,
      ),
    );
  }

  Offset _project(_MapPoint point, Rect rect) {
    return _projectMapPoint(point, rect, mapBounds);
  }

  @override
  bool shouldRepaint(covariant _HongKongMapPainter oldDelegate) {
    return oldDelegate.refreshSignature != refreshSignature ||
        oldDelegate.selectedContactId != selectedContactId ||
        oldDelegate.currentDistrictName != currentDistrictName ||
        oldDelegate.visibleDistricts != visibleDistricts ||
        oldDelegate.mapBounds != mapBounds ||
        oldDelegate.textScaler != textScaler;
  }

  static const List<_DistrictShape> _districts = [
    _DistrictShape(
      name: '屯門區',
      color: Color(0xFFA9DCA4),
      labelPoint: _MapPoint(22.39, 113.96),
      points: [
        _MapPoint(22.46, 113.86),
        _MapPoint(22.43, 114.03),
        _MapPoint(22.36, 114.02),
        _MapPoint(22.34, 113.92),
        _MapPoint(22.38, 113.84),
      ],
    ),
    _DistrictShape(
      name: '元朗區',
      color: Color(0xFFAED2EC),
      labelPoint: _MapPoint(22.45, 114.05),
      points: [
        _MapPoint(22.52, 113.98),
        _MapPoint(22.52, 114.14),
        _MapPoint(22.44, 114.15),
        _MapPoint(22.39, 114.04),
        _MapPoint(22.43, 114.00),
      ],
    ),
    _DistrictShape(
      name: '北區',
      color: Color(0xFFF2B0BD),
      labelPoint: _MapPoint(22.52, 114.18),
      points: [
        _MapPoint(22.57, 114.10),
        _MapPoint(22.55, 114.29),
        _MapPoint(22.48, 114.28),
        _MapPoint(22.46, 114.14),
        _MapPoint(22.52, 114.14),
      ],
    ),
    _DistrictShape(
      name: '大埔區',
      color: Color(0xFFA9DDD2),
      labelPoint: _MapPoint(22.45, 114.22),
      points: [
        _MapPoint(22.50, 114.18),
        _MapPoint(22.48, 114.34),
        _MapPoint(22.40, 114.32),
        _MapPoint(22.38, 114.21),
        _MapPoint(22.44, 114.15),
      ],
    ),
    _DistrictShape(
      name: '西貢區',
      color: Color(0xFFC8ADA7),
      labelPoint: _MapPoint(22.35, 114.31),
      points: [
        _MapPoint(22.43, 114.28),
        _MapPoint(22.42, 114.42),
        _MapPoint(22.28, 114.40),
        _MapPoint(22.27, 114.27),
        _MapPoint(22.34, 114.23),
      ],
    ),
    _DistrictShape(
      name: '沙田區',
      color: Color(0xFFF4D1A0),
      labelPoint: _MapPoint(22.38, 114.20),
      points: [
        _MapPoint(22.42, 114.15),
        _MapPoint(22.41, 114.25),
        _MapPoint(22.34, 114.24),
        _MapPoint(22.33, 114.16),
      ],
    ),
    _DistrictShape(
      name: '荃灣區',
      color: Color(0xFFBDE2A6),
      labelPoint: _MapPoint(22.37, 114.09),
      points: [
        _MapPoint(22.41, 114.02),
        _MapPoint(22.40, 114.15),
        _MapPoint(22.34, 114.14),
        _MapPoint(22.33, 114.04),
      ],
    ),
    _DistrictShape(
      name: '葵青區',
      color: Color(0xFF8CD5B0),
      labelPoint: _MapPoint(22.33, 114.12),
      points: [
        _MapPoint(22.35, 114.08),
        _MapPoint(22.35, 114.16),
        _MapPoint(22.30, 114.16),
        _MapPoint(22.29, 114.10),
      ],
    ),
    _DistrictShape(
      name: '深水埗',
      color: Color(0xFFE2A1B4),
      labelPoint: _MapPoint(22.33, 114.16),
      points: [
        _MapPoint(22.35, 114.13),
        _MapPoint(22.35, 114.18),
        _MapPoint(22.31, 114.18),
        _MapPoint(22.31, 114.14),
      ],
    ),
    _DistrictShape(
      name: '黃大仙',
      color: Color(0xFFF0C3A7),
      labelPoint: _MapPoint(22.34, 114.20),
      points: [
        _MapPoint(22.36, 114.18),
        _MapPoint(22.36, 114.24),
        _MapPoint(22.32, 114.23),
        _MapPoint(22.33, 114.18),
      ],
    ),
    _DistrictShape(
      name: '九龍城',
      color: Color(0xFFEFAE90),
      labelPoint: _MapPoint(22.32, 114.19),
      points: [
        _MapPoint(22.33, 114.17),
        _MapPoint(22.33, 114.22),
        _MapPoint(22.30, 114.22),
        _MapPoint(22.30, 114.17),
      ],
    ),
    _DistrictShape(
      name: '觀塘',
      color: Color(0xFFE9A884),
      labelPoint: _MapPoint(22.31, 114.24),
      points: [
        _MapPoint(22.33, 114.22),
        _MapPoint(22.32, 114.27),
        _MapPoint(22.29, 114.27),
        _MapPoint(22.29, 114.22),
      ],
    ),
    _DistrictShape(
      name: '油尖旺',
      color: Color(0xFFE6D39A),
      labelPoint: _MapPoint(22.305, 114.165),
      points: [
        _MapPoint(22.32, 114.15),
        _MapPoint(22.32, 114.18),
        _MapPoint(22.29, 114.18),
        _MapPoint(22.29, 114.15),
      ],
    ),
    _DistrictShape(
      name: '中西區',
      color: Color(0xFFD7C4EE),
      labelPoint: _MapPoint(22.285, 114.145),
      points: [
        _MapPoint(22.30, 114.11),
        _MapPoint(22.30, 114.16),
        _MapPoint(22.27, 114.16),
        _MapPoint(22.265, 114.12),
      ],
    ),
    _DistrictShape(
      name: '灣仔區',
      color: Color(0xFFEEC767),
      labelPoint: _MapPoint(22.275, 114.175),
      points: [
        _MapPoint(22.29, 114.16),
        _MapPoint(22.29, 114.19),
        _MapPoint(22.265, 114.20),
        _MapPoint(22.265, 114.16),
      ],
    ),
    _DistrictShape(
      name: '東區',
      color: Color(0xFFF3A3A8),
      labelPoint: _MapPoint(22.275, 114.225),
      points: [
        _MapPoint(22.29, 114.19),
        _MapPoint(22.29, 114.28),
        _MapPoint(22.24, 114.28),
        _MapPoint(22.25, 114.20),
      ],
    ),
    _DistrictShape(
      name: '南區',
      color: Color(0xFFBFB8E8),
      labelPoint: _MapPoint(22.235, 114.19),
      points: [
        _MapPoint(22.26, 114.12),
        _MapPoint(22.25, 114.28),
        _MapPoint(22.19, 114.26),
        _MapPoint(22.20, 114.10),
      ],
    ),
    _DistrictShape(
      name: '離島區',
      color: Color(0xFFE7C86D),
      labelPoint: _MapPoint(22.24, 113.94),
      points: [
        _MapPoint(22.33, 113.85),
        _MapPoint(22.31, 114.05),
        _MapPoint(22.23, 114.08),
        _MapPoint(22.18, 113.95),
        _MapPoint(22.22, 113.82),
      ],
    ),
  ];

  static const List<_IslandShape> _islands = [
    _IslandShape(center: _MapPoint(22.21, 114.12), width: 12, height: 5),
    _IslandShape(center: _MapPoint(22.16, 114.02), width: 8, height: 4),
    _IslandShape(center: _MapPoint(22.28, 114.33), width: 9, height: 5),
  ];
}

class _MapPoint {
  const _MapPoint(this.latitude, this.longitude);

  final double latitude;
  final double longitude;
}

class _MapBounds {
  const _MapBounds({
    required this.minLatitude,
    required this.maxLatitude,
    required this.minLongitude,
    required this.maxLongitude,
  });

  static const hongKong = _MapBounds(
    minLatitude: _HongKongMapPainter._minLatitude,
    maxLatitude: _HongKongMapPainter._maxLatitude,
    minLongitude: _HongKongMapPainter._minLongitude,
    maxLongitude: _HongKongMapPainter._maxLongitude,
  );

  final double minLatitude;
  final double maxLatitude;
  final double minLongitude;
  final double maxLongitude;

  double get latitudeSpan => max(0.0001, maxLatitude - minLatitude);
  double get longitudeSpan => max(0.0001, maxLongitude - minLongitude);
  double get centerLatitude => (minLatitude + maxLatitude) / 2;

  double get physicalAspectRatio {
    final longitudeScale = cos(_degreesToRadians(centerLatitude)).abs();
    return max(0.2, longitudeSpan * longitudeScale / latitudeSpan);
  }

  _MapBounds padded(double fraction) {
    final latitudePadding = latitudeSpan * fraction;
    final longitudePadding = longitudeSpan * fraction;
    return _MapBounds(
      minLatitude: minLatitude - latitudePadding,
      maxLatitude: maxLatitude + latitudePadding,
      minLongitude: minLongitude - longitudePadding,
      maxLongitude: maxLongitude + longitudePadding,
    );
  }

  bool containsPoint(_MapPoint point) {
    return point.latitude >= minLatitude &&
        point.latitude <= maxLatitude &&
        point.longitude >= minLongitude &&
        point.longitude <= maxLongitude;
  }

  bool containsLocation(DeviceLocation location) {
    return location.latitude >= minLatitude &&
        location.latitude <= maxLatitude &&
        location.longitude >= minLongitude &&
        location.longitude <= maxLongitude;
  }

  _MapPoint clampPoint(_MapPoint point) {
    return _MapPoint(
      point.latitude.clamp(minLatitude, maxLatitude).toDouble(),
      point.longitude.clamp(minLongitude, maxLongitude).toDouble(),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is _MapBounds &&
        other.minLatitude == minLatitude &&
        other.maxLatitude == maxLatitude &&
        other.minLongitude == minLongitude &&
        other.maxLongitude == maxLongitude;
  }

  @override
  int get hashCode =>
      Object.hash(minLatitude, maxLatitude, minLongitude, maxLongitude);
}

class _DistrictShape {
  const _DistrictShape({
    required this.name,
    required this.color,
    required this.labelPoint,
    required this.points,
  });

  final String name;
  final Color color;
  final _MapPoint labelPoint;
  final List<_MapPoint> points;
}

class _IslandShape {
  const _IslandShape({
    required this.center,
    required this.width,
    required this.height,
  });

  final _MapPoint center;
  final double width;
  final double height;
}

String? _districtNameForLocation(DeviceLocation location) {
  return _districtNameForPoint(
    _MapPoint(location.latitude, location.longitude),
  );
}

String? _districtNameForPoint(_MapPoint point) {
  for (final district in _HongKongMapPainter._districts.reversed) {
    if (_containsMapPoint(district.points, point)) {
      return district.name;
    }
  }

  return null;
}

_DistrictShape? _districtByName(String districtName) {
  for (final district in _HongKongMapPainter._districts) {
    if (district.name == districtName) {
      return district;
    }
  }
  return null;
}

List<_DistrictShape> _localizedDistrictsForDistrict(String? districtName) {
  final anchorDistrict = districtName == null
      ? null
      : _districtByName(districtName);
  if (anchorDistrict == null) {
    return const <_DistrictShape>[];
  }

  final districts = _HongKongMapPainter._districts.toList()
    ..sort((a, b) {
      if (a.name == anchorDistrict.name) {
        return -1;
      }
      if (b.name == anchorDistrict.name) {
        return 1;
      }

      final aDistance = _mapPointDistance(
        a.labelPoint,
        anchorDistrict.labelPoint,
      );
      final bDistance = _mapPointDistance(
        b.labelPoint,
        anchorDistrict.labelPoint,
      );
      final distanceCompare = aDistance.compareTo(bDistance);
      if (distanceCompare != 0) {
        return distanceCompare;
      }
      return _districtOrder(a.name).compareTo(_districtOrder(b.name));
    });

  return List.unmodifiable(districts.take(3));
}

List<_DistrictShape> _visibleDistrictsForRadar({
  required String? activeDistrictName,
  required List<RadarContact> contacts,
}) {
  final districts = <_DistrictShape>[
    ..._localizedDistrictsForDistrict(activeDistrictName),
  ];
  final seenDistrictNames = districts.map((district) => district.name).toSet();

  for (final contact in contacts.where((contact) => contact.isSosActive)) {
    final districtName = _districtNameForLocation(contact.location);
    if (districtName == null || seenDistrictNames.contains(districtName)) {
      continue;
    }
    final district = _districtByName(districtName);
    if (district == null) {
      continue;
    }
    districts.add(district);
    seenDistrictNames.add(district.name);
  }

  if (districts.isEmpty && contacts.any((contact) => contact.isSosActive)) {
    return _HongKongMapPainter._districts;
  }

  return List.unmodifiable(districts);
}

_MapBounds? _mapBoundsForDistricts(List<_DistrictShape> districts) {
  if (districts.isEmpty) {
    return null;
  }

  final points = districts.expand((district) => district.points).toList();
  var minLatitude = points.first.latitude;
  var maxLatitude = points.first.latitude;
  var minLongitude = points.first.longitude;
  var maxLongitude = points.first.longitude;

  for (final point in points.skip(1)) {
    minLatitude = min(minLatitude, point.latitude);
    maxLatitude = max(maxLatitude, point.latitude);
    minLongitude = min(minLongitude, point.longitude);
    maxLongitude = max(maxLongitude, point.longitude);
  }

  return _MapBounds(
    minLatitude: minLatitude,
    maxLatitude: maxLatitude,
    minLongitude: minLongitude,
    maxLongitude: maxLongitude,
  ).padded(0.18);
}

double _mapPointDistance(_MapPoint a, _MapPoint b) {
  final dLat = a.latitude - b.latitude;
  final dLng =
      (a.longitude - b.longitude) *
      cos(_degreesToRadians((a.latitude + b.latitude) / 2));
  return sqrt(dLat * dLat + dLng * dLng);
}

Rect _fitMapRect(Rect rect, _MapBounds bounds) {
  final targetAspect = bounds.physicalAspectRatio;
  final rectAspect = rect.width / rect.height;
  if (rectAspect > targetAspect) {
    final width = rect.height * targetAspect;
    return Rect.fromLTWH(
      rect.left + (rect.width - width) / 2,
      rect.top,
      width,
      rect.height,
    );
  }

  final height = rect.width / targetAspect;
  return Rect.fromLTWH(
    rect.left,
    rect.top + (rect.height - height) / 2,
    rect.width,
    height,
  );
}

bool _containsMapPoint(List<_MapPoint> polygon, _MapPoint point) {
  var inside = false;

  for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i, i += 1) {
    final current = polygon[i];
    final previous = polygon[j];
    final crossesLatitude =
        (current.latitude > point.latitude) !=
        (previous.latitude > point.latitude);

    if (!crossesLatitude) {
      continue;
    }

    final intersectionLongitude =
        (previous.longitude - current.longitude) *
            (point.latitude - current.latitude) /
            (previous.latitude - current.latitude) +
        current.longitude;

    if (point.longitude < intersectionLongitude) {
      inside = !inside;
    }
  }

  return inside;
}

Offset _projectLocationToMap(
  DeviceLocation location,
  Rect rect, [
  _MapBounds bounds = _MapBounds.hongKong,
]) {
  return _projectMapPoint(
    bounds.clampPoint(_MapPoint(location.latitude, location.longitude)),
    rect,
    bounds,
  );
}

Offset _projectMapPoint(
  _MapPoint point,
  Rect rect, [
  _MapBounds bounds = _MapBounds.hongKong,
]) {
  final clampedPoint = bounds.clampPoint(point);
  final x =
      (clampedPoint.longitude - bounds.minLongitude) / bounds.longitudeSpan;
  final y =
      1 - (clampedPoint.latitude - bounds.minLatitude) / bounds.latitudeSpan;
  return Offset(rect.left + rect.width * x, rect.top + rect.height * y);
}

_MapPoint _unprojectMapPoint(
  Offset point,
  Rect rect, [
  _MapBounds bounds = _MapBounds.hongKong,
]) {
  final longitude =
      bounds.minLongitude +
      ((point.dx - rect.left) / rect.width) * bounds.longitudeSpan;
  final latitude =
      bounds.maxLatitude -
      ((point.dy - rect.top) / rect.height) * bounds.latitudeSpan;

  return _MapPoint(latitude, longitude);
}

int _districtOrder(String districtName) {
  final index = _HongKongMapPainter._districts.indexWhere(
    (district) => district.name == districtName,
  );
  return index == -1 ? _HongKongMapPainter._districts.length : index;
}

class CommunityNetworkPage extends StatefulWidget {
  const CommunityNetworkPage({super.key, required this.enabled});

  final bool enabled;

  @override
  State<CommunityNetworkPage> createState() => _CommunityNetworkPageState();
}

class _CommunityNetworkPageState extends State<CommunityNetworkPage> {
  WebViewController? _controller;
  var _progress = 0;

  @override
  void initState() {
    super.initState();
    if (!widget.enabled) {
      return;
    }

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) => setState(() => _progress = progress),
          onPageFinished: (_) {
            if (!mounted) {
              return;
            }
            setState(() => _progress = 100);
          },
        ),
      )
      ..loadRequest(Uri.parse(_aiecoWebUrl));
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    return Scaffold(
      appBar: AppBar(
        title: const Text('社區網絡'),
        actions: [
          if (controller != null)
            IconButton(
              tooltip: '重新載入',
              onPressed: () => unawaited(controller.reload()),
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: controller == null
          ? const _WebPagePlaceholder()
          : Stack(
              children: [
                Positioned.fill(child: WebViewWidget(controller: controller)),
                if (_progress < 100)
                  Positioned(
                    left: 0,
                    top: 0,
                    right: 0,
                    child: LinearProgressIndicator(
                      value: _progress == 0 ? null : _progress / 100,
                    ),
                  ),
              ],
            ),
    );
  }
}

class _SosLightButton extends StatelessWidget {
  const _SosLightButton({required this.controller});

  final _SosLightController controller;

  Future<void> _handlePressed(BuildContext context) async {
    String? message;
    if (controller.active) {
      message = await controller.stop();
    } else {
      final confirmed = await _confirmStart(context);
      if (confirmed) {
        message = await controller.start();
      }
    }
    if (!context.mounted || message == null) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _confirmStart(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('啟動 SOS 燈？'),
          content: const Text('手機閃光燈會持續閃出 SOS 燈號，直到你再按一次停止。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              icon: const Icon(Icons.flash_on),
              label: const Text('確認啟動'),
            ),
          ],
        );
      },
    );
    return confirmed == true;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final active = controller.active;
        final foregroundColor = active ? Colors.white : const Color(0xFFC4512C);
        final backgroundColor = active
            ? const Color(0xFFC4512C)
            : const Color(0xFFFFEEE3);

        return Tooltip(
          message: active ? '停止 SOS 燈' : '啟動 SOS 燈',
          child: FilledButton.icon(
            onPressed: controller.busy ? null : () => _handlePressed(context),
            icon: controller.busy
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.flash_on, size: 16),
            label: const Text(
              'SOS 燈',
              maxLines: 1,
              overflow: TextOverflow.clip,
            ),
            style: FilledButton.styleFrom(
              backgroundColor: backgroundColor,
              foregroundColor: foregroundColor,
              disabledBackgroundColor: backgroundColor.withValues(alpha: 0.62),
              disabledForegroundColor: foregroundColor.withValues(alpha: 0.62),
              minimumSize: const Size(78, 36),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
        );
      },
    );
  }
}

class _SosLightController extends ChangeNotifier {
  static const MethodChannel _channel = MethodChannel(
    'hk.aieco.propagation_light/wifi_mesh',
  );
  static const _sosPattern = <_SosPulse>[
    _SosPulse(true, Duration(milliseconds: 220)),
    _SosPulse(false, Duration(milliseconds: 220)),
    _SosPulse(true, Duration(milliseconds: 220)),
    _SosPulse(false, Duration(milliseconds: 220)),
    _SosPulse(true, Duration(milliseconds: 220)),
    _SosPulse(false, Duration(milliseconds: 660)),
    _SosPulse(true, Duration(milliseconds: 660)),
    _SosPulse(false, Duration(milliseconds: 220)),
    _SosPulse(true, Duration(milliseconds: 660)),
    _SosPulse(false, Duration(milliseconds: 220)),
    _SosPulse(true, Duration(milliseconds: 660)),
    _SosPulse(false, Duration(milliseconds: 660)),
    _SosPulse(true, Duration(milliseconds: 220)),
    _SosPulse(false, Duration(milliseconds: 220)),
    _SosPulse(true, Duration(milliseconds: 220)),
    _SosPulse(false, Duration(milliseconds: 220)),
    _SosPulse(true, Duration(milliseconds: 220)),
    _SosPulse(false, Duration(milliseconds: 1540)),
  ];

  bool _active = false;
  bool _busy = false;
  bool _disposed = false;
  int _runId = 0;
  String? _errorMessage;

  bool get active => _active;
  bool get busy => _busy;

  Future<String?> toggle() {
    return _active ? stop() : start();
  }

  Future<String?> start() async {
    if (_busy || _active) {
      return null;
    }
    if (!Platform.isAndroid && !Platform.isIOS) {
      _errorMessage = 'SOS 燈需要 Android / iOS 手機閃光燈。';
      _notify();
      return _errorMessage;
    }

    final runId = ++_runId;
    _active = true;
    _busy = true;
    _errorMessage = null;
    _notify();

    final ready = await _setTorch(true);
    if (!_isCurrent(runId)) {
      await _setTorch(false, updateError: false);
      return null;
    }

    _busy = false;
    if (!ready) {
      _active = false;
      _runId += 1;
      _notify();
      return _errorMessage;
    }

    _notify();
    unawaited(
      _runPattern(
        runId,
        startIndex: 1,
        initialDelay: _sosPattern.first.duration,
      ),
    );
    return null;
  }

  Future<String?> stop() async {
    if (!_active && !_busy) {
      return null;
    }

    _active = false;
    _busy = true;
    _runId += 1;
    _notify();
    await _setTorch(false, updateError: false);
    _busy = false;
    _notify();
    return null;
  }

  Future<void> _runPattern(
    int runId, {
    required int startIndex,
    required Duration initialDelay,
  }) async {
    await Future<void>.delayed(initialDelay);

    var index = startIndex;
    while (_isCurrent(runId)) {
      final pulse = _sosPattern[index];
      final ok = await _setTorch(pulse.enabled);
      if (!_isCurrent(runId)) {
        return;
      }
      if (!ok && pulse.enabled) {
        _active = false;
        _runId += 1;
        await _setTorch(false, updateError: false);
        _notify();
        return;
      }
      await Future<void>.delayed(pulse.duration);
      index = (index + 1) % _sosPattern.length;
    }
  }

  Future<bool> _setTorch(bool enabled, {bool updateError = true}) async {
    try {
      await _channel.invokeMethod<Object?>('setTorch', <String, Object?>{
        'enabled': enabled,
      });
      return true;
    } on PlatformException catch (error) {
      if (updateError) {
        _errorMessage = error.message ?? 'SOS 燈操作失敗：${error.code}';
      }
    } on MissingPluginException {
      if (updateError) {
        _errorMessage = '目前平台未提供 SOS 燈原生控制。';
      }
    }
    return false;
  }

  bool _isCurrent(int runId) {
    return !_disposed && _active && _runId == runId;
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    final shouldStopTorch = _active || _busy;
    _disposed = true;
    _active = false;
    _runId += 1;
    if (shouldStopTorch) {
      unawaited(_setTorch(false, updateError: false));
    }
    super.dispose();
  }
}

class _SosPulse {
  const _SosPulse(this.enabled, this.duration);

  final bool enabled;
  final Duration duration;
}

class _WebPagePlaceholder extends StatelessWidget {
  const _WebPagePlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Center(child: Text(_aiecoWebUrl));
  }
}

class _StatusAndPeersPanel extends StatelessWidget {
  const _StatusAndPeersPanel({required this.mesh});

  final MeshChatService mesh;

  @override
  Widget build(BuildContext context) {
    final peers = mesh.peers;
    final isOnlineMode = mesh.networkMode == MeshNetworkMode.online;
    final modeTitle = isOnlineMode ? '線上光網' : '離線 mesh';
    final peerSummary = isOnlineMode
        ? '${peers.length} 個線上光點'
        : '${peers.length} 個附近節點';

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 400),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: mesh.isRunning
                          ? const Color(0xFFE0F2E9)
                          : const Color(0xFFFFEEE3),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      mesh.isRunning
                          ? (isOnlineMode ? Icons.public : Icons.hub)
                          : Icons.portable_wifi_off,
                      color: mesh.isRunning
                          ? const Color(0xFF0D7C66)
                          : const Color(0xFFC4512C),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          mesh.isRunning ? '$modeTitle 已啟動' : '$modeTitle 未啟動',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        Text(
                          peerSummary,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SegmentedButton<MeshNetworkMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment<MeshNetworkMode>(
                    value: MeshNetworkMode.online,
                    icon: Icon(Icons.public, size: 16),
                    label: Text('線上'),
                  ),
                  ButtonSegment<MeshNetworkMode>(
                    value: MeshNetworkMode.offline,
                    icon: Icon(Icons.hub_outlined, size: 16),
                    label: Text('離線'),
                  ),
                ],
                selected: {mesh.networkMode},
                onSelectionChanged: (selection) {
                  unawaited(mesh.setNetworkMode(selection.single));
                },
              ),
              const SizedBox(height: 10),
              _NetworkModeNotice(mesh: mesh),
              const SizedBox(height: 12),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFFFAFBF7),
                  border: Border.all(color: const Color(0xFFD7DED7)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.badge_outlined,
                        color: Color(0xFF0D7C66),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '你的光點名稱',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: const Color(0xFF66756D)),
                            ),
                            Text(
                              mesh.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Tooltip(
                        message: '光點名稱固定，不能更改',
                        child: Icon(Icons.lock_outline, size: 20),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                mesh.status,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: const Color(0xFF4B5F56)),
              ),
              const SizedBox(height: 12),
              if (peers.isEmpty)
                _EmptyPeers(
                  networkMode: mesh.networkMode,
                  onlineConfigured: mesh.onlineConfigured,
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: peers.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      return _PeerTile(peer: peers[index]);
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NetworkModeNotice extends StatelessWidget {
  const _NetworkModeNotice({required this.mesh});

  final MeshChatService mesh;

  @override
  Widget build(BuildContext context) {
    final isOnlineMode = mesh.networkMode == MeshNetworkMode.online;
    final icon = isOnlineMode ? Icons.cloud_done_outlined : Icons.router;
    final color = isOnlineMode && !mesh.onlineConfigured
        ? const Color(0xFFC4512C)
        : const Color(0xFF0D7C66);
    final text = isOnlineMode
        ? mesh.onlineConfigured
              ? '線上模式：入 APP 會連接 relay 聊天，不需要接同一 WiFi。'
              : '線上模式未設定 relay。請用 --dart-define=AIECO_ONLINE_RELAY_URL=wss://... 建置。'
        : '離線模式：同一 WiFi / mesh LAN 內自動尋找光點。';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFBF7),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE0E5DE)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: const Color(0xFF4B5F56)),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyPeers extends StatelessWidget {
  const _EmptyPeers({
    required this.networkMode,
    required this.onlineConfigured,
  });

  final MeshNetworkMode networkMode;
  final bool onlineConfigured;

  @override
  Widget build(BuildContext context) {
    final message = switch (networkMode) {
      MeshNetworkMode.online =>
        onlineConfigured ? '等待已進入 APP 的線上光點自動出現。' : '線上 relay 未設定，暫時不能連接線上光點。',
      MeshNetworkMode.offline => '等待同一 WiFi / mesh LAN 內已開啟本 app 的用戶自動配對。',
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFBF7),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE0E5DE)),
      ),
      child: Text(message),
    );
  }
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({required this.peer});

  final MeshPeer peer;

  @override
  Widget build(BuildContext context) {
    final seconds = DateTime.now().difference(peer.lastSeen).inSeconds;
    final age = seconds < 2 ? '剛剛' : '$seconds 秒前';
    final source = peer.isOnline ? '線上同步' : '自動配對';

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE0E5DE)),
      ),
      child: Row(
        children: [
          const CircleAvatar(
            radius: 18,
            backgroundColor: Color(0xFFDFF3EF),
            child: Icon(
              Icons.lightbulb_outline,
              size: 18,
              color: Color(0xFF0D7C66),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  peer.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                Text(
                  '$source · $age',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WifiMeshPanel extends StatefulWidget {
  const _WifiMeshPanel({
    required this.controller,
    required this.onNetworkReady,
    required this.onPeerReady,
    required this.scrollInternally,
  });

  final WifiMeshController controller;
  final Future<void> Function() onNetworkReady;
  final Future<void> Function(WifiP2pPeer peer) onPeerReady;
  final bool scrollInternally;

  @override
  State<_WifiMeshPanel> createState() => _WifiMeshPanelState();
}

class _WifiMeshPanelState extends State<_WifiMeshPanel> {
  WifiNetworkInfo? _selectedWifi;

  WifiNetworkInfo? _currentSelectedWifi() {
    final selected = _selectedWifi;
    if (selected == null) {
      return null;
    }

    for (final network in widget.controller.wifiNetworks) {
      if (network.ssid == selected.ssid) {
        return network;
      }
    }

    return null;
  }

  void _selectWifi(WifiNetworkInfo network) {
    setState(() {
      _selectedWifi = network;
    });
  }

  Future<void> _connectWifi(WifiNetworkInfo network) async {
    _selectWifi(network);
    await widget.controller.connectWifi(network);
    await widget.onNetworkReady();
  }

  Future<void> _connectPeer(WifiP2pPeer peer) async {
    await widget.controller.connectPeer(peer);
    await widget.onPeerReady(peer);
  }

  Future<void> _scanPeersAndConnectMesh() async {
    await widget.controller.discoverAppPeers();
    final meshPeer = widget.controller.firstAppP2pPeer;
    if (meshPeer == null) {
      widget.controller.setLocalMessage(
        widget.controller.isIOS
            ? '未找到同一 WiFi 內已開啟本 app 的 LAN peer。請兩部手機都按「權限」，並允許本地網絡。'
            : '未找到已開啟本 app 的 Wi‑Fi Direct peer。請兩部手機都按「權限」，並保持 WiFi 開啟。',
      );
      return;
    }

    await _connectPeer(meshPeer);
  }

  Future<void> _submitSelectedWifi() async {
    final network = _currentSelectedWifi();
    if (network == null) {
      widget.controller.setLocalMessage('請先在下方選一個 WiFi。');
      return;
    }

    await _connectWifi(network);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = widget.controller;
    final group = controller.group;
    final hotspot = controller.hotspot;
    final selectedWifi = _currentSelectedWifi();
    final canConnectSelected = selectedWifi != null && !controller.busy;
    final meshPeer = controller.firstAppP2pPeer;
    final wirelessContent = <Widget>[
      _WifiNotice(controller: controller),
      if (group != null) ...[
        const SizedBox(height: 12),
        _CredentialBox(
          title: 'Wi‑Fi Direct Group',
          ssid: group.networkName,
          passphrase: group.passphrase,
          detail:
              '${group.isGroupOwner ? '本機是 group owner' : '本機是 client'} · ${group.clients.length} client',
        ),
      ],
      if (hotspot != null) ...[
        const SizedBox(height: 12),
        _CredentialBox(
          title: 'AIECO 本地熱點',
          ssidLabel: '實際 SSID',
          passphraseLabel: '實際密碼',
          ssid: hotspot.ssid,
          passphrase: hotspot.preSharedKey,
          detail:
              'Android 會分配實際 WiFi 名稱和密碼，不能固定為 aiecohk。其他手機請連接上方資料，再打開傳播光聊天。',
        ),
      ],
      const SizedBox(height: 12),
      _MeshAutoConnectNotice(controller: controller, meshPeer: meshPeer),
      const SizedBox(height: 8),
      if (!controller.isIOS) ...[
        _BluetoothHotspotNotice(controller: controller),
        const SizedBox(height: 8),
      ],
      Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: controller.busy
                  ? null
                  : () => unawaited(_scanPeersAndConnectMesh()),
              icon: const Icon(Icons.radar),
              label: Text(controller.isIOS ? '掃 LAN 並連接' : '掃 P2P 並連接'),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: canConnectSelected
                ? () => unawaited(_submitSelectedWifi())
                : null,
            icon: const Icon(Icons.login),
            label: const Text('連接所選'),
          ),
        ],
      ),
      const SizedBox(height: 10),
      if (controller.p2pPeers.isNotEmpty) ...[
        Text(
          controller.isIOS ? 'WiFi LAN peers' : 'Wi‑Fi Direct peers',
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        ...controller.p2pPeers.map(
          (peer) => _P2pPeerTile(
            peer: peer,
            onConnect: () => unawaited(_connectPeer(peer)),
          ),
        ),
        const SizedBox(height: 12),
      ],
      if (controller.wifiNetworks.isNotEmpty) ...[
        Text(
          '附近 WiFi',
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        ...controller.wifiNetworks.map(
          (network) => _WifiNetworkTile(
            network: network,
            selected: selectedWifi?.ssid == network.ssid,
            onSelect: () => _selectWifi(network),
            onConnect: () => unawaited(_connectWifi(network)),
          ),
        ),
      ],
      if (controller.p2pPeers.isEmpty && controller.wifiNetworks.isEmpty)
        _EmptyWireless(controller: controller),
      const SizedBox(height: 28),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: controller.isAndroid
                        ? const Color(0xFFE7F0FF)
                        : const Color(0xFFF3F1EC),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    controller.boundToBluetooth
                        ? Icons.bluetooth_connected
                        : controller.isAndroid
                        ? Icons.wifi_tethering
                        : Icons.wifi,
                    color: controller.isAndroid
                        ? const Color(0xFF285BAA)
                        : const Color(0xFF756D61),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        controller.isIOS ? 'WiFi LAN peers' : 'WiFi P2P / 熱點',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        controller.summary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (controller.busy)
                  const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    tooltip: '刷新狀態',
                    onPressed: () => unawaited(controller.refreshStatus()),
                    icon: const Icon(Icons.refresh),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: controller.busy
                      ? null
                      : () => unawaited(controller.requestPermissions()),
                  icon: const Icon(Icons.verified_user_outlined),
                  label: const Text('權限'),
                ),
                FilledButton.icon(
                  onPressed: controller.busy
                      ? null
                      : () => unawaited(controller.discoverAppPeers()),
                  icon: const Icon(Icons.radar),
                  label: Text(controller.isIOS ? '掃 LAN' : '掃 P2P'),
                ),
                if (!controller.isIOS) ...[
                  OutlinedButton.icon(
                    onPressed: controller.busy
                        ? null
                        : () => unawaited(controller.createGroup()),
                    icon: const Icon(Icons.hub_outlined),
                    label: const Text('開群組'),
                  ),
                  OutlinedButton.icon(
                    onPressed: controller.busy
                        ? null
                        : () => unawaited(controller.toggleHotspot()),
                    icon: Icon(
                      hotspot == null
                          ? Icons.wifi_tethering
                          : Icons.stop_circle,
                    ),
                    label: Text(hotspot == null ? '開熱點' : '關熱點'),
                  ),
                  OutlinedButton.icon(
                    onPressed: controller.busy
                        ? null
                        : () => unawaited(
                            controller.openBluetoothTetherSettings(),
                          ),
                    icon: const Icon(Icons.bluetooth_connected),
                    label: const Text('藍芽熱點'),
                  ),
                ],
                IconButton.outlined(
                  tooltip: 'WiFi 設定',
                  onPressed: controller.busy
                      ? null
                      : () => unawaited(controller.openWifiSettings()),
                  icon: const Icon(Icons.settings),
                ),
                if (!controller.isIOS)
                  IconButton.outlined(
                    tooltip: '藍芽設定',
                    onPressed: controller.busy
                        ? null
                        : () => unawaited(controller.openBluetoothSettings()),
                    icon: const Icon(Icons.bluetooth),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (widget.scrollInternally)
              Expanded(child: ListView(children: wirelessContent))
            else
              ...wirelessContent,
          ],
        ),
      ),
    );
  }
}

class _WifiNotice extends StatelessWidget {
  const _WifiNotice({required this.controller});

  final WifiMeshController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFBF7),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE0E5DE)),
      ),
      child: Text(
        controller.lastMessage,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

class _MeshAutoConnectNotice extends StatelessWidget {
  const _MeshAutoConnectNotice({
    required this.controller,
    required this.meshPeer,
  });

  final WifiMeshController controller;
  final WifiP2pPeer? meshPeer;

  @override
  Widget build(BuildContext context) {
    final peer = meshPeer;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF4FF),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFC9DDF7)),
      ),
      child: Row(
        children: [
          const Icon(Icons.hub_outlined, color: Color(0xFF285BAA)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              peer == null
                  ? controller.isIOS
                        ? 'MESH 自動連接會掃同一 WiFi 內的 app peers，不用輸入 IP。掃到後會用 TCP mesh 同步。'
                        : 'MESH 自動連接會掃 Wi‑Fi Direct app peers，不用輸入密碼。掃到後會發出 P2P 連接邀請。'
                  : '已找到 app peer：${peer.name}，可直接連接。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _BluetoothHotspotNotice extends StatelessWidget {
  const _BluetoothHotspotNotice({required this.controller});

  final WifiMeshController controller;

  @override
  Widget build(BuildContext context) {
    final text = _statusText();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF1EDFF),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFD8CDF6)),
      ),
      child: Row(
        children: [
          Icon(
            controller.boundToBluetooth
                ? Icons.bluetooth_connected
                : Icons.bluetooth,
            color: const Color(0xFF5A46A0),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }

  String _statusText() {
    if (!controller.isAndroid) {
      return '藍芽熱點目前只在 Android 系統設定開放。';
    }
    if (!controller.bluetoothSupported) {
      return '此裝置未報告藍芽支援。';
    }
    if (controller.boundToBluetooth) {
      return '已偵測藍芽網絡，沒有 WiFi 本地網絡時會用藍芽網絡通訊。';
    }
    if (controller.bluetoothEnabled) {
      return '藍芽已開啟，可到系統設定啟用藍芽網絡共享。';
    }
    return '藍芽未開啟，可先到藍芽設定配對裝置。';
  }
}

class _CredentialBox extends StatelessWidget {
  const _CredentialBox({
    required this.title,
    required this.ssid,
    required this.passphrase,
    required this.detail,
    this.ssidLabel = 'SSID',
    this.passphraseLabel = '密碼',
  });

  final String title;
  final String? ssid;
  final String? passphrase;
  final String detail;
  final String ssidLabel;
  final String passphraseLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFE7F0FF),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFC9D9F5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          SelectableText('$ssidLabel: ${ssid ?? '系統未提供'}'),
          SelectableText('$passphraseLabel: ${passphrase ?? '系統未提供'}'),
          const SizedBox(height: 4),
          Text(detail, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _P2pPeerTile extends StatelessWidget {
  const _P2pPeerTile({required this.peer, required this.onConnect});

  final WifiP2pPeer peer;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFE0E5DE)),
        ),
        child: Row(
          children: [
            const CircleAvatar(
              radius: 18,
              backgroundColor: Color(0xFFE7F0FF),
              child: Icon(Icons.devices, size: 18, color: Color(0xFF285BAA)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    peer.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  Row(
                    children: [
                      if (peer.isAppPeer) ...[
                        const _AppPeerBadge(),
                        const SizedBox(width: 6),
                      ],
                      Expanded(
                        child: Text(
                          peer.hasLanEndpoint
                              ? '同一 WiFi · ${peer.host}:${peer.port}'
                              : peer.isAppPeer
                              ? '已開啟本 app · ${peer.statusText}'
                              : 'Wi‑Fi Direct 裝置 · ${peer.statusText}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: peer.hasLanEndpoint ? '連接 LAN peer' : '連接 P2P',
              onPressed: onConnect,
              icon: const Icon(Icons.link),
            ),
          ],
        ),
      ),
    );
  }
}

class _AppPeerBadge extends StatelessWidget {
  const _AppPeerBadge();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFEAF4FF),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFC9DDF7)),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          'APP',
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}

class _WifiNetworkTile extends StatelessWidget {
  const _WifiNetworkTile({
    required this.network,
    required this.selected,
    required this.onSelect,
    required this.onConnect,
  });

  final WifiNetworkInfo network;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onSelect,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: selected ? const Color(0xFFE0F2E9) : Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected
                    ? const Color(0xFF0D7C66)
                    : const Color(0xFFE0E5DE),
              ),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: Colors.white,
                  child: Icon(
                    network.secured ? Icons.lock : Icons.lock_open,
                    size: 18,
                    color: const Color(0xFF0D7C66),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              network.ssid,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          if (network.isMeshNetwork)
                            const Padding(
                              padding: EdgeInsets.only(left: 6),
                              child: _MeshNetworkBadge(),
                            ),
                        ],
                      ),
                      Text(
                        '${network.level} dBm · ${network.frequency} MHz',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (selected)
                  const Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: Icon(Icons.check_circle, color: Color(0xFF0D7C66)),
                  ),
                IconButton(
                  tooltip: '連接 WiFi',
                  onPressed: onConnect,
                  icon: const Icon(Icons.login),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MeshNetworkBadge extends StatelessWidget {
  const _MeshNetworkBadge();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFE0F2E9),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFB9DDC8)),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          'MESH',
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}

class _EmptyWireless extends StatelessWidget {
  const _EmptyWireless({required this.controller});

  final WifiMeshController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFBF7),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE0E5DE)),
      ),
      child: Text(
        controller.isIOS
            ? '未有同一 WiFi 內的 app peers。先按「權限」，允許本地網絡，再掃 LAN。'
            : '未有 Wi‑Fi Direct app peers 或 WiFi 掃描結果。先按「權限」，再掃 P2P。',
      ),
    );
  }
}

class _ChatPanel extends StatefulWidget {
  const _ChatPanel({
    required this.mesh,
    required this.messageController,
    required this.scrollController,
    required this.onSend,
    required this.onCreateRoom,
    required this.onShareSupply,
    required this.onQuoteUserName,
  });

  final MeshChatService mesh;
  final TextEditingController messageController;
  final ScrollController scrollController;
  final Future<void> Function() onSend;
  final Future<void> Function() onCreateRoom;
  final Future<void> Function() onShareSupply;
  final ValueChanged<String> onQuoteUserName;

  @override
  State<_ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<_ChatPanel> {
  String? _lastObservedRoomId;
  String? _lastObservedMessageId;
  var _lastObservedMessageCount = 0;
  var _needsScrollToEnd = false;
  var _scrollFrameQueued = false;

  void _observeMessages(MeshRoom activeRoom, List<MeshMessage> messages) {
    final lastMessageId = messages.isEmpty ? null : messages.last.id;
    final roomChanged = _lastObservedRoomId != activeRoom.id;
    final messagesChanged =
        _lastObservedMessageId != lastMessageId ||
        _lastObservedMessageCount != messages.length;

    if (!roomChanged && !messagesChanged) {
      if (_needsScrollToEnd) {
        _queueScrollToEnd();
      }
      return;
    }

    _lastObservedRoomId = activeRoom.id;
    _lastObservedMessageId = lastMessageId;
    _lastObservedMessageCount = messages.length;

    if (messages.isNotEmpty) {
      _needsScrollToEnd = true;
      _queueScrollToEnd();
    }
  }

  void _queueScrollToEnd() {
    if (_scrollFrameQueued) {
      return;
    }

    _scrollFrameQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollFrameQueued = false;
      if (!mounted || !_needsScrollToEnd) {
        return;
      }

      final scrollController = widget.scrollController;
      if (!scrollController.hasClients) {
        return;
      }

      _needsScrollToEnd = false;
      scrollController.animateTo(
        scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final activeRoom = widget.mesh.activeRoom;
    final messages = widget.mesh.activeRoomMessages;
    _observeMessages(activeRoom, messages);

    return Card(
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFFE0E5DE))),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.forum_outlined, color: Color(0xFF0D7C66)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        key: const ValueKey('active-room-name'),
                        activeRoom.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                    Text(
                      '${messages.length} 則',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _OnlineUsersStrip(
                  users: widget.mesh.onlineUsers,
                  onQuoteUserName: widget.onQuoteUserName,
                  onLikeUser: widget.mesh.likeUser,
                ),
                const SizedBox(height: 10),
                _RoomSelector(
                  rooms: widget.mesh.rooms,
                  activeRoomId: activeRoom.id,
                  onSelectRoom: widget.mesh.setActiveRoom,
                  onCreateRoom: widget.onCreateRoom,
                ),
                const SizedBox(height: 10),
                _SupplyShareStrip(
                  supplies: widget.mesh.supplies,
                  onShareSupply: widget.onShareSupply,
                  canMarkTaken: widget.mesh.canMarkSupplyTaken,
                  onMarkTaken: widget.mesh.markSupplyTaken,
                ),
              ],
            ),
          ),
          Expanded(
            child: messages.isEmpty
                ? const _EmptyMessages()
                : ListView.builder(
                    controller: widget.scrollController,
                    padding: const EdgeInsets.all(14),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      return _MessageBubble(message: messages[index]);
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('chat-message-input'),
                    controller: widget.messageController,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => unawaited(widget.onSend()),
                    decoration: InputDecoration(
                      hintText: '傳送到 ${activeRoom.name}',
                      prefixIcon: const Icon(Icons.chat_bubble_outline),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                IconButton.filled(
                  tooltip: '送出',
                  onPressed: () => unawaited(widget.onSend()),
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _OnlineUsersStrip extends StatelessWidget {
  const _OnlineUsersStrip({
    required this.users,
    required this.onQuoteUserName,
    required this.onLikeUser,
  });

  final List<MeshOnlineUser> users;
  final ValueChanged<String> onQuoteUserName;
  final ValueChanged<String> onLikeUser;

  @override
  Widget build(BuildContext context) {
    final onlineCount = users.length;
    final sosCount = users.where((user) => user.isSosActive).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.people_alt_outlined, size: 16),
            const SizedBox(width: 6),
            Text(
              '在線用家',
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(width: 8),
            Text(
              '$onlineCount 人在線',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: const Color(0xFF66756D)),
            ),
            if (sosCount > 0) ...[
              const SizedBox(width: 8),
              const Icon(
                Icons.warning_amber,
                size: 16,
                color: Color(0xFFB00020),
              ),
              const SizedBox(width: 3),
              Text(
                '求救 $sosCount',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: const Color(0xFFB00020),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
            const Spacer(),
            TextButton.icon(
              key: const ValueKey('online-user-list-button'),
              onPressed: () => _openOnlineUserList(context),
              icon: const Icon(Icons.manage_search, size: 16),
              label: const Text('找人'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 42,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            itemCount: users.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final user = users[index];
              final label = user.isMe ? '${user.name}（你）' : user.name;
              final isSosActive = user.isSosActive;
              return DecoratedBox(
                decoration: BoxDecoration(
                  color: isSosActive
                      ? const Color(0xFFFFEEE9)
                      : user.isMe
                      ? const Color(0xFFE0F2E9)
                      : const Color(0xFFFAFBF7),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isSosActive
                        ? const Color(0xFFE0B8AE)
                        : const Color(0xFFD7DED7),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.only(left: 6, right: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ActionChip(
                        key: ValueKey(user.isMe ? 'online-user-me' : user.id),
                        avatar: Icon(
                          isSosActive
                              ? Icons.warning_amber
                              : user.isMe
                              ? Icons.person_pin_circle
                              : Icons.person_outline,
                          size: 16,
                          color: isSosActive ? const Color(0xFFB00020) : null,
                        ),
                        label: Text(
                          isSosActive
                              ? '$label · 求救 · 信用 ${user.creditScore}'
                              : '$label · 信用 ${user.creditScore}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        visualDensity: VisualDensity.compact,
                        side: BorderSide.none,
                        backgroundColor: Colors.transparent,
                        tooltip: '引用用戶名稱聊天',
                        onPressed: () => onQuoteUserName(user.name),
                      ),
                      Tooltip(
                        message: user.isMe
                            ? '不能為自己加信用分'
                            : user.likedByMe
                            ? '已加信用分'
                            : '為光點加信用分',
                        child: IconButton(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          onPressed: user.isMe || user.likedByMe
                              ? null
                              : () => onLikeUser(user.id),
                          icon: Icon(
                            user.likedByMe
                                ? Icons.thumb_up_alt
                                : Icons.thumb_up_alt_outlined,
                            size: 18,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _openOnlineUserList(BuildContext context) {
    var query = '';

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final cleanQuery = query.trim();
            final filteredUsers = cleanQuery.isEmpty
                ? users
                : users
                      .where((user) => user.name.contains(cleanQuery))
                      .toList();
            final bottomInset = MediaQuery.viewInsetsOf(sheetContext).bottom;
            final maxHeight = MediaQuery.sizeOf(sheetContext).height * 0.75;

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + bottomInset),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxHeight),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.people_alt_outlined,
                            size: 18,
                            color: Color(0xFF0D7C66),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '在線用家',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                          ),
                          Text(
                            '${filteredUsers.length}/${users.length}',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: const Color(0xFF66756D)),
                          ),
                          const SizedBox(width: 4),
                          IconButton(
                            tooltip: '關閉',
                            onPressed: () => Navigator.of(sheetContext).pop(),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        key: const ValueKey('online-user-search-input'),
                        autofocus: true,
                        decoration: const InputDecoration(
                          labelText: '搜尋光點名稱',
                          prefixIcon: Icon(Icons.search),
                        ),
                        onChanged: (value) {
                          setSheetState(() => query = value);
                        },
                      ),
                      const SizedBox(height: 12),
                      if (filteredUsers.isEmpty)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFAFBF7),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFFE0E5DE)),
                          ),
                          child: const Text('找不到符合的在線光點。'),
                        )
                      else
                        Flexible(
                          child: ListView.separated(
                            shrinkWrap: true,
                            itemCount: filteredUsers.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final user = filteredUsers[index];
                              return _OnlineUserListTile(
                                user: user,
                                onQuoteUserName: (name) {
                                  Navigator.of(sheetContext).pop();
                                  onQuoteUserName(name);
                                },
                                onLikeUser: (userId) {
                                  Navigator.of(sheetContext).pop();
                                  onLikeUser(userId);
                                },
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _OnlineUserListTile extends StatelessWidget {
  const _OnlineUserListTile({
    required this.user,
    required this.onQuoteUserName,
    required this.onLikeUser,
  });

  final MeshOnlineUser user;
  final ValueChanged<String> onQuoteUserName;
  final ValueChanged<String> onLikeUser;

  @override
  Widget build(BuildContext context) {
    final label = user.isMe ? '${user.name}（你）' : user.name;
    final isSosActive = user.isSosActive;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: isSosActive
            ? const Color(0xFFFFEEE9)
            : user.isMe
            ? const Color(0xFFE0F2E9)
            : const Color(0xFFFAFBF7),
        child: Icon(
          isSosActive
              ? Icons.warning_amber
              : user.isMe
              ? Icons.person_pin_circle
              : Icons.person_outline,
          size: 18,
          color: isSosActive
              ? const Color(0xFFB00020)
              : const Color(0xFF0D7C66),
        ),
      ),
      title: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
      subtitle: Text(
        isSosActive
            ? '求救光點 · 信用 ${user.creditScore}'
            : '信用 ${user.creditScore}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '引用用戶名稱聊天',
            onPressed: () => onQuoteUserName(user.name),
            icon: const Icon(Icons.format_quote),
          ),
          IconButton(
            tooltip: user.isMe
                ? '不能為自己加信用分'
                : user.likedByMe
                ? '已加信用分'
                : '為光點加信用分',
            onPressed: user.isMe || user.likedByMe
                ? null
                : () => onLikeUser(user.id),
            icon: Icon(
              user.likedByMe ? Icons.thumb_up_alt : Icons.thumb_up_alt_outlined,
            ),
          ),
        ],
      ),
      onTap: () => onQuoteUserName(user.name),
    );
  }
}

class _RoomSelector extends StatelessWidget {
  const _RoomSelector({
    required this.rooms,
    required this.activeRoomId,
    required this.onSelectRoom,
    required this.onCreateRoom,
  });

  final List<MeshRoom> rooms;
  final String activeRoomId;
  final ValueChanged<String> onSelectRoom;
  final Future<void> Function() onCreateRoom;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 38,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: rooms.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final room = rooms[index];
                return ChoiceChip(
                  selected: room.id == activeRoomId,
                  onSelected: (_) => onSelectRoom(room.id),
                  label: Text(room.name),
                  avatar: const Icon(Icons.bubble_chart_outlined, size: 16),
                );
              },
            ),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: () => unawaited(onCreateRoom()),
          icon: const Icon(Icons.add),
          label: const Text('建立光團'),
        ),
      ],
    );
  }
}

class _SupplyShareStrip extends StatelessWidget {
  const _SupplyShareStrip({
    required this.supplies,
    required this.onShareSupply,
    required this.canMarkTaken,
    required this.onMarkTaken,
  });

  final List<MeshSupply> supplies;
  final Future<void> Function() onShareSupply;
  final bool Function(MeshSupply supply) canMarkTaken;
  final ValueChanged<String> onMarkTaken;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.inventory_2_outlined, size: 16),
            const SizedBox(width: 6),
            Text(
              '物資分享',
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(width: 8),
            Text(
              '${supplies.length} 項',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: const Color(0xFF66756D)),
            ),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: () => unawaited(onShareSupply()),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('分享物資'),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (supplies.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFFAFBF7),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE0E5DE)),
            ),
            child: const Text('暫未有人分享物資。可先分享水、電池、藥物、食物或集合點資訊。'),
          )
        else
          SizedBox(
            height: 96,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: supplies.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final supply = supplies[index];
                return _SupplyTile(
                  supply: supply,
                  canMarkTaken: canMarkTaken(supply),
                  onMarkTaken: () => onMarkTaken(supply.id),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _SupplyTile extends StatelessWidget {
  const _SupplyTile({
    required this.supply,
    required this.canMarkTaken,
    required this.onMarkTaken,
  });

  final MeshSupply supply;
  final bool canMarkTaken;
  final VoidCallback onMarkTaken;

  @override
  Widget build(BuildContext context) {
    final quantity = supply.quantity.isEmpty ? '未列數量' : supply.quantity;
    final note = supply.note.isEmpty ? '未列交收資料' : supply.note;

    return SizedBox(
      width: 210,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 7, 8, 6),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFE0E5DE)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.volunteer_activism_outlined,
                  size: 16,
                  color: Color(0xFF0D7C66),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    supply.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              quantity,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              note,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 3),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${supply.offeredByName} · ${_formatShortTime(supply.createdAt)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF66756D),
                    ),
                  ),
                ),
                if (canMarkTaken)
                  TextButton.icon(
                    onPressed: onMarkTaken,
                    icon: const Icon(Icons.task_alt, size: 14),
                    label: const Text('已取完'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      textStyle: Theme.of(context).textTheme.labelSmall,
                      minimumSize: const Size(0, 24),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _formatShortTime(DateTime time) {
    final local = time.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

class _EmptyMessages extends StatelessWidget {
  const _EmptyMessages();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  color: const Color(0xFFE0F2E9),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.light_mode_outlined,
                  color: Color(0xFF0D7C66),
                  size: 34,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                '未有訊息',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              const Text(
                '同一 WiFi、熱點或已互通的 mesh 網段內，用戶開啟此 app 後即可互相傳訊。',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final MeshMessage message;

  @override
  Widget build(BuildContext context) {
    final alignment = message.isMine
        ? CrossAxisAlignment.end
        : CrossAxisAlignment.start;
    final bubbleColor = message.isMine
        ? const Color(0xFF0D7C66)
        : const Color(0xFFF0F3EE);
    final textColor = message.isMine ? Colors.white : const Color(0xFF17211E);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: alignment,
        children: [
          Text(
            '${message.senderName} · ${_formatTime(message.sentAt)}',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: const Color(0xFF66756D)),
          ),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: bubbleColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Text(
                  message.text,
                  style: TextStyle(color: textColor, height: 1.35),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatTime(DateTime time) {
    final local = time.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

class WifiMeshController extends ChangeNotifier {
  WifiMeshController() {
    if (_nativeWirelessBridgeAvailable) {
      unawaited(refreshStatus());
    } else {
      _lastMessage = '目前平台未提供 Wi‑Fi peer 原生控制，可使用同一 WiFi LAN chat。';
    }
  }

  static const MethodChannel _channel = MethodChannel(
    'hk.aieco.propagation_light/wifi_mesh',
  );

  bool _busy = false;
  bool _wifiDirectSupported = false;
  bool _wifiPeerSupported = false;
  bool _hotspotSupported = false;
  bool _bluetoothSupported = false;
  bool _wifiEnabled = false;
  bool _bluetoothEnabled = false;
  bool _boundToWifi = false;
  bool _boundToBluetooth = false;
  int _networkGeneration = 0;
  String _lastMessage = '正在讀取 Wi‑Fi mesh 狀態。';
  WifiP2pConnection? _connection;
  WifiDirectGroup? _group;
  WifiHotspotInfo? _hotspot;
  List<WifiP2pPeer> _p2pPeers = <WifiP2pPeer>[];
  List<WifiNetworkInfo> _wifiNetworks = <WifiNetworkInfo>[];

  bool get isAndroid => Platform.isAndroid;
  bool get isIOS => Platform.isIOS;
  bool get busy => _busy;
  bool get wifiDirectSupported => _wifiDirectSupported;
  bool get wifiPeerSupported => _wifiPeerSupported;
  bool get hotspotSupported => _hotspotSupported;
  bool get bluetoothSupported => _bluetoothSupported;
  bool get wifiEnabled => _wifiEnabled;
  bool get bluetoothEnabled => _bluetoothEnabled;
  bool get boundToWifi => _boundToWifi;
  bool get boundToBluetooth => _boundToBluetooth;
  int get networkGeneration => _networkGeneration;
  String get lastMessage => _lastMessage;
  WifiP2pConnection? get connection => _connection;
  WifiDirectGroup? get group => _group;
  WifiHotspotInfo? get hotspot => _hotspot;
  List<WifiP2pPeer> get p2pPeers => List.unmodifiable(_p2pPeers);
  List<WifiNetworkInfo> get wifiNetworks => List.unmodifiable(_wifiNetworks);
  WifiP2pPeer? get firstAppP2pPeer {
    for (final peer in _p2pPeers) {
      if (peer.isAppPeer && peer.canInvite) {
        return peer;
      }
    }
    return null;
  }

  WifiNetworkInfo? get firstMeshNetwork {
    for (final network in _wifiNetworks) {
      if (network.isMeshNetwork) {
        return network;
      }
    }
    return null;
  }

  void setLocalMessage(String message) {
    _lastMessage = message;
    notifyListeners();
  }

  String get summary {
    if (isIOS) {
      if (_p2pPeers.isNotEmpty) {
        return '已找到 ${_p2pPeers.length} 個 WiFi LAN peer';
      }
      return _boundToWifi ? '可掃描 WiFi LAN peers' : '等待同一 WiFi LAN';
    }
    if (!_nativeWirelessBridgeAvailable) {
      return 'desktop 使用 LAN chat';
    }
    if (_connection?.groupFormed == true) {
      return _connection!.isGroupOwner ? 'P2P 群組 owner' : '已接入 P2P 群組';
    }
    if (_hotspot != null) {
      return 'AIECO 本地熱點已開啟';
    }
    if (_boundToBluetooth) {
      return '已接入藍芽網絡';
    }
    if (!_wifiDirectSupported && !_wifiPeerSupported && !_bluetoothSupported) {
      return '此裝置未報告 Wi‑Fi Direct / 藍芽';
    }
    if (!_wifiDirectSupported) {
      return _bluetoothEnabled ? '可使用藍芽熱點' : '藍芽未開啟';
    }
    return _wifiEnabled ? '可掃描 P2P / WiFi' : 'WiFi 未開啟';
  }

  Future<void> refreshStatus({bool quiet = false}) async {
    await _callStatus(
      'status',
      successMessage: 'Wi‑Fi mesh 狀態已更新。',
      showBusy: !quiet,
      updateMessage: !quiet,
    );
  }

  Future<void> requestPermissions({bool automatic = false}) async {
    await _callStatus(
      'requestPermissions',
      successMessage: automatic
          ? '已自動要求無線與定位權限。'
          : isIOS
          ? '已要求本地網絡權限。'
          : '已要求 Wi‑Fi 權限。',
    );
  }

  Future<void> discoverPeers() async {
    await _callStatus(
      'discoverPeers',
      successMessage: isIOS
          ? '正在掃描 WiFi LAN peers。'
          : '正在掃描 Wi‑Fi Direct peers。',
    );
  }

  Future<void> discoverAppPeers() async {
    await _callStatus(
      'discoverAppPeers',
      successMessage: isIOS
          ? '正在掃描同一 WiFi 內的 app peers。'
          : '正在掃描 Wi‑Fi Direct app peers。',
    );
  }

  Future<void> scanWifi() async {
    await _callStatus('scanWifi', successMessage: '附近 WiFi 掃描已更新。');
  }

  Future<void> connectPeer(WifiP2pPeer peer) async {
    await _callStatus(
      'connectPeer',
      arguments: <String, Object?>{
        'deviceAddress': peer.address,
        'host': peer.host,
        'port': peer.port,
      },
      successMessage: isIOS
          ? '已選取 ${peer.name}，正在用 WiFi LAN mesh 同步。'
          : '已向 ${peer.name} 發出 Wi‑Fi Direct 連接邀請。',
    );
  }

  Future<void> connectWifi(WifiNetworkInfo network) async {
    await _callStatus(
      'connectWifi',
      arguments: <String, Object?>{'ssid': network.ssid, 'passphrase': ''},
      successMessage: '已要求連接 WiFi：${network.ssid}',
    );
  }

  Future<void> createGroup() async {
    await _callStatus(
      'createGroup',
      successMessage: '已要求建立 Wi‑Fi Direct group。',
    );
  }

  Future<void> removeGroup() async {
    await _callStatus(
      'removeGroup',
      successMessage: '已要求移除 Wi‑Fi Direct group。',
    );
  }

  Future<void> toggleHotspot() async {
    if (_hotspot == null) {
      await _callStatus(
        'startLocalOnlyHotspot',
        successMessage: 'AIECO 本地熱點已啟動。請把其他手機連到顯示的 SSID。',
      );
    } else {
      await _callStatus('stopLocalOnlyHotspot', successMessage: '本地熱點已停止。');
    }
  }

  Future<void> openWifiSettings() async {
    await _callStatus(
      'openWifiSettings',
      successMessage: isIOS ? '已打開 iOS 設定。' : '已打開 Android WiFi 設定。',
    );
  }

  Future<void> openBluetoothSettings() async {
    await _callStatus(
      'openBluetoothSettings',
      successMessage: '已打開 Android 藍芽設定。',
    );
  }

  Future<void> openBluetoothTetherSettings() async {
    await _callStatus(
      'openBluetoothTetherSettings',
      successMessage: '已打開 Android 熱點與網絡共享設定。',
    );
  }

  Future<void> openAppSettings() async {
    await _callStatus('openAppSettings', successMessage: '已打開 app 權限設定。');
  }

  Future<void> _callStatus(
    String method, {
    Object? arguments,
    required String successMessage,
    bool showBusy = true,
    bool updateMessage = true,
  }) async {
    if (!_nativeWirelessBridgeAvailable) {
      if (updateMessage) {
        _lastMessage = '此功能需要 Android / iOS 原生 Wi‑Fi peer API。';
        notifyListeners();
      }
      return;
    }

    if (showBusy) {
      _busy = true;
      notifyListeners();
    }
    try {
      final result = await _channel.invokeMethod<Object?>(method, arguments);
      if (result is Map) {
        _applyStatus(Map<String, Object?>.from(result));
      }
      if (updateMessage) {
        _lastMessage = _extractMessage(result) ?? successMessage;
      }
    } on PlatformException catch (error) {
      if (updateMessage) {
        _lastMessage = error.message ?? 'Android 無線操作失敗：${error.code}';
        if (error.details is Map) {
          final details = Map<String, Object?>.from(error.details as Map);
          final missing = details['missing'];
          if (missing is List && missing.isNotEmpty) {
            _lastMessage = '缺少權限：${missing.join(', ')}。請按「權限」或到 App 設定允許。';
          }
        }
      }
    } on MissingPluginException {
      if (updateMessage) {
        _lastMessage = '目前平台未提供 Wi‑Fi mesh 原生控制。';
      }
    } finally {
      if (showBusy) {
        _busy = false;
      }
      notifyListeners();
    }
  }

  void _applyStatus(Map<String, Object?> status) {
    final capabilities = _mapValue(status['capabilities']);
    _wifiDirectSupported = _boolValue(capabilities['wifiDirectSupported']);
    _wifiPeerSupported = _boolValue(capabilities['wifiPeerSupported']);
    _hotspotSupported = _boolValue(capabilities['localOnlyHotspotSupported']);
    _bluetoothSupported = _boolValue(capabilities['bluetoothSupported']);
    _wifiEnabled = _boolValue(status['wifiEnabled']);
    _bluetoothEnabled = _boolValue(status['bluetoothEnabled']);
    _boundToWifi = _boolValue(status['boundToWifi']);
    _boundToBluetooth = _boolValue(status['boundToBluetooth']);
    _networkGeneration = _intValue(status['networkGeneration']);
    _connection = WifiP2pConnection.fromMap(_mapValue(status['connection']));
    _group = WifiDirectGroup.fromMap(_mapValue(status['group']));
    _hotspot = WifiHotspotInfo.fromMap(_mapValue(status['hotspot']));
    _p2pPeers = _listOfMaps(status['peers'])
        .map(WifiP2pPeer.fromMap)
        .where((peer) => peer.address.isNotEmpty)
        .toList();
    _wifiNetworks = _listOfMaps(status['wifiNetworks'])
        .map(WifiNetworkInfo.fromMap)
        .where((network) => network.ssid.isNotEmpty)
        .toList();
  }

  static String? _extractMessage(Object? result) {
    if (result is Map && result['message'] is String) {
      return result['message'] as String;
    }
    return null;
  }

  static Map<String, Object?> _mapValue(Object? value) {
    if (value is Map) {
      return Map<String, Object?>.from(value);
    }
    return <String, Object?>{};
  }

  static List<Map<String, Object?>> _listOfMaps(Object? value) {
    if (value is List) {
      return value
          .whereType<Map>()
          .map((item) => Map<String, Object?>.from(item))
          .toList();
    }
    return <Map<String, Object?>>[];
  }

  static bool _boolValue(Object? value) => value == true;

  static bool get _nativeWirelessBridgeAvailable =>
      Platform.isAndroid || Platform.isIOS;
}

class LightRadarController extends ChangeNotifier {
  static const MethodChannel _channel = MethodChannel(
    'hk.aieco.propagation_light/wifi_mesh',
  );

  bool _busy = false;
  DeviceLocation? _location;
  String _message = '按「定位」讀取手機位置。';

  bool get busy => _busy;
  DeviceLocation? get location => _location;
  String get message => _message;

  Future<DeviceLocation?> locate(
    String displayName, {
    bool quiet = false,
  }) async {
    if (!Platform.isAndroid) {
      _message = '定位功能目前只在 Android 原生端開放。';
      notifyListeners();
      return null;
    }

    if (!quiet) {
      _busy = true;
      _message = '正在讀取手機定位。';
      notifyListeners();
    }

    var changed = false;

    try {
      final result = await _channel.invokeMethod<Object?>(
        'currentLocation',
        <String, Object?>{'displayName': displayName},
      );
      if (result is Map) {
        final map = Map<String, Object?>.from(result);
        final nextLocation = DeviceLocation.fromMap(map);
        changed = !quiet || _shouldReplaceLocation(_location, nextLocation);
        if (changed) {
          _location = nextLocation;
          _message = _stringValue(
            map['message'],
            fallback: nextLocation.isInsideHongKong
                ? '定位成功'
                : '定位成功，位置在香港地圖範圍外',
          );
        }
        return nextLocation;
      } else {
        if (!quiet) {
          _message = '定位沒有回傳有效資料。';
        }
      }
    } on PlatformException catch (error) {
      if (!quiet) {
        _message = error.message ?? '定位失敗：${error.code}';
        if (error.details is Map) {
          final details = Map<String, Object?>.from(error.details as Map);
          final missing = details['missing'];
          if (missing is List && missing.isNotEmpty) {
            _message = '缺少定位權限：${missing.join(', ')}。請按「定位」並允許位置權限。';
          }
        }
      }
    } on MissingPluginException {
      if (!quiet) {
        _message = '目前平台未提供手機定位。';
      }
    } finally {
      if (!quiet) {
        _busy = false;
      }
      if (!quiet || changed) {
        notifyListeners();
      }
    }
    return null;
  }
}

class DeviceLocation {
  const DeviceLocation({
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    required this.provider,
    required this.timestamp,
    required this.fromCache,
  });

  factory DeviceLocation.fromMap(Map<String, Object?> map) {
    return DeviceLocation(
      latitude: _doubleValue(map['latitude']),
      longitude: _doubleValue(map['longitude']),
      accuracyMeters: max(0, _doubleValue(map['accuracyMeters'])),
      provider: _stringValue(map['provider'], fallback: 'unknown'),
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        _intValue(map['timestampMillis']),
      ),
      fromCache: map['fromCache'] == true,
    );
  }

  final double latitude;
  final double longitude;
  final double accuracyMeters;
  final String provider;
  final DateTime timestamp;
  final bool fromCache;

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'latitude': latitude,
      'longitude': longitude,
      'accuracyMeters': accuracyMeters,
      'provider': provider,
      'timestampMillis': timestamp.millisecondsSinceEpoch,
      'fromCache': fromCache,
    };
  }

  bool get isInsideHongKong {
    return latitude >= 22.13 &&
        latitude <= 22.57 &&
        longitude >= 113.82 &&
        longitude <= 114.43;
  }
}

class RadarContact {
  const RadarContact({
    required this.id,
    required this.name,
    required this.location,
    required this.isMe,
    required this.isSosActive,
    required this.lastSeen,
  });

  final String id;
  final String name;
  final DeviceLocation location;
  final bool isMe;
  final bool isSosActive;
  final DateTime lastSeen;

  double distanceFrom(DeviceLocation other) {
    return _distanceBetweenLocations(location, other);
  }
}

bool _shouldReplaceLocation(DeviceLocation? previous, DeviceLocation next) {
  if (previous == null) {
    return true;
  }

  final distanceMeters = _distanceBetweenLocations(previous, next);
  if (distanceMeters >= _radarLocationUpdateThresholdMeters) {
    return true;
  }

  final accuracyDelta = previous.accuracyMeters - next.accuracyMeters;
  return accuracyDelta >= _radarAccuracyUpdateThresholdMeters;
}

double _distanceBetweenLocations(DeviceLocation left, DeviceLocation right) {
  const earthRadiusMeters = 6371000.0;
  final dLat = _degreesToRadians(left.latitude - right.latitude);
  final dLng = _degreesToRadians(left.longitude - right.longitude);
  final lat1 = _degreesToRadians(right.latitude);
  final lat2 = _degreesToRadians(left.latitude);
  final a =
      sin(dLat / 2) * sin(dLat / 2) +
      cos(lat1) * cos(lat2) * sin(dLng / 2) * sin(dLng / 2);
  final c = 2 * atan2(sqrt(a), sqrt(1 - a));
  return earthRadiusMeters * c;
}

double _degreesToRadians(double degrees) {
  return degrees * pi / 180;
}

double _doubleValue(Object? value) {
  if (value is double) {
    return value;
  }
  if (value is int) {
    return value.toDouble();
  }
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value) ?? 0;
  }
  return 0;
}

class WifiP2pPeer {
  const WifiP2pPeer({
    required this.name,
    required this.address,
    required this.status,
    required this.statusText,
    required this.isGroupOwner,
    required this.isAppPeer,
    required this.host,
    required this.port,
  });

  factory WifiP2pPeer.fromMap(Map<String, Object?> map) {
    return WifiP2pPeer(
      name: _stringValue(map['deviceName'], fallback: '未命名 P2P 裝置'),
      address: _stringValue(map['deviceAddress']),
      status: _intValue(map['status']),
      statusText: _stringValue(map['statusText'], fallback: '未知'),
      isGroupOwner: map['isGroupOwner'] == true,
      isAppPeer: map['isAppPeer'] == true,
      host: _stringValue(map['host']),
      port: _intValue(map['port']),
    );
  }

  final String name;
  final String address;
  final int status;
  final String statusText;
  final bool isGroupOwner;
  final bool isAppPeer;
  final String host;
  final int port;

  bool get canInvite => statusText != '不可用' && statusText != '失敗';
  bool get hasLanEndpoint => host.isNotEmpty && port > 0;
}

class WifiNetworkInfo {
  const WifiNetworkInfo({
    required this.ssid,
    required this.bssid,
    required this.capabilities,
    required this.frequency,
    required this.level,
  });

  factory WifiNetworkInfo.fromMap(Map<String, Object?> map) {
    return WifiNetworkInfo(
      ssid: _stringValue(map['ssid']),
      bssid: _stringValue(map['bssid']),
      capabilities: _stringValue(map['capabilities']),
      frequency: _intValue(map['frequency']),
      level: _intValue(map['level']),
    );
  }

  final String ssid;
  final String bssid;
  final String capabilities;
  final int frequency;
  final int level;

  bool get isMeshNetwork {
    final lower = ssid.toLowerCase();
    return lower.contains('mesh') || lower.contains('aieco');
  }

  bool get secured =>
      capabilities.contains('WEP') || capabilities.contains('WPA');
}

class WifiP2pConnection {
  const WifiP2pConnection({
    required this.groupFormed,
    required this.isGroupOwner,
    required this.groupOwnerAddress,
  });

  static WifiP2pConnection? fromMap(Map<String, Object?> map) {
    if (map.isEmpty) {
      return null;
    }

    return WifiP2pConnection(
      groupFormed: map['groupFormed'] == true,
      isGroupOwner: map['isGroupOwner'] == true,
      groupOwnerAddress: _stringValue(map['groupOwnerAddress']),
    );
  }

  final bool groupFormed;
  final bool isGroupOwner;
  final String groupOwnerAddress;
}

class WifiDirectGroup {
  const WifiDirectGroup({
    required this.networkName,
    required this.passphrase,
    required this.isGroupOwner,
    required this.clients,
  });

  static WifiDirectGroup? fromMap(Map<String, Object?> map) {
    if (map.isEmpty) {
      return null;
    }

    return WifiDirectGroup(
      networkName: _stringValue(map['networkName']),
      passphrase: _stringValue(map['passphrase']),
      isGroupOwner: map['isGroupOwner'] == true,
      clients: WifiMeshController._listOfMaps(
        map['clients'],
      ).map(WifiP2pPeer.fromMap).toList(),
    );
  }

  final String networkName;
  final String passphrase;
  final bool isGroupOwner;
  final List<WifiP2pPeer> clients;
}

class WifiHotspotInfo {
  const WifiHotspotInfo({required this.ssid, required this.preSharedKey});

  static WifiHotspotInfo? fromMap(Map<String, Object?> map) {
    if (map.isEmpty) {
      return null;
    }

    return WifiHotspotInfo(
      ssid: _cleanQuotedString(_stringValue(map['ssid'])),
      preSharedKey: _cleanQuotedString(_stringValue(map['preSharedKey'])),
    );
  }

  final String ssid;
  final String preSharedKey;
}

String _stringValue(Object? value, {String fallback = ''}) {
  if (value is String) {
    return value;
  }
  return fallback;
}

int _intValue(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value) ?? 0;
  }
  return 0;
}

bool? _optionalBoolValue(Object? value) {
  if (value is bool) {
    return value;
  }
  if (value is String) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'true') {
      return true;
    }
    if (normalized == 'false') {
      return false;
    }
  }
  return null;
}

String _cleanQuotedString(String value) {
  if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

class MeshChatService extends ChangeNotifier {
  MeshChatService()
    : _nodeId = _newId('node'),
      _displayName = _newSixDigitDisplayName() {
    _seenMessageIds.add(_nodeId);
    _rooms[_defaultRoomId] = MeshRoom(
      id: _defaultRoomId,
      name: _defaultRoomName,
      createdBy: _nodeId,
      createdAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  static const int tcpPort = 47888;
  static const int discoveryPort = 47889;
  static const String _helloKind = 'aieco.light.hello.v1';
  static const String _byeKind = 'aieco.light.bye.v1';
  static const String _chatKind = 'aieco.light.chat.v1';
  static const String _roomKind = 'aieco.light.room.v1';
  static const String _locationKind = 'aieco.light.location.v1';
  static const String _supplyKind = 'aieco.light.supply.v1';
  static const String _creditKind = 'aieco.light.credit.v1';
  static const String _defaultRoomId = 'room:main';
  static const String _defaultRoomName = '傳播頻道';
  static const String _appName = 'AIECO.HK 傳播光';
  static const String _nodeIdPrefsKey = 'mesh.nodeId';
  static const String _displayNamePrefsKey = 'mesh.displayName';
  static const Duration _announcementInterval = Duration(seconds: 4);
  static const Duration _cleanupInterval = Duration(seconds: 3);
  static const Duration _onlineReconnectDelay = Duration(seconds: 5);
  static const List<Duration> _presenceBurstDelays = <Duration>[
    Duration.zero,
    Duration(milliseconds: 700),
    Duration(milliseconds: 1800),
    Duration(milliseconds: 3500),
  ];
  static const Duration _peerTtl = Duration(seconds: 18);
  static const Duration _locationTtl = Duration(minutes: 30);
  static final RegExp _sixDigitNamePattern = RegExp(r'^\d{6}$');
  static final Random _random = Random.secure();

  String _nodeId;
  final Map<String, MeshPeer> _peers = <String, MeshPeer>{};
  final Map<String, RadarContact> _peerLocations = <String, RadarContact>{};
  final Map<String, MeshRoom> _rooms = <String, MeshRoom>{};
  final Map<String, MeshSupply> _supplies = <String, MeshSupply>{};
  final Map<String, MeshCreditVote> _creditVotes = <String, MeshCreditVote>{};
  final List<MeshMessage> _messages = <MeshMessage>[];
  final Set<String> _seenMessageIds = <String>{};
  final Set<String> _seenRoomIds = <String>{_defaultRoomId};
  final Map<String, DateTime> _lastSyncAt = <String, DateTime>{};

  ServerSocket? _tcpServer;
  RawDatagramSocket? _udpSocket;
  WebSocket? _onlineSocket;
  Timer? _announcementTimer;
  Timer? _cleanupTimer;
  Timer? _onlineReconnectTimer;
  Future<void>? _startFuture;
  MeshNetworkMode _networkMode = _onlineRelayUrl.isEmpty
      ? MeshNetworkMode.offline
      : MeshNetworkMode.online;
  bool _onlineConnecting = false;
  bool _rejoiningTransport = false;
  DeviceLocation? _myLocation;
  String _displayName;
  String _activeRoomId = _defaultRoomId;
  bool _isRunning = false;
  bool _disposed = false;
  bool _sosActive = false;
  String _status = _onlineRelayUrl.isEmpty ? '正在準備離線 mesh 節點。' : '正在準備線上光之網絡。';
  List<String> _localAddresses = <String>[];

  bool get isRunning => _isRunning;
  MeshNetworkMode get networkMode => _networkMode;
  bool get onlineConfigured => _onlineRelayUrl.trim().isNotEmpty;
  bool get onlineConnected =>
      _onlineSocket != null && _onlineSocket?.readyState == WebSocket.open;
  String get onlineRelayUrl => _onlineRelayUrl;
  String get displayName => _displayName;
  String get status => _status;
  List<String> get localAddresses => List.unmodifiable(_localAddresses);
  DeviceLocation? get myLocation => _myLocation;
  bool get sosActive => _sosActive;

  List<RadarContact> get radarContacts {
    final now = DateTime.now();
    final contacts = <RadarContact>[
      if (_myLocation != null)
        RadarContact(
          id: _nodeId,
          name: _displayName,
          location: _myLocation!,
          isMe: true,
          isSosActive: _sosActive,
          lastSeen: now,
        ),
      ..._peerLocations.values.where(
        (contact) => _isActivePeerLocation(contact, now),
      ),
    ];

    contacts.sort((a, b) {
      if (a.isMe == b.isMe) {
        final myLocation = _myLocation;
        if (myLocation != null) {
          final distanceCompare = a
              .distanceFrom(myLocation)
              .compareTo(b.distanceFrom(myLocation));
          if (distanceCompare != 0) {
            return distanceCompare;
          }
        }
        return a.name.compareTo(b.name);
      }
      return a.isMe ? -1 : 1;
    });
    return List.unmodifiable(contacts);
  }

  List<RadarContact> radarContactsWithin(double meters) {
    final location = _myLocation;
    if (location == null) {
      return const <RadarContact>[];
    }

    final now = DateTime.now();
    final contacts =
        _peerLocations.values
            .where(
              (contact) =>
                  _isActivePeerLocation(contact, now) &&
                  contact.distanceFrom(location) <= meters,
            )
            .toList()
          ..sort(
            (a, b) =>
                a.distanceFrom(location).compareTo(b.distanceFrom(location)),
          );
    return List.unmodifiable(contacts);
  }

  bool _isActivePeerLocation(RadarContact contact, DateTime now) {
    if (now.difference(contact.lastSeen) > _locationTtl) {
      return false;
    }

    final peer = _peers[contact.id];
    if (peer == null) {
      return false;
    }

    return now.difference(peer.lastSeen) <= _peerTtl;
  }

  List<MeshPeer> get peers {
    final values = _peers.values.toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return List.unmodifiable(values);
  }

  List<MeshOnlineUser> get onlineUsers {
    final values = <MeshOnlineUser>[
      MeshOnlineUser(
        id: _nodeId,
        name: _displayName,
        isMe: true,
        lastSeen: DateTime.now(),
        creditScore: creditScoreFor(_nodeId),
        likedByMe: false,
        isSosActive: _sosActive,
      ),
      ...peers.map(
        (peer) => MeshOnlineUser(
          id: peer.id,
          name: peer.name,
          isMe: false,
          lastSeen: peer.lastSeen,
          creditScore: creditScoreFor(peer.id),
          likedByMe: hasLikedUser(peer.id),
          isSosActive: peer.sosActive,
        ),
      ),
    ];
    return List.unmodifiable(values);
  }

  List<MeshSupply> get supplies {
    final values = _supplies.values.where((supply) => !supply.isTaken).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable(values);
  }

  bool canMarkSupplyTaken(MeshSupply supply) {
    return supply.offeredById == _nodeId && !supply.isTaken;
  }

  int creditScoreFor(String userId) {
    return _creditVotes.values
        .where((vote) => vote.targetId == userId)
        .map((vote) => vote.voterId)
        .toSet()
        .length;
  }

  bool hasLikedUser(String userId) {
    return _creditVotes.containsKey(_creditVoteKey(_nodeId, userId));
  }

  List<MeshRoom> get rooms {
    final values = _rooms.values.toList()
      ..sort((a, b) {
        if (a.id == _defaultRoomId) {
          return -1;
        }
        if (b.id == _defaultRoomId) {
          return 1;
        }
        return a.createdAt.compareTo(b.createdAt);
      });
    return List.unmodifiable(values);
  }

  MeshRoom get activeRoom => _rooms[_activeRoomId] ?? _rooms[_defaultRoomId]!;

  List<MeshMessage> get messages => List.unmodifiable(_messages);

  List<MeshMessage> get activeRoomMessages {
    final roomId = activeRoom.id;
    return List.unmodifiable(
      _messages.where((message) => message.roomId == roomId),
    );
  }

  Future<void> loadSavedDisplayName() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedNodeId = prefs.getString(_nodeIdPrefsKey);
      final savedName = prefs.getString(_displayNamePrefsKey);
      final nextNodeId = _isNodeId(savedNodeId) ? savedNodeId! : _nodeId;
      final nextName = _isSixDigitDisplayName(savedName)
          ? savedName!
          : _displayName;

      if (savedNodeId != nextNodeId) {
        await prefs.setString(_nodeIdPrefsKey, nextNodeId);
      }

      if (savedName != nextName) {
        await prefs.setString(_displayNamePrefsKey, nextName);
      }

      if (_disposed) {
        return;
      }

      final identityChanged = nextNodeId != _nodeId || nextName != _displayName;
      if (!identityChanged) {
        return;
      }

      final previousNodeId = _nodeId;
      _nodeId = nextNodeId;
      _displayName = nextName;
      if (previousNodeId != _nodeId) {
        _seenMessageIds.remove(previousNodeId);
        _seenMessageIds.add(_nodeId);
        _rooms[_defaultRoomId] = MeshRoom(
          id: _defaultRoomId,
          name: _defaultRoomName,
          createdBy: _nodeId,
          createdAt: DateTime.fromMillisecondsSinceEpoch(0),
        );
      }
      notifyListeners();
      _announcePresence();
    } on Object {
      // Tests and unsupported platforms may not have the preferences plugin.
    }
  }

  Future<void> start() async {
    if (_isRunning) {
      return;
    }

    final inFlightStart = _startFuture;
    if (inFlightStart != null) {
      await inFlightStart;
      return;
    }

    final nextStart = _startTransport();
    _startFuture = nextStart;
    try {
      await nextStart;
    } finally {
      if (_startFuture == nextStart) {
        _startFuture = null;
      }
    }
  }

  Future<void> _startTransport() async {
    if (_networkMode == MeshNetworkMode.online) {
      await _startOnlineTransport();
      return;
    }

    await _startOfflineTransport();
  }

  Future<void> _startOnlineTransport() async {
    if (!onlineConfigured) {
      _status =
          '線上光之網絡未設定 relay。請用 --dart-define=AIECO_ONLINE_RELAY_URL=wss://... 建置。';
      notifyListeners();
      return;
    }

    _localAddresses = <String>[];
    _isRunning = true;
    _status = '正在連接線上光之網絡。';
    notifyListeners();

    _announcementTimer = Timer.periodic(
      _announcementInterval,
      (_) => _announcePresence(),
    );
    _cleanupTimer = Timer.periodic(
      _cleanupInterval,
      (_) => _removeStalePeers(),
    );
    await _connectOnlineRelay();
  }

  Future<void> _startOfflineTransport() async {
    try {
      _localAddresses = await _loadLocalAddresses();
      _tcpServer = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        tcpPort,
        shared: true,
      );
      _tcpServer?.listen(_handleIncomingSocket);

      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
      );
      _udpSocket?.broadcastEnabled = true;
      _udpSocket?.listen(_handleDiscoveryEvent);

      _isRunning = true;
      _status = '已啟動離線節點。連到同一 WiFi / mesh LAN 後會自動尋找同伴。';
      notifyListeners();

      _announcePresenceBurst();
      _announcementTimer = Timer.periodic(
        _announcementInterval,
        (_) => _announcePresence(),
      );
      _cleanupTimer = Timer.periodic(
        _cleanupInterval,
        (_) => _removeStalePeers(),
      );
    } on Object catch (error) {
      _status = '啟動失敗：$error';
      await stop();
      notifyListeners();
    }
  }

  Future<void> refreshNetworkPresence({bool forceRejoin = false}) async {
    if (_networkMode == MeshNetworkMode.online) {
      if (!_isRunning) {
        await start();
        return;
      }

      if (!onlineConfigured) {
        _status =
            '線上光之網絡未設定 relay。請用 --dart-define=AIECO_ONLINE_RELAY_URL=wss://... 建置。';
      } else if (onlineConnected) {
        _announcePresence();
        _status = '線上光之網絡已連線，用戶入 APP 即可聊天。';
      } else {
        _status = '線上光之網絡正在重連。';
        unawaited(_connectOnlineRelay());
      }
      notifyListeners();
      return;
    }

    if (!_isRunning) {
      await start();
      return;
    }

    final nextAddresses = await _loadLocalAddresses();
    final addressesChanged = !_sameStringList(_localAddresses, nextAddresses);
    if (forceRejoin ||
        addressesChanged ||
        _udpSocket == null ||
        _tcpServer == null) {
      await _rejoinTransport(nextAddresses);
      return;
    }

    _localAddresses = nextAddresses;
    _announcePresenceBurst();
    _status = '已連到 MESH LAN，正在自動尋找同伴。';
    notifyListeners();
  }

  Future<void> setNetworkMode(MeshNetworkMode mode) async {
    if (_networkMode == mode) {
      if (mode == MeshNetworkMode.online && !onlineConfigured) {
        _status =
            '線上光之網絡未設定 relay。請用 --dart-define=AIECO_ONLINE_RELAY_URL=wss://... 建置。';
        notifyListeners();
      }
      return;
    }

    final wasRunning = _isRunning || _startFuture != null;
    if (_isRunning) {
      _announceGoodbye();
    }

    _isRunning = false;
    await _closeTransport();
    _startFuture = null;
    _rejoiningTransport = false;
    _clearPeerPresence();
    _networkMode = mode;

    _status = switch (mode) {
      MeshNetworkMode.online =>
        onlineConfigured ? '已切換線上光之網絡，正在連接 relay。' : '已切換線上光之網絡，但未設定 relay。',
      MeshNetworkMode.offline => '已切換離線 mesh，連到同一 WiFi / mesh LAN 後會自動尋找同伴。',
    };
    notifyListeners();

    if (wasRunning && (mode != MeshNetworkMode.online || onlineConfigured)) {
      await start();
    }
  }

  Future<void> syncLanPeer(WifiP2pPeer peer) async {
    if (_networkMode == MeshNetworkMode.online) {
      await setNetworkMode(MeshNetworkMode.offline);
    }

    if (!peer.hasLanEndpoint) {
      _status = '這個 peer 未提供 LAN 位址，不能直接同步。';
      notifyListeners();
      return;
    }

    if (!_isRunning) {
      await start();
    }
    if (!_isRunning) {
      _status = '節點尚未啟動，不能連接 LAN peer。';
      notifyListeners();
      return;
    }

    if (_localAddresses.contains(peer.host)) {
      _status = '已略過本機 LAN peer。';
      notifyListeners();
      return;
    }

    final helloSent = await _sendJson(peer.host, peer.port, _helloPacket());
    if (!helloSent) {
      _status = '未能連接 ${peer.name}（${peer.host}:${peer.port}）。請確認對方節點已啟動。';
      notifyListeners();
      return;
    }

    _rememberPeer(
      id: 'endpoint:${peer.host}:${peer.port}',
      name: peer.name,
      host: peer.host,
      port: peer.port,
      notify: false,
    );
    await _syncRecentState(peer.host, peer.port);
    _status = '已連接 ${peer.name}，正在透過 WiFi LAN mesh 同步。';
    notifyListeners();
  }

  Future<void> stop() async {
    if (_isRunning) {
      _announceGoodbye();
    }

    _isRunning = false;
    await _closeTransport();
    _startFuture = null;
    _rejoiningTransport = false;
    _clearPeerPresence();
    _status = '節點已停止。';
    notifyListeners();
  }

  Future<void> _rejoinTransport(List<String> nextAddresses) async {
    if (_rejoiningTransport) {
      return;
    }

    _rejoiningTransport = true;
    try {
      await _closeTransport();
      _isRunning = false;
      _startFuture = null;
      _clearPeerPresence();
      _localAddresses = nextAddresses;

      await start();
      if (!_isRunning) {
        return;
      }

      _status = '已自動重接光點節點，正在重新尋找同伴。';
      _announcePresenceBurst();
      notifyListeners();
    } finally {
      _rejoiningTransport = false;
    }
  }

  Future<void> _closeTransport() async {
    _announcementTimer?.cancel();
    _cleanupTimer?.cancel();
    _onlineReconnectTimer?.cancel();
    _announcementTimer = null;
    _cleanupTimer = null;
    _onlineReconnectTimer = null;
    _onlineConnecting = false;

    final onlineSocket = _onlineSocket;
    _onlineSocket = null;
    await onlineSocket?.close(
      WebSocketStatus.normalClosure,
      'transport closed',
    );

    _udpSocket?.close();
    _udpSocket = null;

    await _tcpServer?.close();
    _tcpServer = null;
  }

  Future<void> _connectOnlineRelay() async {
    if (!onlineConfigured ||
        _disposed ||
        !_isRunning ||
        _networkMode != MeshNetworkMode.online ||
        _onlineConnecting ||
        onlineConnected) {
      return;
    }

    _onlineReconnectTimer?.cancel();
    _onlineReconnectTimer = null;
    _onlineConnecting = true;

    try {
      final socket = await WebSocket.connect(_onlineRelayUrl.trim());
      if (_disposed || !_isRunning || _networkMode != MeshNetworkMode.online) {
        _onlineConnecting = false;
        await socket.close(WebSocketStatus.normalClosure, 'mode changed');
        return;
      }

      _onlineSocket = socket;
      _onlineConnecting = false;
      socket.pingInterval = const Duration(seconds: 20);
      _status = '已連上線上光之網絡。入 APP 即可聊天，不用接同一 WiFi。';
      notifyListeners();

      socket.listen(
        _handleOnlineMessage,
        onDone: () => _handleOnlineDisconnected(socket),
        onError: (_) => _handleOnlineDisconnected(socket),
        cancelOnError: true,
      );

      unawaited(_sendPacketToOnline(_helloPacket()));
      unawaited(_syncRecentStateOnline());
    } on Object catch (error) {
      _onlineConnecting = false;
      _onlineSocket = null;
      if (_disposed || !_isRunning || _networkMode != MeshNetworkMode.online) {
        return;
      }

      _status = '線上光之網絡未連上，稍後自動重試：$error';
      notifyListeners();
      _scheduleOnlineReconnect();
    }
  }

  void _handleOnlineMessage(Object? data) {
    String? text;
    if (data is String) {
      text = data;
    } else if (data is List<int>) {
      text = utf8.decode(data, allowMalformed: true);
    }

    if (text == null) {
      return;
    }

    for (final line in const LineSplitter().convert(text)) {
      _handlePacketLine(line, 'online-relay', fromOnline: true);
    }
  }

  void _handleOnlineDisconnected(WebSocket socket) {
    if (!identical(_onlineSocket, socket)) {
      return;
    }

    _onlineSocket = null;
    _onlineConnecting = false;
    if (_disposed || !_isRunning || _networkMode != MeshNetworkMode.online) {
      return;
    }

    _status = '線上光之網絡連線中斷，正在重連。';
    notifyListeners();
    _scheduleOnlineReconnect();
  }

  void _scheduleOnlineReconnect() {
    if (!onlineConfigured ||
        _disposed ||
        !_isRunning ||
        _networkMode != MeshNetworkMode.online ||
        _onlineReconnectTimer != null) {
      return;
    }

    _onlineReconnectTimer = Timer(_onlineReconnectDelay, () {
      _onlineReconnectTimer = null;
      unawaited(_connectOnlineRelay());
    });
  }

  void _clearPeerPresence() {
    _peers.clear();
    _peerLocations.clear();
    _lastSyncAt.clear();
  }

  void setDisplayName(String _) {
    _status = '光點名稱已固定，不能更改。';
    notifyListeners();
  }

  void setActiveRoom(String roomId) {
    if (!_rooms.containsKey(roomId) || roomId == _activeRoomId) {
      return;
    }

    _activeRoomId = roomId;
    notifyListeners();
  }

  void createRoom(String name) {
    final clean = name.trim();
    if (clean.isEmpty) {
      _status = '請先輸入光團名稱。';
      notifyListeners();
      return;
    }

    final room = MeshRoom(
      id: _newId('room'),
      name: clean,
      createdBy: _nodeId,
      createdAt: DateTime.now(),
    );
    _rememberRoom(room, activate: true);
    _status = '已建立光團：${room.name}';
    notifyListeners();

    final packet = room.toPacket(senderId: _nodeId, senderName: _displayName);
    unawaited(_sendLocalPacket(packet));
  }

  void shareSupply({
    required String title,
    required String quantity,
    required String note,
  }) {
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) {
      _status = '請先輸入物資名稱。';
      notifyListeners();
      return;
    }

    final now = DateTime.now();
    final supply = MeshSupply(
      id: _newId('supply'),
      title: cleanTitle,
      quantity: quantity.trim(),
      note: note.trim(),
      offeredById: _nodeId,
      offeredByName: _displayName,
      createdAt: now,
      updatedAt: now,
      status: MeshSupply.availableStatus,
    );
    _rememberSupply(supply);
    _status = '已分享物資：${supply.title}';
    notifyListeners();

    final packet = supply.toPacket(hops: 0);
    unawaited(_sendLocalPacket(packet));
  }

  void markSupplyTaken(String supplyId) {
    final supply = _supplies[supplyId];
    if (supply == null) {
      _status = '找不到這項物資。';
      notifyListeners();
      return;
    }
    if (supply.offeredById != _nodeId) {
      _status = '只有分享物資的光點可以改為已取完。';
      notifyListeners();
      return;
    }
    if (supply.isTaken) {
      _status = '這項物資已標記為已取完。';
      notifyListeners();
      return;
    }

    final updated = supply.markTaken();
    _rememberSupply(updated);
    _status = '已將 ${supply.title} 標記為已取完。';
    notifyListeners();

    final packet = updated.toPacket(hops: 0);
    unawaited(_sendLocalPacket(packet));
  }

  void likeUser(String userId) {
    if (userId == _nodeId) {
      _status = '不能為自己加信用分。';
      notifyListeners();
      return;
    }
    if (hasLikedUser(userId)) {
      _status = '你已經為這個光點加過信用分。';
      notifyListeners();
      return;
    }

    final targetName = _peers[userId]?.name ?? '光點';
    final vote = MeshCreditVote(
      voterId: _nodeId,
      voterName: _displayName,
      targetId: userId,
      targetName: targetName,
      createdAt: DateTime.now(),
    );
    _rememberCreditVote(vote);
    _status = '已為 $targetName 加 1 點光點信用。';
    notifyListeners();

    final packet = vote.toPacket(hops: 0);
    unawaited(_sendLocalPacket(packet));
  }

  void setStatus(String value) {
    _status = value;
    notifyListeners();
  }

  void updateLocation(DeviceLocation location) {
    if (!_shouldReplaceLocation(_myLocation, location)) {
      return;
    }

    _myLocation = location;
    _status = '光之雷達已更新你的定位。';
    notifyListeners();

    final packet = _locationPacket();
    unawaited(_sendLocalPacket(packet));
    if (_networkMode == MeshNetworkMode.offline && _isRunning) {
      _announcePresence();
    }
  }

  void setSosActive(bool active) {
    if (_sosActive == active) {
      return;
    }

    _sosActive = active;
    _status = active ? 'SOS 燈已啟動，正在顯示求救光點。' : 'SOS 燈已停止。';
    notifyListeners();

    final location = _myLocation;
    if (location != null) {
      unawaited(_sendLocalPacket(_locationPacket()));
    } else {
      unawaited(refreshNetworkPresence());
    }
    _announcePresenceBurst();
  }

  Future<void> sendMessage(String text) async {
    final clean = text.trim();
    if (clean.isEmpty) {
      return;
    }

    if (!_isRunning) {
      await start();
    }

    final room = activeRoom;
    final messageId = _newId('msg');
    final sentAt = DateTime.now();
    final message = MeshMessage(
      id: messageId,
      roomId: room.id,
      roomName: room.name,
      senderId: _nodeId,
      senderName: _displayName,
      text: clean,
      sentAt: sentAt,
      isMine: true,
    );
    final packet = message.toPacket();

    _seenMessageIds.add(messageId);
    _messages.add(message);
    _trimMessages();
    notifyListeners();

    final delivered = await _sendPacketToNetwork(packet);
    _status = _messageDeliveryStatus(delivered);
    notifyListeners();
  }

  void _handleIncomingSocket(Socket socket) {
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => _handlePacketLine(line, socket.remoteAddress.address),
          onDone: socket.destroy,
          onError: (_) => socket.destroy(),
          cancelOnError: true,
        );
  }

  void _handleDiscoveryEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) {
      return;
    }

    while (true) {
      final datagram = _udpSocket?.receive();
      if (datagram == null) {
        break;
      }

      final line = utf8.decode(datagram.data, allowMalformed: true);
      _handlePacketLine(line, datagram.address.address, discoveredByUdp: true);
    }
  }

  void _handlePacketLine(
    String line,
    String remoteHost, {
    bool discoveredByUdp = false,
    bool fromOnline = false,
  }) {
    final packet = _decodePacket(line);
    if (packet == null) {
      return;
    }

    final effectiveRemoteHost = _remoteHostForPacket(
      packet,
      remoteHost,
      fromOnline,
    );

    switch (packet['kind']) {
      case _helloKind:
        _handleHelloPacket(
          packet,
          effectiveRemoteHost,
          discoveredByUdp,
          fromOnline: fromOnline,
        );
      case _byeKind:
        _handleByePacket(packet, effectiveRemoteHost);
      case _roomKind:
        _handleRoomPacket(packet, effectiveRemoteHost, fromOnline: fromOnline);
      case _chatKind:
        _handleChatPacket(packet, effectiveRemoteHost, fromOnline: fromOnline);
      case _locationKind:
        _handleLocationPacket(
          packet,
          effectiveRemoteHost,
          fromOnline: fromOnline,
        );
      case _supplyKind:
        _handleSupplyPacket(
          packet,
          effectiveRemoteHost,
          fromOnline: fromOnline,
        );
      case _creditKind:
        _handleCreditPacket(
          packet,
          effectiveRemoteHost,
          fromOnline: fromOnline,
        );
    }
  }

  String _remoteHostForPacket(
    Map<String, dynamic> packet,
    String remoteHost,
    bool fromOnline,
  ) {
    if (!fromOnline) {
      return remoteHost;
    }

    final peerId =
        _stringValue(packet['nodeId']) ??
        _stringValue(packet['senderId']) ??
        _stringValue(packet['offeredById']) ??
        _stringValue(packet['voterId']);
    return peerId == null ? 'online-relay' : 'online:$peerId';
  }

  void _handleByePacket(Map<String, dynamic> packet, String remoteHost) {
    final peerId = _stringValue(packet['nodeId']);
    if (peerId == null || peerId == _nodeId) {
      return;
    }

    final peerPort = _intValue(packet['tcpPort']) ?? tcpPort;
    final peerName = _stringValue(packet['name']) ?? '光點';
    var removed = false;
    _peers.removeWhere((id, peer) {
      final shouldRemove =
          id == peerId || (peer.host == remoteHost && peer.port == peerPort);
      removed = removed || shouldRemove;
      if (shouldRemove) {
        _peerLocations.remove(id);
      }
      return shouldRemove;
    });
    _lastSyncAt.remove('$remoteHost:$peerPort');

    if (!removed) {
      return;
    }

    _status = '$peerName 已下線。';
    notifyListeners();
  }

  void _handleHelloPacket(
    Map<String, dynamic> packet,
    String remoteHost,
    bool discoveredByUdp, {
    bool fromOnline = false,
  }) {
    final peerId = _stringValue(packet['nodeId']);
    if (peerId == null || peerId == _nodeId) {
      return;
    }

    final peerName = _stringValue(packet['name']) ?? '未命名節點';
    final peerPort = _intValue(packet['tcpPort']) ?? tcpPort;
    final sosActive = _optionalBoolValue(packet['sosActive']);
    _rememberPeer(
      id: peerId,
      name: peerName,
      host: remoteHost,
      port: peerPort,
      sosActive: sosActive,
    );
    _rememberRoomsFromList(packet['rooms']);
    _rememberSuppliesFromList(packet['supplies']);
    _rememberCreditVotesFromList(packet['creditVotes']);
    _rememberLocationFromMap(
      id: peerId,
      name: peerName,
      value: packet['location'],
      isSosActive: sosActive,
    );

    if (fromOnline) {
      unawaited(_throttledOnlineSync(peerId));
    } else if (discoveredByUdp) {
      unawaited(_throttledSync(remoteHost, peerPort));
    } else {
      unawaited(_syncRecentState(remoteHost, peerPort));
    }
  }

  void _handleRoomPacket(
    Map<String, dynamic> packet,
    String remoteHost, {
    bool fromOnline = false,
  }) {
    final room = MeshRoom.fromMap(packet);
    if (room == null) {
      return;
    }

    final senderId = _stringValue(packet['senderId']);
    if (senderId == _nodeId) {
      return;
    }

    final senderName = _stringValue(packet['senderName']);
    final senderPort = _intValue(packet['tcpPort']) ?? tcpPort;
    if (senderId != null && senderName != null) {
      _rememberPeer(
        id: senderId,
        name: senderName,
        host: remoteHost,
        port: senderPort,
        sosActive: _optionalBoolValue(packet['sosActive']),
      );
    }

    final firstSeen = !_seenRoomIds.contains(room.id);
    _rememberRoom(room);
    if (!firstSeen) {
      return;
    }

    _status = '收到新光團：${room.name}';
    notifyListeners();

    final hops = _intValue(packet['hops']) ?? 0;
    if (fromOnline || hops >= 8) {
      return;
    }

    final forwarded = Map<String, Object?>.from(packet);
    forwarded['hops'] = hops + 1;
    unawaited(_sendPacketToPeers(forwarded, exceptHost: remoteHost));
  }

  void _handleChatPacket(
    Map<String, dynamic> packet,
    String remoteHost, {
    bool fromOnline = false,
  }) {
    final messageId = _stringValue(packet['messageId']);
    final senderId = _stringValue(packet['senderId']);
    final text = _stringValue(packet['text']);
    if (messageId == null ||
        senderId == null ||
        senderId == _nodeId ||
        text == null ||
        text.trim().isEmpty) {
      return;
    }

    final senderName = _stringValue(packet['senderName']) ?? '未知光點';
    final peerPort = _intValue(packet['tcpPort']) ?? tcpPort;
    _rememberPeer(
      id: senderId,
      name: senderName,
      host: remoteHost,
      port: peerPort,
      sosActive: _optionalBoolValue(packet['sosActive']),
    );

    if (!_seenMessageIds.add(messageId)) {
      return;
    }

    final sentAt =
        DateTime.tryParse(_stringValue(packet['sentAt']) ?? '') ??
        DateTime.now();
    final roomId = _stringValue(packet['roomId']) ?? _defaultRoomId;
    final roomName = _stringValue(packet['roomName']) ?? _defaultRoomName;
    _rememberRoom(
      MeshRoom(
        id: roomId,
        name: roomName,
        createdBy: senderId,
        createdAt: sentAt,
      ),
    );

    _messages.add(
      MeshMessage(
        id: messageId,
        roomId: roomId,
        roomName: roomName,
        senderId: senderId,
        senderName: senderName,
        text: text,
        sentAt: sentAt,
        isMine: false,
      ),
    );
    _trimMessages();
    _status = '收到 $senderName 在 $roomName 的訊息，正在傳播。';
    notifyListeners();

    final hops = _intValue(packet['hops']) ?? 0;
    if (fromOnline || hops >= 8) {
      return;
    }

    final forwarded = Map<String, Object?>.from(packet);
    forwarded['hops'] = hops + 1;
    unawaited(
      _sendPacketToPeers(
        forwarded,
        exceptPeerId: senderId,
        exceptHost: remoteHost,
      ),
    );
  }

  void _handleLocationPacket(
    Map<String, dynamic> packet,
    String remoteHost, {
    bool fromOnline = false,
  }) {
    final senderId = _stringValue(packet['senderId']);
    final senderName = _stringValue(packet['senderName']);
    if (senderId == null || senderId == _nodeId || senderName == null) {
      return;
    }

    final location = DeviceLocation.fromMap(Map<String, Object?>.from(packet));
    if (location.latitude == 0 || location.longitude == 0) {
      return;
    }

    final peerPort = _intValue(packet['tcpPort']) ?? tcpPort;
    _rememberPeer(
      id: senderId,
      name: senderName,
      host: remoteHost,
      port: peerPort,
      sosActive: _optionalBoolValue(packet['sosActive']),
      notify: false,
    );
    final sosActive =
        _optionalBoolValue(packet['sosActive']) ??
        _peers[senderId]?.sosActive ??
        _peerLocations[senderId]?.isSosActive ??
        false;
    _peerLocations[senderId] = RadarContact(
      id: senderId,
      name: senderName,
      location: location,
      isMe: false,
      isSosActive: sosActive,
      lastSeen: DateTime.now(),
    );
    notifyListeners();

    final hops = _intValue(packet['hops']) ?? 0;
    if (fromOnline || hops >= 8) {
      return;
    }

    final forwarded = Map<String, Object?>.from(packet);
    forwarded['hops'] = hops + 1;
    unawaited(
      _sendPacketToPeers(
        forwarded,
        exceptPeerId: senderId,
        exceptHost: remoteHost,
      ),
    );
  }

  void _handleSupplyPacket(
    Map<String, dynamic> packet,
    String remoteHost, {
    bool fromOnline = false,
  }) {
    final supply = MeshSupply.fromMap(Map<String, Object?>.from(packet));
    if (supply == null) {
      return;
    }

    final senderPort = _intValue(packet['tcpPort']) ?? tcpPort;
    if (supply.offeredById != _nodeId) {
      _rememberPeer(
        id: supply.offeredById,
        name: supply.offeredByName,
        host: remoteHost,
        port: senderPort,
        notify: false,
      );
    }

    final changed = _rememberSupply(supply);
    if (!changed) {
      return;
    }

    _status = supply.isTaken
        ? '${supply.offeredByName} 的物資已取完：${supply.title}'
        : '收到 ${supply.offeredByName} 分享的物資：${supply.title}';
    notifyListeners();

    final hops = _intValue(packet['hops']) ?? 0;
    if (fromOnline || hops >= 8) {
      return;
    }

    final forwarded = Map<String, Object?>.from(packet);
    forwarded['hops'] = hops + 1;
    unawaited(_sendPacketToPeers(forwarded, exceptHost: remoteHost));
  }

  void _handleCreditPacket(
    Map<String, dynamic> packet,
    String remoteHost, {
    bool fromOnline = false,
  }) {
    final vote = MeshCreditVote.fromMap(Map<String, Object?>.from(packet));
    if (vote == null || vote.voterId == vote.targetId) {
      return;
    }

    final senderPort = _intValue(packet['tcpPort']) ?? tcpPort;
    if (vote.voterId != _nodeId) {
      _rememberPeer(
        id: vote.voterId,
        name: vote.voterName,
        host: remoteHost,
        port: senderPort,
        notify: false,
      );
    }

    final key = vote.key;
    final firstSeen = !_creditVotes.containsKey(key);
    _rememberCreditVote(vote);
    if (!firstSeen) {
      return;
    }

    _status = '${vote.voterName} 為 ${vote.targetName} 加了 1 點光點信用。';
    notifyListeners();

    final hops = _intValue(packet['hops']) ?? 0;
    if (fromOnline || hops >= 8) {
      return;
    }

    final forwarded = Map<String, Object?>.from(packet);
    forwarded['hops'] = hops + 1;
    unawaited(_sendPacketToPeers(forwarded, exceptHost: remoteHost));
  }

  void _announcePresence() {
    if (_networkMode == MeshNetworkMode.online) {
      unawaited(_sendPacketToOnline(_helloPacket()));
      return;
    }

    final socket = _udpSocket;
    if (socket == null) {
      return;
    }

    final bytes = utf8.encode('${jsonEncode(_helloPacket())}\n');
    socket.send(bytes, InternetAddress('255.255.255.255'), discoveryPort);
  }

  void _announcePresenceBurst() {
    for (final delay in _presenceBurstDelays) {
      if (delay == Duration.zero) {
        _announcePresence();
        continue;
      }

      unawaited(
        Future<void>.delayed(delay).then((_) {
          if (!_disposed && _isRunning) {
            _announcePresence();
          }
        }),
      );
    }
  }

  void _announceGoodbye() {
    final packet = _goodbyePacket();
    if (_networkMode == MeshNetworkMode.online) {
      unawaited(_sendPacketToOnline(packet));
      return;
    }

    final socket = _udpSocket;
    if (socket != null) {
      final bytes = utf8.encode('${jsonEncode(packet)}\n');
      socket.send(bytes, InternetAddress('255.255.255.255'), discoveryPort);
    }
    unawaited(_sendPacketToPeers(packet));
  }

  Map<String, Object?> _helloPacket() {
    final location = _myLocation;
    return <String, Object?>{
      'kind': _helloKind,
      'app': _appName,
      'nodeId': _nodeId,
      'name': _displayName,
      'tcpPort': tcpPort,
      'sosActive': _sosActive,
      'sentAt': DateTime.now().toUtc().toIso8601String(),
      'site': 'AIECO.HK',
      'rooms': rooms.map((room) => room.toMap()).toList(),
      'supplies': _supplies.values.map((supply) => supply.toMap()).toList(),
      'creditVotes': _creditVotes.values.map((vote) => vote.toMap()).toList(),
      if (location != null) 'location': location.toMap(),
    };
  }

  Map<String, Object?> _goodbyePacket() {
    return <String, Object?>{
      'kind': _byeKind,
      'app': _appName,
      'nodeId': _nodeId,
      'name': _displayName,
      'tcpPort': tcpPort,
      'sosActive': false,
      'sentAt': DateTime.now().toUtc().toIso8601String(),
      'site': 'AIECO.HK',
    };
  }

  Map<String, Object?> _locationPacket({int hops = 0}) {
    final location = _myLocation;
    return <String, Object?>{
      'kind': _locationKind,
      'app': _appName,
      'senderId': _nodeId,
      'senderName': _displayName,
      'tcpPort': tcpPort,
      'sosActive': _sosActive,
      'hops': hops,
      'sentAt': DateTime.now().toUtc().toIso8601String(),
      if (location != null) ...location.toMap(),
    };
  }

  Future<int> _sendLocalPacket(Map<String, Object?> packet) async {
    if (!_isRunning) {
      await start();
    }
    if (!_isRunning) {
      return 0;
    }

    return _sendPacketToNetwork(packet);
  }

  Future<int> _sendPacketToNetwork(
    Map<String, Object?> packet, {
    String? exceptPeerId,
    String? exceptHost,
  }) async {
    if (_networkMode == MeshNetworkMode.online) {
      return await _sendPacketToOnline(packet) ? 1 : 0;
    }

    return _sendPacketToPeers(
      packet,
      exceptPeerId: exceptPeerId,
      exceptHost: exceptHost,
    );
  }

  String _messageDeliveryStatus(int delivered) {
    if (_networkMode == MeshNetworkMode.online) {
      if (!onlineConfigured) {
        return '線上光之網絡未設定 relay。訊息已留在本機。';
      }
      return delivered == 0 ? '線上光之網絡暫未連線。訊息已留在本機，重連後會同步最近訊息。' : '訊息已送到線上光之網絡。';
    }

    return delivered == 0
        ? '未找到其他已開啟本 app 的節點。訊息已留在本機，連到同一 WiFi / mesh LAN 後會自動傳播。'
        : '訊息已送往 $delivered 個節點，並會由節點繼續轉傳。';
  }

  Future<bool> _sendPacketToOnline(Map<String, Object?> packet) async {
    final socket = _onlineSocket;
    if (!onlineConfigured ||
        socket == null ||
        socket.readyState != WebSocket.open) {
      if (_isRunning && _networkMode == MeshNetworkMode.online) {
        unawaited(_connectOnlineRelay());
      }
      return false;
    }

    try {
      socket.add(jsonEncode(packet));
      return true;
    } on Object {
      _handleOnlineDisconnected(socket);
      return false;
    }
  }

  Future<int> _sendPacketToPeers(
    Map<String, Object?> packet, {
    String? exceptPeerId,
    String? exceptHost,
  }) async {
    var delivered = 0;
    final snapshot = _peers.values.toList();

    for (final peer in snapshot) {
      if (peer.id == exceptPeerId || peer.host == exceptHost) {
        continue;
      }

      final ok = await _sendJson(peer.host, peer.port, packet);
      if (ok) {
        delivered += 1;
      }
    }

    return delivered;
  }

  Future<bool> _sendJson(
    String host,
    int port,
    Map<String, Object?> packet,
  ) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 2),
      );
      socket.write('${jsonEncode(packet)}\n');
      await socket.flush();
      await socket.close();
      return true;
    } on Object {
      socket?.destroy();
      return false;
    }
  }

  Future<void> _throttledSync(String host, int port) async {
    final key = '$host:$port';
    final previous = _lastSyncAt[key];
    if (previous != null &&
        DateTime.now().difference(previous) < const Duration(seconds: 15)) {
      return;
    }

    _lastSyncAt[key] = DateTime.now();
    await _syncRecentState(host, port);
  }

  Future<void> _throttledOnlineSync(String peerId) async {
    final key = 'online-sync:$peerId';
    final previous = _lastSyncAt[key];
    if (previous != null &&
        DateTime.now().difference(previous) < const Duration(seconds: 15)) {
      return;
    }

    _lastSyncAt[key] = DateTime.now();
    await _syncRecentStateOnline();
  }

  Future<void> _syncRecentState(String host, int port) async {
    for (final room in rooms) {
      await _sendJson(
        host,
        port,
        room.toPacket(senderId: _nodeId, senderName: _displayName, hops: 1),
      );
    }

    for (final supply in _supplies.values) {
      await _sendJson(host, port, supply.toPacket(hops: 1));
    }

    for (final vote in _creditVotes.values) {
      await _sendJson(host, port, vote.toPacket(hops: 1));
    }

    final recent = _messages.length <= 20
        ? _messages
        : _messages.sublist(_messages.length - 20);
    for (final message in recent) {
      await _sendJson(host, port, message.toPacket(hops: 1));
    }

    if (_myLocation != null) {
      await _sendJson(host, port, _locationPacket(hops: 1));
    }
  }

  Future<void> _syncRecentStateOnline() async {
    if (_networkMode != MeshNetworkMode.online || !onlineConnected) {
      return;
    }

    for (final room in rooms) {
      await _sendPacketToOnline(
        room.toPacket(senderId: _nodeId, senderName: _displayName, hops: 1),
      );
    }

    for (final supply in _supplies.values) {
      await _sendPacketToOnline(supply.toPacket(hops: 1));
    }

    for (final vote in _creditVotes.values) {
      await _sendPacketToOnline(vote.toPacket(hops: 1));
    }

    final recent = _messages.length <= 20
        ? _messages
        : _messages.sublist(_messages.length - 20);
    for (final message in recent) {
      await _sendPacketToOnline(message.toPacket(hops: 1));
    }

    if (_myLocation != null) {
      await _sendPacketToOnline(_locationPacket(hops: 1));
    }
  }

  void _rememberPeer({
    required String id,
    required String name,
    required String host,
    required int port,
    bool? sosActive,
    bool notify = true,
  }) {
    if (id == _nodeId) {
      return;
    }

    if (_networkMode == MeshNetworkMode.online) {
      if (_sameDisplayName(name, _displayName)) {
        _removePeerById(id);
        if (notify) {
          notifyListeners();
        }
        return;
      }
      _removeOnlinePeersWithSameName(id: id, name: name);
    } else {
      _removePeersFromSameEndpoint(id: id, host: host, port: port);
    }

    final existing = _peers[id];
    if (existing == null) {
      _peers[id] = MeshPeer(
        id: id,
        name: name,
        host: host,
        port: port,
        sosActive: sosActive ?? false,
        lastSeen: DateTime.now(),
      );
    } else {
      existing
        ..name = name
        ..host = host
        ..port = port
        ..sosActive = sosActive ?? existing.sosActive
        ..lastSeen = DateTime.now();
    }
    if (sosActive != null) {
      final existingContact = _peerLocations[id];
      if (existingContact != null && existingContact.isSosActive != sosActive) {
        _peerLocations[id] = RadarContact(
          id: existingContact.id,
          name: name,
          location: existingContact.location,
          isMe: existingContact.isMe,
          isSosActive: sosActive,
          lastSeen: existingContact.lastSeen,
        );
      }
    }

    if (notify) {
      notifyListeners();
    }
  }

  void _removePeersFromSameEndpoint({
    required String id,
    required String host,
    required int port,
  }) {
    _peers.removeWhere(
      (peerId, peer) => peerId != id && peer.host == host && peer.port == port,
    );
  }

  void _removeOnlinePeersWithSameName({
    required String id,
    required String name,
  }) {
    final stalePeerIds = _peers.entries
        .where(
          (entry) =>
              entry.key != id && _sameDisplayName(entry.value.name, name),
        )
        .map((entry) => entry.key)
        .toList();
    for (final peerId in stalePeerIds) {
      _removePeerById(peerId);
    }
  }

  void _removePeerById(String id) {
    final removed = _peers.remove(id);
    _peerLocations.remove(id);
    if (removed != null) {
      _lastSyncAt.removeWhere((key, _) => key.contains(id));
    }
  }

  void _rememberRoom(MeshRoom room, {bool activate = false}) {
    if (room.id.isEmpty || room.name.trim().isEmpty) {
      return;
    }

    _seenRoomIds.add(room.id);
    final existing = _rooms[room.id];
    if (existing == null || room.createdAt.isBefore(existing.createdAt)) {
      _rooms[room.id] = room;
    }
    if (activate) {
      _activeRoomId = room.id;
    }
  }

  void _rememberRoomsFromList(Object? value) {
    if (value is! List) {
      return;
    }

    var changed = false;
    for (final item in value.whereType<Map>()) {
      final room = MeshRoom.fromMap(Map<String, Object?>.from(item));
      if (room == null || _rooms.containsKey(room.id)) {
        continue;
      }
      _rememberRoom(room);
      changed = true;
    }
    if (changed) {
      notifyListeners();
    }
  }

  bool _rememberSupply(MeshSupply supply) {
    if (supply.id.isEmpty || supply.title.trim().isEmpty) {
      return false;
    }

    final existing = _supplies[supply.id];
    if (existing == null || supply.updatedAt.isAfter(existing.updatedAt)) {
      _supplies[supply.id] = supply;
      return true;
    }
    return false;
  }

  void _rememberSuppliesFromList(Object? value) {
    if (value is! List) {
      return;
    }

    var changed = false;
    for (final item in value.whereType<Map>()) {
      final supply = MeshSupply.fromMap(Map<String, Object?>.from(item));
      if (supply == null) {
        continue;
      }
      changed = _rememberSupply(supply) || changed;
    }
    if (changed) {
      notifyListeners();
    }
  }

  void _rememberCreditVote(MeshCreditVote vote) {
    if (vote.voterId.isEmpty ||
        vote.targetId.isEmpty ||
        vote.voterId == vote.targetId) {
      return;
    }

    _creditVotes[vote.key] = vote;
  }

  void _rememberCreditVotesFromList(Object? value) {
    if (value is! List) {
      return;
    }

    var changed = false;
    for (final item in value.whereType<Map>()) {
      final vote = MeshCreditVote.fromMap(Map<String, Object?>.from(item));
      if (vote == null || _creditVotes.containsKey(vote.key)) {
        continue;
      }
      _rememberCreditVote(vote);
      changed = true;
    }
    if (changed) {
      notifyListeners();
    }
  }

  void _rememberLocationFromMap({
    required String id,
    required String name,
    required Object? value,
    bool? isSosActive,
  }) {
    if (id == _nodeId || value is! Map) {
      return;
    }

    final location = DeviceLocation.fromMap(Map<String, Object?>.from(value));
    if (location.latitude == 0 || location.longitude == 0) {
      return;
    }
    final existingContact = _peerLocations[id];
    final nextSosActive = isSosActive ?? existingContact?.isSosActive ?? false;
    if (existingContact != null &&
        !_shouldReplaceLocation(existingContact.location, location) &&
        existingContact.isSosActive == nextSosActive) {
      return;
    }

    _peerLocations[id] = RadarContact(
      id: id,
      name: name,
      location: location,
      isMe: false,
      isSosActive: nextSosActive,
      lastSeen: DateTime.now(),
    );
    notifyListeners();
  }

  void _removeStalePeers() {
    final now = DateTime.now();
    var removed = false;
    final stalePeerIds = <String>{};

    _peers.removeWhere((peerId, peer) {
      final shouldRemove = now.difference(peer.lastSeen) > _peerTtl;
      removed = removed || shouldRemove;
      if (shouldRemove) {
        stalePeerIds.add(peerId);
      }
      return shouldRemove;
    });

    for (final peerId in stalePeerIds) {
      removed = _peerLocations.remove(peerId) != null || removed;
    }

    _peerLocations.removeWhere((_, contact) {
      final shouldRemove = !_isActivePeerLocation(contact, now);
      removed = removed || shouldRemove;
      return shouldRemove;
    });
    if (removed) {
      notifyListeners();
    }
  }

  void _trimMessages() {
    const maxMessages = 300;
    if (_messages.length > maxMessages) {
      _messages.removeRange(0, _messages.length - maxMessages);
    }
  }

  Map<String, dynamic>? _decodePacket(String line) {
    try {
      final decoded = jsonDecode(line.trim());
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } on Object {
      return null;
    }
    return null;
  }

  Future<List<String>> _loadLocalAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      return interfaces
          .expand((networkInterface) => networkInterface.addresses)
          .map((address) => address.address)
          .where((address) => !address.startsWith('127.'))
          .toSet()
          .toList()
        ..sort();
    } on Object {
      return <String>[];
    }
  }

  static bool _sameStringList(List<String> left, List<String> right) {
    if (left.length != right.length) {
      return false;
    }

    for (var index = 0; index < left.length; index += 1) {
      if (left[index] != right[index]) {
        return false;
      }
    }
    return true;
  }

  static String _creditVoteKey(String voterId, String targetId) {
    return '$voterId->$targetId';
  }

  static String? _stringValue(Object? value) {
    if (value is String) {
      return value;
    }
    return null;
  }

  static int? _intValue(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is String) {
      return int.tryParse(value);
    }
    return null;
  }

  static String _newId(String prefix) {
    final time = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final suffix = _random.nextInt(1 << 32).toRadixString(36);
    return '$prefix-$time-$suffix';
  }

  static String _newSixDigitDisplayName() {
    return (_random.nextInt(900000) + 100000).toString();
  }

  static bool _isNodeId(String? value) {
    return value != null &&
        value.startsWith('node-') &&
        value.length > 'node-'.length;
  }

  static bool _isSixDigitDisplayName(String? value) {
    return value != null && _sixDigitNamePattern.hasMatch(value);
  }

  static bool _sameDisplayName(String left, String right) {
    return left.trim() == right.trim();
  }

  @override
  void dispose() {
    _disposed = true;
    if (_isRunning) {
      _announceGoodbye();
    }
    _isRunning = false;
    _announcementTimer?.cancel();
    _cleanupTimer?.cancel();
    _onlineReconnectTimer?.cancel();
    _udpSocket?.close();
    _tcpServer?.close();
    _onlineSocket?.close(WebSocketStatus.normalClosure, 'disposed');
    super.dispose();
  }
}

class MeshOnlineUser {
  const MeshOnlineUser({
    required this.id,
    required this.name,
    required this.isMe,
    required this.lastSeen,
    required this.creditScore,
    required this.likedByMe,
    required this.isSosActive,
  });

  final String id;
  final String name;
  final bool isMe;
  final DateTime lastSeen;
  final int creditScore;
  final bool likedByMe;
  final bool isSosActive;
}

class MeshSupply {
  const MeshSupply({
    required this.id,
    required this.title,
    required this.quantity,
    required this.note,
    required this.offeredById,
    required this.offeredByName,
    required this.createdAt,
    required this.updatedAt,
    required this.status,
  });

  static const String availableStatus = 'available';
  static const String takenStatus = 'taken';

  static MeshSupply? fromMap(Map<String, Object?> map) {
    final id = MeshChatService._stringValue(map['supplyId']);
    final title = MeshChatService._stringValue(map['title']);
    final offeredById =
        MeshChatService._stringValue(map['offeredById']) ??
        MeshChatService._stringValue(map['senderId']);
    final offeredByName =
        MeshChatService._stringValue(map['offeredByName']) ??
        MeshChatService._stringValue(map['senderName']);
    if (id == null ||
        id.isEmpty ||
        title == null ||
        title.trim().isEmpty ||
        offeredById == null ||
        offeredByName == null) {
      return null;
    }

    final createdAt =
        DateTime.tryParse(
          MeshChatService._stringValue(map['createdAt']) ?? '',
        ) ??
        DateTime.now();
    final updatedAt =
        DateTime.tryParse(
          MeshChatService._stringValue(map['updatedAt']) ?? '',
        ) ??
        createdAt;
    return MeshSupply(
      id: id,
      title: title,
      quantity: MeshChatService._stringValue(map['quantity']) ?? '',
      note: MeshChatService._stringValue(map['note']) ?? '',
      offeredById: offeredById,
      offeredByName: offeredByName,
      createdAt: createdAt,
      updatedAt: updatedAt,
      status:
          MeshChatService._stringValue(map['status']) ??
          (map['isTaken'] == true ? takenStatus : availableStatus),
    );
  }

  final String id;
  final String title;
  final String quantity;
  final String note;
  final String offeredById;
  final String offeredByName;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String status;

  bool get isTaken => status == takenStatus;

  MeshSupply markTaken() {
    return MeshSupply(
      id: id,
      title: title,
      quantity: quantity,
      note: note,
      offeredById: offeredById,
      offeredByName: offeredByName,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      status: takenStatus,
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'supplyId': id,
      'title': title,
      'quantity': quantity,
      'note': note,
      'offeredById': offeredById,
      'offeredByName': offeredByName,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'updatedAt': updatedAt.toUtc().toIso8601String(),
      'status': status,
      'isTaken': isTaken,
    };
  }

  Map<String, Object?> toPacket({int hops = 0}) {
    return <String, Object?>{
      'kind': MeshChatService._supplyKind,
      'app': MeshChatService._appName,
      'senderId': offeredById,
      'senderName': offeredByName,
      'tcpPort': MeshChatService.tcpPort,
      'hops': hops,
      ...toMap(),
    };
  }
}

class MeshCreditVote {
  const MeshCreditVote({
    required this.voterId,
    required this.voterName,
    required this.targetId,
    required this.targetName,
    required this.createdAt,
  });

  static MeshCreditVote? fromMap(Map<String, Object?> map) {
    final voterId =
        MeshChatService._stringValue(map['voterId']) ??
        MeshChatService._stringValue(map['senderId']);
    final voterName =
        MeshChatService._stringValue(map['voterName']) ??
        MeshChatService._stringValue(map['senderName']);
    final targetId = MeshChatService._stringValue(map['targetId']);
    final targetName = MeshChatService._stringValue(map['targetName']);
    if (voterId == null ||
        voterName == null ||
        targetId == null ||
        targetName == null ||
        voterId == targetId) {
      return null;
    }

    final createdAt =
        DateTime.tryParse(
          MeshChatService._stringValue(map['createdAt']) ?? '',
        ) ??
        DateTime.now();
    return MeshCreditVote(
      voterId: voterId,
      voterName: voterName,
      targetId: targetId,
      targetName: targetName,
      createdAt: createdAt,
    );
  }

  final String voterId;
  final String voterName;
  final String targetId;
  final String targetName;
  final DateTime createdAt;

  String get key => MeshChatService._creditVoteKey(voterId, targetId);

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'voterId': voterId,
      'voterName': voterName,
      'targetId': targetId,
      'targetName': targetName,
      'createdAt': createdAt.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> toPacket({int hops = 0}) {
    return <String, Object?>{
      'kind': MeshChatService._creditKind,
      'app': MeshChatService._appName,
      'senderId': voterId,
      'senderName': voterName,
      'tcpPort': MeshChatService.tcpPort,
      'hops': hops,
      ...toMap(),
    };
  }
}

class MeshRoom {
  const MeshRoom({
    required this.id,
    required this.name,
    required this.createdBy,
    required this.createdAt,
  });

  static MeshRoom? fromMap(Map<String, Object?> map) {
    final id = MeshChatService._stringValue(map['roomId']);
    final name = MeshChatService._stringValue(map['roomName']);
    if (id == null || id.isEmpty || name == null || name.trim().isEmpty) {
      return null;
    }

    final createdAt =
        DateTime.tryParse(
          MeshChatService._stringValue(map['createdAt']) ?? '',
        ) ??
        DateTime.now();
    return MeshRoom(
      id: id,
      name: name,
      createdBy:
          MeshChatService._stringValue(map['createdBy']) ??
          MeshChatService._stringValue(map['senderId']) ??
          '',
      createdAt: createdAt,
    );
  }

  final String id;
  final String name;
  final String createdBy;
  final DateTime createdAt;

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'roomId': id,
      'roomName': name,
      'createdBy': createdBy,
      'createdAt': createdAt.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> toPacket({
    required String senderId,
    required String senderName,
    int hops = 0,
  }) {
    return <String, Object?>{
      'kind': MeshChatService._roomKind,
      'app': MeshChatService._appName,
      'senderId': senderId,
      'senderName': senderName,
      'tcpPort': MeshChatService.tcpPort,
      'hops': hops,
      ...toMap(),
    };
  }
}

class MeshPeer {
  MeshPeer({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.sosActive,
    required this.lastSeen,
  });

  final String id;
  String name;
  String host;
  int port;
  bool sosActive;
  DateTime lastSeen;

  bool get isOnline => host.startsWith('online:');
}

class MeshMessage {
  const MeshMessage({
    required this.id,
    required this.roomId,
    required this.roomName,
    required this.senderId,
    required this.senderName,
    required this.text,
    required this.sentAt,
    required this.isMine,
  });

  final String id;
  final String roomId;
  final String roomName;
  final String senderId;
  final String senderName;
  final String text;
  final DateTime sentAt;
  final bool isMine;

  Map<String, Object?> toPacket({int hops = 0}) {
    return <String, Object?>{
      'kind': MeshChatService._chatKind,
      'app': MeshChatService._appName,
      'messageId': id,
      'roomId': roomId,
      'roomName': roomName,
      'senderId': senderId,
      'senderName': senderName,
      'tcpPort': MeshChatService.tcpPort,
      'text': text,
      'sentAt': sentAt.toUtc().toIso8601String(),
      'hops': hops,
    };
  }
}
