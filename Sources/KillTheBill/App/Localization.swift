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
        guard let path = Bundle.module.path(
            forResource: language.resolvedIdentifier,
            ofType: "lproj"
        ), let bundle = Bundle(path: path) else {
            return .module
        }
        return bundle
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
