package aieco.light.mesh

import android.Manifest
import android.annotation.SuppressLint
import android.content.ActivityNotFoundException
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.camera2.CameraAccessException
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.Uri
import android.net.wifi.WifiConfiguration
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.net.wifi.WifiManager.LocalOnlyHotspotReservation
import android.net.wifi.WpsInfo
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pDevice
import android.net.wifi.p2p.WifiP2pDeviceList
import android.net.wifi.p2p.WifiP2pGroup
import android.net.wifi.p2p.WifiP2pInfo
import android.net.wifi.p2p.WifiP2pManager
import android.net.wifi.p2p.WifiP2pManager.ActionListener
import android.net.wifi.p2p.WifiP2pManager.Channel
import android.net.wifi.p2p.WifiP2pManager.ConnectionInfoListener
import android.net.wifi.p2p.WifiP2pManager.GroupInfoListener
import android.net.wifi.p2p.WifiP2pManager.PeerListListener
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceInfo
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceRequest
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private lateinit var bridge: WifiMeshBridge

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = WifiMeshBridge(this)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            WifiMeshBridge.CHANNEL_NAME
        ).setMethodCallHandler { call, result ->
            bridge.handle(call, result)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!::bridge.isInitialized) {
            bridge = WifiMeshBridge(this)
        }
        bridge.register()
    }

    override fun onResume() {
        super.onResume()
        if (::bridge.isInitialized) {
            bridge.onResume()
        }
    }

    override fun onPause() {
        if (::bridge.isInitialized) {
            bridge.onPause()
        }
        super.onPause()
    }

    override fun onDestroy() {
        if (::bridge.isInitialized) {
            bridge.unregister()
        }
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        if (::bridge.isInitialized) {
            bridge.onRequestPermissionsResult(requestCode)
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }
}

private class WifiMeshBridge(private val activity: Activity) {
    companion object {
        const val CHANNEL_NAME = "hk.aieco.propagation_light/wifi_mesh"
        private const val PERMISSION_REQUEST_CODE = 4788
        private const val TORCH_PERMISSION_REQUEST_CODE = 4789
        private const val APP_SERVICE_INSTANCE = "AIECO Mesh"
        private const val APP_SERVICE_TYPE = "_aieco-mesh._tcp"
        private const val TRANSPORT_BLUETOOTH = "bluetooth"
        private const val TRANSPORT_WIFI = "wifi"
    }

    private val appContext = activity.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private val wifiManager = appContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val locationManager =
        appContext.getSystemService(Context.LOCATION_SERVICE) as LocationManager
    private val cameraManager =
        appContext.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    private val p2pManager =
        appContext.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
    private val connectivityManager =
        appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val bluetoothManager =
        appContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val bluetoothAdapter: BluetoothAdapter?
        get() = bluetoothManager?.adapter
    private var p2pChannel: Channel? = null
    private var currentPeers = emptyList<Map<String, Any?>>()
    private var currentGroup: Map<String, Any?>? = null
    private var currentConnection: Map<String, Any?>? = null
    private var currentWifiNetworks = emptyList<Map<String, Any?>>()
    private val appPeerAddresses = linkedSetOf<String>()
    private val appPeerNames = mutableMapOf<String, String>()
    private var localAppServiceAdded = false
    private var hotspotReservation: LocalOnlyHotspotReservation? = null
    private var hotspotInfo: Map<String, Any?>? = null
    private var hotspotStarting = false
    private var hotspotRequestId = 0
    private var wifiDirectNetwork: Network? = null
    private var localNetwork: Network? = null
    private var bluetoothNetwork: Network? = null
    private var networkGeneration = 0L
    private var receiverRegistered = false
    private var foregroundActive = false
    private var lastInviteListenAt = 0L
    private var wifiP2pEnabled = p2pManager != null
    private var p2pOperationBusy = false
    private var lastP2pOperationAt = 0L
    private var preferLocalNetwork = true
    private var preferBluetoothNetwork = false
    private var transportMode = TRANSPORT_WIFI
    private var pendingLocationResult: MethodChannel.Result? = null
    private var pendingLocationLowPower = false
    private var pendingLocationMaxCacheAgeMillis = 120_000L
    private var torchCameraId: String? = null

