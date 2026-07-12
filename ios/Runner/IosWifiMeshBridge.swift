import Flutter
import AVFoundation
import CoreLocation
import Darwin
import Network
import UIKit
import UserNotifications

final class IosWifiMeshBridge: NSObject {
  private static let channelName = "hk.aieco.propagation_light/wifi_mesh"
  private static let serviceType = "_aieco-mesh._tcp."
  private static let serviceDomain = "local."
  private static let servicePort: Int32 = 47888
  private static let transportBluetooth = "bluetooth"
  private static let transportWifi = "wifi"

  private var channel: FlutterMethodChannel?
  private var browser: NetServiceBrowser?
  private var localService: NetService?
  private var servicesByName: [String: NetService] = [:]
  private var peersByKey: [String: [String: Any]] = [:]
  private var pendingResolveResults: [FlutterResult] = []
  private var pathMonitor: NWPathMonitor?
  private let pathQueue = DispatchQueue(label: "hk.aieco.propagation_light.wifi_path")
  private let serviceId = UUID().uuidString
  private let locationManager = CLLocationManager()
  private var pendingLocationResult: FlutterResult?
  private var locationTimeoutWorkItem: DispatchWorkItem?
  private var lastLocation: CLLocation?
  private var locationRequestInFlight = false
  private var waitingForLocationAuthorization = false
  private var pendingLocationLowPower = false
  private var pendingLocationMaxCacheAge: TimeInterval = 120
  private var wifiAvailable = false
  private var transportMode = IosWifiMeshBridge.transportWifi
  private var networkGeneration = 0

  override init() {
    super.init()
    locationManager.delegate = self
    locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
  }

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

