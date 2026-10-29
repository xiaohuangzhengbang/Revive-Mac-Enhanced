import SwiftUI
import Foundation

enum Lang: String, CaseIterable, Identifiable {
    case zhHant = "zh-Hant"
    case zhHans = "zh-Hans"
    case en = "en"
    case es = "es"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .zhHant: return "繁體中文"
        case .zhHans: return "简体中文"
        case .en: return "English"
        case .es: return "Español"
        }
    }
}

/// Lightweight in-app localization: strings live in a Swift table so the user
/// can switch language instantly (no relaunch). Views observe `shared`; non-view
/// code (engine, verifier) reads `Localizer.shared.t(...)` directly.
final class Localizer: ObservableObject {
    static let shared = Localizer()
    private static let key = "revive.language"

    @Published var lang: Lang {
        didSet { UserDefaults.standard.set(lang.rawValue, forKey: Self.key) }
    }

    init() {
        if let saved = UserDefaults.standard.string(forKey: Self.key),
           let l = Lang(rawValue: saved) {
            lang = l
        } else {
            let pref = Locale.preferredLanguages.first ?? "zh-Hant"
            if pref.hasPrefix("zh-Hant") || pref.hasPrefix("zh-TW") || pref.hasPrefix("zh-HK") {
                lang = .zhHant
            } else if pref.hasPrefix("zh") {
                lang = .zhHans
            } else if pref.hasPrefix("es") {
                lang = .es
            } else if pref.hasPrefix("en") {
                lang = .en
            } else {
                lang = .zhHant
            }
        }
    }

    func t(_ key: String) -> String {
        guard let row = Self.table[key] else { return key }
        return row[lang.rawValue] ?? row["en"] ?? key
    }

