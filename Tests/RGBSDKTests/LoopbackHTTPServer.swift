import Foundation
@preconcurrency import Network

/// Test-only HTTP/1.1 peer. Binds an ephemeral loopback port and uses real sockets;
/// it does not intercept URLSession or replace the SDK transport. Shared with
/// the ordinary-import consumer fixture. No production/backend service is used.
final class LoopbackHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    struct Response: Sendable {
        var status = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body = Data()
        var chunked = false
        var declaredLength: Int? = nil
        var beforeHeadersMilliseconds: UInt64 = 0
        var beforeBodyMilliseconds: UInt64 = 0

        static func json(_ text: String, status: Int = 200) -> Self {
            Self(status: status, body: Data(text.utf8))
        }
    }

    enum Failure: Error { case unavailable, malformedRequest, requestTimeout }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "org.utexo.test.loopback")
    private let lock = NSLock()
    private let handler: @Sendable (Request) async throws -> Response
    private var connections: [UUID: NWConnection] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var requests: [Request] = []
    private var stopped = false

    init(handler: @escaping @Sendable (Request) async throws -> Response) throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let readiness = ListenerReadiness(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: readiness.finish(nil)
                case let .failed(error): readiness.finish(error)
                case .cancelled: readiness.finish(Failure.unavailable)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
        guard let port = listener.port,
              let url = URL(string: "http://127.0.0.1:\(port.rawValue)") else { throw Failure.unavailable }
        return url
    }

    func snapshot() -> [Request] { lock.withLock { requests } }

    func waitForRequests(_ count: Int) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while snapshot().count < count {
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw Failure.requestTimeout }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func stop() {
        let work = lock.withLock { () -> ([NWConnection], [Task<Void, Never>]) in
            stopped = true
            let work = (Array(connections.values), Array(tasks.values))
            connections.removeAll(); tasks.removeAll()
            return work
        }
        listener.cancel()
        for task in work.1 { task.cancel() }
        for connection in work.0 { connection.cancel() }
    }

    deinit { stop() }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        lock.withLock {
            guard !stopped else { connection.cancel(); return }
            connections[id] = connection
            connection.start(queue: queue)
            tasks[id] = Task { [weak self] in
                guard let self else { connection.cancel(); return }
                defer {
                    connection.cancel()
                    self.lock.withLock { self.connections[id] = nil; self.tasks[id] = nil }
                }
                do {
                    let request = try await Self.readRequest(connection)
                    self.lock.withLock { self.requests.append(request) }
                    let response = try await self.handler(request)
                    try await Self.writeResponse(response, connection: connection)
                } catch {
                    // Deliberate client cancellations/truncated messages are
                    // exercised by tests. Never print credentials or bodies.
                }
            }
        }
    }

    private static func readRequest(_ connection: NWConnection) async throws -> Request {
        var bytes = Data()
        let delimiter = Data([13, 10, 13, 10])
        var headerEnd: Data.Index?
        while headerEnd == nil {
            bytes.append(try await receive(connection))
            guard bytes.count <= 131_072 else { throw Failure.malformedRequest }
            headerEnd = bytes.range(of: delimiter)?.upperBound
        }
        guard let headerEnd, let header = String(data: bytes[..<headerEnd], encoding: .utf8) else {
            throw Failure.malformedRequest
        }
        let lines = header.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3 else { throw Failure.malformedRequest }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let split = line.firstIndex(of: ":") else { throw Failure.malformedRequest }
            let key = line[..<split].lowercased()
            guard headers[key] == nil else { throw Failure.malformedRequest }
            headers[key] = String(line[line.index(after: split)...]).trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil,
              let count = Int(headers["content-length"] ?? "0"), (0...131_072).contains(count) else {
            throw Failure.malformedRequest
        }
        var body = Data(bytes[headerEnd...])
        while body.count < count {
            body.append(try await receive(connection))
            guard body.count <= 131_072 else { throw Failure.malformedRequest }
        }
        guard body.count == count else { throw Failure.malformedRequest }
        return Request(method: String(first[0]), path: String(first[1]), headers: headers, body: body)
    }

    private static func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(throwing: complete ? Failure.malformedRequest : Failure.unavailable) }
            }
        }
    }

    private static func writeResponse(_ response: Response, connection: NWConnection) async throws {
        if response.beforeHeadersMilliseconds > 0 {
            try await Task.sleep(nanoseconds: response.beforeHeadersMilliseconds * 1_000_000)
        }
        var headers = response.headers
        headers["Connection"] = "close"
        if response.chunked { headers["Transfer-Encoding"] = "chunked" }
        else { headers["Content-Length"] = String(response.declaredLength ?? response.body.count) }
        let head = "HTTP/1.1 \(response.status) Fixture\r\n"
            + headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
        try await send(Data(head.utf8), connection)
        if response.beforeBodyMilliseconds > 0 {
            try await Task.sleep(nanoseconds: response.beforeBodyMilliseconds * 1_000_000)
        }
        if response.chunked {
            for offset in stride(from: 0, to: response.body.count, by: 127) {
                let chunk = response.body[offset..<min(offset + 127, response.body.count)]
                var data = Data("\(String(chunk.count, radix: 16))\r\n".utf8)
                data.append(chunk); data.append(contentsOf: [13, 10])
                try await send(data, connection)
            }
            try await send(Data("0\r\n\r\n".utf8), connection)
        } else { try await send(response.body, connection) }
    }

    private static func send(_ data: Data, _ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
}

private final class ListenerReadiness: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func finish(_ error: Error?) {
        lock.withLock {
            guard let continuation else { return }
            self.continuation = nil
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        }
    }
}
