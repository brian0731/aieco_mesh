from pathlib import Path
from html import escape
import json
import re

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    BaseDocTemplate, Flowable, Frame, KeepTogether, PageBreak, PageTemplate,
    Paragraph, Spacer, Table, TableStyle,
)
from pypdf import PdfReader


ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "output" / "pdf"
OUT.mkdir(parents=True, exist_ok=True)
PDF_PATH = OUT / "LightMesh_App_Functions_and_Application_Plan_zh_Hant.pdf"
MD_PATH = OUT / "LightMesh_App_Functions_and_Application_Plan_zh_Hant.md"
QA_PATH = ROOT / "tmp" / "pdfs" / "document_qa.json"

pdfmetrics.registerFont(TTFont("TC", "C:/Windows/Fonts/msjh.ttc", subfontIndex=0))
pdfmetrics.registerFont(TTFont("TCB", "C:/Windows/Fonts/msjhbd.ttc", subfontIndex=0))
pdfmetrics.registerFontFamily("TC", normal="TC", bold="TCB", italic="TC", boldItalic="TCB")

INK = colors.HexColor("#1C292B")
TEAL = colors.HexColor("#006E63")
BLUE = colors.HexColor("#335E96")
MUTED = colors.HexColor("#596A6D")
LINE = colors.HexColor("#D8E1E0")
PALE = colors.HexColor("#EDF5F3")
PALEBLUE = colors.HexColor("#EFF3F8")
AMBER = colors.HexColor("#906414")
WHITE = colors.white
PAGE_W, PAGE_H = A4
MARGIN = 43
CONTENT_W = PAGE_W - MARGIN * 2

STYLES = {
    "body": ParagraphStyle(
        "body", fontName="TC", fontSize=10.1, leading=16.3,
        textColor=INK, wordWrap="CJK", spaceAfter=7,
    ),
    "small": ParagraphStyle(
        "small", fontName="TC", fontSize=8.6, leading=13.2,
        textColor=MUTED, wordWrap="CJK", spaceAfter=5,
    ),
    "h1": ParagraphStyle(
        "h1", fontName="TCB", fontSize=23, leading=31,
        textColor=INK, wordWrap="CJK", spaceAfter=10,
    ),
    "h2": ParagraphStyle(
        "h2", fontName="TCB", fontSize=12.2, leading=19,
        textColor=TEAL, wordWrap="CJK", spaceBefore=8, spaceAfter=6,
    ),
    "lead": ParagraphStyle(
        "lead", fontName="TC", fontSize=11.2, leading=18,
        textColor=MUTED, wordWrap="CJK", spaceAfter=13,
    ),
    "table": ParagraphStyle(
        "table", fontName="TC", fontSize=9.1, leading=14.2,
        textColor=INK, wordWrap="CJK", spaceAfter=0,
    ),
    "th": ParagraphStyle(
        "th", fontName="TCB", fontSize=9.1, leading=14.2,
        textColor=WHITE, wordWrap="CJK", spaceAfter=0,
    ),
    "note": ParagraphStyle(
        "note", fontName="TC", fontSize=9.4, leading=15,
        textColor=TEAL, wordWrap="CJK", spaceAfter=0,
    ),
}


def P(text, style="body"):
    markup = escape(text).replace("\n", "<br/>")
    markup = re.sub(
        r"https://[^<\s]+",
        lambda match: f'<link href="{match.group(0)}">{match.group(0)}</link>',
        markup,
    )
    return Paragraph(markup, STYLES[style])


def section(title, text=None):
    return {"kind": "section", "title": title, "text": text}


def para(text, style="body"):
    return {"kind": "para", "text": text, "style": style}


def bullets(*items):
    return {"kind": "bullets", "items": list(items)}


def table(headers, rows, widths=None):
    return {"kind": "table", "headers": headers, "rows": rows, "widths": widths}


def note(text):
    return {"kind": "note", "text": text}


def diagram(kind):
    return {"kind": "diagram", "diagram": kind}


