# 香港離線瓦片地圖

雷達的離線模式使用 `flutter_map` 的 `AssetTileProvider`，不會在執行時連接任何地圖服務。瓦片必須以標準 XYZ 格式放在：

```text
assets/map_tiles/hong_kong/{z}/{x}/{y}.png
```

目前打包原生 zoom 10–16，地圖介面可將 zoom 16 瓦片繼續放大至 zoom 18。Zoom 10 用於全港概覽，zoom 15–16 可顯示道路及建築物細節。啟動時必須同時找到 zoom 10 和 zoom 16 的 PNG，才會啟用瓦片地圖；否則會顯示舊有十八區概覽圖及提示。

九龍及黃大仙附近另有局部 zoom 17 詳細層，範圍為經度 114.12–114.27、緯度 22.29–22.39。範圍外會自動繼續使用 zoom 16，不會出現空白地圖。

黃大仙區另有 zoom 18 詳細層，範圍為經度 114.18–114.24、緯度 22.32–22.36。離開黃大仙後會自動使用九龍 zoom 17 或全港 zoom 16。

## 匯入

先從允許離線使用及重新散佈的圖資來源匯出香港 XYZ PNG 瓦片，再執行：

```powershell
.\tool\import_hk_tiles.ps1 -Source 'D:\hk_xyz_tiles'
flutter pub get
flutter run
```

來源目錄必須是 `{z}\{x}\{y}.png`，而且只接受原生 zoom 10–16。匯入後必須重新 build，因為 Flutter assets 是建置時打包。

## 圖資授權與容量

不要用批量腳本直接下載 `tile.openstreetmap.org`；OSM 官方公開 tile server 並非離線圖包分發服務。應使用可供離線匯出的供應商，或自行由 OpenStreetMap 資料渲染瓦片，並保留 `© OpenStreetMap contributors` 署名。

全港 raster tiles 仍會明顯增加 App 容量。正式發佈前應按實際需要裁切香港邊界、壓縮 PNG，並檢查 Android App Bundle / iOS 安裝大小。
