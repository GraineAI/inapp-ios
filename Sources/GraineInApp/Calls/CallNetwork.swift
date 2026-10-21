import Foundation

/**
 * The call's network on URLSession: the ticket POST and the voice WebSocket
 * (`URLSessionWebSocketTask`, with the ticket in the subprotocol header).
 * Foundation only — the same code runs on a phone and in the Mac's live test.
 *
 * No `Origin` header is sent, as for every in-app call: the agent's Allowed
 * domains must contain `app://`.
 */
final class URLSessionCallNetwork: CallNetwork {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    func post(_ url: URL, body: Data, completion: @escaping (Int, Data?) -> Void) {
        postWithHeaders(url, body: body) { status, data, _ in completion(status, data) }
    }

    func postWithHeaders(_ url: URL, body: Data, completion: @escaping (Int, Data?, [String: String]) -> Void) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        session.dataTask(with: request) { data, response, error in
            if error != nil {
                completion(0, nil, [:])
                return
            }
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (name, value) in http?.allHeaderFields ?? [:] {
                if let n = name as? String, let v = value as? String { headers[n.lowercased()] = v }
            }
            completion(http?.statusCode ?? 0, data, headers)
        }.resume()
    }

    func openSocket(_ url: URL, protocols: [String], events: CallSocketEvents) -> CallSocket {
        URLSessionCallSocket(url: url, protocols: protocols, events: events)
    }
}

/// One voice WebSocket. Reports opened once, then frames, then closed exactly once.
final class URLSessionCallSocket: NSObject, CallSocket, URLSessionWebSocketDelegate {
    private let events: CallSocketEvents
    private let lock = NSLock()
    private var finished = false
    private var session: URLSession!
    private var task: URLSessionWebSocketTask!

    init(url: URL, protocols: [String], events: CallSocketEvents) {
        self.events = events
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "ai.graine.calls.socket"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        // The session holds its delegate strongly until invalidated — done in `finish`.
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        task = protocols.isEmpty ? session.webSocketTask(with: url) : session.webSocketTask(with: url, protocols: protocols)
        // Agent frames are ~13 KB of base64; leave generous room.
        task.maximumMessageSize = 4 * 1024 * 1024
        task.resume()
        receive()
    }

    func send(_ text: String) {
        guard !isFinished else { return }
        task.send(.string(text)) { [weak self] error in
            if let error = error { self?.finish(byServer: false, detail: GraineInApp.describe(error)) }
        }
    }

    func close() {
        guard markFinished() else { return }
        task.cancel(with: .normalClosure, reason: nil)
        session.finishTasksAndInvalidate()
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text): self.deliver(text)
                case .data(let data): if let text = String(data: data, encoding: .utf8) { self.deliver(text) }
                @unknown default: break
                }
                self.receive()
            case .failure(let error):
                self.finish(byServer: false, detail: GraineInApp.describe(error))
            }
        }
    }

    private func deliver(_ text: String) {
        guard !isFinished else { return }
        events.received(text)
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard !isFinished else { return }
        events.opened()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let why = reason.flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 }
        finish(byServer: true, detail: why ?? "closed (\(closeCode.rawValue))", code: closeCode.rawValue)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let http = (task.response as? HTTPURLResponse)?.statusCode
        let detail: String
        if let status = http, status >= 400 {
            detail = "The conversation was refused (\(status))."
        } else if let error = error {
            detail = GraineInApp.describe(error)
        } else {
            detail = "The connection closed."
        }
        finish(byServer: false, detail: detail)
    }

    // MARK: - Once

    private var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    /// True for the first caller only.
    private func markFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }

    private func finish(byServer: Bool, detail: String?, code: Int? = nil) {
        guard markFinished() else { return }
        // A close frame can arrive just before the error that ends the task: its code still goes with it (read before
        // the cancel), so a reader that tells one close from another — the chat's 4408 and 4410 — is not misled.
        let code = code ?? (task.closeCode == .invalid ? nil : task.closeCode.rawValue)
        task.cancel()
        session.finishTasksAndInvalidate()
        events.closed(byServer, detail, code)
    }
}