PAGES = [
    {
        "title": "光之協定",
        "subtitle": "社區救生圈 APP｜功能規格與應用方案",
        "cover": True,
        "blocks": [
            para("讓善意成為可交付的支援，讓連結保有自主與餘裕。", "lead"),
            diagram("cover"),
            table(
                ["規劃項目", "本版決策"],
                [
                    ["產品定位", "在傳播光 LightMesh 上，建立居民、志願者與社區機構可共同使用的互助協作層。"],
                    ["核心機制", "負載隔離與備援 / 透明連結與自主退出 / 支持轉譯與資源媒合"],
                    ["交付範圍", "APP 功能、主要畫面、服務與資料設計、應用場景、試點營運及驗收方案。"],
                    ["規劃基線", "2026-10-21｜版本 1.0｜本地程式庫 34b06cc｜pubspec 1.3.0+130"],
                ],
                [0.22, 0.78],
            ),
            note("文件性質：項目規劃建議。既有功能以本地文件及程式結構核對；新增功能、數值門檻、時程與成效目標均為待試點驗證的設計。"),
            para("編製視角：Ka-ra / 項目經理。以清明、可追溯、可中斷的協作規則，承接「光之協定」的共生價值。", "small"),
            section("閱讀索引"),
            para("02-05 頁｜定位、現況、流程與核心模組\n06-10 頁｜容量、授權、媒合、功能與任務狀態\n11-15 頁｜介面、架構、離線、資料與權限\n16-20 頁｜應用場景、交付計畫、驗收與依據", "small"),
        ],
    },
    {
        "title": "產品定位與成功條件",
        "subtitle": "01 / PRODUCT BRIEF",
        "blocks": [
            section("要解決的問題", "社區已有聊天與分享渠道，但需求容易埋在對話中，支援者的可用時間難以掌握；過度承諾、臨時退出與資訊中斷，會讓一項互助停在半途。"),
            table(
                ["使用者", "主要工作", "完成標準"],
                [
                    ["居民 / 求助者", "提出一項具體需求，選擇對象及資料可見範圍。", "知道誰承接、何時交付、未被承接時如何轉介。"],
                    ["支援者 / 志願者", "發布餘裕、接受任務、保留休息及退出權。", "任務不超過自行設定的容量；可追蹤交接。"],
                    ["社區機構 / 物資站", "維護庫存、時段、服務區及備援名單。", "同一物資不被重複承諾，缺口可被看見。"],
                    ["協調員 / 管理者", "處理例外、安排交接、追蹤未完成需求。", "有明確權限、操作原因與事件紀錄。"],
                ],
                [0.19, 0.40, 0.41],
            ),
            section("三項產品承諾"),
            bullets(
                "清明：每筆需求、配對、容量限制與狀態變更，都能說明依據及下一步。",
                "強韌：單項任務或連線故障時，只限制受影響的承諾與資料流，保留其他服務。",
                "共生：支持可轉為物資、時間或技能；無償支援與自願交換均可成立。",
            ),
            section("首版邊界"),
            bullets(
                "優先支援同一社區的日常互助、物資交收、志願者輪值及通訊中斷時的狀態保存。",
                "SOS 提供清晰的求助狀態與外部求助入口；社區回覆、網絡送達與專業救援受理分別標示。",
                "首版以明確規則媒合；Ka-ra 為可追溯的文案與協作介面，不自動判斷心理狀態或承諾救援結果。",
            ),
            note("試點假設：香港單一屋苑或鄰里，100 戶、20 名支援者、1 個合作機構。此為規劃規模，尚未招募或確認合作。"),
        ],
    },
    {
        "title": "既有基礎與功能缺口",
        "subtitle": "02 / BASELINE AND GAP",
        "blocks": [
            para("基線來自目前工作區的 README、Flutter 主程式及平台橋接程式；本次未執行 APP 或裝置連線測試。下列「既有」表示程式中存在相關實作，並非生產環境能力保證。", "small"),
            table(
                ["能力", "本地程式已見", "本方案新增 / 強化"],
                [
                    ["身份與社區", "顯示身份、暱稱、光團、帳號與私隱入口。", "角色權限、社區成員確認、服務區及代理操作授權。"],
                    ["聊天與連線", "WebSocket relay、LAN TCP/UDP、轉發、部分聊天 ACK。", "任務事件回執、持久化待送佇列、能力協商、敏感資料隔離。"],
                    ["求助", "MeshHelpRequest；active / resolved；可關聯 SOS。", "需求分類、期限、承接人、交接、取消及雙方完成確認。"],
                    ["物資與交換", "MeshSupply；分享 / 交換；available / taken。", "結構化數量、單位、有效期、預約及庫存衝突處理。"],
                    ["位置與活動", "線上地圖、香港離線圖、光點與活動。", "粗略位置預設、逐次授權、短期位置與過期標示。"],
                    ["安全與治理", "封鎖、舉報、內容檢查及管理操作。", "分工授權、簽章與重播防護、安全儲存、操作稽核。"],
                    ["個人餘裕", "未見本方案定義的容量與交接模型。", "容量上限、休息模式、備援名單及恢復確認。"],
                ],
                [0.17, 0.39, 0.44],
            ),
            section("實作依據"),
            bullets(
                "lib/main.dart：MeshChatService、MeshHelpRequest、MeshSupply、MeshRadarActivity，以及帳號、舉報與管理介面。[L1]",
                "ios/Runner/IosWifiMeshBridge.swift：Bonjour / NetService 發現及 includesPeerToPeer 設定。[L2]",
                "android/app/src/main/AndroidManifest.xml：附近裝置權限與 dataSync 前景服務宣告。[L3]",
            ),
            note("沿用目前四個主要分頁：光之網絡、光之通道、光之雷達、社區資訊。新互助流程先置於光之通道；個人容量放在身份入口。"),
        ],
    },
    {
        "title": "資訊架構與主要旅程",
        "subtitle": "03 / EXPERIENCE STRUCTURE",
        "blocks": [
            table(
                ["主要入口", "功能組成", "關鍵狀態"],
                [
                    ["光之通道 / 互助", "需求清單、提供支援、任務詳情、交付與交接。", "待承接、待確認、進行中、待核對、完成、例外。"],
                    ["光之雷達", "地區需求、物資站、光點、求助狀態。", "粗略 / 精確、位置時間、是否過期。"],
                    ["光之網絡", "線上 / 離線、附近節點、同步佇列、重試。", "僅本機、待同步、已送達、受理狀態未知。"],
                    ["社區資訊", "服務時間、聯絡點、官方資訊及機構公告。", "來源、更新時間、服務中 / 暫停。"],
                    ["身份 / 我的容量", "可支援時段、任務上限、休息、授權與退出。", "可接單、接近上限、暫停、交接中。"],
                ],
                [0.23, 0.44, 0.33],
            ),
            section("居民旅程"),
            para("提出需求 → 選擇公開欄位與交付期限 → 收到可用支援 → 雙方確認 → 查看進度 → 確認完成；無人承接時，保留需求並可轉介協調員。"),
            section("支援者旅程"),
            para("設定餘裕 → 查看符合地區與時段的任務 → 核對配對理由 → 接受承諾 → 完成交付；臨時超載時啟動交接並停止新增承諾。"),
            section("協調員旅程"),
            para("查看最少必要資訊 → 找出逾期、缺口與交接事件 → 聯絡已同意的備援 → 確認新承接人 → 記錄結果。敏感內容依個案授權取得。"),
            section("服務狀態分開顯示"),
            table(
                ["通訊狀態", "協作狀態", "交付狀態"],
                [
                    ["已建立 / 待同步 / 對端已收", "待回覆 / 已承接 / 待交接", "待交付 / 待確認 / 已完成"],
                ],
                [0.33, 0.34, 0.33],
            ),
            note("「訊息已送達」只表示對端收件；「有人協助」需要明確承接；「任務完成」需要交付確認。"),
        ],
    },
    {
        "title": "三大核心模組",
        "subtitle": "04 / PROTOCOL TO PRODUCT",
        "blocks": [
            diagram("modules"),
            table(
                ["模組", "觸發與運作", "系統必須維持的條件"],
                [
                    ["A｜負載隔離與備援", "本人按下休息，或自行設定的任務 / 時間 / 物資上限被觸發；暫停新增承諾並提出交接。", "求助入口維持可用；既有任務不被靜默刪除；恢復由本人確認。"],
                    ["B｜透明連結與自主退出", "每次合作建立獨立條款，記錄範圍、期限、資源、資料授權與終止方式。", "任何一方可撤回後續合作；單一連結終止不影響其他合作。"],
                    ["C｜支持轉譯與資源媒合", "將需要與餘裕寫為可交付資源，先過濾資格與容量，再提供可解釋候選。", "供需雙方確認才產生承諾；不把善意或情緒轉為人身評分。"],
                ],
                [0.23, 0.41, 0.36],
            ),
            section("共同執行邏輯"),
            bullets(
                "需求與資源具備唯一識別碼、版本、期限及擁有者。",
                "每次狀態變更附操作者、規則版本、時間與原因；參與者可查看與自身相關的歷程。",
                "容量不足、網絡不可用或權限不足時，回傳明確狀態與可選下一步。",
                "使用者可預覽自動化規則、修改門檻及撤回授權；容量原因預設僅本人可見。",
            ),
            note("「高頻」在產品中轉譯為及時、具體、尊重容量的支持；不作為可量測的生理、心理或靈性指標。"),
        ],
    },
    {
        "title": "模組 A：容量與備援",
        "subtitle": "05 / CAPACITY CONTROL",
        "blocks": [
            section("功能 A01｜我的容量"),
            para("使用者設定可接任務數、可支援時段、每日分鐘數及可提供的資源數量。各限制分開計算，任一項不足即停止相關類別的新承諾。範例：同時最多 2 項任務、今日 60 分鐘；均為可修改的試點預設。"),
            table(
                ["狀態", "觸發", "執行與可見性"],
                [
                    ["可接單", "目前用量低於本人設定上限。", "顯示符合範圍的邀請；預約亦占用容量，避免多次同時接受。"],
                    ["接近上限", "達個人預警門檻，例如 80%。", "只向本人提示；接受下一項前顯示預計用量。"],
                    ["暫停接單", "本人啟動休息，或任一硬上限已滿。", "停止新增派發與邀請；公開僅顯示暫不接受，不顯示原因。"],
                    ["交接中", "本人表示現有任務無法完成。", "建立交接事件；通知任務對方及已授權協調員；備援需自行接受。"],
                    ["恢復中", "本人確認恢復，且有足夠可用容量。", "重新核對未完成與預約項目，再恢復邀請。"],
                ],
                [0.17, 0.34, 0.49],
            ),
            section("功能 A02｜備援池"),
            bullets(
                "備援名單採自願加入，記錄服務類別、地區、時段與可接單上限。",
                "交接依可用容量逐一或分批邀請；未回覆只代表待回覆，不代表已承接。",
                "新承接人與需求方確認後，更新責任歸屬並結束原承諾；交接期間保留時間線。",
                "沒有備援時，標示未承接並通知相關人；不以系統名義保證補位成功。",
            ),
            note("A-AC01：達上限時新增承諾被拒，求助仍可提交。A-AC02：休息模式不自動封鎖居民、不取消其獲取支援的資格。"),
        ],
    },
    {
        "title": "模組 B：透明與可撤回",
        "subtitle": "06 / CONSENT AND CONNECTIONS",
        "blocks": [
            section("功能 B01｜單次合作契約"),
            table(
                ["條款欄位", "規格"],
                [
                    ["參與與範圍", "需求方、支援方、社區、資源類別；每項合作具獨立 connectionId。"],
                    ["交付條件", "數量 / 單位、地點精度、時段、截止時間、是否無償或自願交換。"],
                    ["資料權限", "逐欄設定誰可查看聯絡方式、精確位置、需求細節與進度；預設最少揭露。"],
                    ["期限與退出", "授權到期時間、撤回入口、取消影響及交接方式；修改條款後須重新確認。"],
                    ["完成與爭議", "雙方完成確認、缺交 / 失聯標記、協調員介入範圍與紀錄可見性。"],
                ],
                [0.23, 0.77],
            ),
            section("功能 B02｜撤回與交接"),
            para("提出退出 → 本機立即停止新增承諾與後續分享 → 發布撤回事件 → 通知對方 → 已開工事項進入取消或交接流程 → 確認結果。合作義務不延伸至其他任務，也不以扣除求助資格強迫留任。"),
            section("離線撤回的實際邊界"),
            bullets(
                "撤回先在本機生效；其他裝置要在收到撤回或原授權到期後，才能更新狀態。",
                "敏感資料採短期授權、限對象傳送；不承諾可收回對方已保存的內容或截圖。",
                "離線的不可撤回風險在分享前展示；使用者可改用粗略地區或公共交收點。",
            ),
            section("可追溯與權限範圍"),
            bullets(
                "參與者查看自己的同意版本、進度與撤回紀錄；協調員只見處理個案所需欄位。",
                "管理動作記錄操作者、原因、影響對象及授權依據，並提供申訴入口。",
            ),
            note("B-AC01：單一 connectionId 退出後，其他連結仍有效。B-AC02：修改精確位置授權不能沿用舊版同意。"),
        ],
    },
    {
        "title": "模組 C：把支持變成交付",
        "subtitle": "07 / RESOURCE MATCHING",
        "blocks": [
            table(
                ["支持意圖", "結構化資源", "完成依據"],
                [
                    ["「我可以幫一點忙」", "代領物資 1 次；今天 17:00 至 18:00；限定同屋苑。", "已領取 / 已轉交，由接收方確認。"],
                    ["「我有多餘食物」", "餐食 3 份；交收期限；保存與內容由提供者填寫。", "預約數量與實際交付數量一致。"],
                    ["「我願意陪伴」", "電話或線上陪伴 20 分鐘；雙方約定時段。", "僅記錄是否完成，不記錄對話內容。"],
                    ["「我可以分享技能」", "手機設定協助 30 分鐘；公共地點或遠端。", "需求方確認問題已處理或需再安排。"],
                ],
                [0.25, 0.45, 0.30],
            ),
            section("功能 C01｜需求與提供卡"),
            para("必填：類別、數量與單位、粗略地區、可交付時段、到期時間、可見範圍。選填：技能要求、無償 / 交換條件、備註。精確地址與聯絡方式在雙方同意後才揭露。"),
            section("功能 C02｜可解釋媒合"),
            bullets(
                "先過濾：社區範圍、時段交集、資源仍有效、尚有容量、雙方權限與封鎖設定。",
                "再排序：期限接近程度、同區程度、可完成數量；同條件優先較早提出的需求。",
                "顯示理由，例如「同區、時段重疊 30 分鐘、可提供 2 份」；使用者可改選。",
                "候選只是建議；需求方與提供方確認後，才建立正式承諾與資源預約。",
            ),
            section("功能 C03｜交付與回饋"),
            para("完成後確認交付數量、時間及未完成原因；僅用彙總資料改善服務。既有信用功能不作為基本求助、SOS 或支援資格門檻，也不換算居民價值。"),
            note("C-AC01：同一庫存不能重複確認超額數量。C-AC02：無償支援不要求對等回報；交換條件由雙方逐次確認。"),
        ],
    },
    {
        "title": "APP 功能清單與優先序",
        "subtitle": "08 / MVP BACKLOG",
        "blocks": [
            para("P0：首個社區試點前必須完成。P1：試點後依資料擴充。依賴涉及安全與資料一致性的功能，未驗證前不開放敏感欄位或不可逆確認。", "small"),
            table(
                ["編號 / 優先", "功能與範圍", "主要依賴 / 驗收重點"],
                [
                    ["F01 / P0", "身份、社區與角色；保留既有光點身份。", "機構角色需核驗；新舊身份可映射。"],
                    ["F02 / P0", "需求卡：分類、數量、期限、可見範圍。", "擴充 MeshHelpRequest；取消與到期明確。"],
                    ["F03 / P0", "提供卡：物資、時間、技能及交換條件。", "擴充 MeshSupply；結構化數量與單位。"],
                    ["F04 / P0", "個人容量、休息及停止新增承諾。", "容量預約原子化；本人可恢復。"],
                    ["F05 / P0", "規則媒合、雙方確認與任務追蹤。", "每項結果可解釋；不自動強制派單。"],
                    ["F06 / P0", "單次同意、退出、交接與備援名單。", "權限逐項生效；無備援時維持未承接。"],
                    ["F07 / P0", "待送佇列、去重、過期、衝突處理。", "重開 APP 可恢復；離線預約屬暫定。"],
                    ["F08 / P0", "位置授權、資料保護及操作稽核。", "敏感欄位不進公開 mesh 廣播。"],
                    ["F09 / P0", "協調員待辦、事件處理與彙總成效。", "角色驗證、最少可見及可追溯操作。"],
                    ["F10 / P0", "通知、無障礙與既有功能回歸驗收。", "大字體、拒絕權限、通知停用均可操作。"],
                    ["F11 / P1", "機構批量時段、跨社區轉介。", "跨社區授權、營運容量與資料協議。"],
                    ["F12 / P1", "Ka-ra 文字整理與自選語言協助。", "預覽並確認；敏感內容處理另行授權。"],
                ],
                [0.18, 0.42, 0.40],
            ),
            note("不列入首版：自動心理診斷、居民綜合評分、金錢結算、保證常駐的手機中繼、未經授權的精確位置追蹤。"),
        ],
    },
    {
        "title": "任務生命週期與例外",
        "subtitle": "09 / STATES AND ACCEPTANCE",
        "blocks": [
            diagram("states"),
            table(
                ["動作", "誰可執行", "狀態與一致性要求"],
                [
                    ["建立 / 發布", "需求方或明確授權的代辦者。", "草稿 → 待承接；未同步時顯示僅本機 / 待傳送。"],
                    ["提出承接", "具可用容量的支援者。", "待承接 → 待雙方確認；預約有期限且占用容量。"],
                    ["確認合作", "需求方與支援方。", "待確認 → 進行中；記錄同意版本與資源預約。"],
                    ["完成 / 核對", "支援方回報，需求方核對。", "進行中 → 待核對 → 完成；未回覆保留待核對。"],
                    ["退出 / 取消", "任一參與者可提出。", "標記取消或待交接；保留已交付數量與退出時間。"],
                    ["到期 / 失聯", "依公開規則標示，協調員處理。", "未承接需求到期後停止媒合；進行中項目轉例外，不直接判定完成。"],
                ],
                [0.19, 0.30, 0.51],
            ),
            section("必要例外路徑"),
            bullets(
                "E01｜無人承接：到提醒時間後通知需求方；經同意可送協調員待辦，不產生假承接。",
                "E02｜提供者超載：停止新增邀請；原任務維持可見，等待取消或雙方確認交接。",
                "E03｜兩人同搶最後一份物資：僅擁有者 / 權威服務可確認一筆；另一筆回到候選。",
                "E04｜完成爭議：標記待協調；各方查看自己的交付紀錄，管理者不能單方抹除歷程。",
                "E05｜SOS：顯示網絡狀態、有效時間與回覆者身份；外部求助受理需獨立確認。",
            ),
            note("任務逾期、訊息 ACK、信用分與 SOS 關閉，都不能單獨觸發「服務已完成」。"),
        ],
    },
    {
        "title": "主要畫面示意",
        "subtitle": "10 / APP WIREFRAMES",
        "blocks": [
            para("以下為新增功能的流程示意，採用示例資料；不是既有 APP 截圖。保留原有主要分頁，避免新舊協作入口並行造成重複。", "small"),
            diagram("wireframes"),
            table(
                ["畫面", "主要操作", "必要狀態"],
                [
                    ["互助清單", "提出需求 / 提供支援；依類別、地區與期限篩選。", "空清單、無符合結果、待同步、資料過期。"],
                    ["任務詳情", "查看條件與配對理由；接受、取消、交接、完成。", "待雙方確認、已被承接、容量不足、權限不足。"],
                    ["我的容量", "修改上限與時段；啟動休息；處理待交接。", "上限已滿、休息中、尚有未完成任務。"],
                ],
                [0.19, 0.44, 0.37],
            ),
            section("易用性與無障礙驗收"),
            bullets(
                "關鍵任務提供文字與圖示；狀態不只依顏色區分；支援螢幕閱讀器與放大字體。",
                "提供繁體中文；沿用專案既有語言機制，其他語言內容與流程同步驗收。",
                "位置與聯絡資訊分次授權；拒絕定位仍可手動選地區及公共交收點。",
                "通知被關閉時，APP 內仍有待辦；取消、退出與求助入口保持可找到。",
            ),
        ],
    },
    {
        "title": "應用架構與既有整合",
        "subtitle": "11 / SYSTEM ARCHITECTURE",
        "blocks": [
            diagram("architecture"),
            table(
                ["層級", "設計決策", "與現有程式的關係"],
                [
                    ["Flutter 體驗層", "互助清單、容量、任務與同意介面。", "沿用主要分頁與翻譯機制。"],
                    ["領域邏輯層", "Capacity、Consent、Matching、Task 四個獨立服務。", "新規則先抽離；不在 main.dart 再堆疊所有業務邏輯。"],
                    ["本機資料層", "具交易能力的資料庫、待送事件、版本與回執。", "SharedPreferences 保留一般偏好；敏感資料與金鑰另用安全儲存。[S5]"],
                    ["傳輸介面層", "統一傳送 / 接收 / 狀態回報；接 WebSocket 與 LAN。", "保留 MeshChatService 傳輸能力；新增事件處理可獨立測試。"],
                    ["社區服務層", "建議增設身份、角色、任務、庫存及稽核 API。", "現有 relay 以廣播為主；不直接視為授權或庫存交易服務。[L4]"],
                ],
                [0.19, 0.43, 0.38],
            ),
            section("部署與安全開關"),
            bullets(
                "分開 development、staging、pilot；新功能由社區層級開關逐步啟用。",
                "公開清單與私密任務細節分開傳輸；私密內容需驗證對象、權限與加密路徑。",
                "伺服器異常時停止新增遠端確認，保留本機查看、編輯草稿與待送事件。",
                "機構端首版採小型受權工作台；API 及資料庫技術選型由既有運維能力決定。",
            ),
            note("所有新增 API、資料庫與安全機制均為本方案建議，尚未在本次工作中實作或部署。"),
        ],
    },
    {
        "title": "離線協作與資料完整性",
        "subtitle": "12 / OFFLINE AND RELIABILITY",
        "blocks": [
            section("封包與事件規則"),
            bullets(
                "事件封套包含 eventId、schemaVersion、actorId、entityId、entityVersion、createdAt、expiresAt、visibility 與驗證資訊。",
                "訊息 ID 去重；擁有者遞增版本排序；設定期限與轉發上限；敏感狀態不單靠裝置時間排序。",
                "控制與私密事件驗證發送者、權限、有效期及重播；採成熟加密實作並完成審查後才開放。",
                "未知版本保留原始事件於隔離佇列，顯示無法處理；不把新任務資料降級成公開聊天內容。",
            ),
            table(
                ["情況", "處理規則"],
                [
                    ["斷網 / APP 重開", "資料先寫入本機交易與待送佇列；重試沿用同一 eventId；回執前顯示待同步。"],
                    ["離線庫存與容量", "預約先暫定；每項資源同時僅一個指定權威可確認。權威移交先凍結確認並完成交接；斷線時不另立確認來源。"],
                    ["多方同時修改", "任務同意採版本比對；庫存與容量採單一權威確認。衝突回到待確認，不靜默覆寫。"],
                    ["退出 / 撤回", "優先同步撤回與取消事件；接收端見到後停止後續操作。斷線對端仍受原有效期限制。"],
                    ["重複 / 過期 / 舊包", "去重、拒絕過期、拒絕倒退版本；維持取消墓碑至事件保留期結束，避免舊包復活。"],
                ],
                [0.27, 0.73],
            ),
            section("平台實測邊界"),
            para("Android Wi-Fi Direct 權限依平台版本處理；dataSync 前景服務存在時限條件。iOS 本地網絡需取得使用者授權，背景執行也受系統調度限制。因此手機不能被承諾為全天候可靠中繼。[S1-S4]"),
            note("R-AC01：離線提交、重開及恢復連線後不重複建立任務。R-AC02：超時、拒絕權限、撤回晚到與舊版節點，都有可辨識的狀態。"),
        ],
    },
    {
        "title": "資料模型與服務介面",
        "subtitle": "13 / DATA AND API CONTRACTS",
        "blocks": [
            table(
                ["實體", "核心欄位", "擁有者 / 變更規則"],
                [
                    ["Member", "id、communityId、role、displayName、status", "身份服務驗證角色；顯示名不等於權限憑證。"],
                    ["Need / Offer", "id、ownerId、category、quantity、unit、area、timeWindow、expiresAt", "發布者維護內容與版本；精確地址分欄保護。"],
                    ["Capacity", "memberId、limits、reserved、used、availability、version", "本人設定上限；確認承諾由權威交易更新。"],
                    ["Connection / Consent", "parties、scope、fields、expiresAt、consentVersion、revokedAt", "雙方逐版確認；撤回記錄不可被舊版覆蓋。"],
                    ["Task / Reservation", "needId、offerId、parties、status、quantity、handoverId、version", "合法狀態轉移、容量檢查與庫存預約一起提交。"],
                    ["Event / Receipt", "eventId、entityId、actor、version、type、expiry、receiptStatus", "去重、驗證、稽核；內容與存取權限分開。"],
                ],
                [0.21, 0.47, 0.32],
            ),
            section("建議 API 與事件"),
            table(
                ["操作", "建議介面", "契約重點"],
                [
                    ["建立需求 / 提供", "POST /v1/needs 或 /v1/offers", "冪等鍵、社區範圍、欄位驗證。"],
                    ["預約 / 確認", "POST /v1/tasks/{id}/accept", "需版本與同意；容量、庫存原子更新。"],
                    ["交接 / 撤回", "POST /v1/tasks/{id}/handover\nPOST /v1/connections/{id}/revoke", "驗證參與者；附原因及作用範圍。"],
                    ["同步與回執", "POST /v1/events；GET /v1/events?cursor=...", "增量游標、去重回執、權限過濾。"],
                ],
                [0.21, 0.43, 0.36],
            ),
            para("事件名稱建議：need.created、offer.updated、task.accepted、capacity.paused、handover.requested、consent.revoked、task.completed。以上為領域事件，尚未定義為現有 aieco.light.* 封包。", "small"),
            note("相容策略：握手宣告能力與版本；舊版仍可聊天及瀏覽原有資料；新任務必須由支援新規格的端點明確確認。"),
        ],
    },
    {
        "title": "權限、私隱與社區治理",
        "subtitle": "14 / PERMISSIONS AND OPERATIONS",
        "blocks": [
            table(
                ["資料 / 操作", "本人", "合作對方", "協調員", "其他成員"],
                [
                    ["粗略需求與地區", "編輯", "依公開範圍", "依公開範圍", "依公開範圍"],
                    ["聯絡與精確位置", "授權", "逐次同意", "個案授權", "不可見"],
                    ["容量上限與原因", "可見 / 修改", "僅可接狀態", "僅可接狀態", "僅可接狀態"],
                    ["任務與交接歷程", "自己的個案", "自己的個案", "獲派個案", "不可見"],
                    ["角色與管理處置", "查看自身結果", "查看自身結果", "按職責操作", "僅必要公告"],
                ],
                [0.28, 0.16, 0.20, 0.20, 0.16],
            ),
            section("資料生命週期｜以下為試點建議"),
            bullets(
                "精確位置：每次同意後最長分享 30 分鐘；逾期停止展示，無必要即清除可還原內容。",
                "已完成任務：建議保留 90 日供參與者處理爭議；稽核與統計另行最小化並定期覆核。",
                "記錄與備份：敏感欄位遮罩；設定刪除時程、權限及備份過期策略，避免刪除後無期限復原。",
                "刪除帳號：停止新分享、處理未完成承諾、移除可識別資料；保留項目與理由向本人列明。",
            ),
            section("營運責任"),
            bullets(
                "社區機構：確認服務範圍、值班時段、備援數量與實體交收點。",
                "協調員：追蹤例外、驗證交接與回覆舉報；不得以管理權限任意查看全部私密資料。",
                "技術團隊：角色驗證、資料保護、備份還原、故障通報及部署回退。",
                "機構上線前確認所在地適用的資料、服務及保留要求；本文件不作合規認證。",
            ),
            note("個人封鎖與接單暫停分開：封鎖保護雙方邊界；求助可由有授權的協調渠道承接，不對被封鎖對象強制送達。"),
        ],
    },
    {
        "title": "應用方案：日常互助",
        "subtitle": "15 / EVERYDAY APPLICATIONS",
        "blocks": [
            section("場景 A｜餐食與日用品互助"),
            table(
                ["項目", "運作方案"],
                [
                    ["參與者與入口", "居民提出「晚餐 1 份，18:30 前」；機構發布當日可提供數量；鄰里可承接交收。"],
                    ["運作流程", "需求卡 → 同區與時段媒合 → 預約物資與支援者時間 → 雙方確認 → 公共交收點交付。"],
                    ["關鍵例外", "物資不足則部分交付或保持缺口；支援者退出則交接；需求方未核對則維持待確認。"],
                    ["所需資源", "一個有人管理的交收點、機構庫存負責人、可用輪值時段及清楚的物資說明。"],
                    ["成效觀察", "交付率、浪費量、未承接需求、重複預約衝突；無須公開求助者的困境原因。"],
                ],
                [0.24, 0.76],
            ),
            section("場景 B｜時間與技能支援"),
            table(
                ["項目", "運作方案"],
                [
                    ["參與者與入口", "居民提出手機設定、代領物資或約定時段的電話陪伴需求。"],
                    ["運作流程", "填寫工作與時間 → 支援者預覽需求 → 確認容量與資料權限 → 約定完成標準 → 核對結果。"],
                    ["關鍵例外", "服務範圍改變時重訂條件；支援者只剩 15 分鐘，可改約或轉介，不被自動加派。"],
                    ["所需資源", "服務清單、可聯絡時段、公共會面點與有同意的備援名單。"],
                    ["成效觀察", "按時完成率、支援者自評容量、臨時退出及交接成功率；陪伴內容不進紀錄。"],
                ],
                [0.24, 0.76],
            ),
            note("啟動順序：先做機構可穩定供應的少量類別，再按實際承接率擴充；宣傳規模跟隨服務容量。"),
        ],
    },
    {
        "title": "應用方案：韌性與永續",
        "subtitle": "16 / RESILIENCE AND SUSTAINABILITY",
        "blocks": [
            section("場景 C｜通訊中斷與社區協調"),
            table(
                ["項目", "運作方案"],
                [
                    ["啟動條件", "外網不可用或服務失聯；APP 顯示可用的本地連線與最後同步時間。"],
                    ["運作流程", "連至現場已可互通的 LAN → 查看本機清單與時間 → 建立最少必要需求 → 待送 / 對端收件 → 人員確認承接。"],
                    ["機構配置", "經測試的現場網絡、供電與值班聯絡點；紙本名單及公共公告作備援。"],
                    ["承諾邊界", "離線庫存採暫定；顯示位置時效；不假設每部手機都能跨網橋接或持續背景轉發。[L0][S2-S4]"],
                    ["驗證方式", "分別測試前景、背景、鎖屏、斷電與網絡分割；逐項記錄可達範圍及失敗狀態。"],
                ],
                [0.24, 0.76],
            ),
            section("場景 D｜循環物資與社區活動"),
            table(
                ["項目", "運作方案"],
                [
                    ["參與者與入口", "居民分享可再用日用品；機構發布修繕、清潔或回收活動與名額。"],
                    ["運作流程", "物資 / 活動卡 → 確認狀況與名額 → 預約交收或參與時段 → 交付 → 更新可用數量。"],
                    ["關鍵例外", "過期下架、未到場釋出名額、物品狀況不符轉為待協調，不直接扣減基本求助權。"],
                    ["成效觀察", "再使用件數、實際完成參與時數、未取走數量與重複刊登率。"],
                ],
                [0.24, 0.76],
            ),
            note("永續共生的量測聚焦資源是否被使用、需求是否被承接、支援者是否仍有餘裕；不以訊息量或居民排名取代成果。"),
        ],
    },
    {
        "title": "12 週交付與試點營運",
        "subtitle": "17 / DELIVERY ROADMAP",
        "blocks": [
            para("以下從正式啟動日起算，不代表已承諾上線日期。以兩名 Flutter、一名後端及部分時間的 QA、UX、PM 與社區營運協作規劃；既有系統與安全評估結果會影響排期。", "small"),
            table(
                ["階段", "工作與負責", "關卡 / 交付"],
                [
                    ["第 1-2 週", "PM + UX + 社區：訪談、服務盤點、需求 / 容量規則；工程：身份、安全與離線實驗。", "G1：流程、資料與試點範圍確認；高風險技術有實驗結果。"],
                    ["第 3-4 週", "Flutter + 後端：需求 / 提供卡、角色、任務狀態、資料庫與基本介面。", "G2：端到端完成一次建立、承接與取消。"],
                    ["第 5-6 週", "工程：容量、同意、撤回、交接、庫存一致性及事件同步。", "G3：併發與離線例外通過；敏感資料保護可驗證。"],
                    ["第 7-8 週", "QA + 工程 + 社區：裝置矩陣、無障礙、權限拒絕、操作演練與回退。", "G4：P0 驗收；未完成安全項目維持關閉。"],
                    ["第 9-12 週", "營運 + PM：先 20 戶與 5 名支援者，再依容量分階段擴至假設規模。", "G5：四週觀察，決定延長、調整或擴區。"],
                ],
                [0.17, 0.47, 0.36],
            ),
            section("營運節奏"),
            bullets(
                "每日：更新服務時段與庫存；查看逾期、交接及無人承接需求；完成值班交接。",
                "每週：檢查退出原因、支援者餘裕、資料存取與誤派事件；調整容量及邀請範圍。",
                "故障時：暫停新確認、保留既有任務與本機資料；以已公告聯絡點接續服務。",
            ),
            section("資源與預算模型"),
            para("規劃投入：Flutter 2、後端 1、QA 0.5、UX 0.3、PM 0.4、營運 0.3，共 4.5 個全職當量。若全期 60 個工作日，基準約 270 人日；20% 預備量後約 324 人日，屬配置假設而非報價。"),
            para("成本 = 各角色人日 × 核准內部日成本 + 託管 / 通訊 + 測試設備 + 社區營運。外包費、設備採購、平台費與維護期另行詢價；每週依實際投入重估。", "small"),
        ],
    },
    {
        "title": "成效、驗收與風險決策",
        "subtitle": "18 / MEASUREMENT AND RELEASE GATES",
        "blocks": [
            table(
                ["量測項目", "定義 / 試點目標假設"],
                [
                    ["有效需求完成率", "期限內雙方確認完成的需求 / 有效已發布需求；觀察目標 ≥70%，另列無人承接與撤回。"],
                    ["首次承接時間", "限服務時段內，從成功發布至首次明確承接；中位數目標 ≤60 分鐘，另報未承接比例。"],
                    ["容量保護", "因系統確認造成的超額承諾為 0；以交易紀錄與併發測試判定。"],
                    ["同步完整性", "固定測試集中的有效事件，在可達連線恢復後無遺失、無重複生效；未送達清楚標示。"],
                    ["可退出性", "退出後新邀請停止；離線對端同步 / 到期邊界可驗證；追蹤交接成功率。"],
                    ["支援者可持續性", "每週自願回報可承受程度與休息需求；只用彙總趨勢，不產生個人排名。"],
                ],
                [0.26, 0.74],
            ),
            section("發布前必要驗收"),
            bullets(
                "兩名支援者同時接受同一資源；不得出現超額確認或重複扣庫存。",
                "斷網、重開 APP、重試及回執晚到；不得重複建立任務或恢復已撤回授權。",
                "偽造身份、越權管理、舊版同意與重播事件；被拒且保留最少必要稽核。",
                "實機測試 iOS / Android 的前景、背景、鎖屏與拒絕權限；不得顯示假送達。",
                "大字體、螢幕閱讀器、無定位與無通知情境可完成需求、退出及查看待辦。",
            ),
            section("風險與項目決策"),
            table(
                ["風險", "控制 / 決策人"],
                [
                    ["供給不足 / 志願者超載", "先限制服務類別與招募規模；社區負責人確認備援能力。"],
                    ["離線、庫存或授權衝突", "暫定預約、單一權威確認與短期授權；技術負責人驗證。"],
                    ["資料外洩 / 角色越權", "安全開關、權限及加密審查；未過關不開私密資料流程。"],
                    ["社區流程未準備好", "確認值班、聯絡點及交接責任後才招募；PM 決定試點準備度。"],
                ],
                [0.34, 0.66],
            ),
        ],
    },
    {
        "title": "依據、假設與啟動清單",
        "subtitle": "19 / REFERENCES AND NEXT DECISIONS",
        "blocks": [
            section("本地依據｜檢視日期 2026-10-21"),
            para("[L0] README.md：產品功能、線上 / 離線模式及 app-layer mesh 邊界。\n[L1] lib/main.dart：MeshChatService、MeshHelpRequest、MeshSupply、MeshRadarActivity、身份與安全介面。\n[L2] ios/Runner/IosWifiMeshBridge.swift：Bonjour 及 peer-to-peer 發現設定。\n[L3] android/app/src/main/AndroidManifest.xml：附近裝置與前景服務宣告。\n[L4] docs/WEBSOCKET_RELAY_PROMPT.md：現有 relay 的廣播定位；不是資料庫或授權服務規格。\n[L5] pubspec.yaml：Flutter 專案、依賴與本地版本 1.3.0+130。", "small"),
            section("外部技術依據｜查閱日期 2026-10-21"),
            para("[S1] Android Developers｜Wi-Fi Direct (peer-to-peer or P2P) overview\nhttps://developer.android.com/develop/connectivity/wifi/wifi-direct\n[S2] Android Developers｜Foreground service timeouts\nhttps://developer.android.com/develop/background-work/services/fgs/timeout\n[S3] Apple Developer｜TN3179: Understanding local network privacy\nhttps://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy\n[S4] Apple Developer｜Extending your app’s background execution time\nhttps://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time\n[S5] OWASP MASVS｜MASVS-STORAGE\nhttps://mas.owasp.org/MASVS/05-MASVS-STORAGE/", "small"),
            section("尚待確認的項目"),
            table(
                ["決策", "建議負責人 / 產出"],
                [
                    ["試點社區與合作機構", "項目發起人：服務範圍、招募名單、實體聯絡點。"],
                    ["容量、保留期及服務時間", "PM + 社區營運：可修改的試點參數與責任表。"],
                    ["部署、身份與安全方案", "技術負責人：角色模型、資料保護方案與驗證結果。"],
                    ["時程、預算及量測目標", "項目發起人 + PM：核准配置、基線與階段驗收日期。"],
                ],
                [0.37, 0.63],
            ),
            note("啟動交付包：選定一個社區、兩項服務、明確的值班與備援名單；先完成一次需求、承接、退出與交接演練，再開放居民試用。"),
        ],
    },
]


