import Foundation

enum AppLanguage {
    static let system = "system"
    private static let preferenceKey = "AppleLanguages"

    static var available: [String] {
        Bundle.main.localizations.filter { $0 != "Base" }.sorted {
            name(for: $0).localizedStandardCompare(name(for: $1)) == .orderedAscending
        }
    }

    static func name(for identifier: String) -> String {
        Locale(identifier: identifier).localizedString(forIdentifier: identifier) ?? identifier
    }

    static func selection(in defaults: UserDefaults = .standard,
                          domain: String? = Bundle.main.bundleIdentifier) -> String {
        guard let domain,
              let languages = defaults.persistentDomain(forName: domain)?[preferenceKey] as? [String],
              let language = languages.first else { return system }
        return language
    }

    static func select(_ language: String, in defaults: UserDefaults = .standard) {
        if language == system {
            defaults.removeObject(forKey: preferenceKey)
        } else {
            defaults.set([language], forKey: preferenceKey)
        }
    }
}