    private val receiver =
        object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION -> requestPeers()
                    WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                        requestConnectionInfo()
                        requestGroupInfo()
                    }
                    WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION -> requestGroupInfo()
                    WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION ->
                        handleP2pStateChanged(intent)
                }
            }
        }

    private val networkCallback =
        object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                rememberWifiNetwork(network)
            }

            override fun onLost(network: Network) {
                var changed = false
                if (wifiDirectNetwork == network) {
                    wifiDirectNetwork = null
                    changed = true
                }
                if (localNetwork == network) {
                    localNetwork = null
                    changed = true
                }
                if (changed) {
                    networkGeneration += 1
                    bindProcessToPreferredNetwork()
                }
            }

            override fun onLinkPropertiesChanged(
                network: Network,
                linkProperties: LinkProperties
            ) {
                rememberWifiNetwork(network, linkProperties.interfaceName)
            }
        }

    private val bluetoothNetworkCallback =
        object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                bluetoothNetwork = network
                networkGeneration += 1
                bindProcessToPreferredNetwork()
            }

            override fun onLost(network: Network) {
                if (bluetoothNetwork == network) {
                    bluetoothNetwork = null
                    networkGeneration += 1
                    bindProcessToPreferredNetwork()
                }
            }
        }

    fun register() {
        if (p2pManager != null && p2pChannel == null) {
            p2pChannel = p2pManager.initialize(appContext, Looper.getMainLooper(), null)
        }

        if (!receiverRegistered) {
            val filter = IntentFilter().apply {
                addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
                addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
                addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
                addAction(WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                appContext.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                appContext.registerReceiver(receiver, filter)
            }
            receiverRegistered = true
        }

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .build()
        runCatching { connectivityManager.registerNetworkCallback(request, networkCallback) }
        val bluetoothRequest = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_BLUETOOTH)
            .build()
        runCatching {
            connectivityManager.registerNetworkCallback(
                bluetoothRequest,
                bluetoothNetworkCallback
            )
        }
    }

    fun unregister() {
        if (receiverRegistered) {
            runCatching { appContext.unregisterReceiver(receiver) }
            receiverRegistered = false
        }
        runCatching { applyTorch(false) }
        pendingLocationResult?.error("activity_destroyed", "定位中斷。", null)
        pendingLocationResult = null
        runCatching { connectivityManager.unregisterNetworkCallback(networkCallback) }
        runCatching { connectivityManager.unregisterNetworkCallback(bluetoothNetworkCallback) }
        wifiDirectNetwork = null
        localNetwork = null
        bluetoothNetwork = null
        // Do not clear the process-wide network binding here. On newer
        // Android versions the Activity can be destroyed while the mesh
        // foreground service is still running; clearing it disconnects the
        // service from the Wi-Fi/P2P network and breaks background LAN chat.
        // The binding is replaced automatically when a preferred network is
        // discovered again, or when the process is stopped.
    }

    fun onResume() {
        foregroundActive = true
        armWifiDirectInviteReceiver()
    }

    fun onPause() {
        foregroundActive = false
    }

    fun onRequestPermissionsResult(requestCode: Int) {
        if (requestCode != PERMISSION_REQUEST_CODE) {
            return
        }

        armWifiDirectInviteReceiver()

        val result = pendingLocationResult ?: return
        pendingLocationResult = null

        if (hasLocationPermission()) {
            currentLocation(
                result,
                pendingLocationLowPower,
                pendingLocationMaxCacheAgeMillis
            )
        } else {
            result.error(
                "permission_missing",
                "需要位置權限後才可在光之雷達顯示你的光點。",
                locationPermissionSnapshot()
            )
        }
    }

    private fun bindProcessToNetwork(network: Network?) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            runCatching { connectivityManager.bindProcessToNetwork(network) }
        } else {
            @Suppress("DEPRECATION")
            runCatching { ConnectivityManager.setProcessDefaultNetwork(network) }
        }
    }

    private fun bindProcessToPreferredNetwork() {
        bindProcessToNetwork(preferredNetwork())
    }

    private fun preferredNetwork(): Network? {
        if (!preferLocalNetwork) {
            return null
        }

        val p2pGroupFormed = currentConnection?.get("groupFormed") == true
        if (transportMode == TRANSPORT_BLUETOOTH) {
            return bluetoothNetwork
        }
        if (wifiDirectNetwork != null) {
            return wifiDirectNetwork
        }
        if (p2pGroupFormed) {
            return null
        }
        return localNetwork
    }

    private fun handleP2pStateChanged(intent: Intent) {
        val state = intent.getIntExtra(
            WifiP2pManager.EXTRA_WIFI_STATE,
            WifiP2pManager.WIFI_P2P_STATE_DISABLED
        )
        wifiP2pEnabled = state == WifiP2pManager.WIFI_P2P_STATE_ENABLED
        if (wifiP2pEnabled) {
            requestConnectionInfo()
            requestGroupInfo()
            return
        }

        currentPeers = emptyList()
        currentGroup = null
        currentConnection = null
        wifiDirectNetwork = null
        networkGeneration += 1
        bindProcessToPreferredNetwork()
    }

    private fun rememberWifiNetwork(network: Network, interfaceName: String? = null) {
        val isWifiDirect = isWifiDirectInterface(
            interfaceName ?: runCatching {
                connectivityManager.getLinkProperties(network)?.interfaceName
            }.getOrNull()
        )
        var changed = false
        if (isWifiDirect) {
            if (wifiDirectNetwork != network) {
                wifiDirectNetwork = network
                changed = true
            }
            if (localNetwork == network) {
                localNetwork = null
                changed = true
            }
        } else if (wifiDirectNetwork != network && localNetwork != network) {
            localNetwork = network
            changed = true
        }
        if (changed) {
            networkGeneration += 1
            bindProcessToPreferredNetwork()
        }
    }

    private fun refreshKnownNetworks() {
        var nextWifiDirectNetwork: Network? = null
        var nextLocalNetwork: Network? = null
        var nextBluetoothNetwork: Network? = null

        for (network in connectivityManager.allNetworks) {
            val capabilities = runCatching {
                connectivityManager.getNetworkCapabilities(network)
            }.getOrNull() ?: continue
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH)) {
                if (nextBluetoothNetwork == null) {
                    nextBluetoothNetwork = network
                }
                continue
            }
            if (!capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                continue
            }

            val interfaceName = runCatching {
                connectivityManager.getLinkProperties(network)?.interfaceName
            }.getOrNull()
            if (isWifiDirectInterface(interfaceName)) {
                nextWifiDirectNetwork = network
            } else if (nextLocalNetwork == null) {
                nextLocalNetwork = network
            }
        }

        if (
            wifiDirectNetwork == nextWifiDirectNetwork &&
                localNetwork == nextLocalNetwork &&
                bluetoothNetwork == nextBluetoothNetwork
        ) {
            return
        }

        wifiDirectNetwork = nextWifiDirectNetwork
        localNetwork = nextLocalNetwork
        bluetoothNetwork = nextBluetoothNetwork
        networkGeneration += 1
        bindProcessToPreferredNetwork()
    }

    private fun isWifiDirectInterface(interfaceName: String?): Boolean {
        val name = interfaceName ?: return false
        return name.startsWith("p2p", ignoreCase = true) ||
            name.contains("-p2p", ignoreCase = true)
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capabilities" -> result.success(capabilities())
            "requestNotificationPermission" -> requestNotificationPermission(result)
            "startBackgroundMeshService" -> startBackgroundMeshService(result)
            "stopBackgroundMeshService" -> stopBackgroundMeshService(result)
            "showChatNotification" -> showChatNotification(call, result)
            "clearChatNotifications" -> {
                MeshNotifications.clearChatNotifications(appContext)
                result.success(true)
            }
            "requestPermissions" -> {
                requestRuntimePermissions()
                armWifiDirectInviteReceiver()
                result.success(permissionSnapshot())
            }
            "prepareWifiDirectInvite" -> prepareWifiDirectInvite(result)
            "openWifiSettings" -> {
                activity.startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
                result.success(true)
            }
            "openWifiDirectSettings" -> openWifiDirectSettings(result)
            "openBluetoothSettings" -> openBluetoothSettings(result)
            "openBluetoothTetherSettings" -> openBluetoothTetherSettings(result)
            "openLocationSettings" -> openLocationSettings(result)
            "openExternalUrl" -> openExternalUrl(call.argument<String>("url"), result)
            "openAppSettings" -> {
                val intent = Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:${activity.packageName}")
                )
                activity.startActivity(intent)
                result.success(true)
            }
            "setPreferLocalNetwork" -> setPreferLocalNetwork(
                call.argument<Boolean>("enabled") == true,
                result
            )
            "setTransportMode" -> setTransportMode(
                call.argument<String>("mode"),
                result
            )
            "setTorch" -> setTorch(call.argument<Boolean>("enabled") == true, result)
            "discoverPeers" -> discoverPeers(result)
            "discoverAppPeers" -> discoverAppPeers(result)
            "getPeers" -> {
                requestPeers()
                result.success(currentPeers)
            }
            "connectPeer" -> connectPeer(call.argument<String>("deviceAddress"), result)
            "scanWifi" -> scanWifi(result)
            "connectWifi" -> connectWifi(
                call.argument<String>("ssid"),
                call.argument<String>("passphrase"),
                result
            )
            "createGroup" -> createGroup(result)
            "removeGroup" -> removeGroup(result)
            "groupInfo" -> {
                refreshP2pSnapshot {
                    result.success(status())
                }
            }
            "startLocalOnlyHotspot" -> startLocalOnlyHotspot(result)
            "stopLocalOnlyHotspot" -> {
                stopLocalOnlyHotspot()
                result.success(status())
            }
            "currentLocation" -> currentLocation(call, result)
            "status" -> {
                refreshP2pSnapshot {
                    result.success(status())
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            !hasPermission(Manifest.permission.POST_NOTIFICATIONS)
        ) {
            activity.requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                PERMISSION_REQUEST_CODE
            )
        }
        result.success(permissionSnapshot())
    }

    private fun startBackgroundMeshService(result: MethodChannel.Result) {
        val intent = Intent(appContext, MeshBackgroundService::class.java)
        val started = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                appContext.startForegroundService(intent)
            } else {
                appContext.startService(intent)
            }
        }.isSuccess

        if (started) {
            result.success(true)
        } else {
            result.error(
                "background_service_failed",
                "未能啟動背景光之網絡服務。",
                null
            )
        }
    }

    private fun stopBackgroundMeshService(result: MethodChannel.Result) {
        val stopped = appContext.stopService(
            Intent(appContext, MeshBackgroundService::class.java)
        )
        result.success(stopped)
    }

    private fun showChatNotification(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val roomName = (args?.get("title") as? String)?.trim().orEmpty()
        val senderName = (args?.get("senderName") as? String)?.trim().orEmpty()
        val body = (args?.get("body") as? String)?.trim().orEmpty()
        if (body.isEmpty()) {
            result.success(false)
            return
        }

        val title = if (roomName.isEmpty()) "傳播光新留言" else roomName
        val text = if (senderName.isEmpty()) body else "$senderName：$body"
        result.success(MeshNotifications.showChatNotification(appContext, title, text))
    }

    private fun openExternalUrl(url: String?, result: MethodChannel.Result) {
        if (url.isNullOrBlank()) {
            result.error("invalid_url", "缺少連結。", null)
            return
        }
        val uri = Uri.parse(url)
        val scheme = uri.scheme?.lowercase()
        if (scheme != "https" && scheme != "http") {
            result.error("invalid_url", "只可開啟 http 或 https 連結。", null)
            return
        }

        val intent = Intent(Intent.ACTION_VIEW, uri).apply {
            addCategory(Intent.CATEGORY_BROWSABLE)
        }
        try {
            activity.startActivity(intent)
            result.success(true)
        } catch (error: ActivityNotFoundException) {
            result.error("url_unavailable", "未能打開連結。", error.localizedMessage)
        }
    }

    private fun openBluetoothSettings(result: MethodChannel.Result) {
        val opened = openFirstAvailableSettingsAction(
            listOf(
                Settings.ACTION_BLUETOOTH_SETTINGS,
                Settings.ACTION_WIRELESS_SETTINGS
            )
        )
        if (opened) {
            result.success(status() + mapOf("message" to "已打開 Android 藍芽設定。"))
        } else {
            result.error("settings_unavailable", "未能打開藍芽設定。", null)
        }
    }

    private fun openWifiDirectSettings(result: MethodChannel.Result) {
        transportMode = TRANSPORT_WIFI
        preferBluetoothNetwork = false
        networkGeneration += 1
        bindProcessToPreferredNetwork()
        val opened = openFirstAvailableSettingsAction(
            listOf(
                "android.settings.WIFI_P2P_SETTINGS",
                Settings.ACTION_WIFI_SETTINGS,
                Settings.ACTION_WIRELESS_SETTINGS
            )
        )
        if (opened) {
            result.success(
                status() + mapOf(
                    "message" to "已打開 Wi‑Fi Direct 設定。請在 Direct 頁選擇另一部手機連接，完成後返回 APP。"
                )
            )
        } else {
            result.error("settings_unavailable", "未能打開 Wi‑Fi Direct 設定。", null)
        }
    }

    private fun openBluetoothTetherSettings(result: MethodChannel.Result) {
        transportMode = TRANSPORT_BLUETOOTH
        preferBluetoothNetwork = true
        networkGeneration += 1
        bindProcessToPreferredNetwork()
        val opened = openFirstAvailableSettingsAction(
            listOf(
                "android.settings.TETHER_SETTINGS",
                Settings.ACTION_WIRELESS_SETTINGS,
                Settings.ACTION_BLUETOOTH_SETTINGS
            )
        )
        if (opened) {
            result.success(
                status() + mapOf(
                    "message" to "已啟用藍芽共享優先模式，請在系統設定開啟藍芽網絡共享。返回後 app 會優先使用該網絡。"
                )
            )
        } else {
            result.error("settings_unavailable", "未能打開熱點與網絡共享設定。", null)
        }
    }

    private fun openLocationSettings(result: MethodChannel.Result) {
        val opened = openFirstAvailableSettingsAction(
            listOf(
                Settings.ACTION_LOCATION_SOURCE_SETTINGS,
                Settings.ACTION_SETTINGS
            )
        )
        if (opened) {
            result.success(
                status() + mapOf(
                    "message" to "已打開 Android 定位設定。請開啟定位服務後再掃手機。"
                )
            )
        } else {
            result.error("settings_unavailable", "未能打開定位設定。", null)
        }
    }

    private fun openFirstAvailableSettingsAction(actions: List<String>): Boolean {
        for (action in actions) {
            val opened = runCatching {
                activity.startActivity(Intent(action))
                true
            }.getOrDefault(false)
            if (opened) {
                return true
            }
        }
        return false
    }

    private fun capabilities(): Map<String, Any?> {
        val hasP2pFeature =
            activity.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT)
        val hasBluetoothFeature =
            activity.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH)
        return mapOf(
            "platform" to "android",
            "sdkInt" to Build.VERSION.SDK_INT,
            "wifiDirectSupported" to (p2pManager != null && hasP2pFeature),
            "localOnlyHotspotSupported" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O),
            "bluetoothSupported" to (bluetoothAdapter != null && hasBluetoothFeature),
            "torchSupported" to hasTorch(),
            "canOpenWifiSettings" to true,
            "canOpenWifiDirectSettings" to true,
            "canOpenBluetoothSettings" to true,
            "canOpenBluetoothTetherSettings" to true,
            "canOpenLocationSettings" to true,
            "permissions" to permissionSnapshot()
        )
    }

    private fun status(): Map<String, Any?> {
        refreshKnownNetworks()
        val selectedNetwork = preferredNetwork()
        val boundToBluetooth = selectedNetwork != null && selectedNetwork == bluetoothNetwork
        val boundToWifi =
            selectedNetwork != null &&
                selectedNetwork != bluetoothNetwork &&
                (wifiDirectNetwork != null || localNetwork != null)

        // Merge currentPeers with group clients to show connected devices
        val allPeers = buildList {
            addAll(currentPeers)

            // Add group clients (already connected devices) to the peer list
            currentGroup?.let { group ->
                @Suppress("UNCHECKED_CAST")
                val clients = (group["clients"] as? List<Map<String, Any?>>).orEmpty()

                // Filter out duplicates by device address
                val existingAddresses = currentPeers.mapNotNull {
                    it["deviceAddress"] as? String
                }.toSet()

                clients.forEach { client ->
                    val address = client["deviceAddress"] as? String
                    if (address != null && address !in existingAddresses) {
                        add(client)
                    }
                }
            }
        }

        return mapOf(
            "capabilities" to capabilities(),
            "peers" to if (transportMode == TRANSPORT_BLUETOOTH) emptyList<Map<String, Any?>>() else allPeers,
            "wifiNetworks" to if (transportMode == TRANSPORT_BLUETOOTH) emptyList<Map<String, Any?>>() else currentWifiNetworks,
            "group" to currentGroup,
            "connection" to currentConnection,
            "hotspot" to hotspotInfo,
            "wifiEnabled" to wifiManager.isWifiEnabled,
            "wifiP2pEnabled" to wifiP2pEnabled,
            "locationServicesEnabled" to locationServicesEnabled(),
            "bluetoothEnabled" to isBluetoothEnabled(),
            "preferLocalNetwork" to preferLocalNetwork,
            "preferBluetoothNetwork" to preferBluetoothNetwork,
            "transportMode" to transportMode,
            "boundToWifi" to boundToWifi,
            "boundToBluetooth" to boundToBluetooth,
            "networkGeneration" to networkGeneration
        )
    }

    private fun setTransportMode(mode: String?, result: MethodChannel.Result) {
        val nextMode = when (mode) {
            TRANSPORT_BLUETOOTH -> TRANSPORT_BLUETOOTH
            else -> TRANSPORT_WIFI
        }
        if (transportMode != nextMode) {
            transportMode = nextMode
            preferBluetoothNetwork = nextMode == TRANSPORT_BLUETOOTH
            networkGeneration += 1
        }
        bindProcessToPreferredNetwork()
        val message = if (transportMode == TRANSPORT_BLUETOOTH) {
            "已切換藍芽模式；離線聊天只會使用藍芽網絡。"
        } else {
            "已切換 WiFi 模式；離線聊天只會使用 WiFi / Wi‑Fi Direct。"
        }
        result.success(status() + mapOf("message" to message))
    }

    private fun setPreferLocalNetwork(enabled: Boolean, result: MethodChannel.Result) {
        if (preferLocalNetwork != enabled) {
            preferLocalNetwork = enabled
            networkGeneration += 1
        }
        bindProcessToPreferredNetwork()
        result.success(status())
    }

    private fun ensureP2pReadyForOperation(result: MethodChannel.Result): Boolean {
        if (!wifiP2pEnabled) {
            result.error(
                "wifi_direct_disabled",
                "Wi‑Fi Direct 未啟用。請先開啟 Wi‑Fi / Wi‑Fi Direct 後再掃手機。",
                status()
            )
            return false
        }
        if (!hasCoreWifiPermission()) {
            requestRuntimePermissions()
            result.error("permission_missing", "需要 Wi‑Fi Direct 權限後才可操作。", permissionSnapshot())
            return false
        }
        // Android 13+ with NEARBY_WIFI_DEVICES(neverForLocation): location services not needed for P2P
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU && !locationServicesEnabled()) {
            result.error("location_mode_off", locationModeRequiredMessage(), locationModeSnapshot())
            return false
        }
        if (p2pOperationBusy) {
            result.error(
                "BUSY",
                "Wi‑Fi Direct 正在處理上一個操作，請稍後再試。",
                status()
            )
            return false
        }
        return true
    }

    private fun runP2pOperationWithDebounce(block: () -> Unit) {
        p2pOperationBusy = true
        val now = System.currentTimeMillis()
        val waitMs = (500L - (now - lastP2pOperationAt)).coerceAtLeast(0L)
        lastP2pOperationAt = now + waitMs
        mainHandler.postDelayed(block, waitMs)
    }

    private fun finishP2pOperation() {
        p2pOperationBusy = false
        lastP2pOperationAt = System.currentTimeMillis()
    }

    private fun setTorch(enabled: Boolean, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            result.error("torch_unavailable", "此 Android 版本未支援 SOS 燈。", null)
            return
        }

        if (!hasTorch()) {
            result.error("torch_unavailable", "此裝置未找到可用閃光燈。", null)
            return
        }

        if (enabled && !hasPermission(Manifest.permission.CAMERA)) {
            activity.requestPermissions(
                arrayOf(Manifest.permission.CAMERA),
                TORCH_PERMISSION_REQUEST_CODE
            )
            result.error(
                "permission_missing",
                "請允許相機權限後再按一次 SOS 燈。",
                mapOf(
                    "required" to listOf(Manifest.permission.CAMERA),
                    "missing" to listOf(Manifest.permission.CAMERA)
                )
            )
            return
        }

        try {
            applyTorch(enabled)
            result.success(
                mapOf(
                    "enabled" to enabled,
                    "torchSupported" to true,
                    "message" to if (enabled) "SOS 燈已啟動。" else "SOS 燈已停止。"
                )
            )
        } catch (error: SecurityException) {
            result.error(
                "permission_missing",
                "需要相機權限後才可使用 SOS 燈。",
                mapOf(
                    "required" to listOf(Manifest.permission.CAMERA),
                    "missing" to listOf(Manifest.permission.CAMERA)
                )
            )
        } catch (error: CameraAccessException) {
            result.error("torch_unavailable", "未能存取手機閃光燈。", error.reason)
        } catch (error: Exception) {
            result.error("torch_failed", error.message ?: "SOS 燈操作失敗。", null)
        }
    }

    private fun applyTorch(enabled: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return
        }
        val cameraId = findTorchCameraId() ?: return
        cameraManager.setTorchMode(cameraId, enabled)
    }

    private fun hasTorch(): Boolean {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && findTorchCameraId() != null
    }

    private fun findTorchCameraId(): String? {
        torchCameraId?.let { return it }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return null
        }

        return try {
            var fallback: String? = null
            for (cameraId in cameraManager.cameraIdList) {
                val characteristics = cameraManager.getCameraCharacteristics(cameraId)
                val hasFlash =
                    characteristics.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
                if (!hasFlash) {
                    continue
                }

                if (fallback == null) {
                    fallback = cameraId
                }
                val facing = characteristics.get(CameraCharacteristics.LENS_FACING)
                if (facing == CameraCharacteristics.LENS_FACING_BACK) {
                    torchCameraId = cameraId
                    return cameraId
                }
            }
            torchCameraId = fallback
            fallback
        } catch (_: Exception) {
            null
        }
    }

    private fun permissionSnapshot(): Map<String, Any?> {
        val required = requiredPermissions()
        return mapOf(
            "required" to required,
            "missing" to required.filter { permission ->
                !hasPermission(permission)
            }
        )
    }

    private fun requiredPermissions(): List<String> {
        val permissions = mutableListOf(
            Manifest.permission.ACCESS_WIFI_STATE,
            Manifest.permission.ACCESS_NETWORK_STATE,
            Manifest.permission.CHANGE_WIFI_MULTICAST_STATE
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            permissions += Manifest.permission.NEARBY_WIFI_DEVICES
            permissions += Manifest.permission.POST_NOTIFICATIONS
        } else {
            permissions += Manifest.permission.ACCESS_FINE_LOCATION
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            permissions += Manifest.permission.BLUETOOTH_CONNECT
        }
        permissions += Manifest.permission.CAMERA
        permissions += Manifest.permission.ACCESS_COARSE_LOCATION
        permissions += Manifest.permission.ACCESS_FINE_LOCATION

        return permissions.distinct()
    }

    private fun requestRuntimePermissions(): Boolean {
        val missing = permissionSnapshot()["missing"] as List<*>
        val requestable = missing.filterIsInstance<String>().filter { permission ->
            Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                activity.shouldShowRequestPermissionRationale(permission) ||
                !hasPermission(permission)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && requestable.isNotEmpty()) {
            activity.requestPermissions(requestable.toTypedArray(), PERMISSION_REQUEST_CODE)
            return true
        }

        return false
    }

    private fun currentLocation(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val lowPower = args?.get("lowPower") == true
        val maxCacheAgeMillis =
            ((args?.get("maxCacheAgeMillis") as? Number)?.toLong() ?: 120_000L)
                .coerceIn(0L, 900_000L)
        currentLocation(result, lowPower, maxCacheAgeMillis)
    }

    @SuppressLint("MissingPermission")
    private fun currentLocation(
        result: MethodChannel.Result,
        lowPower: Boolean = false,
        maxCacheAgeMillis: Long = 120_000L
    ) {
        if (!hasLocationPermission()) {
            if (pendingLocationResult != null) {
                result.error(
                    "permission_pending",
                    "正在等待位置權限。",
                    locationPermissionSnapshot()
                )
                return
            }

            pendingLocationResult = result
            pendingLocationLowPower = lowPower
            pendingLocationMaxCacheAgeMillis = maxCacheAgeMillis
            if (requestRuntimePermissions()) {
                return
            }

            pendingLocationResult = null
            result.error(
                "permission_missing",
                "需要位置權限後才可在光之雷達顯示你的光點。",
                locationPermissionSnapshot()
            )
            return
        }

        val cached = bestLastKnownLocation()
        val now = System.currentTimeMillis()
        if (cached != null &&
            maxCacheAgeMillis > 0L &&
            cached.time > 0 &&
            now - cached.time < maxCacheAgeMillis
        ) {
            result.success(cached.toLocationMap(fromCache = true, message = "已使用最近定位"))
            return
        }

        val providers = (if (lowPower) {
            listOf(LocationManager.NETWORK_PROVIDER)
        } else {
            listOf(LocationManager.NETWORK_PROVIDER, LocationManager.GPS_PROVIDER)
        })
            .filter { provider ->
                runCatching { locationManager.isProviderEnabled(provider) }.getOrDefault(false)
            }

        if (providers.isEmpty()) {
            if (cached != null) {
                result.success(cached.toLocationMap(fromCache = true, message = "定位服務未開啟，已使用暫存位置"))
            } else {
                result.error("location_disabled", "請先開啟手機定位服務。", null)
            }
            return
        }

        var finished = false
        var listener: LocationListener? = null

        fun clearListener() {
            listener?.let { runCatching { locationManager.removeUpdates(it) } }
            listener = null
        }

        fun finishWithLocation(location: Location, fromCache: Boolean, message: String) {
            if (finished) {
                return
            }
            finished = true
            clearListener()
            result.success(location.toLocationMap(fromCache = fromCache, message = message))
        }

        fun finishWithError(code: String, message: String) {
            if (finished) {
                return
            }
            finished = true
            clearListener()
            result.error(code, message, null)
        }

        listener =
            object : LocationListener {
                override fun onLocationChanged(location: Location) {
                    finishWithLocation(location, fromCache = false, message = "定位成功")
                }

                override fun onProviderEnabled(provider: String) = Unit

                override fun onProviderDisabled(provider: String) = Unit

                @Deprecated("Deprecated in Android framework")
                override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) = Unit
            }

        var requested = false
        for (provider in providers) {
            val activeListener = listener ?: continue
            val ok = runCatching {
                locationManager.requestLocationUpdates(
                    provider,
                    if (lowPower) 30_000L else 0L,
                    if (lowPower) 25f else 0f,
                    activeListener,
                    Looper.getMainLooper()
                )
            }.isSuccess
            requested = requested || ok
        }

        if (!requested) {
            if (cached != null) {
                finishWithLocation(cached, fromCache = true, message = "未能刷新定位，已使用暫存位置")
            } else {
                finishWithError("location_unavailable", "未能讀取手機定位。")
            }
            return
        }

        mainHandler.postDelayed({
            if (finished) {
                return@postDelayed
            }
            val fallback = bestLastKnownLocation() ?: cached
            if (fallback != null) {
                finishWithLocation(fallback, fromCache = true, message = "定位逾時，已使用最近位置")
            } else {
                finishWithError("location_timeout", "定位逾時，請到室外或開啟更準確定位。")
            }
        }, if (lowPower) 4500L else 8000L)
    }

    @SuppressLint("MissingPermission")
    private fun prepareWifiDirectInvite(result: MethodChannel.Result) {
        val manager = p2pManager ?: run {
            result.error("wifi_direct_unavailable", "此 Android 裝置不支援 Wi-Fi Direct。", null)
            return
        }
        val channel = p2pChannel ?: run {
            result.error("wifi_direct_not_ready", "Wi-Fi Direct channel 未準備好。", null)
            return
        }
        if (!hasCoreWifiPermission()) {
            requestRuntimePermissions()
            result.error(
                "permission_missing",
                "需要位置 / Wi‑Fi 權限後才可使用 Wi‑Fi Direct。",
                permissionSnapshot()
            )
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU && !locationServicesEnabled()) {
            result.error("location_mode_off", locationModeRequiredMessage(), locationModeSnapshot())
            return
        }

        armWifiDirectInviteReceiver(
            manager = manager,
            channel = channel,
            force = true,
            onReady = {
                requestPeers {
                    result.success(
                        status() + mapOf(
                            "message" to "Wi‑Fi Direct 已預熱。請掃手機並發出邀請。"
                        )
                    )
                }
            },
            onFailure = { reason ->
                result.error(p2pFailureCode(reason), p2pReason(reason), reason)
            }
        )
    }

    @SuppressLint("MissingPermission")
    private fun armWifiDirectInviteReceiver(
        manager: WifiP2pManager? = p2pManager,
        channel: Channel? = p2pChannel,
        force: Boolean = false,
        onReady: (() -> Unit)? = null,
        onFailure: ((Int) -> Unit)? = null
    ) {
        val activeManager = manager ?: return
        val activeChannel = channel ?: return
        if (!foregroundActive && !force) {
            return
        }
        if (!hasCoreWifiPermission()) return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU && !locationServicesEnabled()) return

        val now = System.currentTimeMillis()
        if (!force && now - lastInviteListenAt < 12_000L) {
            onReady?.invoke()
            return
        }
        lastInviteListenAt = now

        fun startDiscover() {
            activeManager.discoverPeers(
                activeChannel,
                object : ActionListener {
                    override fun onSuccess() {
                        mainHandler.postDelayed({
                            requestPeers { onReady?.invoke() }
                        }, 900)
                    }

                    override fun onFailure(reason: Int) {
                        onFailure?.invoke(reason)
                    }
                }
            )
        }

        fun removeGroupThenDiscover() {
            // Skip removal if a connection is already active — don't break an established session.
            // Only remove if we are a lone GO with no connected peers (both-GO scenario).
            val groupFormed = currentConnection?.get("groupFormed") == true
            if (groupFormed) {
                startDiscover()
                return
            }
            activeManager.removeGroup(activeChannel, object : ActionListener {
                override fun onSuccess() {
                    currentGroup = null
                    currentConnection = null
                    wifiDirectNetwork = null
                    bindProcessToPreferredNetwork()
                    mainHandler.postDelayed({ startDiscover() }, 500L)
                }
                override fun onFailure(reason: Int) {
                    startDiscover()
                }
            })
        }

        configureAppServiceListeners(activeManager, activeChannel)
        ensureLocalAppService(
            activeManager,
            activeChannel,
            onReady = { removeGroupThenDiscover() },
            onFailure = { removeGroupThenDiscover() }
        )
    }

    @SuppressLint("MissingPermission")
    private fun discoverPeers(result: MethodChannel.Result) {
        val manager = p2pManager ?: run {
            result.error("wifi_direct_unavailable", "此 Android 裝置不支援 Wi-Fi Direct。", null)
            return
        }
        val channel = p2pChannel ?: run {
            result.error("wifi_direct_not_ready", "Wi-Fi Direct channel 未準備好。", null)
            return
        }

        if (!ensureP2pReadyForOperation(result)) {
            return
        }

        runP2pOperationWithDebounce {
            runCatching { manager.stopPeerDiscovery(channel, null) }
            mainHandler.postDelayed({
                manager.discoverPeers(
                    channel,
                    object : ActionListener {
                        override fun onSuccess() {
                            mainHandler.postDelayed({
                                requestPeers {
                                    finishP2pOperation()
                                    result.success(
                                        status() + mapOf(
                                            "message" to "已掃描 Wi‑Fi Direct 手機。請選擇手機後發出邀請。"
                                        )
                                    )
                                }
                            }, 900)
                        }

                        override fun onFailure(reason: Int) {
                            finishP2pOperation()
                            result.error(p2pFailureCode(reason), p2pReason(reason), reason)
                        }
                    }
                )
            }, 500L)
        }
    }

    private fun discoverAppPeers(result: MethodChannel.Result) {
        val manager = p2pManager ?: run {
            result.error("wifi_direct_unavailable", "此 Android 裝置不支援 Wi-Fi Direct。", null)
            return
        }
        val channel = p2pChannel ?: run {
            result.error("wifi_direct_not_ready", "Wi-Fi Direct channel 未準備好。", null)
            return
        }

        if (!hasCoreWifiPermission()) {
            requestRuntimePermissions()
            result.error("permission_missing", "需要 Wi-Fi Direct 權限後才可掃描 app peers。", permissionSnapshot())
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU && !locationServicesEnabled()) {
            result.error("location_mode_off", locationModeRequiredMessage(), locationModeSnapshot())
            return
        }

        appPeerAddresses.clear()
        appPeerNames.clear()
        currentPeers = currentPeers.map { peer ->
            peer + mapOf("isAppPeer" to false, "serviceName" to null)
        }

        configureAppServiceListeners(manager, channel)
        warmUpPeerDiscovery(
            manager,
            channel,
            onReady = {
                ensureLocalAppService(
                    manager,
                    channel,
                    onReady = {
                        val request = WifiP2pDnsSdServiceRequest.newInstance(APP_SERVICE_TYPE)
                        manager.clearServiceRequests(
                            channel,
                            object : ActionListener {
                                override fun onSuccess() {
                                    addAppServiceRequest(manager, channel, request, result)
                                }

                                override fun onFailure(reason: Int) {
                                    result.error(p2pFailureCode(reason), p2pReason(reason), reason)
                                }
                            }
                        )
                    },
                    onFailure = { reason ->
                        result.error(p2pFailureCode(reason), p2pReason(reason), reason)
                    }
                )
            },
            onFailure = { reason ->
                result.error(p2pFailureCode(reason), p2pReason(reason), reason)
            }
        )
    }

    @SuppressLint("MissingPermission")
    private fun warmUpPeerDiscovery(
        manager: WifiP2pManager,
        channel: Channel,
        onReady: () -> Unit,
        onFailure: (Int) -> Unit
    ) {
        manager.discoverPeers(
            channel,
            object : ActionListener {
                override fun onSuccess() {
                    mainHandler.postDelayed({
                        requestPeers { onReady() }
                    }, 900)
                }

                override fun onFailure(reason: Int) {
                    onFailure(reason)
                }
            }
        )
    }

    private fun addAppServiceRequest(
        manager: WifiP2pManager,
        channel: Channel,
        request: WifiP2pDnsSdServiceRequest,
        result: MethodChannel.Result
    ) {
        manager.addServiceRequest(
            channel,
            request,
            object : ActionListener {
                override fun onSuccess() {
                    discoverAppServices(manager, channel, result)
                }

                override fun onFailure(reason: Int) {
                    if (reason == WifiP2pManager.ERROR) {
                        refreshP2pSnapshot {
                            result.success(
                                status() + mapOf("message" to "沒有可移除的 Wi‑Fi Direct group。")
                            )
                        }
                        return
                    }
                    result.error(p2pFailureCode(reason), p2pReason(reason), reason)
                }
            }
        )
    }

    private fun discoverAppServices(
        manager: WifiP2pManager,
        channel: Channel,
        result: MethodChannel.Result
    ) {
        manager.discoverServices(
            channel,
            object : ActionListener {
                override fun onSuccess() {
                    mainHandler.postDelayed({
                        requestPeers {
                            result.success(
                                status() + mapOf(
                                    "message" to appPeerDiscoveryMessage()
                                )
                            )
                        }
                    }, 2200)
                }

                override fun onFailure(reason: Int) {
                    result.error(p2pFailureCode(reason), p2pReason(reason), reason)
                }
            }
        )
    }

    private fun configureAppServiceListeners(manager: WifiP2pManager, channel: Channel) {
        manager.setDnsSdResponseListeners(
            channel,
            { instanceName, registrationType, srcDevice ->
                if (isAiecoService(instanceName, registrationType)) {
                    rememberAppPeer(srcDevice, instanceName)
                }
            },
            { fullDomainName, txtRecordMap, srcDevice ->
                val appName = txtRecordMap["app"].orEmpty()
                if (appName == "aieco_mesh" || fullDomainName.contains("aieco", ignoreCase = true)) {
                    rememberAppPeer(srcDevice, fullDomainName)
                }
            }
        )
    }

    private fun ensureLocalAppService(
        manager: WifiP2pManager,
        channel: Channel,
        onReady: () -> Unit,
        onFailure: (Int) -> Unit
    ) {
        if (localAppServiceAdded) {
            onReady()
            return
        }

        val record = mapOf(
            "app" to "aieco_mesh",
            "name" to "傳播光"
        )
        val serviceInfo = WifiP2pDnsSdServiceInfo.newInstance(
            APP_SERVICE_INSTANCE,
            APP_SERVICE_TYPE,
            record
        )
        manager.addLocalService(
            channel,
            serviceInfo,
            object : ActionListener {
                override fun onSuccess() {
                    localAppServiceAdded = true
                    onReady()
                }

                override fun onFailure(reason: Int) {
                    onFailure(reason)
                }
            }
        )
    }

    private fun isAiecoService(instanceName: String?, registrationType: String?): Boolean {
        return instanceName?.contains("AIECO", ignoreCase = true) == true ||
            registrationType?.startsWith(APP_SERVICE_TYPE, ignoreCase = true) == true ||
            registrationType?.contains("aieco-mesh", ignoreCase = true) == true
    }

    private fun rememberAppPeer(device: WifiP2pDevice, serviceName: String?) {
        if (device.deviceAddress.isBlank()) return
        appPeerAddresses += device.deviceAddress
        if (!serviceName.isNullOrBlank()) {
            appPeerNames[device.deviceAddress] = serviceName
        }

        val peerMap = device.toMap(
            isAppPeer = true,
            serviceName = appPeerNames[device.deviceAddress]
        )
        currentPeers = (currentPeers.filter {
            it["deviceAddress"]?.toString() != device.deviceAddress
        } + peerMap).sortedBy {
            it["deviceName"]?.toString().orEmpty()
        }
    }

    private fun appPeerDiscoveryMessage(): String {
        val count = appPeerAddresses.size
        return if (count > 0) {
            "已先預熱 Wi‑Fi Direct peer 掃描，並找到 $count 個 app peer，可直接連接。"
        } else {
            "已預熱 Wi‑Fi Direct peer 掃描，但未找到已開啟本 app 的 peer。請確認兩部手機都開啟本 app、按權限，並開啟定位服務。"
        }
    }

    @SuppressLint("MissingPermission")
    private fun requestPeers(onComplete: (() -> Unit)? = null) {
        val manager = p2pManager ?: return
        val channel = p2pChannel ?: return
        if (!hasCoreWifiPermission()) {
            onComplete?.invoke()
            return
        }

        manager.requestPeers(
            channel,
            PeerListListener { peers: WifiP2pDeviceList ->
                currentPeers = peers.deviceList.map { peer ->
                    peer.toMap(
                        isAppPeer = appPeerAddresses.contains(peer.deviceAddress),
                        serviceName = appPeerNames[peer.deviceAddress]
                    )
                }.sortedBy {
                    it["deviceName"]?.toString().orEmpty()
                }
                onComplete?.invoke()
            }
        )
    }

    @SuppressLint("MissingPermission")
    private fun connectPeer(deviceAddress: String?, result: MethodChannel.Result) {
        val manager = p2pManager ?: run {
            result.error("wifi_direct_unavailable", "此 Android 裝置不支援 Wi-Fi Direct。", null)
            return
        }
        val channel = p2pChannel ?: run {
            result.error("wifi_direct_not_ready", "Wi-Fi Direct channel 未準備好。", null)
            return
        }
        if (deviceAddress.isNullOrBlank()) {
            result.error("bad_peer", "缺少 Wi‑Fi Direct deviceAddress。", null)
            return
        }
        if (!ensureP2pReadyForOperation(result)) return

        runP2pOperationWithDebounce {
            runCatching { manager.stopPeerDiscovery(channel, null) }
            mainHandler.postDelayed({ fullCleanupThenConnect(deviceAddress, result) }, 300L)
        }
    }

    // Always cancelConnect → removeGroup → wait → connect, regardless of current state.
    // This avoids branching on groupFormed which caused skipped cleanup and persistent ERROR.
    private fun fullCleanupThenConnect(deviceAddress: String, result: MethodChannel.Result) {
        val manager = p2pManager ?: return finishAndError(result, "wifi_direct_unavailable", "Wi-Fi Direct 不可用。")
        val ch1 = p2pChannel ?: return finishAndError(result, "wifi_direct_not_ready", "Channel 未就緒。")

        manager.cancelConnect(ch1, object : ActionListener {
            override fun onSuccess() = step2()
            override fun onFailure(reason: Int) = step2()
            fun step2() {
                val ch2 = p2pChannel ?: return finishAndError(result, "wifi_direct_not_ready", "Channel 未就緒。")
                mainHandler.postDelayed({
                    manager.removeGroup(ch2, object : ActionListener {
                        override fun onSuccess() {
                            currentGroup = null
                            currentConnection = null
                            wifiDirectNetwork = null
                            bindProcessToPreferredNetwork()
                            rediscoverThenConnect(manager, deviceAddress, result)
                        }
                        override fun onFailure(reason: Int) {
                            // No group to remove, or framework error — proceed anyway
                            rediscoverThenConnect(manager, deviceAddress, result)
                        }
                    })
                }, 250L)
            }
        })
    }

    // After cleanup, re-run discoverPeers so Android 13+ peer list is repopulated
    // before connect() is called (removeGroup clears the peer list on Android 13+).
    @SuppressLint("MissingPermission")
    private fun rediscoverThenConnect(manager: WifiP2pManager, deviceAddress: String, result: MethodChannel.Result) {
        val channel = p2pChannel ?: return finishAndError(result, "wifi_direct_not_ready", "Channel 未就緒。")
        manager.discoverPeers(channel, object : ActionListener {
            override fun onSuccess() {
                mainHandler.postDelayed({ doConnect(deviceAddress, result, 0) }, 1500L)
            }
            override fun onFailure(reason: Int) {
                mainHandler.postDelayed({ doConnect(deviceAddress, result, 0) }, 800L)
            }
        })
    }

    @SuppressLint("MissingPermission")
    private fun doConnect(deviceAddress: String, result: MethodChannel.Result, retryCount: Int) {
        val manager = p2pManager ?: return finishAndError(result, "wifi_direct_unavailable", "Wi-Fi Direct 不可用。")
        val channel = p2pChannel ?: return finishAndError(result, "wifi_direct_not_ready", "Channel 未就緒。")

        val config = WifiP2pConfig().apply {
            this.deviceAddress = deviceAddress
            wps.setup = WpsInfo.PBC
        }
        manager.connect(channel, config, object : ActionListener {
            override fun onSuccess() {
                mainHandler.postDelayed({
                    refreshP2pSnapshot {
                        finishP2pOperation()
                        result.success(status() + mapOf("message" to "Wi‑Fi Direct 邀請已送出，請在另一部手機接受系統邀請。"))
                    }
                }, 1500L)
            }

            override fun onFailure(reason: Int) {
                when {
                    reason == WifiP2pManager.ERROR && retryCount < 2 -> {
                        // Reinit channel to recover corrupted P2P framework state, then retry
                        reinitP2pChannel()
                        mainHandler.postDelayed({ doConnect(deviceAddress, result, retryCount + 1) }, 1500L)
                    }
                    reason == WifiP2pManager.BUSY && retryCount < 3 -> {
                        mainHandler.postDelayed({ doConnect(deviceAddress, result, retryCount + 1) }, 1000L * (retryCount + 1))
                    }
                    else -> {
                        finishP2pOperation()
                        result.error(p2pFailureCode(reason), p2pReason(reason), reason)
                    }
                }
            }
        })
    }

    private fun reinitP2pChannel() {
        runCatching { p2pChannel?.close() }
        p2pChannel = p2pManager?.initialize(appContext, Looper.getMainLooper(), null)
    }

    private fun finishAndError(result: MethodChannel.Result, code: String, message: String) {
        finishP2pOperation()
        result.error(code, message, null)
    }

    @SuppressLint("MissingPermission")
    private fun scanWifi(result: MethodChannel.Result) {
        if (!hasCoreWifiPermission()) {
            requestRuntimePermissions()
            result.error("permission_missing", "需要 Wi-Fi 掃描權限後才可列出附近 Wi-Fi。", permissionSnapshot())
            return
        }
        if (!locationServicesEnabled()) {
            result.error("location_mode_off", locationModeRequiredMessage(), locationModeSnapshot())
            return
        }

        runCatching { wifiManager.startScan() }
        currentWifiNetworks = wifiManager.scanResults
            .filter { it.SSID.isNotBlank() }
            .sortedWith(compareByDescending<android.net.wifi.ScanResult> { it.level }.thenBy { it.SSID })
            .distinctBy { it.SSID }
            .take(40)
            .map {
                mapOf(
                    "ssid" to it.SSID,
                    "bssid" to it.BSSID,
                    "capabilities" to it.capabilities,
                    "frequency" to it.frequency,
                    "level" to it.level
                )
            }
        result.success(status())
    }

    private fun connectWifi(ssid: String?, passphrase: String?, result: MethodChannel.Result) {
        if (ssid.isNullOrBlank()) {
            result.error("bad_wifi", "缺少 Wi-Fi SSID。", null)
            return
        }
        if (!hasCoreWifiPermission()) {
            requestRuntimePermissions()
            result.error("permission_missing", "需要 Wi-Fi 權限後才可連接。", permissionSnapshot())
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val specifierBuilder = WifiNetworkSpecifier.Builder().setSsid(ssid)
            if (!passphrase.isNullOrBlank()) {
                specifierBuilder.setWpa2Passphrase(passphrase)
            }
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .setNetworkSpecifier(specifierBuilder.build())
                .build()
            connectivityManager.requestNetwork(request, networkCallback)
            result.success(
                status() + mapOf(
                    "wifiConnectMode" to "specifier",
                    "message" to "已找到 MESH 網，Android 會彈出連接確認。確認後會自動配對。"
                )
            )
            return
        }

        @Suppress("DEPRECATION")
        val config = WifiConfiguration().apply {
            SSID = "\"$ssid\""
            if (passphrase.isNullOrBlank()) {
                allowedKeyManagement.set(WifiConfiguration.KeyMgmt.NONE)
            } else {
                preSharedKey = "\"$passphrase\""
            }
        }
        @Suppress("DEPRECATION")
        val networkId = wifiManager.addNetwork(config)
        if (networkId == -1) {
            result.error("wifi_connect_failed", "未能建立 Wi-Fi 設定。", null)
            return
        }
        @Suppress("DEPRECATION")
        val enabled = wifiManager.enableNetwork(networkId, true)
        @Suppress("DEPRECATION")
        wifiManager.reconnect()
        result.success(status() + mapOf("wifiConnectMode" to "legacy", "enabled" to enabled))
    }

    private fun createGroup(result: MethodChannel.Result) {
        val manager = p2pManager ?: run {
            result.error("wifi_direct_unavailable", "此 Android 裝置不支援 Wi-Fi Direct。", null)
            return
        }
        val channel = p2pChannel ?: run {
            result.error("wifi_direct_not_ready", "Wi-Fi Direct channel 未準備好。", null)
            return
        }
        if (!hasCoreWifiPermission()) {
            requestRuntimePermissions()
            result.error("permission_missing", "需要 Wi-Fi Direct 權限後才可開 group。", permissionSnapshot())
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU && !locationServicesEnabled()) {
            result.error("location_mode_off", locationModeRequiredMessage(), locationModeSnapshot())
            return
        }

        refreshP2pSnapshot {
            if (currentGroup != null || currentConnection?.get("groupFormed") == true) {
                result.success(
                    status() + mapOf("message" to "Wi‑Fi Direct group 已在運作。")
                )
            } else {
                @SuppressLint("MissingPermission")
                manager.createGroup(
                    channel,
                    object : ActionListener {
                        override fun onSuccess() {
                            mainHandler.postDelayed({
                                refreshP2pSnapshot {
                                    result.success(
                                        status() + mapOf(
                                            "message" to "Wi‑Fi Direct group 已開啟。"
                                        )
                                    )
                                }
                            }, 1200)
                        }

                        override fun onFailure(reason: Int) {
                            if (reason == WifiP2pManager.BUSY) {
                                refreshP2pSnapshot {
                                    result.success(
                                        status() + mapOf(
                                            "message" to "Wi‑Fi Direct 正在準備 group，稍後會再自動掃描。"
                                        )
                                    )
                                }
                                return
                            }
                            result.error(p2pFailureCode(reason), p2pReason(reason), reason)
                        }
                    }
                )
            }
        }
    }

    private fun removeGroup(result: MethodChannel.Result) {
        val manager = p2pManager ?: run {
            result.success(status())
            return
        }
        val channel = p2pChannel ?: run {
            result.success(status())
            return
        }

        manager.removeGroup(
            channel,
            object : ActionListener {
                override fun onSuccess() {
                    currentGroup = null
                    currentConnection = null
                    wifiDirectNetwork = null
                    bindProcessToPreferredNetwork()
                    result.success(status())
                }

                override fun onFailure(reason: Int) {
                    if (reason == WifiP2pManager.ERROR || reason == WifiP2pManager.BUSY) {
                        refreshP2pSnapshot {
                            result.success(
                                status() + mapOf("message" to "沒有可移除的 Wi‑Fi Direct group。")
                            )
                        }
                        return
                    }
                    result.error(p2pFailureCode(reason), p2pReason(reason), reason)
                }
            }
        )
    }

    @SuppressLint("MissingPermission")
    private fun refreshP2pSnapshot(onComplete: () -> Unit) {
        var pending = 2
        var finished = false

        fun done() {
            if (finished) {
                return
            }
            pending -= 1
            if (pending <= 0) {
                finished = true
                onComplete()
            }
        }

        mainHandler.postDelayed({
            if (!finished) {
                finished = true
                onComplete()
            }
        }, 1400L)

        requestConnectionInfo { done() }
        requestGroupInfo { done() }
    }

    private fun requestConnectionInfo(onComplete: (() -> Unit)? = null) {
        val manager = p2pManager ?: run {
            onComplete?.invoke()
            return
        }
        val channel = p2pChannel ?: run {
            onComplete?.invoke()
            return
        }
        if (!hasCoreWifiPermission()) {
            onComplete?.invoke()
            return
        }

        runCatching {
            manager.requestConnectionInfo(
                channel,
                ConnectionInfoListener { info: WifiP2pInfo ->
                    currentConnection = mapOf(
                        "groupFormed" to info.groupFormed,
                        "isGroupOwner" to info.isGroupOwner,
                        "groupOwnerAddress" to info.groupOwnerAddress?.hostAddress
                    )
                    if (!info.groupFormed) {
                        wifiDirectNetwork = null
                    }
                    bindProcessToPreferredNetwork()
                    onComplete?.invoke()
                }
            )
        }.onFailure {
            onComplete?.invoke()
        }
    }

    @SuppressLint("MissingPermission")
    private fun requestGroupInfo(onComplete: (() -> Unit)? = null) {
        val manager = p2pManager ?: run {
            onComplete?.invoke()
            return
        }
        val channel = p2pChannel ?: run {
            onComplete?.invoke()
            return
        }
        if (!hasCoreWifiPermission()) {
            onComplete?.invoke()
            return
        }

        runCatching {
            manager.requestGroupInfo(
                channel,
                GroupInfoListener { group: WifiP2pGroup? ->
                    currentGroup = group?.toMap()
                    onComplete?.invoke()
                }
            )
        }.onFailure {
            onComplete?.invoke()
        }
    }

    private fun startLocalOnlyHotspot(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.error("hotspot_unavailable", "Android 8.0 以下不支援 LocalOnlyHotspot API。", null)
            return
        }
        if (hotspotReservation != null) {
            result.success(status())
            return
        }
        if (hotspotStarting) {
            result.success(status() + mapOf("message" to "本地熱點正在啟動，請稍候。"))
            return
        }
        if (!hasCoreWifiPermission()) {
            requestRuntimePermissions()
            result.error("permission_missing", "需要 Wi-Fi 權限後才可啟動本地熱點。", permissionSnapshot())
            return
        }

        val requestId = ++hotspotRequestId
        hotspotStarting = true
        @SuppressLint("MissingPermission")
        try {
            wifiManager.startLocalOnlyHotspot(
                object : WifiManager.LocalOnlyHotspotCallback() {
                    private var completed = false

                    private fun isCurrentRequest(): Boolean {
                        return hotspotRequestId == requestId
                    }

                    override fun onStarted(reservation: LocalOnlyHotspotReservation) {
                        if (completed || !isCurrentRequest() || !hotspotStarting) {
                            runCatching { reservation.close() }
                            return
                        }
                        completed = true
                        hotspotStarting = false
                        hotspotReservation = reservation
                        hotspotInfo = reservation.wifiConfiguration.toHotspotMap()
                        result.success(status())
                    }

                    override fun onStopped() {
                        if (!isCurrentRequest()) {
                            return
                        }
                        hotspotStarting = false
                        hotspotReservation = null
                        hotspotInfo = null
                    }

                    override fun onFailed(reason: Int) {
                        if (completed || !isCurrentRequest()) {
                            return
                        }
                        completed = true
                        hotspotStarting = false
                        hotspotReservation = null
                        hotspotInfo = null
                        result.error("hotspot_failed", hotspotReason(reason), reason)
                    }
                },
                mainHandler
            )
        } catch (error: Exception) {
            if (hotspotRequestId == requestId) {
                hotspotRequestId += 1
            }
            hotspotStarting = false
            result.error(
                "hotspot_failed",
                error.message ?: "本地熱點啟動失敗。",
                null
            )
        }
    }

    private fun stopLocalOnlyHotspot() {
        hotspotRequestId += 1
        hotspotStarting = false
        runCatching { hotspotReservation?.close() }
        hotspotReservation = null
        hotspotInfo = null
    }

    private fun hasCoreWifiPermission(): Boolean {
        val permissions = mutableListOf(
            Manifest.permission.ACCESS_WIFI_STATE,
            Manifest.permission.ACCESS_NETWORK_STATE,
            Manifest.permission.CHANGE_WIFI_MULTICAST_STATE
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // Android 13+: NEARBY_WIFI_DEVICES (neverForLocation) replaces ACCESS_FINE_LOCATION for P2P
            permissions += Manifest.permission.NEARBY_WIFI_DEVICES
        } else {
            permissions += Manifest.permission.ACCESS_FINE_LOCATION
        }
        return permissions.all { permission ->
            hasPermission(permission)
        }
    }

    private fun locationServicesEnabled(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            locationManager.isLocationEnabled
        } else {
            @Suppress("DEPRECATION")
            runCatching {
                Settings.Secure.getInt(
                    activity.contentResolver,
                    Settings.Secure.LOCATION_MODE
                ) != Settings.Secure.LOCATION_MODE_OFF
            }.getOrDefault(false)
        }
    }

    private fun locationModeSnapshot(): Map<String, Any?> {
        return mapOf(
            "locationServicesEnabled" to locationServicesEnabled(),
            "canOpenLocationSettings" to true
        )
    }

    private fun locationModeRequiredMessage(): String {
        return "Android 需要開啟定位服務後，Wi‑Fi Direct 掃描和邀請才會正常。請開啟 Location Mode 後再試。"
    }

    private fun hasLocationPermission(): Boolean {
        return hasPermission(Manifest.permission.ACCESS_FINE_LOCATION) ||
            hasPermission(Manifest.permission.ACCESS_COARSE_LOCATION)
    }

    private fun isBluetoothEnabled(): Boolean {
        val adapter = bluetoothAdapter ?: return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            !hasPermission(Manifest.permission.BLUETOOTH_CONNECT)
        ) {
            return false
        }
        return runCatching { adapter.isEnabled }.getOrDefault(false)
    }

    private fun locationPermissionSnapshot(): Map<String, Any?> {
        val required = listOf(
            Manifest.permission.ACCESS_COARSE_LOCATION,
            Manifest.permission.ACCESS_FINE_LOCATION
        )
        return mapOf(
            "required" to required,
            "missing" to required.filter { permission -> !hasPermission(permission) }
        )
    }

    @SuppressLint("MissingPermission")
    private fun bestLastKnownLocation(): Location? {
        if (!hasLocationPermission()) {
            return null
        }
        return listOf(
            LocationManager.GPS_PROVIDER,
            LocationManager.NETWORK_PROVIDER,
            LocationManager.PASSIVE_PROVIDER
        ).mapNotNull { provider ->
            runCatching { locationManager.getLastKnownLocation(provider) }.getOrNull()
        }.maxByOrNull { location -> location.time }
    }

    private fun hasPermission(permission: String): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    }

    private fun p2pReason(reason: Int): String {
        return when (reason) {
            WifiP2pManager.P2P_UNSUPPORTED -> "此裝置不支援 Wi-Fi Direct。"
            WifiP2pManager.BUSY -> "Wi-Fi Direct 正忙，請稍後再試。"
            WifiP2pManager.ERROR -> "Wi-Fi Direct 系統錯誤。"
            else -> "Wi-Fi Direct 操作失敗：$reason"
        }
    }

    private fun p2pFailureCode(reason: Int): String {
        return when (reason) {
            WifiP2pManager.P2P_UNSUPPORTED -> "P2P_UNSUPPORTED"
            WifiP2pManager.BUSY -> "BUSY"
            WifiP2pManager.ERROR -> "ERROR"
            else -> "P2P_$reason"
        }
    }

    private fun hotspotReason(reason: Int): String {
        return when (reason) {
            WifiManager.LocalOnlyHotspotCallback.ERROR_NO_CHANNEL ->
                "沒有可用 Wi-Fi channel。"
            WifiManager.LocalOnlyHotspotCallback.ERROR_GENERIC ->
                "本地熱點啟動失敗。"
            WifiManager.LocalOnlyHotspotCallback.ERROR_INCOMPATIBLE_MODE ->
                "目前 Wi-Fi 模式不兼容本地熱點。"
            WifiManager.LocalOnlyHotspotCallback.ERROR_TETHERING_DISALLOWED ->
                "系統或電訊商不允許熱點。"
            else -> "本地熱點啟動失敗：$reason"
        }
    }
}