def draw_text(c, text, x, y, size=10, bold=False, color=INK):
    c.setFillColor(color)
    c.setFont("TCB" if bold else "TC", size)
    c.drawString(x, y, text)


def box(c, x, y, w, h, title, lines, fill=PALE, title_color=TEAL, size=9.3):
    c.setFillColor(fill)
    c.setStrokeColor(LINE)
    c.roundRect(x, y, w, h, 4, fill=1, stroke=1)
    draw_text(c, title, x + 13, y + h - 23, size + 1, True, title_color)
    for idx, line in enumerate(lines):
        draw_text(c, line, x + 13, y + h - 44 - idx * 15, size=size)


def arrow(c, x1, y1, x2, y2, color=TEAL):
    c.setStrokeColor(color)
    c.setFillColor(color)
    c.setLineWidth(1.2)
    c.line(x1, y1, x2, y2)
    path = c.beginPath()
    path.moveTo(x2, y2)
    if abs(x2 - x1) >= abs(y2 - y1):
        direction = 1 if x2 >= x1 else -1
        path.lineTo(x2 - 5 * direction, y2 + 3)
        path.lineTo(x2 - 5 * direction, y2 - 3)
    else:
        direction = 1 if y2 >= y1 else -1
        path.lineTo(x2 - 3, y2 - 5 * direction)
        path.lineTo(x2 + 3, y2 - 5 * direction)
    path.close()
    c.drawPath(path, stroke=0, fill=1)


