# iOS App Store GitHub Actions

本專案已加入 `.github/workflows/ios-app-store.yml`。

Workflow 會在 `macos-26` runner 上編譯 Flutter iOS app、簽署 IPA、把 IPA 存成 GitHub Actions artifact，並上傳到 App Store Connect。此 runner 需提供 Xcode 26 / iOS 26 SDK 或更新版本，符合 App Store Connect 上傳要求。

## 必填 GitHub Secrets

請到 GitHub repository settings，或 Environment `apple`，加入以下 secrets：

- `IOS_BUNDLE_ID`：App Store bundle identifier，例如 `aiecohk.light.mesh`。
- `IOS_DISTRIBUTION_CERTIFICATE_BASE64`：Apple Distribution `.p12` 憑證的 base64。
- `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD`：該 `.p12` 的密碼。
- `IOS_PROVISIONING_PROFILE_BASE64`：App Store provisioning profile `.mobileprovision` 的 base64。
- `APP_STORE_CONNECT_API_KEY_ID`：App Store Connect API key ID。
- `APP_STORE_CONNECT_API_ISSUER_ID`：App Store Connect issuer ID。
- `APP_STORE_CONNECT_API_KEY_BASE64`：App Store Connect `AuthKey_XXXXXX.p8` 檔案的 base64。

`IOS_BUNDLE_ID` 必須和 App Store Connect app、App Store provisioning profile 內的 bundle id 完全一致。

可選 release build secrets：

- `AIECO_ONLINE_RELAY_URL`：正式 WebSocket relay URL，例如 `wss://YOUR_RELAY_DOMAIN/ws/light`。
- `GOOGLE_MAPS_API_KEY`：正式 Google Maps API key。

## 轉成 Base64

PowerShell：

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("distribution.p12"))
[Convert]::ToBase64String([IO.File]::ReadAllBytes("AppStore.mobileprovision"))
[Convert]::ToBase64String([IO.File]::ReadAllBytes("AuthKey_XXXXXX.p8"))
```

macOS：

```bash
base64 -i distribution.p12 | pbcopy
base64 -i AppStore.mobileprovision | pbcopy
base64 -i AuthKey_XXXXXX.p8 | pbcopy
```

## 執行方式

可以到 GitHub Actions 手動執行 `iOS App Store Release`，或 push tag 觸發：

```bash
git tag v1.0.6
git push origin v1.0.6
```

預設會使用 `pubspec.yaml` 的 version name，build number 則是 `pubspec build number + GitHub run number`。手動執行 workflow 時可以覆蓋 version 和 build number。

若要上傳精確版本 `1.0.8 (118)`，請手動執行 workflow，並填入：

- `build_name`: `1.0.8`
- `build_number`: `118`

## App Store 注意事項

Workflow 會把 build 上傳到 App Store Connect。Apple review submission、出口合規、價格、截圖、隱私資料和正式 release 時間仍需在 App Store Connect 完成，除非之後再加入額外的 metadata / review automation。

Apple 官方文件：

- [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
- [Submit an app](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app/)
