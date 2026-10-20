# iOS App Store 上架文案

以下為針對名稱價格字眼及 Guideline 2.3.10 的替換文案。只複製相應欄位內的文字到 App Store Connect；本文件不會自動更新商店資料。

## 修改位置

1. 在 App Store Connect 選取本 App，進入「App 資訊」，修改各已設定語言的「名稱」及「副標題」。名稱及副標題各自最多 30 個字元。
2. 進入被拒絕的 iOS 版本，更新各已設定語言的「描述」。不要直接把跨平台開發用的 README 貼入商店描述。
3. 檢查其餘現有商店素材：移除名稱、副標題、關鍵字及截圖宣傳文字內的價格字眼（例如「免費」、「Free」、「優惠」）；描述及其他商店素材不要宣傳 Android、Google Play 或其他手機平台。
4. 儲存全部修改後，再使用下方回覆草稿回覆 App Review，並重新送審。

專案 `ios/Runner/Info.plist` 的 `CFBundleDisplayName` 已是「傳播光」，不含價格字眼。此處要修改的是 App Store Connect 內的商店資料。Apple 說明，若只因 metadata 問題被拒，修正後可重新提交相同 build；其他需要修改 App 本身的問題則另行處理。

## 繁體中文

### 名稱

```text
傳播光 LightMesh
```

### 副標題

```text
附近聊天、光團協作與物資分享
```

### 描述

```text
傳播光 LightMesh 是社區溝通與物資分享工具，讓你交換訊息、組織光團及與附近用戶互相協作。

主要功能
• 光之通道：傳送文字訊息，與已連線用戶溝通。
• 光團：建立或切換主題頻道，按地區、活動或小隊交流。
• 物資分享：發布物資名稱、數量及交收備註，並更新已取完狀態。
• 光之雷達：開啟定位分享後，在地圖查看已分享位置的光點。
• SOS 燈號：使用手機閃光燈發出 SOS 燈號，並向已連線用戶分享求助狀態。

連線方式
線上模式需要互聯網連線。
沒有互聯網時，可使用本地網絡聊天。各裝置需要連接同一 Wi-Fi 或可互通的本地網絡、開啟本 App，並允許本地網絡權限。通訊範圍及可用性取決於實際網絡連線；離線聊天時請保持 App 在前景運作。

定位功能需要你的授權。你可以選擇是否開啟位置分享。
```

## English

### Name

```text
傳播光 LightMesh
```

### Subtitle

```text
Chat, groups & supply sharing
```

### Description

```text
LightMesh helps communities exchange messages, organize topic groups and share supplies.

Features
• Chat: exchange text messages with connected users.
• Groups: create or switch topic channels for a neighborhood, activity or team.
• Supply sharing: post item names, quantities and handover notes, and mark items as taken.
• Radar: view shared user locations on a map when location sharing is enabled.
• SOS signal: flash an SOS pattern using the phone's flashlight and share a help status with connected users.

Connectivity
Online mode requires an internet connection.
Without internet access, local chat is available when devices are on the same Wi-Fi or a mutually reachable local network. Each user must open the app and allow local network access. Range and availability depend on network connectivity. Keep the app in the foreground during offline chat.

Location features require your permission. You can choose whether to enable location sharing.
```

## App Review 回覆草稿

請先在 App Store Connect 儲存以上修改，然後才使用此回覆。這是草稿，尚未傳送給 Apple。

```text
Thank you for your feedback.

We have updated the App Store name to “傳播光 LightMesh” and removed pricing references from the name and subtitle.

We have revised the app description to remove Android references and focus on the features available in the iOS app, including community chat, topic groups, supply sharing, location sharing and SOS signaling. The description also explains the network requirements for offline local chat.

Please review the updated metadata. Thank you.
```

## Apple 官方文件

- [App Review Guidelines — 2.3.7 及 2.3.10](https://developer.apple.com/app-store/review/guidelines/#accurate-metadata)
- [App information — 名稱及副標題限制](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)
- [Reply to App Review messages — metadata 修正後可重新提交相同 build](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/reply-to-app-review-messages/)