class Graphic(Flowable):
    HEIGHTS = {
        "cover": 159, "modules": 140, "states": 100,
        "architecture": 206, "wireframes": 307,
    }

    def __init__(self, kind):
        super().__init__()
        self.kind = kind
        self.width = CONTENT_W
        self.height = self.HEIGHTS[kind]

    def draw(self):
        c, w, h = self.canv, self.width, self.height
        if self.kind == "cover":
            draw_text(c, "LIGHTMESH  /  COMMUNITY LIFEBUOY", 0, h - 14, 9, True, TEAL)
            cell = (w - 24) / 3
            names = [
                ("01  保有餘裕", ["容量限制", "休息與備援"]),
                ("02  自主連結", ["單次同意", "退出與交接"]),
                ("03  支持落地", ["物資 / 時間 / 技能", "媒合與交付"]),
            ]
            for i, (name, lines) in enumerate(names):
                box(c, i * (cell + 12), 24, cell, 102, name, lines,
                    PALE if i != 1 else PALEBLUE, TEAL if i != 1 else BLUE)
            c.setStrokeColor(TEAL)
            c.setLineWidth(1)
            c.line(0, 7, w, 7)
        elif self.kind == "modules":
            cell = (w - 24) / 3
            data = [
                ("A  容量", ["可承諾多少？", "暫停 / 交接 / 恢復"]),
                ("B  連結", ["同意分享甚麼？", "授權 / 到期 / 撤回"]),
                ("C  資源", ["能交付甚麼？", "媒合 / 預約 / 核對"]),
            ]
            for i, (title, lines) in enumerate(data):
                box(c, i * (cell + 12), 35, cell, 94, title, lines,
                    PALE if i != 1 else PALEBLUE, size=8.8)
                if i < 2:
                    arrow(c, (i + 1) * cell + i * 12 + 2, 81,
                          (i + 1) * (cell + 12) - 2, 81)
            draw_text(c, "共同底層：身份驗證 / 事件紀錄 / 權限 / 離線狀態", 4, 13, 10, True, BLUE)
        elif self.kind == "states":
            labels = ["待承接", "待確認", "進行中", "待核對", "完成"]
            cell = (w - 64) / 5
            for i, label in enumerate(labels):
                x = i * (cell + 16)
                c.setFillColor(PALE if i < 4 else TEAL)
                c.setStrokeColor(LINE)
                c.roundRect(x, 52, cell, 31, 3, fill=1, stroke=1)
                draw_text(c, label, x + (cell - pdfmetrics.stringWidth(label, "TCB", 10)) / 2,
                          63, 10, True, INK if i < 4 else WHITE)
                if i < 4:
                    arrow(c, x + cell + 2, 68, x + cell + 14, 68)
            draw_text(c, "分支：取消 / 到期 / 待交接 / 待協調", 2, 27, 10, True, BLUE)
            draw_text(c, "每次變更保留版本、同意依據與操作紀錄。", 2, 8, 9, color=MUTED)
        elif self.kind == "architecture":
            box(c, 0, 153, w, 48, "Flutter APP｜居民 / 支援者 / 協調員", [], PALEBLUE)
            arrow(c, w / 2, 150, w / 2, 141)
            box(c, 0, 91, w, 48, "領域服務｜Capacity / Consent / Matching / Task", [])
            arrow(c, w / 2, 88, w / 2, 78)
            half = (w - 18) / 2
            box(c, 0, 12, half, 63, "本機資料與待送事件", ["交易 / 去重 / 期限 / 回執"], size=8.8)
            box(c, half + 18, 12, half, 63, "受權服務與傳輸", ["身份 / 任務庫存 / WebSocket / LAN"], PALEBLUE, BLUE, 8.3)
            arrow(c, half + 2, 42, half + 16, 42, BLUE)
        elif self.kind == "wireframes":
            phone_w = (w - 26) / 3
            for i in range(3):
                x = i * (phone_w + 13)
                c.setStrokeColor(LINE)
                c.setFillColor(WHITE)
                c.roundRect(x, 9, phone_w, 286, 7, fill=1, stroke=1)
                c.setFillColor(PALEBLUE if i == 1 else PALE)
                c.rect(x + 1, 253, phone_w - 2, 31, fill=1, stroke=0)
                draw_text(c, "09:41", x + 11, 279, 6.8, color=MUTED)
                title = ["光之通道", "任務詳情", "我的容量"][i]
                draw_text(c, title, x + 11, 263, 11, True, TEAL)
            x = 0
            draw_text(c, "互助   聊天   物資", x + 11, 237, 8.4, True)
            draw_text(c, "九龍城    今日", x + 11, 217, 8.2, color=MUTED)
            box(c, x + 9, 136, phone_w - 18, 67, "需要晚餐 1 份",
                ["今天 18:30 前", "待承接"], size=8)
            box(c, x + 9, 57, phone_w - 18, 67, "可代領物資",
                ["17:00 - 18:00", "尚有 1 個時段"], PALEBLUE, BLUE, 8)
            draw_text(c, "網絡   通道   雷達   資訊", x + 9, 25, 7.6, color=MUTED)
            x = phone_w + 13
            draw_text(c, "需要晚餐 1 份", x + 11, 232, 10, True)
            for j, line in enumerate(["地區  九龍城", "交付  18:30 前", "地點  確認後分享", "方式  無償支援"]):
                draw_text(c, line, x + 11, 210 - j * 18, 8.3)
            c.setStrokeColor(LINE)
            c.line(x + 11, 142, x + phone_w - 11, 142)
            draw_text(c, "配對理由", x + 11, 127, 8.8, True, BLUE)
            draw_text(c, "同區 / 時段相符", x + 11, 110, 8.3)
            draw_text(c, "尚有 1 項可接容量", x + 11, 94, 8.3)
            c.setFillColor(TEAL)
            c.roundRect(x + 11, 48, phone_w - 22, 28, 3, fill=1, stroke=0)
            draw_text(c, "願意協助", x + 48, 58, 9, True, WHITE)
            draw_text(c, "待雙方確認後成立", x + 20, 28, 7.8, color=MUTED)
            x = 2 * (phone_w + 13)
            for j, line in enumerate(["今日可支援  60 分鐘", "同時任務上限  2 項", "目前進行中  1 項"]):
                draw_text(c, line, x + 11, 231 - j * 24, 8.6)
            c.setFillColor(PALE)
            c.roundRect(x + 11, 133, phone_w - 22, 29, 3, fill=1, stroke=0)
            draw_text(c, "可接單", x + 51, 143, 9, True, TEAL)
            c.setStrokeColor(TEAL)
            c.roundRect(x + 11, 89, phone_w - 22, 28, 3, fill=0, stroke=1)
            draw_text(c, "暫停接單", x + 45, 99, 9, True, TEAL)
            draw_text(c, "待交接  0 項", x + 11, 64, 8.8, True)
            draw_text(c, "我的授權與連結", x + 11, 40, 8.6, color=BLUE)


