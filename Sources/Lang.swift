// Язык интерфейса: русский, английский или эстонский. По умолчанию — первый подходящий из языков macOS,
// иначе английский; в шестерёнке можно выбрать вручную (ключ "language").
import Foundation

enum Lang: String, CaseIterable {
    case ru, en, et

    nonisolated(unsafe) static var current: Lang = detect()

    static func detect() -> Lang {
        if let forced = UserDefaults.standard.string(forKey: "language"), let l = Lang(rawValue: forced) { return l }
        for p in Locale.preferredLanguages {
            if let l = Lang(rawValue: String(p.prefix(2)).lowercased()) { return l }
        }
        return .en
    }

    /// Название языка на нём самом — для меню выбора.
    var selfName: String {
        switch self {
        case .ru: return "Русский"
        case .en: return "English"
        case .et: return "Eesti"
        }
    }
}

/// Строка на языке интерфейса.
func tr(_ ru: String, _ en: String, _ et: String) -> String {
    switch Lang.current {
    case .ru: return ru
    case .en: return en
    case .et: return et
    }
}
