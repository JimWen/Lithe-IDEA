import Foundation

/// Localizes presentation using the app selection without changing diagnostic output.
struct LanguageTestLocalization {
    private let bundle: Bundle

    init(language: AppLanguage, resourceBundle: Bundle = .main) {
        bundle = resourceBundle.url(forResource: language.rawValue, withExtension: "lproj")
            .flatMap(Bundle.init(url:)) ?? resourceBundle
    }

    func text(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    func error(_ message: String) -> String {
        text(message)
    }
}