def render_table(block):
    widths = block["widths"] or [1 / len(block["headers"])] * len(block["headers"])
    data = [[P(value, "th") for value in block["headers"]]]
    data += [[P(str(value), "table") for value in row] for row in block["rows"]]
    widget = Table(data, colWidths=[CONTENT_W * v for v in widths], repeatRows=1, hAlign="LEFT")
    widget.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), TEAL),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 9),
        ("RIGHTPADDING", (0, 0), (-1, -1), 9),
        ("TOPPADDING", (0, 0), (-1, -1), 7),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 7),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [WHITE, colors.HexColor("#F5F8F8")]),
        ("LINEBELOW", (0, 0), (-1, 0), 0.5, TEAL),
        ("LINEBELOW", (0, 1), (-1, -1), 0.4, LINE),
    ]))
    return [widget, Spacer(1, 9)]


def render_block(block):
    kind = block["kind"]
    if kind == "section":
        flow = [P(block["title"], "h2")]
        if block["text"]:
            flow.append(P(block["text"]))
        return flow
    if kind == "para":
        return [P(block["text"], block["style"])]
    if kind == "bullets":
        flow = []
        for value in block["items"]:
            row = Table([[P("-", "body"), P(value)]], colWidths=[13, CONTENT_W - 13])
            row.setStyle(TableStyle([
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 0),
                ("RIGHTPADDING", (0, 0), (-1, -1), 0),
                ("TOPPADDING", (0, 0), (-1, -1), 0),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
            ]))
            flow.append(row)
        return flow
    if kind == "table":
        return render_table(block)
    if kind == "note":
        widget = Table([[P(block["text"], "note")]], colWidths=[CONTENT_W])
        widget.setStyle(TableStyle([
            ("BACKGROUND", (0, 0), (-1, -1), PALE),
            ("BOX", (0, 0), (-1, -1), 0.5, LINE),
            ("LEFTPADDING", (0, 0), (-1, -1), 11),
            ("RIGHTPADDING", (0, 0), (-1, -1), 11),
            ("TOPPADDING", (0, 0), (-1, -1), 10),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 10),
        ]))
        return [Spacer(1, 5), widget, Spacer(1, 7)]
    if kind == "diagram":
        return [Graphic(block["diagram"]), Spacer(1, 6)]
    raise ValueError(kind)


