# 跨 APP 聊天網絡互通

APP A、B 可以各自連接不同的 WebSocket relay。一位用戶接入另一個網絡後，這部手機會同時連接兩台 relay，將訊息雙向轉發給兩邊所有在線用戶。

首次設定請先閱讀[互連 APP 設置教學](INTERCONNECT_APP_SETUP.md)，按步驟完成伺服器、連接碼、APP 建置及手機接通測試。

## 操作

1. 管理員部署下方的共用配對服務，為 A、B 設定各自的 6 位碼。A、B 各自以自己的 `AIECO_ONLINE_RELAY_URL` 及相同的 `AIECO_NETWORK_DIRECTORY_URL` 建置並連上線上光網。
2. B 開啟「光之網絡 → 連接另一個 光網APP → 複製本網絡連接碼」。
3. B 展開卡片後會顯示本網絡的 6 位數字碼。A 的一位用戶輸入或貼上 B 的 6 位碼，按「接通另一個 APP」。也可以交換 A、B 的角色。
4. 顯示「兩個 APP 的聊天室已互通」後，兩邊用戶即可聊天，不需要每人都輸入連接碼。預設主頻道使用相同的 `room:main`；其他光團依 roomId 同步，同名不同 ID 的光團仍是不同光團。
5. 按「中斷互通」、停止節點或切換離線模式會結束這部手機的轉發。

## 行為與限制

- APP 的連接碼改為 6 位數字字串（保留前置零），由共用配對服務查回 relay 地址。APP 輸入框不再接受舊網址碼。底層橋接類別仍支援 relay URL，供內部使用及相容性測試。
- 不能接入自己的光網：輸入本網絡顯示的連接碼會提示改用另一個 APP 的碼。例如本網絡是 `582193`，這個碼應交給另一個光網的用戶輸入。
- 透過交換連接碼找到另一個網絡，沒有公開伺服器目錄，也不會自動掃描 Internet。實際 production 地址只在 APP 與私下部署設定使用，勿提交到公開文件。
- 兩邊 relay 必須使用相容的原生 WebSocket JSON 廣播協定，保留 packet 欄位；專案內的 Dart relay 無需改動。不相容的聊天室後端需要另外做協定轉換。
- 同步聊天、光團、在線光點、定位、SOS、物資、活動、求助、信用及現有管理封包。這是兩個網絡的資料互通，並非私人單對單聊天。
- 接通時，接入者重新公告自己的光點及最近狀態，觸發現有客戶端的狀態同步。聊天補送沿用每個在線客戶端最多 20 則最近訊息，不保證完整歷史；relay 不儲存離線訊息。
- 使用獨立於正常聊天連線的兩條 WebSocket；中斷互通不會關閉正常聊天。斷線每 5 秒重試，單次握手最多等待 12 秒。
- 封包附加 `_lightBridgePath`，最多經過 8 個橋接點；每個橋接點最多保留 1024 個、2 分鐘內的封包簽章，以抑制多位用戶同時橋接造成的回音。聊天仍使用原有 messageId 去重。
- 僅轉傳已知 `aieco.light.*.v1` 網絡封包，單封包包括轉發標記不得超過 64 KiB。新協定種類須同步更新允許清單。
- 接入者必須維持 APP 執行與網絡連線。手機背景執行被系統暫停、APP 關閉或停止節點時，橋接會停止；其他仍在線的橋接者可繼續轉發。若需要無人持續運行，應另部署常駐的伺服器橋接服務。
- 互通連線不會在重新開啟 APP 後自動恢復，需重新輸入 6 位碼接入；本網絡直接顯示及複製建置時指定的碼，預設為 `582193`，不需查詢配對服務。

## 6 位碼配對服務部署

