import Flutter
import Darwin
import Network
import UIKit

final class IosWifiMeshBridge: NSObject {
  private static let channelName = "hk.aieco.propagation_light/wifi_mesh"
  private static let serviceType = "_aieco-mesh._tcp."
  private static let serviceDomain = "local."
  private static let servicePort: Int32 = 47888

  private var channel: FlutterMethodChannel?
  private var browser: NetServiceBrowser?
  private var localService: NetService?
  private var servicesByName: [String: NetService] = [:]
  private var peersByKey: [String: [String: Any]] = [:]
  private var pendingResolveResults: [FlutterResult] = []
  private var pathMonitor: NWPathMonitor?
  private let pathQueue = DispatchQueue(label: "hk.aieco.propagation_light.wifi_path")
  private let serviceId = UUID().uuidString
  private var wifiAvailable = false
  private var networkGeneration = 0

  func register(with messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )
    channel?.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    startPathMonitoring()
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "capabilities":
      result(capabilities())
    case "requestPermissions", "discoverPeers", "discoverAppPeers":
      startLocalService()
      startBrowsing()
      finishAfterDiscovery(result)
    case "getPeers":
      startBrowsing()
      result(currentPeers())
    case "connectPeer":
      startLocalService()
      startBrowsing()
      result(status(message: connectPeerMessage(from: call.arguments)))
    case "scanWifi":
      result(status(message: "iOS 不允許 app 掃描附近 WiFi SSID；請先連到同一 WiFi，再掃 LAN peers。"))
    case "connectWifi":
      result(status(message: "iOS 不允許 app 直接切換 WiFi；請到系統 WiFi 設定連接。"))
    case "createGroup", "startLocalOnlyHotspot":
      result(status(message: "iOS 不支援由 app 建立 Wi-Fi Direct group 或本地熱點。"))
    case "removeGroup", "stopLocalOnlyHotspot", "groupInfo", "status":
      result(status())
    case "openWifiSettings", "openBluetoothSettings", "openBluetoothTetherSettings":
      openSettings()
      result(status(message: "已打開 iOS 設定。"))
    case "openAppSettings":
      openAppSettings()
      result(status(message: "已打開 app 權限設定。"))
    case "currentLocation":
      result(FlutterMethodNotImplemented)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func capabilities() -> [String: Any] {
    return [
      "platform": "ios",
      "wifiDirectSupported": false,
      "wifiPeerSupported": true,
      "localOnlyHotspotSupported": false,
      "bluetoothSupported": false,
      "canOpenWifiSettings": true,
      "canOpenBluetoothSettings": true,
      "canOpenBluetoothTetherSettings": false,
      "permissions": [
        "required": ["NSLocalNetworkUsageDescription", "NSBonjourServices"],
        "missing": []
      ]
    ]
  }

  private func status(message: String? = nil) -> [String: Any] {
    var payload: [String: Any] = [
      "capabilities": capabilities(),
      "peers": currentPeers(),
      "wifiNetworks": [],
      "group": NSNull(),
      "connection": NSNull(),
      "hotspot": NSNull(),
      "wifiEnabled": wifiAvailable || hasLocalWifiAddress(),
      "bluetoothEnabled": false,
      "boundToWifi": wifiAvailable || hasLocalWifiAddress(),
      "boundToBluetooth": false,
      "networkGeneration": networkGeneration
    ]
    if let message = message {
      payload["message"] = message
    }
    return payload
  }

  private func currentPeers() -> [[String: Any]] {
    return peersByKey.values.sorted {
      let left = $0["deviceName"] as? String ?? ""
      let right = $1["deviceName"] as? String ?? ""
      return left < right
    }
  }

  private func startLocalService() {
    if localService != nil {
      return
    }

    let serviceName = "AIECO \(UIDevice.current.name) \(String(serviceId.prefix(6)))"
    let service = NetService(
      domain: Self.serviceDomain,
      type: Self.serviceType,
      name: serviceName,
      port: Self.servicePort
    )
    let txt = NetService.data(fromTXTRecord: [
      "app": Data("aieco_mesh".utf8),
      "id": Data(serviceId.utf8),
      "name": Data("傳播光".utf8)
    ])
    service.setTXTRecord(txt)
    service.delegate = self
    service.includesPeerToPeer = true
    service.publish()
    localService = service
  }

  private func startBrowsing() {
    if browser != nil {
      return
    }

    let nextBrowser = NetServiceBrowser()
    nextBrowser.delegate = self
    nextBrowser.includesPeerToPeer = true
    nextBrowser.searchForServices(
      ofType: Self.serviceType,
      inDomain: Self.serviceDomain
    )
    browser = nextBrowser
  }

