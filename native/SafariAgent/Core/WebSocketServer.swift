import Foundation
import Network

/// One WebSocket client of the helper.
final class WSClient: Hashable {
    let id = UUID()
    let connection: NWConnection
    var role: String = "unauthenticated"
    var conversationId: String?   // for MCP bridge clients
    var onMessage: ((WSClient, JSONObject) -> Void)?
    var onClose: ((WSClient) -> Void)?
    private var closed = false
    private let queue: DispatchQueue

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    static func == (a: WSClient, b: WSClient) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled: self.finish()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let error {
                Log.helper.debug("ws receive error: \(String(describing: error), privacy: .public)")
                self.finish()
                return
            }
            if let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                if meta.opcode == .close { self.finish(); return }
                if meta.opcode == .text || meta.opcode == .binary, let data, let obj = JSON.parse(data) {
                    self.onMessage?(self, obj)
                }
            }
            if !self.closed { self.receive() }
        }
    }

    func send(_ obj: JSONObject) {
        guard !closed else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "msg", metadata: [meta])
        connection.send(content: JSON.data(obj), contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    func close() {
        guard !closed else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .close)
        meta.closeCode = .protocolCode(.normalClosure)
        let ctx = NWConnection.ContentContext(identifier: "close", metadata: [meta])
        connection.send(content: nil, contentContext: ctx, isComplete: true, completion: .contentProcessed { [weak self] _ in self?.connection.cancel() })
        finish()
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?(self)
    }
}

/// WebSocket server bound to the loopback interface only.
/// Browser pages cannot use it: connections that carry a web Origin are refused
/// during the handshake, and every client must authenticate with a secret.
final class WebSocketServer {
    private var listener: NWListener?
    private let queue: DispatchQueue
    private(set) var port: UInt16 = 0
    var onClient: ((WSClient) -> Void)?

    init(queue: DispatchQueue) { self.queue = queue }

    /// Origins allowed to connect. Browsers always send Origin for WebSocket
    /// handshakes, so web pages present http(s) origins and are refused.
    static func isAllowedOrigin(_ origin: String?) -> Bool {
        guard let origin, !origin.isEmpty else { return true } // native clients (MCP bridge, tests)
        return origin.hasPrefix("safari-web-extension://")
    }

    func start(completion: @escaping (Result<UInt16, Error>) -> Void) {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 64 * 1024 * 1024
        ws.setClientRequestHandler(queue) { _, headers in
            let origin = headers.first { $0.name.lowercased() == "origin" }?.value
            if WebSocketServer.isAllowedOrigin(origin) {
                return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
            }
            Log.helper.notice("rejected websocket from disallowed origin")
            return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil)
        }
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        do {
            let l = try NWListener(using: params)
            listener = l
            var reported = false
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = l.port?.rawValue ?? 0
                    if !reported { reported = true; completion(.success(self.port)) }
                case .failed(let err):
                    if !reported { reported = true; completion(.failure(err)) }
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                // Defense in depth: only accept loopback peers.
                if case let .hostPort(host, _) = conn.endpoint {
                    let h = "\(host)"
                    if !(h == "127.0.0.1" || h == "::1" || h.hasPrefix("127.")) { conn.cancel(); return }
                }
                let client = WSClient(connection: conn, queue: self.queue)
                self.onClient?(client)
                client.start()
            }
            l.start(queue: queue)
        } catch {
            completion(.failure(error))
        }
    }

    func stop() { listener?.cancel() }
}
