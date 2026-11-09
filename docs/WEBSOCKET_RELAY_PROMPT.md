# 生成提示詞

本篇合併 WebSocket Relay 與互連 APP 後端 Nuxt Setup，包含原生 WebSocket 廣播、隨機 6 位連接碼、查碼 API、Nginx／Apache 部署及完整 AI Prompt。可直接複製[完整生成提示詞](#6-可直接複製的-ai-prompt)交給 AI 開發工具；APP 端操作另見[互連 APP 設置教學](INTERCONNECT_APP_SETUP.md)。

## 1. 後端如何配合兩個 APP

| 角色 | 工作 | 部署位置 |
| --- | --- | --- |
| APP A relay | 廣播 A 光網內的訊息 | A 的 Nuxt server |
| APP B relay | 廣播 B 光網內的訊息 | B 的 Nuxt server |
| 共用查碼服務 | 把 `582193`、B 的碼查成各自的 relay URL | 兩個 APP 都能存取的同一服務 |

新光網首次登記時，由共用後端隨機生成 **6 位數字字串**（`000000` 至 `999999`），檢查沒有重複後保存。同一光網再次登記、查碼或重啟服務，仍使用原碼。碼屬於光網，不是每部手機各自產生。

本文的 `582193`、`704826` 僅用來示範 API 回應；新光網不應寫死這些值。現有 AIECO APP 仍直接顯示及複製 `582193`，舊光網遷移時須保留此登記；新光網使用後端實際生成的碼。

**實作狀態：**本篇是隨機配碼的開發規格及 AI Prompt。現有查碼後端使用管理員提供的 `LIGHTMESH_NETWORKS_JSON`，尚未實作隨機生成及持久化登記；需完成下方 Prompt 的改動後才具備此功能。

只需一位用戶接入，這部手機便會連接兩邊 relay 並雙向轉發。查碼服務不負責轉發聊天，也不會自動連接兩台 server。兩個 APP 共用 GitHub 原始碼，不代表它們已共用聊天室。

## 2. Nuxt 專案與檔案位置

本文對應既有網站的 Nuxt 4、Nitro 2、H3 1。實作前先檢查目標專案的 `package.json` 和 lockfile，沿用其版本。Nitro 2 的 WebSocket 功能須以 experimental 設定啟用，詳見 [Nitro 2 官方文件](https://v2.nitro.build/guide/websocket)；不要混用 Nitro 其他主要版本的設定及 import。

在既有 Nuxt 專案合併以下結構，已有檔案先檢查再修改：

```text
nuxt.config.ts
server/
  routes/ws/light.ts
  utils/lightmeshDirectory.ts
  utils/lightmeshRegistry.ts
  api/lightmesh/
    health.get.ts
    networks/index.get.ts
    networks/[code].get.ts
  tests/lightmeshDirectory.test.ts
scripts/lightmesh-register.ts
.env.example
```

`server/routes/ws/light.ts` 對應 `/ws/light`；`server/api/lightmesh/` 對應 `/api/lightmesh/`。A、B 各自部署 relay，共用查碼服務可設在其中一台 Nuxt server。已有 AIECO 服務時，由該服務管理員新增 B 的登記，無須另建一個彼此不同步的查碼服務。

將以下設定合併到 `nuxt.config.ts`，保留網站原有選項：

```ts
export default defineNuxtConfig({
  nitro: {
    preset: 'node-server',
    experimental: {
      websocket: true,
    },
  },
})
```

### WebSocket Relay 行為及封包

Flutter 以 `AIECO_ONLINE_RELAY_URL` 指向原生 WebSocket，例如 `wss://YOUR_RELAY_DOMAIN/ws/light`；本機開發可使用 `ws://localhost:3000/ws/light`。正式公開文件使用佔位地址，實際 relay URL 放在私下部署設定或 CI secret。

- 使用 `defineWebSocketHandler`，連入時訂閱同一個 topic，例如 `aieco-light`，離線或錯誤時清理客戶端狀態。
- 收到文字封包後驗證 UTF-8 大小不超過 64 KiB、JSON 為 object、`kind` 為 `aieco.light.*`；若有 `app` 欄位，須為字串。
- 合法封包原樣廣播給同一 relay 其他已訂閱客戶端；回傳給來源端並非必要，不可重複廣播。
- 不使用 Socket.IO，不儲存聊天內容。可提供獨立 relay health，顯示目前程序的客戶端數；查碼 health 仍只驗證登記儲存。
- 保留 `_lightBridgePath`、messageId、roomId 及其他原有欄位，不包成另一層 `data`，不新增每跳時間戳或改寫 senderId。這些改寫可能令橋接端把回音視為新訊息。
- 不輸出完整聊天或定位到日誌；若加入每連線流量限制，須允許橋接後的多用戶同步及補送，不可因單人連接兩網而丟失正常訊息。

橋接功能支援以下 packet kind：

```text
aieco.light.hello.v1
aieco.light.bye.v1
aieco.light.chat.v1
aieco.light.room.v1
aieco.light.location.v1
aieco.light.activity.v1
aieco.light.help.v1
aieco.light.supply.v1
aieco.light.credit.v1
aieco.light.admin.v1
```

已有相容 relay 時保留原有功能，只補齊查碼及互連相容性。

## 3. 隨機生成並保存 6 位連接碼

新後端提供管理員使用的本機登記指令，由管理員提交 relay URL；查碼 GET API 維持唯讀，不會為陌生 URL 自動建立光網。

1. 正規化 relay URL；已登記便直接回傳原碼。
2. 未登記則使用 Node.js `crypto.randomInt(0, 1_000_000)`，再以 `padStart(6, '0')` 轉成 6 位字串。方法參考 [Node.js randomInt 官方文件](https://nodejs.org/api/crypto.html#cryptorandomintmin-max-callback)。
3. 用持久化儲存的唯一約束檢查 code 及正規化 relay；碼衝突便重新抽取，設定有限重試，不能覆寫其他光網。
4. 在交易內完成登記，提交成功後才回傳連接碼；同一 relay 的並發登記只保留一筆並回傳相同碼。
5. 重啟、重新部署或多程序查詢都讀取原登記，不重新生成。備份及恢復須包含登記資料。

生成候選碼的核心寫法如下；這段本身不含防重複及儲存流程，不能單獨作為完整配碼功能：

```ts
import { randomInt } from 'node:crypto'

const candidate = randomInt(0, 1_000_000).toString().padStart(6, '0')
```

優先沿用既有資料庫；沒有資料庫時，可由 Prompt 實作使用持久化磁碟的 SQLite 登記庫。為 `code` 與正規化 `relay` 各建立唯一約束，欄位 `code` 用文字保存。多主機部署須使用共用資料庫，不可各自保存一份互不同步的 SQLite。

下列 `.env.example` 路徑為新方案建議設定，須由 Prompt 實作讀取；資料檔放在部署目錄之外，不能隨 `.output` 重建而刪除：

```dotenv
LIGHTMESH_DIRECTORY_DB=C:/private/lightmesh/registry.sqlite
NITRO_HOST=127.0.0.1
NITRO_PORT=3000
```

舊版 `LIGHTMESH_NETWORKS_JSON` 僅用作一次性遷移來源。遷移時完整驗證，保留既有 code／relay 對應；衝突則中止並提示管理員，不得默默換碼。新登記改由後端隨機配碼，管理員毋須手選新碼。

Relay URL 只接受 `ws://` 或 `wss://`，不得包含帳號密碼或 fragment；正式對外使用 `wss://`。沒有公開註冊或覆寫 API，本機指令與網站程序須使用同一個持久化登記庫。

### 查碼 API 格式

以下路徑均相對於網站根目錄：

| 方法及路徑 | 成功 JSON |
| --- | --- |
| `GET /api/lightmesh/health` | `{"ok":true,"service":"lightmesh-network-directory"}` |
| `GET /api/lightmesh/networks/582193` | `{"code":"582193","relay":"wss://APP_A_RELAY_DOMAIN/ws/light"}` |
| `GET /api/lightmesh/networks/704826` | `{"code":"704826","relay":"wss://APP_B_RELAY_DOMAIN/ws/light"}` |
| `GET /api/lightmesh/networks?relay=URL_ENCODED_RELAY_URL` | `{"code":"582193"}`（查 A 時） |

回應使用 JSON。查詢參數格式錯誤回傳 400；合法但未登記回傳 404；登記儲存未初始化或無法讀取回傳 503。成功查碼回應設定 `Cache-Control: no-store`。Health 必須驗證登記儲存可用，儲存故障時不可仍回傳成功；已初始化但尚無登記的空庫可以回傳成功。其他方法不得修改登記表。

APP 使用的 `AIECO_NETWORK_DIRECTORY_URL` 是 base URL，例如 `https://YOUR_DIRECTORY_DOMAIN/api/lightmesh`，不要再加 `/networks`；APP 會自行補上查詢路徑。

## 4. 建置與啟動 Nuxt

在 Nuxt 專案根目錄執行。Node 版本須符合該專案 Nuxt 及 lockfile 的要求；以下啟動方式需 Node 支援 `--env-file`：

```powershell
npm ci
npm run build
node --env-file=.env .output/server/index.mjs
```

`.env` 放在執行指令的目錄，或把 `--env-file` 換成實際檔案路徑；載入規則參考 [Node.js `--env-file` 官方文件](https://nodejs.org/api/cli.html#--env-filefile)。已有 PM2／服務管理器時，將環境變數帶入該程序並更新環境後重啟，沿用原有維持程序運行的方式。

XAMPP 的 `htdocs` 只是檔案位置：把 Nuxt 放入該目錄，不會讓 Apache 自動執行 Nitro。仍須啟動上述 Node 程序，並由 Apache 代理請求。已有 Nuxt 網站的啟動及代理設定時，合併必要路徑即可。

### XAMPP／Apache 路徑代理範例

以下內容合併至已設定 HTTPS 憑證的 VirtualHost。啟用 `proxy`、`proxy_http`、`proxy_wstunnel` 模組，確認 `3000` 與 Node 的 port 相同：

```apache
ProxyPreserveHost On

ProxyPass        "/ws/light" "ws://127.0.0.1:3000/ws/light"
ProxyPassReverse "/ws/light" "ws://127.0.0.1:3000/ws/light"

ProxyPass        "/api/lightmesh/" "http://127.0.0.1:3000/api/lightmesh/"
ProxyPassReverse "/api/lightmesh/" "http://127.0.0.1:3000/api/lightmesh/"
```

路徑規則放在會攔截它們的通用代理或 rewrite 規則之前；若網站已完整代理到 Nuxt，檢查 WebSocket upgrade 是否已支援，避免重複規則。檢查 Apache 設定有效後重載。對外使用 HTTPS／WSS，內部代理使用 loopback HTTP／WS。

此範例沿用 `ws://` ProxyPass 寫法；Apache 2.4.47 起也可由 `mod_proxy_http` 處理 WebSocket upgrade，應按已安裝版本合併設定，參考 [Apache WebSocket 代理官方文件](https://httpd.apache.org/docs/2.4/mod/mod_proxy_wstunnel.html)。

### Nginx Setup：HTTPS、WebSocket 與查碼 API

使用 Nginx 的主機可採以下方式代理到同一台機器的 Nuxt Node 程序 `127.0.0.1:3000`。先完成網域 DNS 及有效 TLS 憑證設定，再把 `relay.example.com`、憑證路徑和 Node port 換成部署值。憑證須涵蓋 APP 實際使用的網域；設定參考 [Nginx HTTPS 官方文件](https://nginx.org/en/docs/http/configuring_https_servers.html)。

以下片段放在 Nginx 的 `http { ... }` 內，例如由該區塊載入的 `conf.d/lightmesh.conf`；`map` 不可放進 `server` 或 `location`。若已有同網域的 HTTPS server，合併對應 location，保留既有網站路由；不要建立重複的同網域 server。

```nginx
map $http_upgrade $lightmesh_connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    server_name relay.example.com;
    return 301 https://relay.example.com$request_uri;
}

server {
    listen 443 ssl;
    server_name relay.example.com;

    ssl_certificate     /etc/nginx/ssl/relay.example.com/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/relay.example.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location = /ws/light {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $lightmesh_connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }

    location ^~ /api/lightmesh/ {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache off;
    }

    # 僅在整站也由這個 Nuxt 程序提供時使用；既有網站保留自己的 location /。
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

`proxy_pass` 未附加 URI，會保留 `/ws/light` 及 `/api/lightmesh/...` 路徑與查詢參數。WebSocket location 明確傳遞 Upgrade／Connection 標頭，並提高閒置讀取逾時；這些設定依據 [Nginx WebSocket 官方文件](https://nginx.org/en/docs/http/websocket.html)。逾時仍不是永久連線保證，APP 應維持原有斷線重連；也可由 relay 提供適當的 WebSocket ping。

在 Nginx 主機檢查設定，成功後才重載；Linux 範例：

```sh
sudo nginx -t
# 上一條成功後才執行：
sudo nginx -s reload
curl --fail https://relay.example.com/api/lightmesh/health
```

Windows Nginx 在其安裝目錄使用 `nginx.exe -t`，成功後執行 `nginx.exe -s reload`。若還有 CDN 或上游代理，亦須允許 WebSocket upgrade。Apache 與 Nginx 是替代代理方式；若在同一主機使用，須規劃不同監聽位址或 port，避免同時佔用 80／443。

APP 的 relay URL 設為 `wss://relay.example.com/ws/light`；共用查碼 base URL 設為提供登記服務的 `https://YOUR_DIRECTORY_DOMAIN/api/lightmesh`。查碼服務若部署在另一個網域，不需在每台 relay 重複部署，兩個 APP 仍使用同一 directory base。

驗證時應先確認內部 Nuxt health 可用，再檢查外部 HTTPS health。WebSocket 請另以真實客戶端測試：握手應回傳 HTTP 101，並確認兩個客戶端能廣播訊息。502 常見於 Node 未啟動或 port 不符；404 檢查路徑與 location；連線定時中斷則檢查代理／CDN 的逾時及 ping 設定。

此入門方案每個光網使用單一 relay 程序。多程序或多台 replica 的記憶體廣播不會自然互通；需要另設共用 pub/sub，不能只增加 worker 數目。

## 5. 驗證後端及 APP

先在 Nuxt 主機檢查內部 API，再檢查對外 HTTPS，方便區分程序與代理問題：

```powershell
Invoke-RestMethod 'http://127.0.0.1:3000/api/lightmesh/health'

$directoryBase = 'https://YOUR_DIRECTORY_DOMAIN/api/lightmesh'
Invoke-RestMethod "$directoryBase/health"
$codeA = Read-Host '輸入後端已保存的 A 連接碼'
$codeB = Read-Host '輸入後端已保存的 B 連接碼'
Invoke-RestMethod "$directoryBase/networks/$codeA"
Invoke-RestMethod "$directoryBase/networks/$codeB"
```

三項外部請求應回傳上表的成功內容；另用一個確定未登記的 6 位碼驗證 404。HTTP health 成功只代表查碼服務可用，還須測試兩台 relay 的 WebSocket 連線及訊息廣播。

在 Flutter 專案分別建置 A、B，沿用上述 `$codeA`、`$codeB` 的後端已保存結果，兩個 APP 使用同一 directory base URL。現有 APP 支援建置時帶入生成碼，毋須新增手機設定入口：

```powershell
flutter build apk --release --dart-define=AIECO_ONLINE_RELAY_URL=wss://APP_A_RELAY_DOMAIN/ws/light --dart-define=AIECO_NETWORK_CONNECTION_CODE=$codeA --dart-define=AIECO_NETWORK_DIRECTORY_URL=https://YOUR_DIRECTORY_DOMAIN/api/lightmesh

# 先保存 A 的 APK，再建置 B，避免覆寫產物。
flutter build apk --release --dart-define=AIECO_ONLINE_RELAY_URL=wss://APP_B_RELAY_DOMAIN/ws/light --dart-define=AIECO_NETWORK_CONNECTION_CODE=$codeB --dart-define=AIECO_NETWORK_DIRECTORY_URL=https://YOUR_DIRECTORY_DOMAIN/api/lightmesh
```

用 A1、A2、B1、B2 四個客戶端，只讓 A1 接入後端為 B 生成並保存的碼。確認 A2 與 B2 能雙向聊天、不重複收到訊息。A1 中斷互通後，在沒有其他橋接者時恢復兩個獨立光網。完整手機步驟見[互連 APP 設置教學](INTERCONNECT_APP_SETUP.md#手機操作)。

## 6. 可直接複製的 AI Prompt

將以下整段貼給 AI 開發工具，並提供目標 Nuxt 專案。提示詞中的網域都是佔位值，實際部署值由管理員填入環境設定。

```text
請用 Nuxt 4 + TypeScript 實作 LightMesh WebSocket Relay 及跨 APP 互連後端，並完成可驗證的 Setup 文件。
若已有 Nuxt 專案，直接整合；若是空目錄，建立相容的 Nuxt 專案與必要檔案。

先檢查 package.json、lockfile、nuxt.config.ts、既有 server routes、部署方式。
沿用既有版本、套件管理器及程式風格，保留其他網站功能和既有資料。
本文參考 Nuxt 4 + Nitro 2 + H3 1；若專案版本不同，查該版本官方 API，
不要混用 Nitro 3 或其他主要版本設定，不要為此功能擅自全面升級依賴。
如已有 relay 或查碼 API，先檢查並合併改動，避免覆寫管理／審核等既有行為。

目標架構：
- APP A 連 A relay，APP B 連 B relay，各自是獨立光網。
- 新光網的連接碼由共用後端隨機生成 ASCII 6 位數字字串，不能寫死 A/B 的值。
- 範圍 000000 至 999999，前置零必須保留；每個光網一個碼，不是每位用戶一個碼。
- 舊 AIECO 光網已使用 582193，遷移須保留原登記，不能令既有 APP 失效。
- 兩個 APP 使用同一個 HTTPS 查碼服務，查到對方的 WebSocket URL。
- 手機現有橋接功能負責連接兩邊並雙向轉發；後端不另建常駐跨網橋接。
- APP 顯示／複製自己的碼是本機操作，不需要查 API，也沒有服務地址設定 UI。

一、共用查碼 API
新增或沿用：
server/utils/lightmeshDirectory.ts
server/utils/lightmeshRegistry.ts
scripts/lightmesh-register.ts
server/api/lightmesh/health.get.ts
server/api/lightmesh/networks/index.get.ts
server/api/lightmesh/networks/[code].get.ts

配碼與儲存：
- 新增管理員本機登記 CLI，接收 relay URL，回傳 {code, relay}；提供可執行指令與 npm script。
- 已登記的正規化 relay 直接回傳原碼；新 relay 使用 node:crypto randomInt(0, 1_000_000)
  加 toString().padStart(6, '0') 生成候選碼，不用 Math.random、時間戳或截短雜湊。
- 優先沿用專案資料庫；沒有則實作 SQLite，路徑由 LIGHTMESH_DIRECTORY_DB 設定，
  與 .output／靜態公開檔案分開，持久化保存 code、normalized relay、建立時間。
- code 為文字欄位，code 和 normalized relay 各有唯一約束；以交易處理插入及並發。
- 碰撞重抽，設定有限重試並明確回報失敗；絕不覆寫舊碼，不無限迴圈。
- 同一 relay 並發登記取得同一碼；不同 relay 不得取得相同碼，交易提交後才回傳。
- 寫入失敗不得回傳未保存的碼；重啟、部署、重複登記、GET 查碼都不得重新生成。
- 多主機使用同一共用資料庫，不各自生成互不同步的登記表；文件說明備份與恢復。
- 舊 LIGHTMESH_NETWORKS_JSON 只作可重複安全執行的一次性遷移輸入，保留既有碼，
  遷移衝突必須中止，不得隨機換碼；新碼不再由管理員手選。
- relay 僅有效 ws/wss URL，不接受 userinfo 或 fragment，無路徑正規化為 /。
- 不硬編碼 production relay，不輸出或提交實際 .env／憑證／資料庫檔。
- CLI 驗證 relay；公開 GET API 只查詢，不可因陌生 relay 或 code 自動建立登記。

API 合約：
GET /api/lightmesh/health：先驗證登記表，再回傳
  {"ok":true,"service":"lightmesh-network-directory"}
GET /api/lightmesh/networks?relay=URL_ENCODED_RELAY_URL：
  正規化查詢 URL，查回已保存的 {code}，code 必須是 6 位字串。
GET /api/lightmesh/networks/:code：回傳已保存的 {code, relay}。
範例值只供說明，實際回傳資料庫已保存的生成碼。
格式錯誤 400，合法但查無登記 404，登記儲存未初始化或讀取失敗 503。
Health 驗證儲存可用；已初始化的空庫可以成功，不能把空庫當作未初始化。
JSON 回應，查碼回應 Cache-Control: no-store，錯誤不洩漏環境變數內容。
不提供公開新增、覆寫、刪除或列出全部光網的 API；其他方法不可修改登記。
在可獨立測試的 utility 使用該版本正確的明確 imports，避免依賴測試環境不存在的 auto-import。

二、WebSocket relay
Flutter 的 AIECO_ONLINE_RELAY_URL 指向 wss://YOUR_RELAY_DOMAIN/ws/light；
開發環境支援 ws://localhost:3000/ws/light。
如已有相容 relay，優先保留並修正互連相容性，不另建重複路由。
如需新增，使用 server/routes/ws/light.ts 對應 /ws/light。
使用原生 WebSocket，Nitro 2 於 nuxt.config.ts 合併
nitro: { preset: 'node-server', experimental: { websocket: true } }。
不要使用 Socket.IO；資料庫只用於連接碼登記，不新增聊天儲存或登入需求。
客戶端 subscribe 到同一 relay topic；收到合法封包後廣播給其他已訂閱客戶端。
依安裝版 CrossWS 的 publish/send 語意處理，不要重複廣播。
只接受可解析的 JSON object、kind 為 aieco.light.* 的文字封包，最大 UTF-8 64 KiB。
若有 app 欄位，須為字串。使用 defineWebSocketHandler，在 open 訂閱 aieco-light topic，
在 close/error 清理狀態；可以提供獨立 relay health 回報本程序的 client count，
不要把 relay health 與查碼儲存 health 混為同一項驗證。
至少相容 hello、bye、chat、room、location、activity、help、supply、credit、admin 的 v1 封包。
合法封包原樣轉發，保留所有欄位，尤其 _lightBridgePath、messageId、roomId、sentAt。
不要包成另一層 data，不要每跳增加時間戳或改寫 senderId／kind。
不要因封包來自橋接、帶有 _lightBridgePath 或其他 relay 中繼欄位就一律丟棄；
回音主要由 APP 的路徑與去重機制處理，需以雙向互連測試確認相容。
無效資料、關閉連線或單一客戶端錯誤不能使整個服務崩潰。
日誌不輸出完整聊天或定位內容。
如新增流量限制，設為可配置且考慮橋接時多用戶同步與補送，加入正常流量不誤擋的驗證。
以單程序 relay 作入門部署；若採多 worker，必須實作共用 pub/sub 並測試跨 worker 廣播。

三、測試與交付
加入有意義的 API 測試：A/B 雙向查碼、前置零、未知碼 404、錯誤格式 400、
儲存故障 503、非 GET 不修改資料、GET 查未知 relay 不建立新碼。
配碼測試須可注入隨機候選以強制碰撞：驗證 6 位格式、前置零、碰撞重試、
重試上限、同一 relay 重複／並發登記、不同 relay 並發唯一性、寫入失敗不回碼、
重啟後仍回原碼、舊 JSON 遷移保留碼及衝突不覆寫。不可只測隨機取樣從未重複。
加入真實 WebSocket 測試：兩客戶端廣播、無效／過大封包拒絕、
_lightBridgePath 及未知附加欄位保持不變，斷線不影響其他用戶。
驗證兩獨立 relay + 現有手機橋接的雙向聊天與去重；無法跑手機時明確記錄未測部分。
執行專案適用的 typecheck、測試及 npm run build，報告實際結果。

交付完整可執行檔案與變更說明，包括 package.json、nuxt.config.ts、relay route、
查碼 API、登記 utility／CLI、測試及 .env.example，不只輸出片段或計劃。
提供 .env.example（只含佔位值）及繁體中文 Setup 文件，包含：
- 相容 Node／Nuxt／Nitro 版本、安裝、npm run dev、建置與正式啟動指令。
- node --env-file=.env .output/server/index.mjs 的環境載入方式及程序重啟方式。
- XAMPP htdocs 不會自動執行 Nuxt，需常駐 Node + Apache 代理。
- HTTPS 查碼 API、WSS upgrade 路徑、Apache 及 Nginx 代理範例與設定檢查。
- Nginx 提供可放在 http 區塊的完整 map/server/location 範例，包含 TLS 憑證、
  HTTP 轉 HTTPS、/ws/light 的 HTTP/1.1 Upgrade/Connection、逾時、關閉 buffering、
  /api/lightmesh/ 保留原始 URI 與 query 的 proxy_pass，以及轉發 Host/來源 IP/協定。
- Nginx 合併既有網域設定，保留其他網站路由；提供 nginx -t、成功後 reload、
  內外部 health 及真實 WebSocket 101/廣播驗證，記錄沒有環境可實測的部分。
- API curl／PowerShell 驗證及 WebSocket 驗證方法。
- APP A/B 三項 dart-define：AIECO_ONLINE_RELAY_URL、
  AIECO_NETWORK_CONNECTION_CODE、AIECO_NETWORK_DIRECTORY_URL。
- CLI 登記指令、生成碼的保存位置、遷移舊登記、備份及恢復步驟。
- A/B 各自使用後端已保存的生成碼建置；兩邊 directory base 相同且不附加 /networks。
- 6 位碼是公開網絡查找代號，不是登入密碼或私聊授權。
先完成程式與本機驗證；不要在未獲授權時更改正式服務或公開實際 relay 地址。
最後列出修改檔案、驗證結果、管理員需要填入的部署值及仍未完成的驗證。
```

## 7. 常見部署問題

| 現象 | 檢查方向 |
| --- | --- |
| 查碼 API 404 | 檔案是否已部署、路徑是否多／少一段 `/api/lightmesh`、Apache 是否轉到正確 Node。 |
| 登記儲存 503 | 檢查資料庫初始化、連線、路徑及讀寫權限；確認 CLI 與網站指向同一儲存。 |
| 查碼成功但無法互通 | 兩邊 relay 是否可連、WSS upgrade 是否成功、APP 是否先連上自己的光網。 |
| A 能到 B，B 的回覆不到 A | 檢查 relay 是否丟棄含中繼欄位的封包，或改寫封包造成去重失效。 |
| B 仍顯示 A 的碼 | 查回後端為 B 保存的生成碼，以此設定 `AIECO_NETWORK_CONNECTION_CODE` 重新建置並安裝。 |
| 重啟後連接碼改變 | 檢查是否每次啟動都重新抽碼，或資料庫是否存放在會被清除的部署目錄。 |
| 同一光網部分用戶收不到 | 檢查是否用了多 worker／replica 卻沒有共用 pub/sub。 |

## 8. Flutter AAB 與 Google Maps 建置範例

完成後端登記後，在 Flutter 專案根目錄使用後端已保存的碼；下例的 `YOUR_NETWORK_CODE` 必須換成實際 6 位碼：

```powershell
flutter build appbundle --release --dart-define=GOOGLE_MAPS_API_KEY=YOUR_GOOGLE_MAPS_API_KEY --dart-define=AIECO_ONLINE_RELAY_URL=wss://YOUR_RELAY_DOMAIN/ws/light --dart-define=AIECO_NETWORK_CONNECTION_CODE=YOUR_NETWORK_CODE --dart-define=AIECO_NETWORK_DIRECTORY_URL=https://YOUR_DIRECTORY_DOMAIN/api/lightmesh
```

`.aab` 產物在 `build/app/outputs/bundle/release/app-release.aab`。Google Maps key 使用自己的建置設定，不在公開文件填入實際 key。

## 9. 本機簡易 Relay

本專案另有不加依賴的 Dart relay，供本機開發測試：

```powershell
dart run tool/aieco_light_relay.dart --port 47890
```

手機的 relay URL 使用 `ws://開發機區域網絡IP:47890`，須能連到開發機。這個範例只提供 relay；隨機配碼與共用查碼服務須另外按上述規格實作。

[返回 README](../README.md) · [APP 設置教學](INTERCONNECT_APP_SETUP.md) · [協定及轉發限制](CROSS_APP_CHAT.md)
