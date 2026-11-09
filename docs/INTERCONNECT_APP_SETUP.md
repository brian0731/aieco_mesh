# 互連 APP 設置教學：讓兩個光網的聊天室互通

同一份 LightMesh 原始碼可以建置成 APP A 和 APP B，各自連到不同的聊天伺服器。完成設定後，只需其中一位用戶輸入另一個光網的連接碼，便可替兩邊在線用戶轉發訊息；其他人不用逐一操作。

這篇文章先說明管理員如何設定，再說明用戶如何接通。已有兩個完成設定的 APP，可直接跳到[手機操作](#手機操作)。

需要建立或補齊 Nuxt 後端，請閱讀[互連 APP 後端 Nuxt Setup + AI Prompt](INTERCONNECT_NUXT_SETUP_AI_PROMPT.md)，內附可直接複製的 AI 開發提示詞。

## 先了解三項設定

| 項目 | APP A | APP B |
| --- | --- | --- |
| 聊天伺服器 `AIECO_ONLINE_RELAY_URL` | A 的 WebSocket relay | B 的 WebSocket relay |
| 本網絡連接碼 `AIECO_NETWORK_CONNECTION_CODE` | `582193` | `704826`（教學範例） |
| 共用查碼服務 `AIECO_NETWORK_DIRECTORY_URL` | 兩邊使用同一個 HTTPS 地址 | 與 A 相同 |

`582193` 是本 APP 的預設碼，畫面直接顯示，按「複製本網絡連接碼」只會複製這 6 位數字，不需先查 API。APP B 必須使用自己在服務登記的另一個碼，不能只改聊天伺服器卻沿用 A 的碼。

查碼服務負責把連接碼查成聊天伺服器地址，聊天訊息仍經兩邊的 WebSocket relay 傳送。單獨顯示或複製一個碼，不代表它已在服務登記。

## 第一步：準備兩個聊天伺服器

兩邊須使用相容的原生 WebSocket LightMesh 協定，並保留訊息中的欄位。已有相容 relay 可以直接沿用；建立新伺服器可參考 [WebSocket Relay 設置說明](WEBSOCKET_RELAY_PROMPT.md)及[本機 Dart Relay 範例](../tool/aieco_light_relay.dart)。

以下統一用佔位地址示範，請換成管理員實際部署的地址：

```text
APP A：wss://APP_A_RELAY_DOMAIN/ws/light
APP B：wss://APP_B_RELAY_DOMAIN/ws/light
```

手機須能連到兩個地址；正式部署使用 `wss://`，反向代理須允許 WebSocket 升級連線。

## 第二步：在同一個查碼服務登記 A、B

APP 預設使用 `https://www.aieco.hk/api/lightmesh`。使用此共用服務時，請由服務管理員登記 APP B 的碼與 relay，手機沒有服務地址或登記連接碼的設定入口。

如果自行部署 Nuxt 配對 API，在執行網站的 Node 程序設定以下環境變數，把兩個佔位 relay 地址換成實際地址：

```dotenv
LIGHTMESH_NETWORKS_JSON='{"582193":"wss://APP_A_RELAY_DOMAIN/ws/light","704826":"wss://APP_B_RELAY_DOMAIN/ws/light"}'
```

每個碼必須是 6 位數字字串，每個 relay 對應一個碼。更新後將設定帶入正式程序並重啟；只改 `.env` 不會更新已執行的程序。

沒有 Nuxt 配對 API，可按照[6 位碼配對服務部署教學](CROSS_APP_CHAT.md#6-位碼配對服務部署)，使用本專案提供的獨立 Dart 服務，再以 HTTPS 對外提供。

部署後確認以下 API：

| 請求（加在查碼服務的 base URL 後） | 預期結果 |
| --- | --- |
| `GET /health` | HTTP 200，`ok` 為 `true` |
| `GET /networks/582193` | HTTP 200，回傳 A 的 relay |
| `GET /networks/704826` | HTTP 200，回傳 B 的 relay |

例如使用 PowerShell 檢查自己的部署：

```powershell
$directoryBase = 'https://YOUR_DIRECTORY_DOMAIN/api/lightmesh'
Invoke-RestMethod "$directoryBase/health"
Invoke-RestMethod "$directoryBase/networks/582193"
Invoke-RestMethod "$directoryBase/networks/704826"
```

把 `$directoryBase` 換成實際 base URL；獨立 Dart 服務的 base URL 不一定包含 `/api/lightmesh`，須與反向代理設定一致。

## 第三步：建置兩個 APP

在專案根目錄執行。以下 Android 指令使用 APP 的預設共用查碼服務：

APP A：

```powershell
flutter build apk --release --dart-define=AIECO_ONLINE_RELAY_URL=wss://APP_A_RELAY_DOMAIN/ws/light --dart-define=AIECO_NETWORK_CONNECTION_CODE=582193
```

先保存 A 的 APK，再建置 APP B，避免產物被覆寫：

```powershell
flutter build apk --release --dart-define=AIECO_ONLINE_RELAY_URL=wss://APP_B_RELAY_DOMAIN/ws/light --dart-define=AIECO_NETWORK_CONNECTION_CODE=704826
```

如使用自己的查碼服務，兩條指令都加入相同的參數：

```text
--dart-define=AIECO_NETWORK_DIRECTORY_URL=https://YOUR_DIRECTORY_DOMAIN/api/lightmesh
```

iOS 在 macOS 使用相同的三項 `--dart-define`，搭配專案的 iOS 建置及簽署流程。現有 [iOS GitHub Actions 教學](IOS_APP_STORE_GITHUB_ACTIONS.md)可用作簽署參考；目前 workflow 使用預設本網絡碼 `582193`，若用它建置 APP B，須在建置步驟額外傳入 `AIECO_NETWORK_CONNECTION_CODE=704826`。

上述參數只設定光網。若要把 A、B 發佈成可同時安裝的兩個產品，還須各自設定 Android application ID、iOS bundle ID、名稱及簽署資料。更新建置參數後須重新建置並安裝，既有手機版本不會自動改設定。

## 手機操作

1. 兩邊安裝包含互連功能且已完成上述設定的版本，開啟「光之網絡」，選擇「線上」，等候各自的光網連線成功。
2. APP A 在「線上／離線」框下方打開「連接另一個 光網APP」，按「複製本網絡連接碼」，將 `582193` 交給 APP B 的一位用戶。
3. 這位 APP B 用戶打開相同功能，在「另一個 APP 的連接碼」輸入或貼上 `582193`，按「接通另一個 APP」。
4. 顯示「兩個 APP 的聊天室已互通」後，兩邊進入「光之通道」的預設「傳播頻道」聊天。
5. 也可反過來：APP A 的一位用戶輸入 B 的 `704826`。只需其中一邊有一人接入，便能雙向互通。

不能輸入自己的碼：A 輸入 `582193`，或 B 輸入 `704826`，都會提示「這是本網絡的連接碼，請使用另一個 APP 的連接碼。」

接入者須保持 APP 執行及連網。關閉 APP、停止節點、按「中斷互通」或切換離線，會結束這部手機的轉發；重新開啟後須再次接入。離線模式會隱藏互連功能。

## 接通後怎樣確認成功

用四部裝置驗證最清楚：A1、A2 使用 APP A，B1、B2 使用 APP B。只讓 A1 輸入 B 的碼。

1. A2 發送一則新訊息，確認 B1、B2 都收到。
2. B2 回覆，確認 A1、A2 都收到。
3. 確認沒有每則訊息重複出現的情況。
4. A1 按「中斷互通」，在沒有其他橋接者時，兩邊恢復各自聊天。

兩邊除了聊天，也會轉發光團、光點、定位、SOS 等支援的光網資料。其他光團依 roomId 同步，同名但不同 ID 的光團仍屬不同聊天室。這是兩個光網的資料互通，接通前應讓參與者了解分享範圍。

## 常見問題

| 情況 | 處理方式 |
| --- | --- |
| 找不到此光網連接碼 | 管理員確認對方的碼已登記，兩個 APP 使用同一查碼服務，並檢查 `/networks/對方碼` 是否回傳 200。 |
| B 也顯示 `582193` | B 建置時漏了自己的 `AIECO_NETWORK_CONNECTION_CODE`；加入 B 的碼後重新建置安裝，並確認服務登記一致。 |
| 提示這是本網絡的碼 | 改用對方的碼；同一個光網內的用戶本來就可聊天，不需互連。 |
| 能複製碼但無法接通 | 複製不需要網絡；接通則需要可用的查碼服務、自己的光網連線及可連到的兩邊 relay。 |
| 提示等待本網絡連線成功 | 先確認自己的線上光網已連線，再嘗試接通。 |
| 查碼成功，但一直連接中 | 檢查兩邊 relay、TLS 憑證、反向代理 WebSocket 升級及手機網絡。 |
| 轉到背景後停止互通 | 接入手機可能被系統暫停；回到 APP 後檢查連線，必要時重新接入。 |
| 沒有 Internet 可以互連嗎？ | 這個功能須能存取查碼服務及兩邊 relay。沒有外網時，可另用同一 WiFi／熱點的離線 mesh；它不會自動接通兩個分開的離線網絡。 |

更多協定行為、補送及轉發限制見[跨 APP 聊天網絡互通說明](CROSS_APP_CHAT.md)。

[返回 README](../README.md)