private fun WifiP2pDevice.toMap(
    isAppPeer: Boolean = false,
    serviceName: String? = null
): Map<String, Any?> {
    return mapOf(
        "deviceName" to deviceName,
        "deviceAddress" to deviceAddress,
        "primaryDeviceType" to primaryDeviceType,
        "secondaryDeviceType" to secondaryDeviceType,
        "status" to status,
        "statusText" to p2pDeviceStatusText(status),
        "isGroupOwner" to isGroupOwner,
        "wpsPbcSupported" to wpsPbcSupported(),
        "wpsKeypadSupported" to wpsKeypadSupported(),
        "wpsDisplaySupported" to wpsDisplaySupported(),
        "serviceDiscoveryCapable" to isServiceDiscoveryCapable,
        "isAppPeer" to isAppPeer,
        "serviceName" to serviceName
    )
}

private fun WifiP2pGroup.toMap(): Map<String, Any?> {
    return mapOf(
        "networkName" to networkName,
        "passphrase" to passphrase,
        "interface" to `interface`,
        "isGroupOwner" to isGroupOwner,
        "owner" to owner?.toMap(),
        "clients" to clientList.map { it.toMap() }
    )
}

private fun Location.toLocationMap(fromCache: Boolean, message: String): Map<String, Any?> {
    return mapOf(
        "latitude" to latitude,
        "longitude" to longitude,
        "accuracyMeters" to if (hasAccuracy()) accuracy.toDouble() else 0.0,
        "provider" to (provider ?: "unknown"),
        "timestampMillis" to if (time > 0) time else System.currentTimeMillis(),
        "fromCache" to fromCache,
        "message" to message
    )
}

@Suppress("DEPRECATION")
private fun WifiConfiguration?.toHotspotMap(): Map<String, Any?> {
    return mapOf(
        "ssid" to this?.SSID,
        "preSharedKey" to this?.preSharedKey,
        "networkId" to this?.networkId
    )
}

private fun p2pDeviceStatusText(status: Int): String {
    return when (status) {
        WifiP2pDevice.AVAILABLE -> "可連接"
        WifiP2pDevice.INVITED -> "已邀請"
        WifiP2pDevice.CONNECTED -> "已連接"
        WifiP2pDevice.FAILED -> "失敗"
        WifiP2pDevice.UNAVAILABLE -> "不可用"
        else -> "未知"
    }
}