    /// Convenience for format strings with arguments.
    func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }

    static let table: [String: [String: String]] = [
        "exact_required": ["zh-Hant": "本版本固定精準剪輯，會重新編碼一次以避免關鍵影格吸附改變時長", "zh-Hans": "本版本固定精准剪辑，会重新编码一次以避免关键帧吸附改变时长", "en": "Exact trim is required; one encode prevents keyframe snapping from changing duration", "es": "Recorte exacto obligatorio; una codificación evita cambios de duración por fotogramas clave"],
        "preview_actual_jpg": ["zh-Hant": "實際成片封面", "zh-Hans": "实际成片封面", "en": "Actual output cover", "es": "Portada del vídeo final"],
        "prepare_preview": ["zh-Hant": "產生成片預覽", "zh-Hans": "生成成片预览", "en": "Prepare output preview", "es": "Preparar vista previa"],
        "preview_full": ["zh-Hant": "查看封面原圖", "zh-Hans": "查看封面原图", "en": "Inspect full cover", "es": "Inspeccionar portada"],
        "preview_close": ["zh-Hant": "關閉預覽", "zh-Hans": "关闭预览", "en": "Close preview", "es": "Cerrar vista previa"],
        "cover_confirm": ["zh-Hant": "我已查看此封面，確認人物沒有閉眼（無人物時確認畫面合適）", "zh-Hans": "我已查看此封面，确认人物没有闭眼（无人物时确认画面合适）", "en": "I inspected this cover: eyes are open, or the scene has no person.", "es": "He comprobado esta portada: ojos abiertos o escena sin personas."],
        "output_parent": ["zh-Hant": "輸出位置…", "zh-Hans": "输出位置…", "en": "Output location…", "es": "Carpeta de salida…"],
        "output_default": ["zh-Hant": "預設原片所在位置；每次自動建立新資料夾", "zh-Hans": "默认原片所在位置；每次自动建立新文件夹", "en": "Beside the source; a new folder is created for every export", "es": "Junto al original; carpeta nueva en cada exportación"],
        "preview_protection_note": ["zh-Hant": "原片唯讀。匯出重用這份成片；檔案檢查通過仍需在蘋果裝置驗收 LIVE。", "zh-Hans": "原片只读。导出复用这份成片；文件检查通过仍需在苹果设备验收 LIVE。", "en": "Source is read-only. Export reuses this pair; LIVE playback still needs Apple-device acceptance.", "es": "Original de solo lectura. Se reutiliza este par; falta validar LIVE en un dispositivo Apple."],
        "jpg_only": ["zh-Hant": "本版本使用 JPG/MOV 配對及嚴格 JPG 檢查", "zh-Hans": "本版本使用 JPG/MOV 配对及严格 JPG 检查", "en": "This version uses JPG/MOV pairs with strict JPEG checks", "es": "Esta versión usa pares JPG/MOV con comprobación JPEG"],
        "add_video": ["zh-Hant": "加入影片", "zh-Hans": "加入影片", "en": "Add Video", "es": "Añadir vídeo"],
        "convert_all": ["zh-Hant": "全部轉換", "zh-Hans": "全部转换", "en": "Convert All", "es": "Convertir todo"],
        "language": ["zh-Hant": "語言", "zh-Hans": "语言", "en": "Language", "es": "Idioma"],
        "dest_photos": ["zh-Hant": "加入照片圖庫", "zh-Hans": "加入照片图库", "en": "Add to Photos", "es": "Añadir a Fotos"],
        "dest_folder": ["zh-Hant": "匯出到資料夾", "zh-Hans": "导出到文件夹", "en": "Export to Folder", "es": "Exportar a carpeta"],
        "sidebar_empty": ["zh-Hant": "拖入影片開始", "zh-Hans": "拖入影片开始", "en": "Drop a video", "es": "Arrastra un vídeo"],
        "videos_count": ["zh-Hant": "%d 部影片", "zh-Hans": "%d 个影片", "en": "%d videos", "es": "%d vídeos"],
        "remove": ["zh-Hant": "移除", "zh-Hans": "移除", "en": "Remove", "es": "Quitar"],
        "hero_tagline": ["zh-Hant": "把影片轉為實況照片，保留原片，核對封面與配對檔案", "zh-Hans": "把视频转为实况照片，保留原片，核对封面与配对文件", "en": "Turn videos into Live Photos; preserve the source and verify the output", "es": "Convierte vídeos en Live Photos; conserva el original y verifica el resultado"],
        "hero_hint": ["zh-Hant": "拖影片進來,或從 Finder 右鍵「用 Revive 轉成 Live Photo」\n可一次拖入多個檔案批次轉換",
                      "zh-Hans": "拖视频进来,或从 Finder 右键「用 Revive 转成 Live Photo」\n可一次拖入多个文件批量转换",
                      "en": "Drop videos here, or right-click in Finder → “Convert to Live Photo with Revive”\nDrop several files to batch convert",
                      "es": "Arrastra vídeos aquí, o clic derecho en Finder → «Convertir a Live Photo con Revive»\nArrastra varios archivos para convertir por lotes"],
        "choose_video": ["zh-Hant": "選擇影片…", "zh-Hans": "选择影片…", "en": "Choose Video…", "es": "Elegir vídeo…"],
        "state_loading": ["zh-Hant": "讀取中…", "zh-Hans": "读取中…", "en": "Loading…", "es": "Cargando…"],
        "state_ready": ["zh-Hant": "%@ · 已選 %@ 秒", "zh-Hans": "%@ · 已选 %@ 秒",
                        "en": "%@ · %@s selected", "es": "%@ · %@s seleccionados"],
        "state_done_saved": ["zh-Hant": "完成,已加入照片圖庫", "zh-Hans": "完成,已加入照片图库",
                             "en": "Done · added to Photos", "es": "Listo · añadido a Fotos"],
        "state_done": ["zh-Hant": "轉換完成", "zh-Hans": "转换完成", "en": "Converted", "es": "Convertido"],
        "cover_photo": ["zh-Hant": "封面照片", "zh-Hans": "封面照片", "en": "Key Photo", "es": "Foto clave"],
        "card_trim": ["zh-Hant": "剪輯", "zh-Hans": "剪辑", "en": "Trim", "es": "Recortar"],
        "card_options": ["zh-Hant": "選項", "zh-Hans": "选项", "en": "Options", "es": "Opciones"],
        "play_clip": ["zh-Hant": "播放片段", "zh-Hans": "播放片段", "en": "Play clip", "es": "Reproducir"],
        "whole": ["zh-Hant": "整段", "zh-Hans": "整段", "en": "Full", "es": "Todo"],
        "middle3": ["zh-Hant": "中間 3 秒", "zh-Hans": "中间 3 秒", "en": "Middle 3s", "es": "3s central"],
        "seconds": ["zh-Hant": "%@ 秒", "zh-Hans": "%@ 秒", "en": "%@s", "es": "%@s"],
        "opt_heic": ["zh-Hant": "HEIC 靜態圖", "zh-Hans": "HEIC 静态图", "en": "HEIC still", "es": "Imagen HEIC"],
        "opt_exact": ["zh-Hant": "精準剪輯", "zh-Hans": "精准剪辑", "en": "Exact trim", "es": "Recorte exacto"],
        "opt_mute": ["zh-Hant": "靜音", "zh-Hans": "静音", "en": "Mute", "es": "Silenciar"],
        "convert_add_photos": ["zh-Hant": "轉換並加入照片圖庫", "zh-Hans": "转换并加入照片图库",
                               "en": "Convert & Add to Photos", "es": "Convertir y añadir a Fotos"],
        "convert_export": ["zh-Hant": "轉換並匯出檔案…", "zh-Hans": "转换并导出文件…",
                           "en": "Convert & Export Files…", "es": "Convertir y exportar…"],
        "reencode_note": ["zh-Hant": "來源編碼無法無損封裝,影片已以視覺無損 HEVC 重編一次(封面照片與相容音訊不受影響)。",
                          "zh-Hans": "源编码无法无损封装,视频已以视觉无损 HEVC 重编一次(封面照片与兼容音频不受影响)。",
                          "en": "Source codec couldn’t be copied losslessly; the video was re-encoded once as visually lossless HEVC (the key photo and compatible audio are unaffected).",
                          "es": "El códec de origen no se pudo copiar sin pérdidas; el vídeo se recodificó una vez como HEVC visualmente sin pérdidas (la foto clave y el audio compatible no se ven afectados)."],
        "verified": ["zh-Hant": "JPG/MOV 檔案檢查通過", "zh-Hans": "JPG/MOV 文件检查通过", "en": "JPG/MOV file checks passed", "es": "Comprobaciones JPG/MOV superadas"],
        "saved_icloud": ["zh-Hant": "已加入照片圖庫，請在蘋果裝置驗收 LIVE 播放", "zh-Hans": "已加入照片图库，请在苹果设备验收 LIVE 播放", "en": "Added to Photos; verify LIVE playback on your Apple device", "es": "Añadido a Fotos; verifica LIVE en tu dispositivo Apple"],
        "show_in_photos": ["zh-Hant": "在照片中顯示", "zh-Hans": "在照片中显示", "en": "Show in Photos", "es": "Ver en Fotos"],
        "details": ["zh-Hant": "細節", "zh-Hans": "细节", "en": "Details", "es": "Detalles"],
        "hide_details": ["zh-Hant": "隱藏細節", "zh-Hans": "隐藏细节", "en": "Hide details", "es": "Ocultar detalles"],

        "converting": ["zh-Hant": "轉換中…", "zh-Hans": "转换中…", "en": "Converting…", "es": "Convirtiendo…"],
        "prog_still": ["zh-Hant": "擷取封面照片…", "zh-Hans": "提取封面照片…", "en": "Extracting key photo…", "es": "Extrayendo foto clave…"],
        "prog_exact": ["zh-Hant": "精準剪輯(重新編碼一次)…", "zh-Hans": "精准剪辑(重新编码一次)…",
                       "en": "Exact trim (re-encoding once)…", "es": "Recorte exacto (recodificando una vez)…"],
        "prog_mux": ["zh-Hant": "無損封裝影片(位元流原樣複製)…", "zh-Hans": "无损封装视频(比特流原样复制)…",
                     "en": "Packaging losslessly (stream copy)…", "es": "Empaquetando sin pérdidas (copia de flujo)…"],
        "prog_reencode": ["zh-Hant": "來源編碼無法無損封裝,以視覺無損 HEVC 重編一次…",
                          "zh-Hans": "源编码无法无损封装,以视觉无损 HEVC 重编一次…",
                          "en": "Source codec can’t be copied; re-encoding once as visually lossless HEVC…",
                          "es": "El códec no se puede copiar; recodificando una vez como HEVC visualmente sin pérdidas…"],
        "saved_n": ["zh-Hant": "已把 %d 張原況照片加入照片圖庫 ✅ (iCloud 照片會自動同步到 iPad)",
                    "zh-Hans": "已把 %d 张实况照片加入照片图库 ✅ (iCloud 照片会自动同步到 iPad)",
                    "en": "Added %d Live Photos to your library ✅ (iCloud syncs to iPad)",
                    "es": "Añadidas %d Live Photos a tu biblioteca ✅ (iCloud sincroniza con el iPad)"],
        "exported_n": ["zh-Hant": "已匯出 %d 對檔案到 %@/", "zh-Hans": "已导出 %d 对文件到 %@/",
                       "en": "Exported %d pairs to %@/", "es": "Exportadas %d parejas a %@/"],
        "export_failed": ["zh-Hant": "匯出失敗:%@", "zh-Hans": "导出失败:%@", "en": "Export failed: %@", "es": "Error al exportar: %@"],
        "verify_failed": ["zh-Hant": "驗證未通過,請展開清單查看缺少的欄位",
                          "zh-Hans": "验证未通过,请展开清单查看缺少的字段",
                          "en": "Verification failed — expand the list to see the missing field",
                          "es": "La verificación falló: despliega la lista para ver el campo que falta"],

        "v_img_id": ["zh-Hant": "照片含 ContentIdentifier (Apple MakerNotes)",
                     "zh-Hans": "照片含 ContentIdentifier (Apple MakerNotes)",
                     "en": "Photo has ContentIdentifier (Apple MakerNotes)",
                     "es": "La foto tiene ContentIdentifier (Apple MakerNotes)"],
        "v_img_id_miss": ["zh-Hant": "缺少 — iOS 會把它當成普通照片", "zh-Hans": "缺少 — iOS 会把它当成普通照片",
                          "en": "Missing — iOS treats it as a normal photo", "es": "Falta: iOS lo trata como foto normal"],
        "v_vid_id": ["zh-Hant": "影片含 content.identifier (QuickTime Keys)",
                     "zh-Hans": "视频含 content.identifier (QuickTime Keys)",
                     "en": "Video has content.identifier (QuickTime Keys)",
                     "es": "El vídeo tiene content.identifier (QuickTime Keys)"],
        "v_vid_id_miss": ["zh-Hant": "缺少 — iOS 無法把影片和照片連結", "zh-Hans": "缺少 — iOS 无法把视频和照片连结",
                          "en": "Missing — iOS can’t link the video to the photo", "es": "Falta: iOS no puede enlazar el vídeo con la foto"],
        "v_match": ["zh-Hant": "兩邊識別碼一致", "zh-Hans": "两边识别码一致",
                    "en": "Identifiers match", "es": "Los identificadores coinciden"],
        "v_match_ok": ["zh-Hant": "一致", "zh-Hans": "一致", "en": "match", "es": "coinciden"],
        "v_match_fail": ["zh-Hant": "照片=%@ 影片=%@", "zh-Hans": "照片=%@ 视频=%@",
                         "en": "photo=%@ video=%@", "es": "foto=%@ vídeo=%@"],
        "v_still": ["zh-Hant": "影片含 still-image-time 中繼資料軌", "zh-Hans": "视频含 still-image-time 元数据轨",
                    "en": "Video has still-image-time metadata track", "es": "El vídeo tiene pista de metadatos still-image-time"],
        "v_still_ok": ["zh-Hant": "存在", "zh-Hans": "存在", "en": "present", "es": "presente"],
        "v_still_miss": ["zh-Hant": "缺少 — 這是多數陽春轉檔器漏掉的欄位", "zh-Hans": "缺少 — 这是多数简易转档器漏掉的字段",
                         "en": "Missing — the field most naive converters skip", "es": "Falta: el campo que la mayoría de conversores omite"],
        "v_names": ["zh-Hant": "檔名主體一致", "zh-Hans": "文件名主体一致",
                    "en": "Basenames match", "es": "Los nombres base coinciden"],

        "err_photos_auth": ["zh-Hant": "沒有照片圖庫的存取權限。請到「系統設定 → 隱私權與安全性 → 照片」允許 Revive。",
                            "zh-Hans": "没有照片图库的访问权限。请到「系统设置 → 隐私与安全性 → 照片」允许 Revive。",
                            "en": "No access to the Photos library. Allow Revive in System Settings → Privacy & Security → Photos.",
                            "es": "Sin acceso a la fototeca. Permite Revive en Ajustes del sistema → Privacidad y seguridad → Fotos."],
        "err_no_video": ["zh-Hant": "找不到影片軌(檔案可能不是有效的影片)", "zh-Hans": "找不到视频轨(文件可能不是有效的视频)",
                         "en": "No video track found (the file may not be a valid video)", "es": "No se encontró pista de vídeo (el archivo puede no ser válido)"],
        "err_read": ["zh-Hant": "無法讀取影片", "zh-Hans": "无法读取视频", "en": "Couldn’t read the video", "es": "No se pudo leer el vídeo"],
        "err_write": ["zh-Hant": "無法寫入輸出", "zh-Hans": "无法写入输出", "en": "Couldn’t write the output", "es": "No se pudo escribir la salida"],
        "err_still": ["zh-Hant": "擷取封面照片失敗", "zh-Hans": "提取封面照片失败", "en": "Failed to extract the key photo", "es": "No se pudo extraer la foto clave"],
        "err_cancelled": ["zh-Hant": "已取消", "zh-Hans": "已取消", "en": "Cancelled", "es": "Cancelado"],
        "err_save_failed": ["zh-Hant": "加入照片圖庫失敗", "zh-Hans": "加入照片图库失败", "en": "Couldn’t add to Photos", "es": "No se pudo añadir a Fotos"],
    ]
}
