import Combine
import Foundation

/// Checks the GitHub releases endpoint for a newer version.
@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(String, URL)
        case failed
    }

    @Published private(set) var state: State = .idle

    private var task: URLSessionDataTask?
    private let session: URLSession
    private let repository = "suliveevil/KagiPeek"

    init(session: URLSession = .shared) {
        self.session = session
    }

    func check(currentVersion: String) {
        guard state != .checking else { return }
        state = .checking

        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            Diag.warning(.net, "update-check failed reason=url")
            state = .failed
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("KagiPeek-update-check", forHTTPHeaderField: "User-Agent")

        task?.cancel()
        let started = Date()
        Diag.debug(.net, "update-check request host=api.github.com path=/repos/\(repository)/releases/latest")
        task = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handle(
                        data: data,
                        response: response,
                        error: error,
                        currentVersion: currentVersion,
                        elapsed: Date().timeIntervalSince(started)
                    )
                }
            }
        }
        task?.resume()
    }

    private func handle(
        data: Data?,
        response: URLResponse?,
        error: Error?,
        currentVersion: String,
        elapsed: TimeInterval
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode
        let statusText = status.map(String.init) ?? "-"
        let milliseconds = Int(elapsed * 1000)

        guard error == nil, let data else {
            // The reason a check failed is the whole point of the log: offline, DNS, TLS and
            // a GitHub outage are all "could not check for updates" in the UI.
            Diag.warning(.net, """
                update-check failed reason=error status=\(statusText) ms=\(milliseconds) \
                error=\(error?.localizedDescription ?? "no data")
                """)
            state = .failed
            return
        }

        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Diag.warning(.net, "update-check failed reason=parse status=\(statusText) ms=\(milliseconds)")
            state = .failed
            return
        }
        guard let tag = payload["tag_name"] as? String else {
            Diag.warning(.net, "update-check failed reason=no-tag status=\(statusText) ms=\(milliseconds)")
            state = .failed
            return
        }
        guard let urlString = payload["html_url"] as? String,
              let url = URL(string: urlString),
              let latest = SemanticVersion(tag),
              let current = SemanticVersion(currentVersion) else {
            Diag.warning(.net, "update-check failed reason=parse status=\(statusText) ms=\(milliseconds)")
            state = .failed
            return
        }

        Diag.info(.net, "update-check status=\(statusText) ms=\(milliseconds) latest=\(tag)")
        if latest > current {
            state = .available(tag, url)
        } else {
            state = .upToDate(currentVersion)
        }
    }
}
