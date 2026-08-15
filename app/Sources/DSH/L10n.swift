import Foundation

/// zh-Hans is the primary product language. English is the fallback.
enum L10n {
    static var isChinese: Bool {
        if let code = Locale.preferredLanguages.first?.lowercased() {
            if code.hasPrefix("en") { return false }
            if code.hasPrefix("zh") { return true }
        }
        if let code = Locale.current.language.languageCode?.identifier.lowercased() {
            if code == "en" { return false }
            if code == "zh" { return true }
        }
        return true
    }

    static func t(_ zh: String, _ en: String) -> String {
        isChinese ? zh : en
    }
}
