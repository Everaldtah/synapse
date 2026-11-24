import UIKit

/// Asks before the user's content leaves the device for a third-party AI service (App Store guideline 5.1.2(i)):
/// the first time each service would receive anything, an alert names it, says what is sent, and waits for
/// Allow or Don't Allow. The answer is remembered per service; Settings › Privacy resets every answer.
@MainActor
enum AIConsent {
    private static let prefix = "aiConsent."
    private static var pending: [String: Task<Bool, Never>] = [:]

    static func isAllowed(_ key: String) -> Bool {
        UserDefaults.standard.bool(forKey: prefix + key)
    }

    /// Returns when `service` may receive the user's content; throws `AIError` when the user declines.
    /// `key` identifies the service (a host name, or "bridge.claude"); `detail` explains where the data goes next.
    static func ensure(key: String, service: String, detail: String? = nil) async throws {
        if isAllowed(key) { return }
        let task: Task<Bool, Never>
        if let existing = pending[key] {
            task = existing
        } else {
            var lines = ["Synapse will send your request to \(service): what you type, the pages and files you include, and any images or audio you attach."]
            if let detail, !detail.isEmpty { lines.append(detail) }
            lines.append("\(service)'s own privacy policy applies. Synapse's developer never receives your data. You can change this in Settings › Privacy.")
            let message = lines.joined(separator: "\n\n")
            task = Task { await confirm(title: "Share with \(service)?", message: message, allow: "Allow", deny: "Don\u{2019}t Allow") }
            pending[key] = task
        }
        let allowed = await task.value
        pending[key] = nil
        if allowed {
            UserDefaults.standard.set(true, forKey: prefix + key)
        } else {
            throw AIError(message: "Nothing was sent: sharing with \(service) isn't allowed. Pick another model, or allow \(service) when Synapse asks.")
        }
    }

    /// Forgets every answer, so each service asks again before its next request.
    static func reset() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// A two-button alert over whatever is on screen; false when nothing can show it.
    static func confirm(title: String, message: String, allow: String, deny: String = "Cancel") async -> Bool {
        guard let top = topViewController() else { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: deny, style: .cancel) { _ in continuation.resume(returning: false) })
            alert.addAction(UIAlertAction(title: allow, style: .default) { _ in continuation.resume(returning: true) })
            top.present(alert, animated: true)
        }
    }

    private static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .sorted { ($0.activationState == .foregroundActive ? 0 : 1) < ($1.activationState == .foregroundActive ? 0 : 1) }
            .flatMap(\.windows)
        guard var top = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController else { return nil }
        while let next = top.presentedViewController, !next.isBeingDismissed {
            top = next
        }
        return top
    }
}
