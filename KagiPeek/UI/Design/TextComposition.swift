import AppKit

/// Answers "does an input method own the keyboard right now?".
///
/// The surfaces that install a local key monitor (search palette, panel) used
/// to carry their own copy of this check — and they disagreed, which is how a Chinese input
/// method ends up losing ↑↓ to the app's list. One implementation, four checks, every surface.
@MainActor
enum TextComposition {
    static func isComposing(in window: NSWindow?) -> Bool {
        func marked(_ client: NSTextInputClient?) -> Bool {
            client?.hasMarkedText() ?? false
        }

        if marked(NSTextInputContext.current?.client) { return true }
        guard let window else { return false }
        if marked(window.firstResponder as? NSTextInputClient) { return true }
        if marked(window.fieldEditor(false, for: nil) as? NSTextInputClient) { return true }
        if let field = window.firstResponder as? NSTextField,
           marked(field.currentEditor() as? NSTextInputClient) {
            return true
        }
        return false
    }
}
