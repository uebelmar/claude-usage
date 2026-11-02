import SwiftUI

private struct BlurEmailsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Für Screenshot-Export: Texte mit E-Mail-Adressen unscharf darstellen.
    var blurEmails: Bool {
        get { self[BlurEmailsKey.self] }
        set { self[BlurEmailsKey.self] = newValue }
    }
}

private struct EmailBlur: ViewModifier {
    @Environment(\.blurEmails) private var blurEmails
    let text: String

    func body(content: Content) -> some View {
        if blurEmails && text.contains("@") {
            content.blur(radius: 4).clipped()
        } else {
            content
        }
    }
}

extension View {
    func emailBlur(_ text: String) -> some View { modifier(EmailBlur(text: text)) }
}