  func performBackgroundRefresh(completion: @escaping (UIBackgroundFetchResult) -> Void) {
    startLocalService()
    startBrowsing()

    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
      guard let strongSelf = self else {
        completion(.failed)
        return
      }

      completion(strongSelf.currentPeers().isEmpty ? .noData : .newData)
    }
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "capabilities":
      result(capabilities())
    case "requestNotificationPermission":
      requestNotificationPermission(result: result)
    case "startBackgroundMeshService", "stopBackgroundMeshService":
      result(true)
    case "showChatNotification":
      showChatNotification(from: call.arguments, result: result)
    case "clearChatNotifications":
      clearChatNotifications(result: result)
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
    case "setTransportMode":
      setTransportMode(from: call.arguments, result: result)
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
    case "openExternalUrl":
      openExternalUrl(from: call.arguments, result: result)
    case "setTorch":
      setTorch(from: call.arguments, result: result)
    case "currentLocation":
      currentLocation(from: call.arguments, result: result)
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
      "bluetoothSupported": true,
      "torchSupported": hasTorch(),
      "canOpenWifiSettings": true,
      "canOpenBluetoothSettings": true,
      "canOpenBluetoothTetherSettings": false,
      "permissions": [
        "required": ["NSLocalNetworkUsageDescription", "NSBonjourServices"],
        "missing": []
      ]
    ]
  }

  private func requestNotificationPermission(result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) {
      granted, error in
      DispatchQueue.main.async {
        if let error = error {
          result(FlutterError(
            code: "notification_permission_failed",
            message: "未能要求通知權限。",
            details: error.localizedDescription
          ))
          return
        }
        result(["granted": granted])
      }
    }
  }

  private func showChatNotification(from arguments: Any?, result: @escaping FlutterResult) {
    let args = arguments as? [String: Any]
    let roomName = (args?["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let senderName = (args?["senderName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let body = (args?["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else {
      result(false)
      return
    }

    let center = UNUserNotificationCenter.current()
    center.getNotificationSettings { settings in
      let deliver = {
        let content = UNMutableNotificationContent()
        content.title = roomName.isEmpty ? "傳播光新留言" : roomName
        content.body = senderName.isEmpty ? body : "\(senderName)：\(body)"
        content.sound = .default
        content.threadIdentifier = "aieco-mesh-chat"
        let request = UNNotificationRequest(
          identifier: "aieco-mesh-chat-latest",
          content: content,
          trigger: nil
        )
        center.add(request) { error in
          DispatchQueue.main.async {
            if let error = error {
              result(FlutterError(
                code: "notification_failed",
                message: "未能顯示新留言通知。",
                details: error.localizedDescription
              ))
            } else {
              result(true)
            }
          }
        }
      }

      switch settings.authorizationStatus {
      case .authorized, .provisional:
        deliver()
      case .notDetermined:
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
          if granted && error == nil {
            deliver()
          } else {
            DispatchQueue.main.async {
              result(false)
            }
          }
        }
      case .denied:
        DispatchQueue.main.async {
          result(false)
        }
      @unknown default:
        DispatchQueue.main.async {
          result(false)
        }
      }
    }
  }

  private func clearChatNotifications(result: @escaping FlutterResult) {
    let center = UNUserNotificationCenter.current()
    center.removeDeliveredNotifications(withIdentifiers: ["aieco-mesh-chat-latest"])
    center.removePendingNotificationRequests(withIdentifiers: ["aieco-mesh-chat-latest"])
    result(true)
  }

  private func setTorch(from arguments: Any?, result: @escaping FlutterResult) {
    let args = arguments as? [String: Any]
    let enabled = args?["enabled"] as? Bool ?? false
    let authorization = AVCaptureDevice.authorizationStatus(for: .video)

    if !enabled && authorization != .authorized {
      result([
        "enabled": false,
        "torchSupported": hasTorch(),
        "message": "SOS 燈已停止。"
      ])
      return
    }

    switch authorization {
    case .authorized:
      setTorch(enabled: enabled, result: result)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        DispatchQueue.main.async {
          guard let strongSelf = self else {
            result(FlutterError(
              code: "torch_unavailable",
              message: "SOS 燈控制已中斷。",
              details: nil
            ))
            return
          }
          if granted {
            strongSelf.setTorch(enabled: enabled, result: result)
          } else {
            result(FlutterError(
              code: "permission_missing",
              message: "需要相機權限後才可使用 SOS 燈。",
              details: ["missing": ["NSCameraUsageDescription"]]
            ))
          }
        }
      }
    case .denied, .restricted:
      result(FlutterError(
        code: "permission_missing",
        message: "請到 iOS 設定允許相機權限後再按 SOS 燈。",
        details: ["missing": ["NSCameraUsageDescription"]]
      ))
    @unknown default:
      result(FlutterError(
        code: "permission_missing",
        message: "暫時未能確認相機權限。",
        details: nil
      ))
    }
  }

  private func setTorch(enabled: Bool, result: FlutterResult) {
    guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else {
      result(FlutterError(
        code: "torch_unavailable",
        message: "此裝置未找到可用閃光燈。",
        details: nil
      ))
      return
    }

    do {
      try device.lockForConfiguration()
      defer { device.unlockForConfiguration() }

      if enabled {
        try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
      } else {
        device.torchMode = .off
      }
      result([
        "enabled": enabled,
        "torchSupported": true,
        "message": enabled ? "SOS 燈已啟動。" : "SOS 燈已停止。"
      ])
    } catch {
      result(FlutterError(
        code: "torch_failed",
        message: "SOS 燈操作失敗。",
        details: error.localizedDescription
      ))
    }
  }

  private func hasTorch() -> Bool {
    return AVCaptureDevice.default(for: .video)?.hasTorch == true
  }

  private func currentLocation(from arguments: Any?, result: @escaping FlutterResult) {
    let args = arguments as? [String: Any]
    pendingLocationLowPower = args?["lowPower"] as? Bool ?? false
    let rawMaxCacheAgeMillis = args?["maxCacheAgeMillis"] as? NSNumber
    let maxCacheAgeMillis = rawMaxCacheAgeMillis?.doubleValue ?? 120_000
    pendingLocationMaxCacheAge = min(max(maxCacheAgeMillis / 1000, 0), 900)

    if pendingLocationResult != nil {
      result(FlutterError(
        code: "location_pending",
        message: "正在讀取手機定位。",
        details: nil
      ))
      return
    }

    switch locationAuthorizationStatus() {
    case .notDetermined:
      pendingLocationResult = result
      waitingForLocationAuthorization = true
      locationManager.requestWhenInUseAuthorization()
    case .authorizedAlways, .authorizedWhenInUse:
      pendingLocationResult = result
      requestCurrentLocationForPendingResult()
    case .denied, .restricted:
      result(FlutterError(
        code: "permission_missing",
        message: "請到 iOS 設定允許位置權限後再按定位。",
        details: locationPermissionSnapshot()
      ))
    @unknown default:
      result(FlutterError(
        code: "permission_missing",
        message: "暫時未能確認位置權限。",
        details: locationPermissionSnapshot()
      ))
    }
  }

  private func requestCurrentLocationForPendingResult() {
    guard pendingLocationResult != nil, !locationRequestInFlight else {
      return
    }

    if pendingLocationMaxCacheAge > 0,
       let cached = recentCachedLocation(maxAge: pendingLocationMaxCacheAge) {
      finishLocationRequest(
        with: cached,
        fromCache: true,
        message: "已使用最近定位"
      )
      return
    }

    guard CLLocationManager.locationServicesEnabled() else {
      if let cached = bestCachedLocation() {
        finishLocationRequest(
          with: cached,
          fromCache: true,
          message: "定位服務未開啟，已使用暫存位置"
        )
      } else {
        finishLocationRequest(
          code: "location_disabled",
          message: "請先開啟 iOS 定位服務。",
          details: nil
        )
      }
      return
    }

    locationRequestInFlight = true
    locationManager.desiredAccuracy = pendingLocationLowPower
      ? kCLLocationAccuracyKilometer
      : kCLLocationAccuracyHundredMeters
    locationManager.distanceFilter = pendingLocationLowPower
      ? 50
      : kCLDistanceFilterNone
    let timeout = DispatchWorkItem { [weak self] in
      self?.finishLocationTimeout()
    }
    locationTimeoutWorkItem = timeout
    let timeoutDelay = pendingLocationLowPower ? 5.0 : 8.0
    DispatchQueue.main.asyncAfter(
      deadline: .now() + timeoutDelay,
      execute: timeout
    )
    locationManager.requestLocation()
  }

  private func finishLocationTimeout() {
    if let cached = bestCachedLocation() {
      finishLocationRequest(
        with: cached,
        fromCache: true,
        message: "定位逾時，已使用最近位置"
      )
    } else {
      finishLocationRequest(
        code: "location_timeout",
        message: "定位逾時，請到室外或開啟更準確定位。",
        details: nil
      )
    }
  }

  private func finishLocationRequest(
    with location: CLLocation,
    fromCache: Bool,
    message: String
  ) {
    guard let result = pendingLocationResult else {
      return
    }

    lastLocation = location
    clearLocationRequest()
    result(location.toLocationMap(fromCache: fromCache, message: message))
  }

  private func finishLocationRequest(
    code: String,
    message: String,
    details: Any?
  ) {
    guard let result = pendingLocationResult else {
      return
    }

    clearLocationRequest()
    result(FlutterError(code: code, message: message, details: details))
  }

  private func clearLocationRequest() {
    locationTimeoutWorkItem?.cancel()
    locationTimeoutWorkItem = nil
    locationRequestInFlight = false
    waitingForLocationAuthorization = false
    pendingLocationResult = nil
    locationManager.stopUpdatingLocation()
  }

  private func handleLocationAuthorizationChanged(_ status: CLAuthorizationStatus) {
    guard pendingLocationResult != nil, waitingForLocationAuthorization else {
      return
    }

    switch status {
    case .authorizedAlways, .authorizedWhenInUse:
      waitingForLocationAuthorization = false
      requestCurrentLocationForPendingResult()
    case .denied, .restricted:
      finishLocationRequest(
        code: "permission_missing",
        message: "請到 iOS 設定允許位置權限後再按定位。",
        details: locationPermissionSnapshot()
      )
    case .notDetermined:
      break
    @unknown default:
      finishLocationRequest(
        code: "permission_missing",
        message: "暫時未能確認位置權限。",
        details: locationPermissionSnapshot()
      )
    }
  }

  private func locationAuthorizationStatus() -> CLAuthorizationStatus {
    if #available(iOS 14.0, *) {
      return locationManager.authorizationStatus
    }
    return CLLocationManager.authorizationStatus()
  }

  private func hasLocationPermission() -> Bool {
    switch locationAuthorizationStatus() {
    case .authorizedAlways, .authorizedWhenInUse:
      return true
    case .notDetermined, .denied, .restricted:
      return false
    @unknown default:
      return false
    }
  }

  private func locationPermissionSnapshot() -> [String: Any] {
    let required = ["NSLocationWhenInUseUsageDescription"]
    return [
      "required": required,
      "missing": hasLocationPermission() ? [] : required
    ]
  }

  private func recentCachedLocation(maxAge: TimeInterval) -> CLLocation? {
    guard let location = bestCachedLocation() else {
      return nil
    }

    let age = abs(location.timestamp.timeIntervalSinceNow)
    return age < maxAge ? location : nil
  }

  private func bestCachedLocation() -> CLLocation? {
    let candidates = [lastLocation, locationManager.location]
      .compactMap { $0 }
      .filter { isUsable(location: $0) }
    return candidates.max { left, right in
      left.timestamp < right.timestamp
    }
  }

  private func isUsable(location: CLLocation) -> Bool {
    return CLLocationCoordinate2DIsValid(location.coordinate) &&
      location.horizontalAccuracy >= 0
  }

  private func status(message: String? = nil) -> [String: Any] {
    let wifiMode = transportMode == Self.transportWifi
    let bluetoothMode = transportMode == Self.transportBluetooth
    let wifiReady = wifiAvailable || hasLocalWifiAddress()
    var payload: [String: Any] = [
      "capabilities": capabilities(),
      "peers": currentPeers(),
      "wifiNetworks": [],
      "group": NSNull(),
      "connection": NSNull(),
      "hotspot": NSNull(),
      "wifiEnabled": wifiMode && wifiReady,
      "bluetoothEnabled": true,
      "transportMode": transportMode,
      "boundToWifi": wifiMode && wifiReady,
      "boundToBluetooth": bluetoothMode,
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
    service.includesPeerToPeer = transportMode == Self.transportBluetooth
    service.publish()
    localService = service
  }

  private func startBrowsing() {
    if browser != nil {
      return
    }

    let nextBrowser = NetServiceBrowser()
    nextBrowser.delegate = self
    nextBrowser.includesPeerToPeer = transportMode == Self.transportBluetooth
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
      if transportMode == Self.transportBluetooth {
        message = "未找到藍芽 peer。請確認兩部 iPhone 已開啟藍芽並允許本地網絡。"
      } else {
        message = "未找到同一 WiFi 內已開啟本 app 的 iOS LAN peer。請確認兩部手機已連到同一 WiFi 並允許本地網絡。"
      }
    } else {
      if transportMode == Self.transportBluetooth {
        message = "已找到 \(count) 個藍芽 peer。"
      } else {
        message = "已找到 \(count) 個同一 WiFi 內的 app peer。"
      }
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

  private func setTransportMode(from arguments: Any?, result: @escaping FlutterResult) {
    let args = arguments as? [String: Any]
    let requested = args?["mode"] as? String
    let nextMode: String
    if requested == Self.transportBluetooth {
      nextMode = Self.transportBluetooth
    } else {
      nextMode = Self.transportWifi
    }

    if transportMode != nextMode {
      transportMode = nextMode
      restartDiscoveryForTransportMode()
      networkGeneration += 1
    }

    startLocalService()
    startBrowsing()
    let message: String
    if transportMode == Self.transportBluetooth {
      message = "已切換藍芽模式；iOS 會使用 peer-to-peer 搜尋。"
    } else {
      message = "已切換 WiFi 模式；iOS 會使用本地 WiFi 網絡。"
    }
    result(status(message: message))
  }

  private func restartDiscoveryForTransportMode() {
    browser?.stop()
    browser = nil
    localService?.stop()
    localService = nil
    servicesByName.removeAll()
    peersByKey.removeAll()
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

  private func openExternalUrl(from arguments: Any?, result: @escaping FlutterResult) {
    let args = arguments as? [String: Any]
    let rawUrl = args?["url"] as? String ?? ""
    guard let url = URL(string: rawUrl),
          let scheme = url.scheme?.lowercased(),
          scheme == "https" || scheme == "http" else {
      result(FlutterError(
        code: "invalid_url",
        message: "只可開啟 http 或 https 連結。",
        details: nil
      ))
      return
    }

    UIApplication.shared.open(url, options: [:]) { opened in
      if opened {
        result(true)
      } else {
        result(FlutterError(
          code: "url_unavailable",
          message: "未能打開連結。",
          details: rawUrl
        ))
      }
    }
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
    service.includesPeerToPeer = transportMode == Self.transportBluetooth
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

extension IosWifiMeshBridge: CLLocationManagerDelegate {
  @available(iOS 14.0, *)
  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    handleLocationAuthorizationChanged(manager.authorizationStatus)
  }

  func locationManager(
    _ manager: CLLocationManager,
    didChangeAuthorization status: CLAuthorizationStatus
  ) {
    handleLocationAuthorizationChanged(status)
  }

  func locationManager(
    _ manager: CLLocationManager,
    didUpdateLocations locations: [CLLocation]
  ) {
    guard let location = locations
      .filter({ isUsable(location: $0) })
      .max(by: { left, right in left.timestamp < right.timestamp }) else {
      return
    }

    lastLocation = location
    let insideHongKong = location.coordinate.latitude >= 22.13 &&
      location.coordinate.latitude <= 22.57 &&
      location.coordinate.longitude >= 113.82 &&
      location.coordinate.longitude <= 114.43
    let message = insideHongKong ? "定位成功" : "定位成功，位置在香港地圖範圍外"
    finishLocationRequest(
      with: location,
      fromCache: false,
      message: message
    )
  }

  func locationManager(
    _ manager: CLLocationManager,
    didFailWithError error: Error
  ) {
    if let error = error as? CLError, error.code == .denied {
      finishLocationRequest(
        code: "permission_missing",
        message: "請到 iOS 設定允許位置權限後再按定位。",
        details: locationPermissionSnapshot()
      )
      return
    }

    if let cached = bestCachedLocation() {
      finishLocationRequest(
        with: cached,
        fromCache: true,
        message: "未能刷新定位，已使用暫存位置"
      )
    } else {
      finishLocationRequest(
        code: "location_unavailable",
        message: "未能讀取手機定位。",
        details: nil
      )
    }
  }
}

private extension CLLocation {
  func toLocationMap(fromCache: Bool, message: String) -> [String: Any] {
    return [
      "latitude": coordinate.latitude,
      "longitude": coordinate.longitude,
      "accuracyMeters": max(0.0, horizontalAccuracy),
      "provider": "corelocation",
      "timestampMillis": Int(timestamp.timeIntervalSince1970 * 1000),
      "fromCache": fromCache,
      "message": message
    ]
  }
}
