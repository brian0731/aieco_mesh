# 傳播光 (LightMesh)

傳播光 LightMesh 是一個免費的線上或離線光之網絡防災、分享物資與定位工具。

WEB
https://www.aieco.hk/community/lifebuoy

IOS
https://apps.apple.com/us/app/%E5%82%B3%E6%92%AD%E5%85%89-lightmesh/id6781610489

Android
https://play.google.com/store/apps/details?id=aieco.light.mesh

線上模式可透過 WebSocket relay 讓用戶入 APP 即可聊天，不需要連同一個 WiFi；沒有外網時，用戶仍可透過藍芽 Mesh、同一個 WiFi、手機熱點、Wi-Fi Direct group、OpenWrt mesh 或其他已互通的 LAN 進入同一個本地傳播頻道聊天。

## 文件

- [WebSocket Relay 生成提示詞](docs/WEBSOCKET_RELAY_PROMPT.md)：用 Nuxt 4 / Nitro 生成線上聊天 relay server。
- [本機 Dart Relay 範例](tool/aieco_light_relay.dart)：不加依賴的測試 relay，可在開發機直接跑。

## 功能

- 線上光之網絡：透過 `AIECO_ONLINE_RELAY_URL` WebSocket relay 傳送聊天、光團、物資、信用和定位 packet。
- 離線 LAN mesh chat：UDP 自動發現節點，TCP 傳送訊息。
- 藍芽 Mesh：Android 可優先使用藍芽網絡共享（Bluetooth PAN）；iOS 可使用系統 peer-to-peer 搜尋附近光點，訊息沿用 app-layer mesh 多 hop 轉發。
- 多 hop 訊息轉發：收到新訊息後會向其他已知節點再傳播。
- 光之通道：聊天、光團、在線用家、用戶信用、物資分享、物資已取完狀態。
- 光之雷達：定位光點，線上 Google Map 或離線香港地圖顯示附近光點。
- SOS：手機閃光燈持續閃出 SOS 燈號，同時在在線用家和光之雷達顯示求救光點。
- Android Wi-Fi Direct：掃描 P2P 裝置、連接 peer、建立或移除 group。
- Android 本地熱點：使用 LocalOnlyHotspot 建立沒有外網的本地 WiFi。
- Android WiFi 選擇：掃描附近 SSID，Android 10+ 透過系統確認框連接給本 app 使用。
- iOS WiFi LAN peers：使用 Bonjour 掃描同一 WiFi 內已開啟本 app 的用戶，並透過 TCP mesh 同步。
- 顯示本機 IP、P2P group SSID/passphrase、hotspot SSID/passphrase。

## APP 內功能介紹

### 光之網絡

光之網絡負責讓光點互相找到對方。線上模式會連接 WebSocket relay，用戶入 APP 即可聊天，不需要接同一個 WiFi。沒有外網時，可切換離線模式，透過藍芽 Mesh、同一個 WiFi、手機熱點、Wi-Fi Direct group、OpenWrt mesh 或其他已互通的 LAN 進入同一個本地傳播頻道。

- 線上光網：同步聊天、光團、物資、信用、定位和 SOS 狀態。
- 離線 mesh：在 LAN 內自動尋找光點，並以 TCP 傳送訊息。
- 多 hop 轉發：收到新訊息後會向其他已知節點再傳播。
- 無線工具：Android 可掃 P2P、開 Wi-Fi Direct group、開本地熱點、掃附近 WiFi；iOS 可掃同一 WiFi 內的 LAN peer。
- 藍芽模式：Android 偵測並優先使用 Bluetooth PAN 網絡；iOS 透過系統 peer-to-peer 尋找附近 peer。
- 自動重試：自動發現失敗時，重新掃描同一 WiFi / Wi-Fi Direct / 熱點網絡。

### 光之通道

光之通道是主要聊天和協作區，用來在不同光團中交換訊息、找人和分享物資。

- 傳播頻道：在目前光團傳送訊息，連線後會自動同步。
- 在線用家：查看已進入 APP 的光點，引用名稱回覆，並為其他光點加信用分。
- 光團：建立或切換主題頻道，讓不同事件、地區或小隊分開溝通。
- 物資分享：發布物資名稱、數量和交收備註；分享者可標記物資已取完。

### 光之雷達

光之雷達用來分享和查看光點位置，協助附近用戶互相找到彼此。

- 定位：讀取手機位置後，把你的光點同步到光之網絡。
- 地圖：線上可使用 Google Map；沒有外網時仍可用香港離線地圖。
- 附近光點：顯示最近光點、距離資訊和求救光點。
- 回覆：可引用光點名稱，返回光之通道聊天。

### SOS

SOS 用於緊急求助，會同時影響手機閃光燈和網絡內的求救狀態。

- SOS 燈：手機閃光燈會持續閃出 SOS 燈號，直到再次按下停止。
- 求救光點：啟動 SOS 後，你會在在線用家和光之雷達中以求救狀態顯示。
- 協助回覆：其他用戶可在雷達找到求救光點，或引用名稱在光之通道回覆。

