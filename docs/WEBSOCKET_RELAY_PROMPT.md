# WebSocket Relay 生成提示詞

傳播光線上模式需要一個 WebSocket relay server。Flutter APP 會連入 `AIECO_ONLINE_RELAY_URL`，例如：

```text
wss://YOUR_RELAY_DOMAIN/ws/light
```

正式公開部署請使用 TLS，開源文件不要寫出 production relay endpoint。實際 URL 請用私下部署文件、CI secret 或本機環境設定管理。

```text
wss://YOUR_RELAY_DOMAIN/ws/light
```

## Relay 行為

- Server 只做 relay，不改 Flutter packet schema。
- Client 傳入 JSON string。
- `kind` 必須是 `aieco.light.*`。
- 通過驗證後 broadcast 給所有已連線 client。
- 可以 broadcast 回 sender，Flutter 會用 `nodeId` / `senderId` 忽略自己的 packet。
- 不需要儲存聊天內容。
- 不使用 Socket.IO，使用原生 WebSocket / Nitro WebSocket。

## Packet 類型

目前 APP 會傳送以下 packet：

```text
aieco.light.hello.v1
aieco.light.bye.v1
aieco.light.chat.v1
aieco.light.room.v1
aieco.light.location.v1
aieco.light.supply.v1
aieco.light.credit.v1
```

## Nuxt / Nitro 生成提示詞

把以下提示詞貼給 Codex / Cursor / Claude / ChatGPT 生成 Nuxt server：

```text
幫我用 Nuxt 4 + TypeScript 建一個 AIECO Light WebSocket relay server。

目標：
- Flutter APP 會用 `AIECO_ONLINE_RELAY_URL=wss://YOUR_RELAY_DOMAIN/ws/light` 連入。
- 開發環境也要支援 `ws://localhost:3000/ws/light`。
- Server 只做 relay，不改 Flutter packet 格式。
- 不需要登入系統，不需要資料庫，不需要儲存聊天內容。
- 不使用 Socket.IO，用 Nuxt / Nitro 原生 WebSocket。

Flutter client 傳入的是 JSON string，格式大約：
{
  "kind": "aieco.light.chat.v1",
  "app": "AIECO.HK 傳播光",
  "senderId": "node-...",
  "senderName": "123456",
  "sentAt": "2026-06-05T00:00:00.000Z"
}

需要接受的 kind：
- aieco.light.hello.v1
- aieco.light.bye.v1
- aieco.light.chat.v1
- aieco.light.room.v1
- aieco.light.location.v1
- aieco.light.supply.v1
- aieco.light.credit.v1

請完成：
1. 建立 Nuxt 4 + TypeScript 專案基本檔案。

2. 在 `nuxt.config.ts` 啟用 Nitro WebSocket：
   - `nitro.experimental.websocket = true`

3. 新增 `server/routes/ws/light.ts`
   - 使用 `defineWebSocketHandler`
   - 維護目前 client 數量
   - on open：
     - client subscribe 到 channel：`aieco-light`
     - 更新 clients count
   - on message：
     - 只接受 text / string message
     - 最大 64KB，超過就忽略
     - JSON.parse 驗證
     - decoded 必須是 object
     - `kind` 必須是 string
     - `kind` 必須 startsWith("aieco.light.")
     - 若 packet 有 `app`，app 必須是 string
     - 通過後用 peer.publish 或同等方法 broadcast 到 `aieco-light`
     - 可以 broadcast 回 sender，Flutter APP 會忽略自己的 nodeId packet
     - 保留原 packet 欄位，可額外加 `relayReceivedAt`
   - on close：
     - unsubscribe `aieco-light`
     - 更新 clients count
   - on error：
     - 安全處理，不讓 server crash

4. 新增 `server/api/health.get.ts`
   - 回傳：
     `{ ok: true, service: "aieco-light-relay", clients: number }`

5. 新增 `README.md`
   - dev 指令：`npm install`、`npm run dev`
   - build 指令：`npm run build`
   - start 指令：`node .output/server/index.mjs`
   - Flutter build example：
     `flutter build apk --release --dart-define=AIECO_ONLINE_RELAY_URL=wss://YOUR_RELAY_DOMAIN/ws/light`
   - 說明 production 要用 HTTPS / WSS

6. 加基本安全限制：
   - 忽略非 JSON
   - 忽略超過 64KB message
   - 忽略不是 `aieco.light.` 開頭的 kind
   - 不在 log 打印完整聊天內容，只 log event 類型和 client count
   - 預留簡單 rate limit，例如每個 socket 每 10 秒最多 60 個 message

7. 請輸出完整檔案內容：
   - package.json
   - nuxt.config.ts
   - server/routes/ws/light.ts
   - server/api/health.get.ts
   - README.md

要求：
- TypeScript 要可通過型別檢查。
- 不要加入資料庫。
- 不要加入 Socket.IO。
- 不要改 Flutter packet schema。
- 不要把聊天內容寫入硬碟。
- 部署目標以 Node.js server 為主。
```

## Flutter Build 範例

```powershell
flutter build apk --release --dart-define=AIECO_ONLINE_RELAY_URL=wss://YOUR_RELAY_DOMAIN/ws/light
```

連 Google Maps key 一起 build：

```powershell
flutter build apk --release --dart-define=GOOGLE_MAPS_API_KEY=你的_KEY --dart-define=AIECO_ONLINE_RELAY_URL=wss://YOUR_RELAY_DOMAIN/ws/light
```

## 本 repo 內的簡易 Relay

本 repo 另有一個不加依賴的 Dart relay，適合本機測試：

```powershell
dart run tool/aieco_light_relay.dart --port 47890
```

Flutter 可指向：

```text
ws://你的開發機IP:47890
```
