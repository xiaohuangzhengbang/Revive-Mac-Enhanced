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
    private let defaults: UserDefaults

    @Published var lang: Lang {
        didSet { defaults.set(lang.rawValue, forKey: Self.key) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.string(forKey: Self.key),
           let l = Lang(rawValue: saved) {
            lang = l
        } else {
            // The Chinese edition starts in Simplified Chinese even when macOS
            // uses English. Initial selection is not persisted; only a user's
            // later language change is, so existing explicit preferences survive.
            lang = .zhHans
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

    /// Translate our diagnostic text only at the display boundary. Engine error
    /// values remain unchanged for timeout classification and native receipts.
    func engineDetail(_ detail: String) -> String {
        if let key = Self.engineDetailKeys[detail] { return t(key) }
        let prefixes = [
            ("Output already exists: ", "engine_output_exists"),
            ("Output directory components must be real directories: ", "engine_directory_component"),
            ("still-image-time append failed: ", "engine_metadata_append"),
            ("sample append failed: ", "engine_sample_append"),
            ("Media writer made no progress for 120 seconds; ", "engine_timeout_details")
        ]
        for (prefix, key) in prefixes where detail.hasPrefix(prefix) {
            return t(key, String(detail.dropFirst(prefix.count)))
        }
        let wrapped = [
            ("still-image-time format description failed (OSStatus ", ")", "engine_metadata_format"),
            ("Couldn't create ", " destination", "engine_image_destination"),
            ("can't read ", " track", "engine_read_track"),
            ("can't write ", " track", "engine_write_track")
        ]
        for (prefix, suffix, key) in wrapped where detail.hasPrefix(prefix) && detail.hasSuffix(suffix) {
            let value = detail.dropFirst(prefix.count).dropLast(suffix.count)
            return t(key, String(value))
        }
        // Native frameworks can return system-language text. Preserve it for
        // diagnosis and explain that it is the original system detail.
        return t("engine_system_detail", detail)
    }

    private static let engineDetailKeys: [String: String] = [
        "Invalid local output name or directory": "engine_invalid_output",
        "Trim times must be finite and within the source duration": "engine_trim_range",
        "Trim end must be after trim start": "engine_trim_order",
        "Cover time must be finite and before the clip end": "engine_cover_range",
        "Cover time is outside the rendered video": "engine_cover_outside",
        "Decoder returned an invalid cover frame time": "engine_cover_decode_time",
        "Final movie does not contain the cover frame": "engine_movie_missing_cover",
        "Output directory must be a real directory": "engine_output_directory",
        "Invalid local directory": "engine_invalid_directory",
        "Cannot determine output ownership": "engine_output_ownership",
        "image encoding failed": "engine_image_encode",
        "couldn't create export session": "engine_export_session",
        "export failed": "engine_export_failed",
        "Final movie would require another video encode": "engine_second_encode",
        "can't add still-image-time metadata track": "engine_metadata_track",
        "still-image-time sample must be inside the movie": "engine_metadata_time",
        "startReading failed": "engine_start_read",
        "startWriting failed": "engine_start_write",
        "read failed": "engine_read_failed",
        "writing failed": "engine_write_failed",
        "writing did not complete": "engine_write_incomplete",
        "Media writer made no progress for 120 seconds": "engine_timeout"
    ]

    static let table: [String: [String: String]] = [
        "import_panel_prompt": ["zh-Hant": "匯入", "zh-Hans": "导入", "en": "Import", "es": "Importar"],
        "output_panel_prompt": ["zh-Hant": "選擇輸出位置", "zh-Hans": "选择输出位置", "en": "Choose Output Location", "es": "Elegir carpeta de salida"],
        "engine_invalid_output": ["zh-Hant": "本機輸出名稱或目錄無效", "zh-Hans": "本地输出名称或目录无效", "en": "Invalid local output name or directory", "es": "Nombre o carpeta de salida local no válidos"],
        "engine_trim_range": ["zh-Hant": "裁剪時間必須有效且位於原影片時長內", "zh-Hans": "裁剪时间必须有效且位于原视频时长内", "en": "Trim times must be finite and within the source duration", "es": "Los tiempos de recorte deben ser válidos y estar dentro del vídeo original"],
        "engine_trim_order": ["zh-Hant": "裁剪結束時間必須晚於開始時間", "zh-Hans": "裁剪结束时间必须晚于开始时间", "en": "Trim end must be after trim start", "es": "El final del recorte debe ser posterior al inicio"],
        "engine_cover_range": ["zh-Hant": "封面時間必須有效且早於片段結束時間", "zh-Hans": "封面时间必须有效且早于片段结束时间", "en": "Cover time must be finite and before the clip end", "es": "El tiempo de portada debe ser válido y anterior al final del clip"],
        "engine_cover_outside": ["zh-Hant": "封面時間超出實際成片範圍", "zh-Hans": "封面时间超出实际成片范围", "en": "Cover time is outside the rendered video", "es": "El tiempo de portada está fuera del vídeo generado"],
        "engine_cover_decode_time": ["zh-Hant": "解碼器傳回的封面影格時間無效", "zh-Hans": "解码器返回的封面帧时间无效", "en": "Decoder returned an invalid cover frame time", "es": "El decodificador devolvió un tiempo de portada no válido"],
        "engine_movie_missing_cover": ["zh-Hant": "最終影片不包含所選封面影格", "zh-Hans": "最终视频不包含所选封面帧", "en": "Final movie does not contain the cover frame", "es": "El vídeo final no contiene el fotograma de portada"],
        "engine_output_directory": ["zh-Hant": "輸出位置必須是真實目錄", "zh-Hans": "输出位置必须是真实目录", "en": "Output directory must be a real directory", "es": "La carpeta de salida debe ser un directorio real"],
        "engine_invalid_directory": ["zh-Hant": "本機目錄無效", "zh-Hans": "本地目录无效", "en": "Invalid local directory", "es": "Directorio local no válido"],
        "engine_output_ownership": ["zh-Hant": "無法確認輸出檔案身分", "zh-Hans": "无法确认输出文件身份", "en": "Cannot determine output ownership", "es": "No se puede identificar el archivo de salida"],
        "engine_image_encode": ["zh-Hant": "封面圖片編碼失敗", "zh-Hans": "封面图片编码失败", "en": "image encoding failed", "es": "Falló la codificación de la imagen"],
        "engine_export_session": ["zh-Hant": "無法建立影片匯出工作", "zh-Hans": "无法创建视频导出任务", "en": "couldn't create export session", "es": "No se pudo crear la sesión de exportación"],
        "engine_export_failed": ["zh-Hant": "影片匯出失敗", "zh-Hans": "视频导出失败", "en": "export failed", "es": "Falló la exportación"],
        "engine_second_encode": ["zh-Hant": "最終影片需要再次編碼，已停止以保持封面一致", "zh-Hans": "最终视频需要再次编码，已停止以保持封面一致", "en": "Final movie would require another video encode", "es": "El vídeo final requeriría otra codificación"],
        "engine_metadata_track": ["zh-Hant": "無法加入實況時間中繼資料軌", "zh-Hans": "无法加入实况时间元数据轨", "en": "can't add still-image-time metadata track", "es": "No se puede añadir la pista de metadatos still-image-time"],
        "engine_metadata_time": ["zh-Hant": "實況時間標記必須位於影片範圍內", "zh-Hans": "实况时间标记必须位于视频范围内", "en": "still-image-time sample must be inside the movie", "es": "La muestra still-image-time debe estar dentro del vídeo"],
        "engine_start_read": ["zh-Hant": "無法開始讀取影片", "zh-Hans": "无法开始读取视频", "en": "startReading failed", "es": "No se pudo iniciar la lectura"],
        "engine_start_write": ["zh-Hant": "無法開始寫入影片", "zh-Hans": "无法开始写入视频", "en": "startWriting failed", "es": "No se pudo iniciar la escritura"],
        "engine_read_failed": ["zh-Hant": "影片讀取失敗", "zh-Hans": "视频读取失败", "en": "read failed", "es": "Falló la lectura"],
        "engine_write_failed": ["zh-Hant": "影片寫入失敗", "zh-Hans": "视频写入失败", "en": "writing failed", "es": "Falló la escritura"],
        "engine_write_incomplete": ["zh-Hant": "影片寫入未完成", "zh-Hans": "视频写入未完成", "en": "writing did not complete", "es": "La escritura no se completó"],
        "engine_timeout": ["zh-Hant": "影片寫入已連續 120 秒沒有進展", "zh-Hans": "视频写入已连续 120 秒没有进展", "en": "Media writer made no progress for 120 seconds", "es": "La escritura del vídeo no avanzó durante 120 segundos"],
        "engine_output_exists": ["zh-Hant": "輸出檔案已存在：%@", "zh-Hans": "输出文件已存在：%@", "en": "Output already exists: %@", "es": "El archivo de salida ya existe: %@"],
        "engine_directory_component": ["zh-Hant": "輸出路徑必須由真實目錄組成：%@", "zh-Hans": "输出路径必须由真实目录组成：%@", "en": "Output directory components must be real directories: %@", "es": "La ruta de salida debe usar directorios reales: %@"],
        "engine_metadata_append": ["zh-Hant": "實況時間標記寫入失敗；系統原始詳情：%@", "zh-Hans": "实况时间标记写入失败；系统原始详情：%@", "en": "still-image-time append failed: %@", "es": "Falló la escritura de still-image-time; detalle original: %@"],
        "engine_sample_append": ["zh-Hant": "媒體資料寫入失敗；系統原始詳情：%@", "zh-Hans": "媒体数据写入失败；系统原始详情：%@", "en": "sample append failed: %@", "es": "Falló la escritura de la muestra; detalle original: %@"],
        "engine_timeout_details": ["zh-Hant": "影片寫入已連續 120 秒沒有進展；診斷詳情：%@", "zh-Hans": "视频写入已连续 120 秒没有进展；诊断详情：%@", "en": "Media writer made no progress for 120 seconds; %@", "es": "La escritura del vídeo no avanzó durante 120 segundos; diagnóstico: %@"],
        "engine_metadata_format": ["zh-Hant": "實況時間中繼資料格式建立失敗（OSStatus %@）", "zh-Hans": "实况时间元数据格式创建失败（OSStatus %@）", "en": "still-image-time format description failed (OSStatus %@)", "es": "Falló la creación del formato still-image-time (OSStatus %@)"],
        "engine_image_destination": ["zh-Hant": "無法建立 %@ 封面輸出", "zh-Hans": "无法创建 %@ 封面输出", "en": "Couldn't create %@ destination", "es": "No se pudo crear el destino %@"],
        "engine_read_track": ["zh-Hant": "無法讀取 %@ 媒體軌", "zh-Hans": "无法读取 %@ 媒体轨", "en": "can't read %@ track", "es": "No se puede leer la pista %@"],
        "engine_write_track": ["zh-Hant": "無法寫入 %@ 媒體軌", "zh-Hans": "无法写入 %@ 媒体轨", "en": "can't write %@ track", "es": "No se puede escribir la pista %@"],
        "engine_system_detail": ["zh-Hant": "系統原始詳情：%@", "zh-Hans": "系统原始详情：%@", "en": "%@", "es": "Detalle original del sistema: %@"],
        "image_motion_short": ["zh-Hant": "圖片運鏡", "zh-Hans": "图片运镜", "en": "PHOTO MOTION", "es": "MOVIMIENTO"],
        "image_motion_note": ["zh-Hant": "靜態圖片會產生 3 秒輕微縮放與平移；這是本機運鏡，不會生成人物動作。", "zh-Hans": "静态图片默认生成 3 秒轻微缩放与平移；这是本地运镜，不会生成人物动作。", "en": "Images become a 3-second gentle zoom-and-pan. This is local camera motion, not generated person movement.", "es": "Las imágenes usan zoom y desplazamiento suaves de 3 segundos; no se generan movimientos de personas."],
        "image_motion_rendering": ["zh-Hant": "正在產生圖片運鏡…", "zh-Hans": "正在生成图片运镜…", "en": "Rendering image motion…", "es": "Creando movimiento de imagen…"],
        "export_gif": ["zh-Hant": "匯出 GIF 動圖…", "zh-Hans": "导出 GIF 动图…", "en": "Export Animated GIF…", "es": "Exportar GIF animado…"],
        "gif_requires_preview": ["zh-Hant": "請先產生圖片運鏡預覽，查看並確認封面。", "zh-Hans": "请先生成图片运镜预览，查看并确认封面。", "en": "Prepare the image-motion preview and inspect and confirm its cover first.", "es": "Prepara la vista previa y confirma la portada primero."],
        "gif_exporting": ["zh-Hant": "正在編碼並檢查 GIF…", "zh-Hans": "正在编码并检查 GIF…", "en": "Encoding and checking GIF…", "es": "Codificando y verificando GIF…"],
        "gif_exported": ["zh-Hant": "GIF 檢查通過，已存入新資料夾：%@", "zh-Hans": "GIF 检查通过，已保存到新文件夹：%@", "en": "GIF verified and saved to a new folder: %@", "es": "GIF verificado y guardado en una carpeta nueva: %@"],
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
        "add_video": ["zh-Hant": "添加影片或圖片", "zh-Hans": "添加视频或图片", "en": "Add Video or Image", "es": "Añadir vídeo o imagen"],
        "convert_all": ["zh-Hant": "全部轉換", "zh-Hans": "全部转换", "en": "Convert All", "es": "Convertir todo"],
        "language": ["zh-Hant": "語言", "zh-Hans": "语言", "en": "Language", "es": "Idioma"],
        "dest_photos": ["zh-Hant": "加入照片圖庫", "zh-Hans": "加入照片图库", "en": "Add to Photos", "es": "Añadir a Fotos"],
        "dest_folder": ["zh-Hant": "匯出到資料夾", "zh-Hans": "导出到文件夹", "en": "Export to Folder", "es": "Exportar a carpeta"],
        "sidebar_empty": ["zh-Hant": "拖入影片或圖片開始", "zh-Hans": "拖入视频或图片开始", "en": "Drop a video or image", "es": "Arrastra un vídeo o imagen"],
        "videos_count": ["zh-Hant": "%d 個素材", "zh-Hans": "%d 个素材", "en": "%d items", "es": "%d archivos"],
        "remove": ["zh-Hant": "移除", "zh-Hans": "移除", "en": "Remove", "es": "Quitar"],
        "hero_tagline": ["zh-Hant": "影片轉實況；靜態圖片製作運鏡動圖與實況", "zh-Hans": "视频转实况；静态图片制作运镜动图与实况", "en": "Create Live Photos from videos, or camera-motion animations from images", "es": "Live Photos de vídeos y animación de cámara de imágenes"],
        "hero_hint": ["zh-Hant": "拖入影片、JPG、PNG 或 HEIC。圖片預設產生 3 秒輕微縮放與平移。\n原檔唯讀，每次匯出自動建立新資料夾。", "zh-Hans": "拖入视频、JPG、PNG 或 HEIC。图片默认生成 3 秒轻微缩放与平移。\n原文件只读，每次导出自动新建文件夹。", "en": "Drop a video, JPG, PNG or HEIC. Images become 3-second gentle zoom-and-pan animations.\nThe original stays read-only; every export uses a new folder.", "es": "Arrastra un vídeo, JPG, PNG o HEIC. Las imágenes crean animaciones suaves de 3 segundos.\nEl original no se modifica; cada exportación usa una carpeta nueva."],
        "choose_video": ["zh-Hant": "選擇影片或圖片…", "zh-Hans": "选择视频或图片…", "en": "Choose Video or Image…", "es": "Elegir vídeo o imagen…"],
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
