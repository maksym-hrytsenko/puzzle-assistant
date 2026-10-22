import SwiftUI

/// Interface language: system, Ukrainian, English or Russian.
/// iOS applies an app's language at launch, so a change needs a restart.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, uk, en, ru

    var id: String { rawValue }

    /// Names in their own language, so they are recognisable in any interface language.
    var title: String {
        switch self {
        case .system: return String(localized: "Як у системі")
        case .uk: return "Українська"
        case .en: return "English"
        case .ru: return "Русский"
        }
    }

    static var current: AppLanguage {
        guard let saved = UserDefaults.standard.string(forKey: "selectedLanguage") else { return .system }
        return AppLanguage(rawValue: saved) ?? .system
    }

    func apply() {
        let defaults = UserDefaults.standard
        if self == .system {
            defaults.removeObject(forKey: "AppleLanguages")
            defaults.removeObject(forKey: "selectedLanguage")
        } else {
            defaults.set([rawValue], forKey: "AppleLanguages")
            defaults.set(rawValue, forKey: "selectedLanguage")
        }
    }
}

struct LanguageMenu: View {
    @State private var selected = AppLanguage.current
    @State private var showRestartHint = false

    var body: some View {
        Menu {
            Picker("Мова", selection: $selected) {
                ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
            }
        } label: {
            Image(systemName: "globe")
        }
        .onChange(of: selected) { _, language in
            language.apply()
            showRestartHint = true
        }
        .alert("Мову змінено", isPresented: $showRestartHint) {
            Button("OK") {}
        } message: {
            Text("Закрийте застосунок (змахніть його вгору в перемикачі програм) і відкрийте знову — інтерфейс буде новою мовою.")
        }
    }
}