APP 預設共用服務地址為 `https://www.aieco.hk/api/lightmesh`。對應 Nuxt API 已加入本機網站專案 `C:/xampp2023/htdocs/aiecohk/server/api/lightmesh/`；需將網站更新部署，設定 `LIGHTMESH_NETWORKS_JSON` 並重啟正式程序，才可使用。詳見該網站專案的 `server/LIGHTMESH_DIRECTORY.md`。以下獨立 Dart 服務亦可用作其他部署方式。

配對服務只負責查碼；聊天室訊息仍經過兩邊原有的 WebSocket relay。此 repo 提供可直接執行的 Dart HTTP 服務，管理員分配固定碼，沒有公開註冊或覆寫 API。

1. 將 `tool/network_directory.example.json` 複製到私下部署目錄的 `networks.json`，把 placeholder 換成實際 relay 地址。每個 key 必須是引號包住的 6 位數字字串，每個 relay 只對應一個碼；例如：

   ```json
   {
     "582193": "wss://APP_A_RELAY_DOMAIN/ws/light",
     "704826": "wss://APP_B_RELAY_DOMAIN/ws/light"
   }
   ```

2. 啟動共用服務：

   ```powershell
   dart run tool/aieco_network_directory.dart --config C:/private/lightmesh/networks.json --port 47891
   ```

   服務監聽 `127.0.0.1:47891`。正式部署透過 HTTPS reverse proxy 對外提供，例如 `https://YOUR_DIRECTORY_DOMAIN`，將路徑原樣轉發至本機服務。程序須由部署平台維持運行；修改 JSON 後重啟服務。重啟使用相同設定即可保留相同碼，無需資料庫。

3. 兩個 APP 都設定同一個配對服務地址，各自使用自己的 relay URL：

   ```powershell
   flutter build apk --release --dart-define=AIECO_ONLINE_RELAY_URL=wss://APP_A_RELAY_DOMAIN/ws/light --dart-define=AIECO_NETWORK_DIRECTORY_URL=https://YOUR_DIRECTORY_DOMAIN
   ```

   APP B 將 relay URL 換成 B 的地址，directory URL 保持相同，並加入 `--dart-define=AIECO_NETWORK_CONNECTION_CODE=704826`，使用 B 在服務登記的碼。iOS GitHub Actions 已支援 repository / environment secret `AIECO_NETWORK_DIRECTORY_URL`。

   APP 直接使用預設正式配對服務，沒有服務地址設定入口，也不會讀取手機曾儲存的舊地址。部署其他共用服務時，只由管理員在建置階段設定 `AIECO_NETWORK_DIRECTORY_URL`。AIECO 光網直接顯示及複製 `582193`，複製內容只有 6 位數字；此操作不依賴 API 或網絡。其他光網由管理員在建置階段以 `AIECO_NETWORK_CONNECTION_CODE` 指定各自在服務登記的碼，APP 內沒有設定入口。接入其他光網時仍須透過配對服務查回對方的 relay 地址。

API：`GET /networks?relay=URL_ENCODED_RELAY_URL` 回傳 `{"code":"582193"}`；`GET /networks/582193` 回傳 `{"code":"582193","relay":"wss://..."}`；`GET /health` 提供健康檢查。查無資料回傳 404，非 GET 方法回傳 405。HTTP 僅供本機測試及 reverse proxy 內部使用，APP 正式設定使用 HTTPS。

6 位碼是公開光網的查找代號，不是登入密碼。知道碼的人可接入該光網。實際 relay 地址仍可經查碼 API 取得，勿將碼當作隱藏地址或存取控制。勿將 production 地址或私下設定提交到公開 repository。

## 驗證

```powershell
flutter analyze
flutter test --concurrency=1
```

`test/relay_network_bridge_test.dart` 使用兩台本機 WebSocket relay，驗證一名接入者讓四個客戶端雙向聊天、光團同步、最近訊息補送、停止節點結束互通、多橋接去重、封包限制、自動重連及取消尚未完成的連線。

完整測試逐一執行，避免既有 LAN 測試同時使用固定 TCP / UDP 通訊埠。
