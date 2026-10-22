import Foundation

/// The HTTP seam: `URLSessionTransport` in the app, `StubTransport` in tests.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (status: Int, body: Data)
    /// Newline-delimited streaming body. The status is known before the first line.
    func lines(for request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>)
}

private struct UncheckedSendable<T>: @unchecked Sendable { let value: T }

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func data(for request: URLRequest) async throws -> (status: Int, body: Data) {
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    public func lines(for request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let boxed = UncheckedSendable(value: bytes)
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in boxed.value.lines {
                        try Task.checkCancellation()
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (status, stream)
    }
}

/// Canned responses plus a record of every request, like `RecordingCommandRunner`.
public final class StubTransport: HTTPTransport, @unchecked Sendable {
    public typealias Handler = @Sendable (URLRequest) throws -> (status: Int, body: Data)
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private let handler: Handler

    public init(handler: @escaping Handler) { self.handler = handler }

    public var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    public func data(for request: URLRequest) async throws -> (status: Int, body: Data) {
        lock.withLock { _requests.append(request) }
        return try handler(request)
    }

    public func lines(for request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
        lock.withLock { _requests.append(request) }
        let (status, body) = try handler(request)
        let lines = String(decoding: body, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return (status, AsyncThrowingStream { c in
            for line in lines { c.yield(line) }
            c.finish()
        })
    }
}