  private func finishAfterDiscovery(_ result: @escaping FlutterResult) {
    pendingResolveResults.append(result)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
      guard let strongSelf = self else { return }
      strongSelf.flushPendingResolveResults()
    }
  }

  private func flushPendingResolveResults() {
    guard !pendingResolveResults.isEmpty else {
      return
    }

    let message: String
    let count = peersByKey.count
    if count == 0 {
      message = "未找到同一 WiFi 內已開啟本 app 的 iOS LAN peer。請確認兩部手機已連到同一 WiFi 並允許本地網絡。"
    } else {
      message = "已找到 \(count) 個同一 WiFi 內的 app peer。"
    }
    let payload = status(message: message)
    let results = pendingResolveResults
    pendingResolveResults.removeAll()
    results.forEach { $0(payload) }
  }

  private func connectPeerMessage(from arguments: Any?) -> String {
    let args = arguments as? [String: Any]
    let address = args?["deviceAddress"] as? String ?? ""
    guard !address.isEmpty else {
      return "缺少 iOS LAN peer 位址。"
    }

    if let peer = peersByKey[address] {
      let host = peer["host"] as? String ?? address
      let port = peer["port"] as? Int ?? Int(Self.servicePort)
      return "已選取 iOS LAN peer：\(host):\(port)。傳播光會用 TCP mesh 同步。"
    }
    return "已選取 iOS LAN peer。傳播光會嘗試用 TCP mesh 同步。"
  }

  private func openSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else {
      return
    }
    UIApplication.shared.open(url)
  }

  private func openAppSettings() {
    openSettings()
  }

  private func startPathMonitoring() {
    if pathMonitor != nil {
      return
    }

    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      let nextWifiAvailable = path.status == .satisfied && path.usesInterfaceType(.wifi)
      DispatchQueue.main.async {
        guard let strongSelf = self else { return }
        if strongSelf.wifiAvailable != nextWifiAvailable {
          strongSelf.wifiAvailable = nextWifiAvailable
          strongSelf.networkGeneration += 1
        }
      }
    }
    monitor.start(queue: pathQueue)
    pathMonitor = monitor
  }

  private func hasLocalWifiAddress() -> Bool {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let first = interfaces else {
      return false
    }
    defer { freeifaddrs(interfaces) }

    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let current = cursor {
      defer { cursor = current.pointee.ifa_next }
      let flags = Int32(current.pointee.ifa_flags)
      let isUp = (flags & IFF_UP) == IFF_UP
      let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK
      guard isUp, !isLoopback, let address = current.pointee.ifa_addr else {
        continue
      }
      if address.pointee.sa_family == UInt8(AF_INET),
         String(cString: current.pointee.ifa_name) == "en0" {
        return true
      }
    }
    return false
  }

  private func remember(service: NetService) {
    guard service.port > 0 else {
      return
    }

    let hosts = resolvedHosts(from: service)
    guard let host = hosts.first else {
      return
    }

    let key = "\(host):\(service.port)"
    peersByKey[key] = [
      "deviceName": service.name.isEmpty ? "iOS LAN peer" : service.name,
      "deviceAddress": key,
      "primaryDeviceType": "ios.local-network",
      "secondaryDeviceType": "",
      "status": 0,
      "statusText": "可連接",
      "isGroupOwner": false,
      "wpsPbcSupported": false,
      "wpsKeypadSupported": false,
      "wpsDisplaySupported": false,
      "serviceDiscoveryCapable": true,
      "isAppPeer": true,
      "serviceName": service.type,
      "host": host,
      "port": service.port
    ]
    networkGeneration += 1
  }

  private func resolvedHosts(from service: NetService) -> [String] {
    return (service.addresses ?? []).compactMap { addressData in
      addressData.withUnsafeBytes { rawBuffer -> String? in
        guard let baseAddress = rawBuffer.baseAddress else {
          return nil
        }
        let sockaddrPointer = baseAddress.assumingMemoryBound(to: sockaddr.self)
        guard sockaddrPointer.pointee.sa_family == UInt8(AF_INET) else {
          return nil
        }

        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
          sockaddrPointer,
          socklen_t(addressData.count),
          &hostBuffer,
          socklen_t(hostBuffer.count),
          nil,
          0,
          NI_NUMERICHOST
        )
        guard result == 0 else {
          return nil
        }
        return String(cString: hostBuffer)
      }
    }
  }
}

extension IosWifiMeshBridge: NetServiceBrowserDelegate {
  func netServiceBrowser(
    _ browser: NetServiceBrowser,
    didFind service: NetService,
    moreComing: Bool
  ) {
    if service.name == localService?.name {
      return
    }
    servicesByName[service.name] = service
    service.delegate = self
    service.includesPeerToPeer = true
    service.resolve(withTimeout: 2.0)
  }

  func netServiceBrowser(
    _ browser: NetServiceBrowser,
    didNotSearch errorDict: [String: NSNumber]
  ) {
    flushPendingResolveResults()
  }

  func netServiceBrowser(
    _ browser: NetServiceBrowser,
    didRemove service: NetService,
    moreComing: Bool
  ) {
    servicesByName.removeValue(forKey: service.name)
    peersByKey = peersByKey.filter { _, peer in
      (peer["deviceName"] as? String) != service.name
    }
    networkGeneration += 1
  }
}

extension IosWifiMeshBridge: NetServiceDelegate {
  func netServiceDidResolveAddress(_ sender: NetService) {
    remember(service: sender)
    flushPendingResolveResults()
  }

  func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
    servicesByName.removeValue(forKey: sender.name)
  }
}