## 線上模式

線上模式需要一個 WebSocket relay server。APP 會連到 `AIECO_ONLINE_RELAY_URL`，server 只需要驗證 packet 後 broadcast 給其他 WebSocket client。

不要在公開文件寫出 production relay endpoint。開源文件只放 placeholder，實際 URL 請用私下部署文件、CI secret 或本機環境設定管理。

```text
wss://YOUR_RELAY_DOMAIN/ws/light
```

正式公開部署建議使用 TLS：

```text
wss://YOUR_RELAY_DOMAIN/ws/light
```

生成 Nuxt / Nitro relay server 的完整提示詞在 [docs/WEBSOCKET_RELAY_PROMPT.md](docs/WEBSOCKET_RELAY_PROMPT.md)。

## 離線模式 Port

- TCP chat：`47888`
- UDP discovery：`47889`

## Android 使用流程

1. 開啟 app，按「權限」允許 WiFi / nearby devices 權限。
2. 按「啟動節點」，讓 TCP/UDP chat service 開始監聽。
3. 可選其中一種接入方式：
   - 同一 WiFi / router / OpenWrt mesh：直接等待自動發現，或重新掃描附近 app peer。
   - Wi-Fi Direct：按「掃 P2P」，選 peer 連接；或按「開群組」由本機做 group owner。
   - 本地熱點：按「開熱點」，其他手機在系統 WiFi 清單連入顯示的 SSID。
   - 附近 WiFi：按「掃附近 WiFi」，輸入密碼後選 SSID 連接。
4. 連入同一網段後，在「傳播頻道」輸入訊息。

## iOS 使用流程

1. 開啟 app，按「權限」並允許本地網絡。
2. 確認兩部 iPhone 已連到同一 WiFi。
3. 按「掃 LAN」或「掃 LAN 並連接」，選到 peer 後會用 TCP mesh 同步。
4. 在「傳播頻道」輸入訊息。

## 藍芽 Mesh 使用流程

### Android

1. 在「光之網絡」選擇「藍芽」模式，按「權限」允許附近裝置 / 藍芽權限。
2. 先在系統中配對裝置，再按「藍芽熱點」開啟藍芽網絡共享。
3. 返回 APP 後按「藍芽刷新」；偵測到 Bluetooth PAN 網絡後，離線聊天會優先經該網絡傳送。

### iOS

1. 確認兩部 iPhone 已開啟藍芽，並允許 APP 使用本地網絡。
2. 在「光之網絡」選擇「藍芽」模式，再按「藍芽刷新」。
3. APP 會使用 iOS 系統 peer-to-peer 搜尋附近光點，找到 peer 後即可在「傳播頻道」聊天。

> 注意：這裡的「藍芽 Mesh」是由 APP 在可用的藍芽網絡 / 系統 peer-to-peer 連線上執行訊息發現與多 hop 轉發，不是 Bluetooth SIG 標準的 Bluetooth Mesh Profile。

## 重要限制

普通 Android / iOS app 不能穩定做完整系統級 L2 bridge/router。也就是說，手機通常不能保證同時「接上一個 WiFi」又「開下一個 WiFi 熱點」並把兩邊橋接成同一個大內聯網。

傳播光目前採用 app-layer mesh：只要 app 可透過 IP 連到其他節點，就會轉發聊天訊息。這可以支援多 hop 傳播，但不是 root router、不是 BATMAN-adv，也不是 802.11s bridge。

要做到多公里穩定大內聯網，建議底層使用：

- OpenWrt router / outdoor AP
- 802.11s mesh
- BATMAN-adv
- 定向天線或中繼節點

手機 app 作為聊天和節點控制介面，連到最近的「傳播光節點」即可。

## 建置

```powershell
flutter analyze
flutter test
flutter build apk --debug
```

開發測試可先跑本機 relay：

```powershell
dart run tool/aieco_light_relay.dart --port 47890
```

Release APK：

```powershell
flutter build apk --release --dart-define=AIECO_ONLINE_RELAY_URL=wss://YOUR_RELAY_DOMAIN/ws/light
```

Google Map key 可一起帶入：

```powershell
flutter build apk --release --dart-define=GOOGLE_MAPS_API_KEY=你的_KEY --dart-define=AIECO_ONLINE_RELAY_URL=wss://YOUR_RELAY_DOMAIN/ws/light
```

Debug APK 會輸出到：

```text
build\app\outputs\flutter-apk\app-debug.apk
```

## iOS GitHub Actions 上架

已加入 GitHub Actions workflow：`.github/workflows/ios-app-store.yml`。設定 Apple 簽署和 App Store Connect secrets 後，可用 `macos-latest` 自動編譯、簽署 IPA 並上傳到 App Store Connect。

設定方式見 [docs/IOS_APP_STORE_GITHUB_ACTIONS.md](docs/IOS_APP_STORE_GITHUB_ACTIONS.md)。
