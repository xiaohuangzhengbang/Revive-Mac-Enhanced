import XCTest
@testable import Revive

/// Proves the four-language string table has no gaps. If someone adds a UI
/// string but forgets a translation, this test fails and names the missing key.
final class LocalizationTests: XCTestCase {
    private let languages = ["zh-Hant", "zh-Hans", "en", "es"]

    private func withFreshDefaults(_ body: (UserDefaults) -> Void) {
        let name = "Revive.LocalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    func testFirstLaunchUsesSimplifiedChineseWithoutSavingAnImplicitChoice() {
        withFreshDefaults { defaults in
            let localizer = Localizer(defaults: defaults)
            XCTAssertEqual(localizer.lang, .zhHans)
            XCTAssertEqual(localizer.t("add_video"), "添加视频或图片")
            XCTAssertNil(defaults.string(forKey: "revive.language"))
        }
    }

    func testEveryStoredLanguagePreferenceSurvivesTheNewDefault() {
        for language in Lang.allCases {
            withFreshDefaults { defaults in
                defaults.set(language.rawValue, forKey: "revive.language")
                XCTAssertEqual(Localizer(defaults: defaults).lang, language)
                XCTAssertEqual(defaults.string(forKey: "revive.language"), language.rawValue)
            }
        }
    }

    func testManualLanguageChangePersistsAndIsRestored() {
        withFreshDefaults { defaults in
            let firstLaunch = Localizer(defaults: defaults)
            firstLaunch.lang = .en
            XCTAssertEqual(defaults.string(forKey: "revive.language"), "en")
            XCTAssertEqual(Localizer(defaults: defaults).lang, .en)
        }
    }

    func testInvalidSavedLanguageFallsBackToSimplifiedChinese() {
        withFreshDefaults { defaults in
            defaults.set("unsupported-language", forKey: "revive.language")
            XCTAssertEqual(Localizer(defaults: defaults).lang, .zhHans)
        }
    }

    func testChineseErrorsTranslateOwnedDiagnosticsAndPreserveSystemDetails() {
        withFreshDefaults { defaults in
            let localizer = Localizer(defaults: defaults)
            XCTAssertEqual(localizer.engineDetail("Output already exists: IMG_LIVE.MOV"),
                           "输出文件已存在：IMG_LIVE.MOV")
            let timeout = localizer.engineDetail("Media writer made no progress for 120 seconds; soun.ready=true")
            XCTAssertTrue(timeout.contains("120 秒"))
            XCTAssertFalse(timeout.contains("Media writer"))
            XCTAssertTrue(timeout.contains("soun.ready=true"))
            let nativeDetail = "The operation could not be completed. (AVFoundationErrorDomain -11800.)"
            let displayed = localizer.engineDetail(nativeDetail)
            XCTAssertTrue(displayed.hasPrefix("系统原始详情："))
            XCTAssertTrue(displayed.contains(nativeDetail))
        }
    }

    func testEveryKeyHasAllFourLanguages() {
        for (key, row) in Localizer.table {
            for lang in languages {
                let value = row[lang]
                XCTAssertNotNil(value, "缺翻譯:key '\(key)' 少了 \(lang)")
                XCTAssertFalse(value?.isEmpty ?? true, "空翻譯:key '\(key)' 的 \(lang) 是空的")
            }
        }
    }

    func testUnknownKeyFallsBackToItself() {
        // a missing key should return the key verbatim, never crash
        XCTAssertEqual(Localizer.shared.t("__no_such_key__"), "__no_such_key__")
    }
}
