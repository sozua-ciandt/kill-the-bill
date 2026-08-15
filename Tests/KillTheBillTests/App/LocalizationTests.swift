import Foundation
import XCTest
@testable import KillTheBill

final class LocalizationTests: XCTestCase {
    func testLoadsEnglishAndBrazilianPortugueseAtRuntime() {
        let english = AppLocalizer(language: .english)
        let portuguese = AppLocalizer(language: .portugueseBrazil)

        XCTAssertEqual(english.text("settings.title"), "Settings")
        XCTAssertEqual(portuguese.text("settings.title"), "Configurações")
        XCTAssertEqual(
            english.plural(
                singular: "overview.session.count.one",
                plural: "overview.session.count",
                count: 1
            ),
            "1 session"
        )
        XCTAssertEqual(
            portuguese.plural(
                singular: "overview.session.count.one",
                plural: "overview.session.count",
                count: 3
            ),
            "3 sessões"
        )
    }

    func testMissingKeyFallsBackToKey() {
        XCTAssertEqual(
            AppLocalizer(language: .english).text("missing.localization.key"),
            "missing.localization.key"
        )
    }

    func testLanguagesHaveMatchingKeysAndFormatPlaceholders() throws {
        let english = try localizationValues(for: "en")
        let portuguese = try localizationValues(for: "pt-BR")

        XCTAssertEqual(Set(english.keys), Set(portuguese.keys))

        for key in english.keys.sorted() {
            let englishValue = try XCTUnwrap(english[key])
            let portugueseValue = try XCTUnwrap(portuguese[key])
            XCTAssertEqual(
                formatPlaceholders(in: englishValue),
                formatPlaceholders(in: portugueseValue),
                "Format arguments differ for localization key \(key)"
            )
        }
    }

    private func localizationValues(for identifier: String) throws -> [String: String] {
        let file = Bundle.module.bundleURL
            .appendingPathComponent("\(identifier.lowercased()).lproj", isDirectory: true)
            .appendingPathComponent("Localizable.strings")
        let data = try Data(contentsOf: file)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        )
    }

    private func formatPlaceholders(in value: String) -> [String] {
        let pattern = #"%(?:\d+\$)?[-+0 #]*\d*(?:\.\d+)?[@a-zA-Z]"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard let range = Range(match.range, in: value) else { return nil }
            return String(value[range])
        }
    }
}
