package aieco.light.mesh

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.net.Inet4Address
import java.util.ArrayDeque
import java.util.UUID

/** Bonjour discovery shared with iOS; Wi-Fi Direct discovery is separate. */
@Suppress("DEPRECATION")
internal class LanPeerDiscovery(context: Context) {
    companion object {
        private const val SERVICE_TYPE = "_aieco-mesh._tcp."
        private const val SERVICE_PORT = 47888
        private const val TAG = "LanPeerDiscovery"
    }

    private val manager = context.getSystemService(Context.NSD_SERVICE) as? NsdManager
    private val handler = Handler(Looper.getMainLooper())
    private val serviceId = UUID.randomUUID().toString()
    private val requestedName = "AIECO Android ${Build.MODEL.take(24)} ${serviceId.take(6)}"
    private var registeredName = requestedName
    private var enabled = false
    private var registration: NsdManager.RegistrationListener? = null
    private var discovery: NsdManager.DiscoveryListener? = null
    private var resolver: NsdManager.ResolveListener? = null
    private val services = linkedMapOf<String, NsdServiceInfo>()
    private val peers = linkedMapOf<String, Map<String, Any?>>()
    private val pending = ArrayDeque<NsdServiceInfo>()
    private val lastResolveAt = mutableMapOf<String, Long>()

    val supported: Boolean get() = manager != null

    fun currentPeers(): List<Map<String, Any?>> = peers.values.sortedBy {
        it["deviceName"] as? String ?: ""
    }

    fun start() {
        val nsd = manager ?: return
        enabled = true
        if (registration == null) registerService(nsd)
        if (discovery == null) discoverServices(nsd)
        services.values.forEach { enqueueResolution(it) }
    }

    fun stop() {
        enabled = false
        val oldDiscovery = discovery
        val oldRegistration = registration
        discovery = null
        registration = null
        services.clear()
        peers.clear()
        pending.clear()
        lastResolveAt.clear()
        if (oldDiscovery != null) runCatching { manager?.stopServiceDiscovery(oldDiscovery) }
        if (oldRegistration != null) runCatching { manager?.unregisterService(oldRegistration) }
        // Keep an in-flight legacy resolver until its callback: older Android
        // versions reject concurrent resolveService requests, even across scans.
    }

    private fun registerService(nsd: NsdManager) {
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                handler.post {
                    if (enabled && registration === this) registeredName = info.serviceName
                }
            }

            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                handler.post {
                    Log.w(TAG, "Registration failed: $errorCode")
                    if (registration === this) registration = null
                }
            }

            override fun onServiceUnregistered(info: NsdServiceInfo) {
                handler.post { if (registration === this) registration = null }
            }

            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "Unregistration failed: $errorCode")
            }
        }
        registration = listener
        val info = NsdServiceInfo().apply {
            serviceName = requestedName
            serviceType = SERVICE_TYPE
            port = SERVICE_PORT
            setAttribute("app", "aieco_mesh")
            setAttribute("id", serviceId)
            setAttribute("name", "AIECO Mesh")
        }
        runCatching { nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener) }
            .onFailure {
                registration = null
                Log.w(TAG, "Cannot register LAN service", it)
            }
    }

    private fun discoverServices(nsd: NsdManager) {
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit

            override fun onServiceFound(info: NsdServiceInfo) {
                handler.post {
                    if (!enabled || discovery !== this ||
                        info.serviceType.trimEnd('.') != SERVICE_TYPE.trimEnd('.') ||
                        info.serviceName == requestedName || info.serviceName == registeredName
                    ) return@post
                    services[info.serviceName] = info
                    enqueueResolution(info)
                }
            }

            override fun onServiceLost(info: NsdServiceInfo) {
                handler.post {
                    if (discovery !== this) return@post
                    services.remove(info.serviceName)
                    peers.remove(info.serviceName)
                    lastResolveAt.remove(info.serviceName)
                }
            }

            override fun onDiscoveryStopped(serviceType: String) {
                handler.post { if (discovery === this) clearDiscovery() }
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                handler.post {
                    Log.w(TAG, "Discovery failed: $errorCode")
                    if (discovery === this) clearDiscovery()
                    runCatching { nsd.stopServiceDiscovery(this) }
                }
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(TAG, "Stopping discovery failed: $errorCode")
            }
        }
        discovery = listener
        runCatching { nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener) }
            .onFailure {
                clearDiscovery()
                Log.w(TAG, "Cannot discover LAN services", it)
            }
    }

    private fun clearDiscovery() {
        discovery = null
        services.clear()
        peers.clear()
        pending.clear()
        lastResolveAt.clear()
    }

    private fun enqueueResolution(info: NsdServiceInfo) {
        if (peers.containsKey(info.serviceName)) return
        val now = android.os.SystemClock.elapsedRealtime()
        val previous = lastResolveAt[info.serviceName]
        if (previous != null && now - previous < 10_000L) return
        lastResolveAt[info.serviceName] = now
        pending.add(info)
        resolveNext()
    }

    private fun resolveNext() {
        val nsd = manager ?: return
        if (!enabled || resolver != null) return
        val info = pending.poll() ?: return
        if (services[info.serviceName] !== info) {
            resolveNext()
            return
        }
        val listener = object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                handler.post {
                    Log.w(TAG, "Resolve failed: $errorCode")
                    if (resolver === this) resolver = null
                    resolveNext()
                }
            }

            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                handler.post {
                    if (enabled && services[info.serviceName] === info) rememberPeer(serviceInfo)
                    if (resolver === this) resolver = null
                    resolveNext()
                }
            }
        }
        resolver = listener
        runCatching { nsd.resolveService(info, listener) }.onFailure {
            resolver = null
            Log.w(TAG, "Cannot resolve LAN service", it)
            resolveNext()
        }
    }

    private fun rememberPeer(info: NsdServiceInfo) {
        if (info.attributes["id"]?.toString(Charsets.UTF_8) == serviceId) return
        val address = if (Build.VERSION.SDK_INT >= 34) {
            info.hostAddresses.filterIsInstance<Inet4Address>().firstOrNull()
        } else {
            info.host as? Inet4Address
        }
        val host = address?.hostAddress ?: return
        if (info.port !in 1..65535) return
        peers[info.serviceName] = mapOf(
            "deviceName" to info.serviceName,
            "deviceAddress" to "$host:${info.port}",
            "status" to 3,
            "statusText" to "可連接",
            "isGroupOwner" to false,
            "isAppPeer" to true,
            "serviceName" to SERVICE_TYPE,
            "primaryDeviceType" to "lan",
            "host" to host,
            "port" to info.port
        )
    }
}