def page_chrome(c, doc):
    c.saveState()
    page = doc.page
    if page <= len(PAGES):
        c.bookmarkPage(f"page-{page}")
        c.addOutlineEntry(PAGES[page - 1]["title"], f"page-{page}", level=0)
    c.setFillColor(WHITE)
    c.rect(0, 0, PAGE_W, PAGE_H, fill=1, stroke=0)
    if page != 1:
        draw_text(c, "LIGHTMESH", MARGIN, PAGE_H - 29, 8.2, True, TEAL)
        label = "光之協定 / APP 功能與應用方案"
        c.setFont("TC", 8)
        c.setFillColor(MUTED)
        c.drawRightString(PAGE_W - MARGIN, PAGE_H - 29, label)
        c.setStrokeColor(LINE)
        c.line(MARGIN, PAGE_H - 39, PAGE_W - MARGIN, PAGE_H - 39)
    c.setStrokeColor(LINE)
    c.line(MARGIN, 40, PAGE_W - MARGIN, 40)
    draw_text(c, "2026-10-21  /  規劃建議 v1.0", MARGIN, 25, 7.5, color=MUTED)
    c.setFont("TC", 8.4)
    c.drawRightString(PAGE_W - MARGIN, 25, f"{page:02d} / {len(PAGES):02d}")
    c.restoreState()


