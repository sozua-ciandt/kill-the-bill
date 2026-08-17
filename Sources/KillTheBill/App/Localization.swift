import Foundation

struct AppLocalizer {
    let language: AppLanguage

    var locale: Locale { Locale(identifier: language.resolvedIdentifier) }

    func text(_ key: String) -> String {
        localizedBundle.localizedString(forKey: key, value: key, table: nil)
    }

    func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }

    func plural(singular: String, plural: String, count: Int) -> String {
        format(count == 1 ? singular : plural, count)
    }

    func currency(_ value: Double) -> String {
        value.formatted(
            .currency(code: "USD")
                .locale(locale)
                .precision(.fractionLength(2))
        )
    }

    func relative(_ date: Date, relativeTo reference: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: reference)
    }

    func dateTime(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
        )
    }

    private var localizedBundle: Bundle {
        // SwiftPM's resource bundler lowercases .lproj directory names
        // (e.g. pt-BR.lproj -> pt-br.lproj), so look up by the lowercased
        // identifier rather than the region-cased one used for Locale.
        guard let path = Bundle.resourcesBundle.path(
            forResource: language.resolvedIdentifier.lowercased(),
            ofType: "lproj"
        ), let bundle = Bundle(path: path) else {
            return .resourcesBundle
        }
        return bundle
    }
}

extension Bundle {
    /// SwiftPM's generated Bundle.module accessor has a single candidate
    /// path, Bundle.main.bundleURL, and fatalErrors outright if it's not
    /// there. That's the .app bundle root for a packaged app, but the
    /// resource bundle actually lives in the conventional Contents/Resources
    /// so codesign can seal it (anything sitting loose at the bundle root
    /// fails `codesign --verify --strict`). Resolve it ourselves instead of
    /// ever touching Bundle.module.
    static var resourcesBundle: Bundle {
        let bundleName = "KillTheBill_KillTheBill.bundle"
        if let resourceURL = Bundle.main.resourceURL,
           let bundle = Bundle(path: resourceURL.appendingPathComponent(bundleName).path) {
            return bundle
        }
        // swift run/swift test: not app-bundled, the resource bundle sits
        // next to the built executable.
        if let bundle = Bundle(path: Bundle.main.bundleURL.appendingPathComponent(bundleName).path) {
            return bundle
        }
        return .module
    }
}

extension AppLanguage {
    var resolvedIdentifier: String {
        switch self {
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
            return preferred.hasPrefix("pt") ? "pt-BR" : "en"
        case .english:
            return "en"
        case .portugueseBrazil:
            return "pt-BR"
        }
    }
}
