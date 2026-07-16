import XCTest
@testable import Revive

/// Proves the four-language string table has no gaps. If someone adds a UI
/// string but forgets a translation, this test fails and names the missing key.
final class LocalizationTests: XCTestCase {
    private let languages = ["zh-Hant", "zh-Hans", "en", "es"]

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
