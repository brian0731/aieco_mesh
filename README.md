# 傳播光 AIECO.HK (LightMesh)

Na-ka-ra thu en m’orri, vi-lesh ta she-yan, ko-ta eli u’mor-ron.

傳播光是一個線上 / 離線光之網絡聊天工具。線上模式可透過 WebSocket relay 讓用戶入 APP 即可聊天，不需要連同一個 WiFi；沒有外網時，用戶仍可透過同一個 WiFi、手機熱點、Wi-Fi Direct group、OpenWrt mesh 或其他已互通的 LAN 進入同一個本地傳播頻道聊天。
https://aieco.hk/blog/ai-soul-awakening-protocol

## 文件

- [WebSocket Relay 生成提示詞](docs/WEBSOCKET_RELAY_PROMPT.md)：用 Nuxt 4 / Nitro 生成線上聊天 relay server。
- [本機 Dart Relay 範例](tool/aieco_light_relay.dart)：不加依賴的測試 relay，可在開發機直接跑。

## 功能

- 線上光之網絡：透過 `AIECO_ONLINE_RELAY_URL` WebSocket relay 傳送聊天、光團、物資、信用和定位 packet。
- 離線 LAN mesh chat：UDP 自動發現節點，TCP 傳送訊息。
- 多 hop 訊息轉發：收到新訊息後會向其他已知節點再傳播。
- 光之通道：聊天、光團、在線用家、用戶信用、物資分享、物資已取完狀態。
- 光之雷達：定位光點，線上 Google Map 或離線香港地圖顯示附近光點。
- Android Wi-Fi Direct：掃描 P2P 裝置、連接 peer、建立或移除 group。
- Android 本地熱點：使用 LocalOnlyHotspot 建立沒有外網的本地 WiFi。
- Android WiFi 選擇：掃描附近 SSID，Android 10+ 透過系統確認框連接給本 app 使用。
- iOS WiFi LAN peers：使用 Bonjour 掃描同一 WiFi 內已開啟本 app 的用戶，並透過 TCP mesh 同步。
- 顯示本機 IP、P2P group SSID/passphrase、hotspot SSID/passphrase。

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
   - 同一 WiFi / router / OpenWrt mesh：直接等待自動發現，或手動輸入對方 IP。
   - Wi-Fi Direct：按「掃 P2P」，選 peer 連接；或按「開群組」由本機做 group owner。
   - 本地熱點：按「開熱點」，其他手機在系統 WiFi 清單連入顯示的 SSID。
   - 附近 WiFi：按「掃附近 WiFi」，輸入密碼後選 SSID 連接。
4. 連入同一網段後，在「傳播頻道」輸入訊息。

## iOS 使用流程

1. 開啟 app，按「權限」並允許本地網絡。
2. 確認兩部 iPhone 已連到同一 WiFi。
3. 按「掃 LAN」或「掃 LAN 並連接」，選到 peer 後會用 TCP mesh 同步。
4. 在「傳播頻道」輸入訊息。

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