def build_pdf():
    doc = BaseDocTemplate(
        str(PDF_PATH), pagesize=A4,
        title="光之協定｜社區救生圈 APP 功能規格與應用方案",
        author="Ka-ra | LightMesh project planning",
        subject="LightMesh community mutual-aid app feature specification and application plan",
        pageCompression=1,
    )
    frame = Frame(MARGIN, 53, CONTENT_W, PAGE_H - 110,
                  leftPadding=0, rightPadding=0, topPadding=0, bottomPadding=0, id="body")
    doc.addPageTemplates([PageTemplate(id="report", frames=[frame], onPage=page_chrome)])
    story = []
    for idx, page in enumerate(PAGES):
        if idx:
            story.append(PageBreak())
        if page.get("cover"):
            story += [Spacer(1, 27), P("LIGHT PROTOCOL / PRODUCT & APPLICATION", "small")]
            cover_style = ParagraphStyle(
                "cover", parent=STYLES["h1"], fontSize=39, leading=52, spaceAfter=5,
            )
            story += [Paragraph(page["title"], cover_style), P(page["subtitle"], "h2"), Spacer(1, 8)]
        else:
            story += [P(page["subtitle"], "small"), P(page["title"], "h1")]
        for block in page["blocks"]:
            story += render_block(block)
    doc.build(story)


