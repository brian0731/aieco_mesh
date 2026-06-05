package com.example.aieco_mesh

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.net.ConnectivityManager
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
        private const val APP_SERVICE_INSTANCE = "AIECO Mesh"
        private const val APP_SERVICE_TYPE = "_aieco-mesh._tcp"
    }

    private val appContext = activity.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private val wifiManager = appContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val locationManager =
        appContext.getSystemService(Context.LOCATION_SERVICE) as LocationManager
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
    private var localNetwork: Network? = null
    private var bluetoothNetwork: Network? = null
    private var networkGeneration = 0L
    private var receiverRegistered = false
    private var pendingLocationResult: MethodChannel.Result? = null

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
                    WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION -> requestConnectionInfo()
                }
            }
        }

    private val networkCallback =
        object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                localNetwork = network
                networkGeneration += 1
                bindProcessToPreferredNetwork()
            }

            override fun onLost(network: Network) {
                if (localNetwork == network) {
                    localNetwork = null
                    networkGeneration += 1
                    bindProcessToPreferredNetwork()
                }
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
        pendingLocationResult?.error("activity_destroyed", "定位中斷。", null)
        pendingLocationResult = null
        runCatching { connectivityManager.unregisterNetworkCallback(networkCallback) }
        runCatching { connectivityManager.unregisterNetworkCallback(bluetoothNetworkCallback) }
        localNetwork = null
        bluetoothNetwork = null
        bindProcessToNetwork(null)
    }

    fun onRequestPermissionsResult(requestCode: Int) {
        if (requestCode != PERMISSION_REQUEST_CODE) {
            return
        }

        val result = pendingLocationResult ?: return
        pendingLocationResult = null

        if (hasLocationPermission()) {
            currentLocation(result)
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
        bindProcessToNetwork(localNetwork ?: bluetoothNetwork)
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capabilities" -> result.success(capabilities())
            "requestPermissions" -> {
                requestRuntimePermissions()
                result.success(permissionSnapshot())
            }
            "openWifiSettings" -> {
                activity.startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
                result.success(true)
            }
            "openBluetoothSettings" -> openBluetoothSettings(result)
            "openBluetoothTetherSettings" -> openBluetoothTetherSettings(result)
            "openAppSettings" -> {
                val intent = Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:${activity.packageName}")
                )
                activity.startActivity(intent)
                result.success(true)
            }
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
                requestConnectionInfo()
                requestGroupInfo()
                result.success(status())
            }
            "startLocalOnlyHotspot" -> startLocalOnlyHotspot(result)
            "stopLocalOnlyHotspot" -> {
                stopLocalOnlyHotspot()
                result.success(status())
            }
            "currentLocation" -> currentLocation(result)
            "status" -> {
                requestConnectionInfo()
                requestGroupInfo()
                result.success(status())
            }
            else -> result.notImplemented()
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

    private fun openBluetoothTetherSettings(result: MethodChannel.Result) {
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
                    "message" to "已打開 Android 熱點與網絡共享設定。請在系統設定開啟藍芽網絡共享。"
                )
            )
        } else {
            result.error("settings_unavailable", "未能打開熱點與網絡共享設定。", null)
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
            "canOpenWifiSettings" to true,
            "canOpenBluetoothSettings" to true,
            "canOpenBluetoothTetherSettings" to true,
            "permissions" to permissionSnapshot()
        )
    }

    private fun status(): Map<String, Any?> {
        return mapOf(
            "capabilities" to capabilities(),
            "peers" to currentPeers,
            "wifiNetworks" to currentWifiNetworks,
            "group" to currentGroup,
            "connection" to currentConnection,
            "hotspot" to hotspotInfo,
            "wifiEnabled" to wifiManager.isWifiEnabled,
            "bluetoothEnabled" to isBluetoothEnabled(),
            "boundToWifi" to (localNetwork != null),
            "boundToBluetooth" to (bluetoothNetwork != null && localNetwork == null),
            "networkGeneration" to networkGeneration
        )
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
        } else {
            permissions += Manifest.permission.ACCESS_FINE_LOCATION
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            permissions += Manifest.permission.BLUETOOTH_CONNECT
        }
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

    @SuppressLint("MissingPermission")
    private fun currentLocation(result: MethodChannel.Result) {
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
        if (cached != null && cached.time > 0 && now - cached.time < 120_000L) {
            result.success(cached.toLocationMap(fromCache = true, message = "已使用最近定位"))
            return
        }

        val providers = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
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
                    0L,
                    0f,
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
        }, 8000L)
    }

    private fun discoverPeers(result: MethodChannel.Result) {
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
            result.error("permission_missing", "需要 Wi-Fi Direct 權限後才可掃描。", permissionSnapshot())
            return
        }

        manager.discoverPeers(
            channel,
            object : ActionListener {
                override fun onSuccess() {
                    mainHandler.postDelayed({
                        requestPeers { result.success(status()) }
                    }, 1200)
                }

                override fun onFailure(reason: Int) {
                    result.error("discover_failed", p2pReason(reason), reason)
                }
            }
        )
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

        appPeerAddresses.clear()
        appPeerNames.clear()
        currentPeers = currentPeers.map { peer ->
            peer + mapOf("isAppPeer" to false, "serviceName" to null)
        }

        configureAppServiceListeners(manager, channel)
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
                            result.error("service_clear_failed", p2pReason(reason), reason)
                        }
                    }
                )
            },
            onFailure = { reason ->
                result.error("local_service_failed", p2pReason(reason), reason)
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
                    result.error("service_request_failed", p2pReason(reason), reason)
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
                    result.error("service_discovery_failed", p2pReason(reason), reason)
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
            "已找到 $count 個 Wi‑Fi Direct app peer，可直接連接。"
        } else {
            "未找到已開啟本 app 的 Wi‑Fi Direct peer。請確認對方也開啟本 app 並按權限。"
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
            result.error("bad_peer", "缺少 Wi-Fi Direct deviceAddress。", null)
            return
        }
        if (!hasCoreWifiPermission()) {
            requestRuntimePermissions()
            result.error("permission_missing", "需要 Wi-Fi Direct 權限後才可連接。", permissionSnapshot())
            return
        }

        val config = WifiP2pConfig().apply {
            this.deviceAddress = deviceAddress
            wps.setup = WpsInfo.PBC
            groupOwnerIntent = 7
        }

        @SuppressLint("MissingPermission")
        manager.connect(
            channel,
            config,
            object : ActionListener {
                override fun onSuccess() {
                    mainHandler.postDelayed({
                        requestConnectionInfo()
                        requestGroupInfo()
                    }, 1200)
                    result.success(status())
                }

                override fun onFailure(reason: Int) {
                    result.error("connect_failed", p2pReason(reason), reason)
                }
            }
        )
    }

    @SuppressLint("MissingPermission")
    private fun scanWifi(result: MethodChannel.Result) {
        if (!hasCoreWifiPermission()) {
            requestRuntimePermissions()
            result.error("permission_missing", "需要 Wi-Fi 掃描權限後才可列出附近 Wi-Fi。", permissionSnapshot())
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

        @SuppressLint("MissingPermission")
        manager.createGroup(
            channel,
            object : ActionListener {
                override fun onSuccess() {
                    mainHandler.postDelayed({ requestGroupInfo() }, 1200)
                    result.success(status())
                }

                override fun onFailure(reason: Int) {
                    result.error("create_group_failed", p2pReason(reason), reason)
                }
            }
        )
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
                    result.success(status())
                }

                override fun onFailure(reason: Int) {
                    result.error("remove_group_failed", p2pReason(reason), reason)
                }
            }
        )
    }

    @SuppressLint("MissingPermission")
    private fun requestConnectionInfo() {
        val manager = p2pManager ?: return
        val channel = p2pChannel ?: return
        if (!hasCoreWifiPermission()) return

        manager.requestConnectionInfo(
            channel,
            ConnectionInfoListener { info: WifiP2pInfo ->
                currentConnection = mapOf(
                    "groupFormed" to info.groupFormed,
                    "isGroupOwner" to info.isGroupOwner,
                    "groupOwnerAddress" to info.groupOwnerAddress?.hostAddress
                )
            }
        )
    }

    @SuppressLint("MissingPermission")
    private fun requestGroupInfo() {
        val manager = p2pManager ?: return
        val channel = p2pChannel ?: return
        if (!hasCoreWifiPermission()) return

        manager.requestGroupInfo(
            channel,
            GroupInfoListener { group: WifiP2pGroup? ->
                currentGroup = group?.toMap()
            }
        )
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
            permissions += Manifest.permission.NEARBY_WIFI_DEVICES
        } else {
            permissions += Manifest.permission.ACCESS_FINE_LOCATION
        }
        return permissions.all { permission ->
            hasPermission(permission)
        }
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
