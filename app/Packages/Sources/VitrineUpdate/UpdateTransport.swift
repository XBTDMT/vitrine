// The only network code in Vitrine (G-21): GET the feed, GET the disk image. HTTPS only; a redirect is followed only to
// HTTPS on the same host; no cookies, no cache, no credentials, nothing sent but the request line and standard headers.
// Bodies are capped while they stream, and the disk image is hashed as it is written.
public import Foundation
import CryptoKit
import Synchronization

public protocol UpdateTransport: Sendable {
    /// The body of `url`, refused past `limit` bytes.
    func fetch(_ url: URL, limit: Int) async throws(UpdateError) -> Data
    /// Streams `url` into `file` (created 0600, must not exist), refused past `limit` bytes; returns the size and
    /// lowercase-hex SHA-256 of what was written.
    func download(_ url: URL, to file: URL, limit: Int64) async throws(UpdateError) -> (size: Int64, sha256: String)
}

public final class URLSessionUpdateTransport: UpdateTransport {
    private let protocolClasses: [AnyClass]?
    private let requestTimeout: TimeInterval
    private let resourceTimeout: TimeInterval

    /// `protocolClasses` replaces the system's URL loaders (tests pass a stub, so nothing reaches the network).
    public init(protocolClasses: [AnyClass]? = nil, requestTimeout: TimeInterval = 30, resourceTimeout: TimeInterval = 600) {
        self.protocolClasses = protocolClasses
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
    }

    public func fetch(_ url: URL, limit: Int) async throws(UpdateError) -> Data {
        let sink = Sink.memory(Data())
        let result = try await run(url, limit: Int64(limit), sink: sink)
        return result.data
    }

    public func download(_ url: URL, to file: URL, limit: Int64) async throws(UpdateError) -> (size: Int64, sha256: String) {
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: file) else { throw .fileSystem("create download file") }
        let result: Loader.Result
        do {
            result = try await run(url, limit: limit, sink: .file(handle))
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        do { try handle.synchronize(); try handle.close() } catch { throw .fileSystem("finish download file") }
        return (result.size, result.sha256)
    }

    // MARK: -

    enum Sink {
        case memory(Data), file(FileHandle)
        var isMemory: Bool { if case .memory = self { true } else { false } }
    }

    private func run(_ url: URL, limit: Int64, sink: Sink) async throws(UpdateError) -> Loader.Result {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else {
            throw .insecureURL(url.absoluteString)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        if let protocolClasses { configuration.protocolClasses = protocolClasses }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false

        let loader = Loader(host: host, limit: limit, sink: sink)
        let session = URLSession(configuration: configuration, delegate: loader, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let outcome: Result<Loader.Result, UpdateError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                loader.start(session.dataTask(with: request), continuation: continuation)
            }
        } onCancel: {
            loader.cancel()
        }
        return try outcome.get()
    }

    /// One request's state. URLSession calls it on its own serial delegate queue; the lock covers `cancel()` from the
    /// awaiting task.
    final class Loader: NSObject, URLSessionDataDelegate, Sendable {
        struct Result: Sendable {
            var data: Data
            var size: Int64
            var sha256: String
        }

        private struct State {
            var sink: Sink
            var received: Int64 = 0
            var hasher = SHA256()
            var failure: UpdateError?
            var continuation: CheckedContinuation<Swift.Result<Result, UpdateError>, Never>?
            var task: URLSessionTask?
        }

        private let host: String
        private let limit: Int64
        private let state: Mutex<State>

        init(host: String, limit: Int64, sink: Sink) {
            self.host = host
            self.limit = limit
            self.state = Mutex(State(sink: sink))
        }

        func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<Swift.Result<Result, UpdateError>, Never>) {
            let cancelled = state.withLock {
                $0.continuation = continuation
                $0.task = task
                return $0.failure != nil
            }
            // Cancelled before it started: it still runs to its completion callback, which reports the failure.
            if cancelled { task.cancel() }
            task.resume()
        }

        func cancel() { fail(.network("cancelled")) }

        /// Records the first failure and stops the request; the completion callback then reports it.
        private func fail(_ error: UpdateError) {
            let task: URLSessionTask? = state.withLock {
                if $0.failure == nil { $0.failure = error }
                return $0.task
            }
            task?.cancel()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            let target = request.url
            let targetHost = target?.host()?.lowercased() ?? "?"
            if target?.scheme?.lowercased() != "https" {
                fail(.insecureURL(target?.absoluteString ?? "?"))
                completionHandler(nil)
            } else if targetHost != host {
                fail(.redirectRefused(from: host, to: targetHost))
                completionHandler(nil)
            } else {
                completionHandler(request)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            let failed = state.withLock { $0.failure != nil }
            guard !failed else { return completionHandler(.cancel) }
            guard let http = response as? HTTPURLResponse, http.url?.scheme?.lowercased() == "https" else {
                fail(.insecureURL(response.url?.absoluteString ?? "?"))
                return completionHandler(.cancel)
            }
            guard http.statusCode == 200 else {
                fail(.httpStatus(http.statusCode))
                return completionHandler(.cancel)
            }
            if http.expectedContentLength > limit {
                let memory = state.withLock { $0.sink.isMemory }
                fail(Self.tooLarge(memory: memory, limit: limit, got: http.expectedContentLength))
                return completionHandler(.cancel)
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let overflow: UpdateError? = state.withLock { s in
                guard s.failure == nil else { return nil }
                s.received += Int64(data.count)
                if s.received > limit { return Self.tooLarge(memory: s.sink.isMemory, limit: limit, got: s.received) }
                s.hasher.update(data: data)
                switch s.sink {
                case .memory(var buffer):
                    buffer.append(data)
                    s.sink = .memory(buffer)
                case .file(let handle):
                    do { try handle.write(contentsOf: data) } catch { return .fileSystem("write download") }
                }
                return nil
            }
            if let overflow { fail(overflow) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            let (continuation, outcome): (CheckedContinuation<Swift.Result<Result, UpdateError>, Never>?, Swift.Result<Result, UpdateError>) =
                state.withLock { s in
                    let c = s.continuation
                    s.continuation = nil
                    s.task = nil
                    if let failure = s.failure { return (c, .failure(failure)) }
                    if let error { return (c, .failure(.network(Self.describe(error)))) }
                    let data: Data
                    if case .memory(let buffer) = s.sink { data = buffer } else { data = Data() }
                    let digest = s.hasher.finalize().map { String(format: "%02x", $0) }.joined()
                    return (c, .success(Result(data: data, size: s.received, sha256: digest)))
                }
            continuation?.resume(returning: outcome)
        }

        private static func tooLarge(memory: Bool, limit: Int64, got: Int64) -> UpdateError {
            memory ? .feedTooLarge : .downloadSizeMismatch(expected: limit, got: got)
        }

        /// A URLError's kind, never its URL or any body.
        static func describe(_ error: any Error) -> String {
            guard let urlError = error as? URLError else { return "error" }
            switch urlError.code {
            case .notConnectedToInternet: return "offline"
            case .timedOut: return "timed out"
            case .cannotFindHost, .dnsLookupFailed: return "server not found"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
                return "secure connection failed"
            case .cancelled: return "cancelled"
            default: return "error \(urlError.code.rawValue)"
            }
        }
    }
}