def build_markdown():
    lines = [
        "# 光之協定：社區救生圈 APP 功能規格與應用方案", "",
        "日期：2026-10-21｜規劃版本：1.0｜本地基線：34b06cc / 1.3.0+130", "",
        "本文件為項目規劃；新增功能與數值目標尚待開發及試點驗證。", "",
    ]
    diagram_text = {
        "cover": "容量與備援 → 透明與自主 → 資源與交付",
        "modules": "A 容量：可承諾多少？\nB 連結：同意分享甚麼？\nC 資源：能交付甚麼？\n共同底層：身份驗證、事件紀錄、權限、離線狀態。",
        "states": "待承接 → 待確認 → 進行中 → 待核對 → 完成\n例外：取消、到期、待交接、待協調。",
        "architecture": "Flutter APP → 領域服務（Capacity / Consent / Matching / Task）→ 本機資料與事件佇列 / 受權服務與傳輸。",
        "wireframes": "畫面示意：互助清單（晚餐需求、代領物資）／任務詳情（條件、配對理由、願意協助）／我的容量（時間、任務上限、暫停接單）。PDF 第 11 頁含三個畫面的線框示意。",
    }
    for page in PAGES:
        lines += [f"## {page['title']}", ""]
        if not page.get("cover"):
            lines += [page["subtitle"], ""]
        for block in page["blocks"]:
            kind = block["kind"]
            if kind == "section":
                lines += [f"### {block['title']}", ""]
                if block["text"]:
                    lines += [block["text"], ""]
            elif kind in ("para", "note"):
                lines += [("> " if kind == "note" else "") + block["text"].replace("\n", "\n\n"), ""]
            elif kind == "bullets":
                lines += [f"- {item}" for item in block["items"]] + [""]
            elif kind == "table":
                lines += [
                    "| " + " | ".join(block["headers"]) + " |",
                    "| " + " | ".join(["---"] * len(block["headers"])) + " |",
                ]
                for row in block["rows"]:
                    lines.append("| " + " | ".join(str(value).replace("|", "/").replace("\n", "<br>") for value in row) + " |")
                lines.append("")
            elif kind == "diagram":
                lines += [diagram_text[block["diagram"]].replace("\n", "\n\n"), ""]
    MD_PATH.write_text("\n".join(lines), encoding="utf-8")


def verify():
    QA_PATH.parent.mkdir(parents=True, exist_ok=True)
    reader = PdfReader(str(PDF_PATH))
    page_texts = [page.extract_text() or "" for page in reader.pages]
    if len(reader.pages) != len(PAGES):
        raise RuntimeError(f"Unexpected pagination: {len(reader.pages)} instead of {len(PAGES)}")
    checks = []
    for idx, (page, text) in enumerate(zip(PAGES, page_texts), 1):
        title_ok = re.sub(r"\s+", "", page["title"]) in re.sub(r"\s+", "", text)
        if not title_ok:
            raise RuntimeError(f"Page {idx}: missing expected title {page['title']}")
        if "\ufffd" in text or "\u25a0" in text:
            raise RuntimeError(f"Page {idx}: replacement glyph")
        checks.append({"page": idx, "title": page["title"], "characters": len(text), "title_ok": title_ok})
    qa = {
        "pdf": str(PDF_PATH), "markdown": str(MD_PATH),
        "page_count": len(reader.pages), "pdf_bytes": PDF_PATH.stat().st_size,
        "page_checks": checks,
    }
    QA_PATH.write_text(json.dumps(qa, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(qa, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    build_pdf()
    build_markdown()
    verify()
