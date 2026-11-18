import Foundation
import Network
import Security
import CryptoKit
import AppKit

/// Sign in with ChatGPT (OpenAI's official OAuth flow for ChatGPT plan usage),
/// following https://developers.openai.com/siwc/token-sharing-open-source/sign-in
/// and the reference implementation in openai/sign-in-with-chatgpt-devkit.
enum SIWC {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static let usageScope = "chatgpt.tokens.use.direct"
    static let callbackPath = "/auth/callback"
    static let preferredPort: UInt16 = 1455
    static let appName = "Safari Agent"
}

struct ChatGPTCredentials: Codable {
    var clientId: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Double          // seconds since 1970
    var scopes: [String]
    var subject: String
    var email: String?
    var name: String?
}

/// Stores credentials in the user's login keychain.
enum CredentialStore {
    static let service = "dev.local.SafariAgent.chatgpt"

    static func load() -> ChatGPTCredentials? {
        guard let d = read(account: "credentials") else { return nil }
        return try? JSONDecoder().decode(ChatGPTCredentials.self, from: d)
    }
    static func save(_ c: ChatGPTCredentials) {
        if let d = try? JSONEncoder().encode(c) { write(account: "credentials", data: d) }
        write(account: "client_id", data: Data(c.clientId.utf8))
    }
    static func clear() { delete(account: "credentials") }
    static var issuedClientId: String? { read(account: "client_id").map { String(decoding: $0, as: UTF8.self) } }
    static func saveClientId(_ id: String) { write(account: "client_id", data: Data(id.utf8)) }

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func read(account: String) -> Data? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
    static func write(account: String, data: Data) {
        let q = base(account)
        let attrs: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(q as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = q
            add.merge(attrs) { $1 }
            add[kSecAttrLabel as String] = "Safari Agent – ChatGPT sign-in"
            SecItemAdd(add as CFDictionary, nil)
        }
    }
    static func delete(account: String) { SecItemDelete(base(account) as CFDictionary) }
}

// MARK: - OIDC discovery & ID token verification

struct OIDCConfig {
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let jwksURI: URL
    let revocationEndpoint: URL?
}

enum OIDC {
    private static var cached: OIDCConfig?

    static func discover() async throws -> OIDCConfig {
        if let c = cached { return c }
        let (d, r) = try await URLSession.shared.data(from: URL(string: "\(SIWC.issuer)/.well-known/openid-configuration")!)
        guard (r as? HTTPURLResponse)?.statusCode == 200, let o = JSON.parse(d), o["issuer"] as? String == SIWC.issuer,
              let a = (o["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
              let t = (o["token_endpoint"] as? String).flatMap(URL.init(string:)),
              let j = (o["jwks_uri"] as? String).flatMap(URL.init(string:)),
              [a, t, j].allSatisfy({ $0.scheme == "https" && $0.host == "auth.openai.com" }) else {
            throw AgentError("discovery_failed", "ChatGPT sign-in configuration could not be verified.")
        }
        let rev = (o["revocation_endpoint"] as? String).flatMap(URL.init(string:))
        let c = OIDCConfig(authorizationEndpoint: a, tokenEndpoint: t, jwksURI: j, revocationEndpoint: rev?.host == "auth.openai.com" ? rev : nil)
        cached = c
        return c
    }

    struct Identity { let subject: String; let email: String?; let name: String? }

    static func verify(idToken: String, clientId: String, nonce: String?, jwks: URL) async throws -> Identity {
        let parts = idToken.split(separator: ".").map(String.init)
        guard parts.count == 3, let hd = Data(base64URL: parts[0]), let pd = Data(base64URL: parts[1]), let sig = Data(base64URL: parts[2]),
              let header = JSON.parse(hd), let payload = JSON.parse(pd) else {
            throw AgentError("invalid_id_token", "ChatGPT returned an invalid identity token.")
        }
        guard header["alg"] as? String == "RS256" else { throw AgentError("invalid_id_token", "Unsupported identity token algorithm.") }
        let (jd, _) = try await URLSession.shared.data(from: jwks)
        guard let keys = JSON.parse(jd)?["keys"] as? [JSONObject] else { throw AgentError("identity_verification_unavailable", "ChatGPT identity keys are unavailable. Try again shortly.") }
        let kid = header["kid"] as? String
        guard let jwk = keys.first(where: { kid == nil || $0["kid"] as? String == kid }), jwk["kty"] as? String == "RSA",
              let n = (jwk["n"] as? String).flatMap({ Data(base64URL: $0) }), let e = (jwk["e"] as? String).flatMap({ Data(base64URL: $0) }) else {
            throw AgentError("invalid_id_token", "No matching key for the ChatGPT identity token.")
        }
        guard let key = rsaPublicKey(modulus: n, exponent: e) else { throw AgentError("invalid_id_token", "Invalid ChatGPT signing key.") }
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        var err: Unmanaged<CFError>?
        guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signingInput as CFData, sig as CFData, &err) else {
            throw AgentError("invalid_id_token", "The ChatGPT identity token signature is invalid.")
        }
        try validateClaims(payload, clientId: clientId, nonce: nonce, now: Date().timeIntervalSince1970)
        return Identity(subject: payload["sub"] as! String, email: payload["email"] as? String, name: payload["name"] as? String)
    }

    /// Claim checks (separate for unit testing).
    static func validateClaims(_ p: JSONObject, clientId: String, nonce: String?, now: Double) throws {
        let bad = AgentError("invalid_id_token", "The ChatGPT identity could not be verified. Please sign in again.")
        guard p["iss"] as? String == SIWC.issuer else { throw bad }
        let audOK: Bool
        if let a = p["aud"] as? String { audOK = a == clientId }
        else if let a = p["aud"] as? [String] { audOK = a.contains(clientId) && (a.count == 1 || p["azp"] as? String == clientId) }
        else { audOK = false }
        guard audOK else { throw bad }
        if let azp = p["azp"] as? String, azp != clientId { throw bad }
        guard let exp = (p["exp"] as? NSNumber)?.doubleValue, exp + 5 > now else { throw bad }
        guard let sub = p["sub"] as? String, !sub.isEmpty else { throw bad }
        if let nonce { guard p["nonce"] as? String == nonce else { throw bad } }
    }

    /// Build a SecKey from an RSA modulus/exponent (PKCS#1 RSAPublicKey DER).
    static func rsaPublicKey(modulus: Data, exponent: Data) -> SecKey? {
        let der = derSequence([derInteger(modulus), derInteger(exponent)])
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        return SecKeyCreateWithData(der as CFData, attrs as CFDictionary, nil)
    }
    static func derLength(_ n: Int) -> Data {
        if n < 0x80 { return Data([UInt8(n)]) }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
    static func derInteger(_ raw: Data) -> Data {
        var b = [UInt8](raw)
        while b.count > 1 && b[0] == 0 { b.removeFirst() }
        if let f = b.first, f & 0x80 != 0 { b.insert(0, at: 0) }
        return Data([0x02]) + derLength(b.count) + Data(b)
    }
    static func derSequence(_ items: [Data]) -> Data {
        let body = items.reduce(Data(), +)
        return Data([0x30]) + derLength(body.count) + body
    }
}

// MARK: - Loopback callback listener

/// Minimal HTTP server on 127.0.0.1 that receives the OAuth redirect.
final class LoopbackCallback {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "dev.local.SafariAgent.oauth")
    private(set) var port: UInt16 = 0
    private let expectedState: String
    private var completion: ((Result<[String: String], AgentError>) -> Void)?
    private var done = false

    init(state: String) { expectedState = state }

    var redirectURI: String { "http://127.0.0.1:\(port)\(SIWC.callbackPath)" }

    func start(preferred: UInt16) async throws {
        do { try await listen(on: preferred) }
        catch { try await listen(on: 0) }
    }

    private func listen(on p: UInt16) async throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: p) ?? .any)
        params.requiredInterfaceType = .loopback
        let l = try NWListener(using: params)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            l.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready:
                    self?.port = l.port?.rawValue ?? 0
                    if !resumed { resumed = true; cont.resume() }
                case .failed(let e):
                    if !resumed { resumed = true; cont.resume(throwing: e) }
                    l.cancel()
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.handle(c) }
            l.start(queue: queue)
        }
        listener = l
    }

    func wait(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: String], Error>) in
            queue.async {
                self.completion = { r in
                    switch r {
                    case .success(let v): cont.resume(returning: v)
                    case .failure(let e): cont.resume(throwing: e)
                    }
                }
                self.queue.asyncAfter(deadline: .now() + timeout) { self.finish(.failure(AgentError("timeout", "ChatGPT sign-in timed out."))) }
            }
        }
    }

    func cancel() { queue.async { self.finish(.failure(AgentError("cancelled", "Sign-in was cancelled."))) } }

    private func finish(_ r: Result<[String: String], AgentError>) {
        guard !done else { return }
        done = true
        listener?.cancel()
        completion?(r)
        completion = nil
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data else { c.cancel(); return }
            let req = String(decoding: data, as: UTF8.self)
            let (status, body, result) = self.process(request: req)
            let html = "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><title>Safari Agent</title><style>body{font:16px -apple-system,system-ui;max-width:32rem;margin:18vh auto;padding:24px;color:#1d1d1f}@media(prefers-color-scheme:dark){body{background:#1e1e20;color:#f2f2f4}}h1{font-size:24px}</style>\(body)</html>"
            let resp = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'\r\nConnection: close\r\nContent-Length: \(html.utf8.count)\r\n\r\n\(html)"
            c.send(content: Data(resp.utf8), completion: .contentProcessed { _ in c.cancel() })
            if let result { self.finish(result) }
        }
    }

    /// Validates the callback request. Unrelated requests don't consume the pending sign-in.
    func process(request: String) -> (String, String, Result<[String: String], AgentError>?) {
        let lines = request.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return ("405 Method Not Allowed", "<p>Not allowed</p>", nil) }
        let host = lines.first { $0.lowercased().hasPrefix("host:") }?.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard host == "127.0.0.1:\(port)" else { return ("400 Bad Request", "<p>Invalid host</p>", nil) }
        guard let comps = URLComponents(string: "http://127.0.0.1\(parts[1])"), comps.path == SIWC.callbackPath else {
            return ("404 Not Found", "<p>Not found</p>", nil)
        }
        var q: [String: String] = [:]
        var dup = false
        for item in comps.queryItems ?? [] {
            if q[item.name] != nil { dup = true }
            q[item.name] = item.value ?? ""
        }
        guard !dup, let st = q["state"], constantTimeEqual(st, expectedState) else {
            return ("400 Bad Request", "<h1>Invalid sign-in state</h1><p>Return to the browser tab that started sign-in.</p>", nil)
        }
        if let e = q["error"] {
            let msg = e == "access_denied" ? "ChatGPT access was not granted." : "ChatGPT sign-in failed (\(e))."
            return ("200 OK", "<h1>Sign-in not completed</h1><p>\(msg) You can close this tab.</p>", .failure(AgentError(e, msg)))
        }
        return ("200 OK", "<h1>Return to Safari</h1><p>Safari Agent is finishing your ChatGPT connection. You can close this tab.</p>", .success(q))
    }
}

// MARK: - OAuth flows

enum ChatGPTOAuth {
    static func pkceChallenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }

    static func signIn(previous: ChatGPTCredentials?) async throws -> ChatGPTCredentials {
        let cfg = try await OIDC.discover()
        let state = Random.token(), nonce = Random.token(), verifier = Random.token()
        let cb = LoopbackCallback(state: state)
        try await cb.start(preferred: SIWC.preferredPort)
        let savedClient: String?
        if let id = previous?.clientId { savedClient = id } else {
            savedClient = await withCheckedContinuation { c in DispatchQueue.global().async { c.resume(returning: CredentialStore.issuedClientId) } }
        }
        var comps = URLComponents(url: cfg.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            .init(name: "client_id", value: savedClient ?? "dynamic_agent_client"),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: cb.redirectURI),
            .init(name: "scope", value: SIWC.scopes),
            .init(name: "resource", value: SIWC.resource),
            .init(name: "state", value: state),
            .init(name: "nonce", value: nonce),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: pkceChallenge(verifier)),
        ]
        if savedClient == nil { items.append(.init(name: "agent_name_hint", value: SIWC.appName)) }
        if let email = previous?.email { items.append(.init(name: "login_hint", value: email)) }
        comps.queryItems = items
        await MainActor.run { _ = NSWorkspace.shared.open(comps.url!) }
        let q = try await cb.wait(timeout: 10 * 60)
        guard let code = q["code"], !code.isEmpty else { throw AgentError("registration_incomplete", "ChatGPT did not complete app registration. Please try again.") }
        let returnedClient = q["client_id"]
        let clientId = returnedClient ?? savedClient
        guard let clientId, clientId != "dynamic_agent_client", clientId.range(of: "^[A-Za-z0-9_-]{1,200}$", options: .regularExpression) != nil else {
            throw AgentError("registration_incomplete", "ChatGPT did not complete app registration. Please try again.")
        }
        if let savedClient, let returnedClient, savedClient != returnedClient {
            throw AgentError("registration_mismatch", "ChatGPT returned a different app registration. Please try again.")
        }
        CredentialStore.saveClientId(clientId)
        let data = try await tokenRequest(cfg.tokenEndpoint, [
            "grant_type": "authorization_code", "client_id": clientId, "code": code, "code_verifier": verifier,
            "redirect_uri": cb.redirectURI, "resource": SIWC.resource,
        ])
        guard let idToken = data["id_token"] as? String else { throw AgentError("invalid_id_token", "ChatGPT did not return a verifiable identity.") }
        let ident = try await OIDC.verify(idToken: idToken, clientId: clientId, nonce: nonce, jwks: cfg.jwksURI)
        if let prev = previous, prev.subject != ident.subject {
            throw AgentError("account_mismatch", "This sign-in returned a different ChatGPT account.")
        }
        return try credentials(from: data, clientId: clientId, identity: ident, requireRefresh: false)
    }

    static func refresh(_ c: ChatGPTCredentials) async throws -> ChatGPTCredentials {
        guard let rt = c.refreshToken else { throw AgentError("invalid_grant", "Your ChatGPT connection has expired. Sign in again.") }
        let cfg = try await OIDC.discover()
        var data = try await tokenRequest(cfg.tokenEndpoint, ["grant_type": "refresh_token", "client_id": c.clientId, "refresh_token": rt, "resource": SIWC.resource])
        if data["scope"] == nil { data["scope"] = c.scopes.joined(separator: " ") }
        var ident = OIDC.Identity(subject: c.subject, email: c.email, name: c.name)
        if let idt = data["id_token"] as? String {
            ident = try await OIDC.verify(idToken: idt, clientId: c.clientId, nonce: nil, jwks: cfg.jwksURI)
            guard ident.subject == c.subject else { throw AgentError("account_mismatch", "The refreshed ChatGPT identity does not match. Sign in again.") }
        }
        return try credentials(from: data, clientId: c.clientId, identity: ident, requireRefresh: true)
    }

    static func revoke(_ c: ChatGPTCredentials) async {
        guard let rt = c.refreshToken, let cfg = try? await OIDC.discover(), let ep = cfg.revocationEndpoint else { return }
        var req = URLRequest(url: ep)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form(["token": rt, "token_type_hint": "refresh_token", "client_id": c.clientId])
        _ = try? await URLSession.shared.data(for: req)
    }

    static func credentials(from d: JSONObject, clientId: String, identity: OIDC.Identity, requireRefresh: Bool) throws -> ChatGPTCredentials {
        guard let scope = d["scope"] as? String else { throw AgentError("invalid_token_response", "ChatGPT did not confirm the granted permissions.") }
        let scopes = scope.split(whereSeparator: { $0 == " " }).map(String.init)
        guard let at = d["access_token"] as? String, !at.isEmpty, (d["token_type"] as? String)?.lowercased() == "bearer",
              let exp = (d["expires_in"] as? NSNumber)?.doubleValue, exp > 0 else {
            throw AgentError("invalid_token_response", "ChatGPT returned incomplete credentials. Please sign in again.")
        }
        let rt = d["refresh_token"] as? String
        if (requireRefresh || scopes.contains("offline_access")) && (rt ?? "").isEmpty {
            throw AgentError("invalid_token_response", "ChatGPT did not return a refresh token. Please sign in again.")
        }
        return ChatGPTCredentials(clientId: clientId, accessToken: at, refreshToken: rt, expiresAt: Date().timeIntervalSince1970 + exp, scopes: scopes,
                                  subject: identity.subject, email: identity.email, name: identity.name)
    }

    static func form(_ p: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return Data(p.sorted { $0.key < $1.key }.map { "\(enc($0.key))=\(enc($0.value))" }.joined(separator: "&").utf8)
    }

    static func tokenRequest(_ url: URL, _ params: [String: String]) async throws -> JSONObject {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = form(params)
        req.timeoutInterval = 30
        let (d, r) = try await URLSession.shared.data(for: req)
        let obj = JSON.parse(d) ?? [:]
        guard let http = r as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (obj["error"] as? String) ?? ((obj["error"] as? JSONObject)?["code"] as? String) ?? "token_error"
            if code == "invalid_grant" { throw AgentError("invalid_grant", "Your ChatGPT connection has expired or was revoked. Sign in again.") }
            let desc = (obj["error_description"] as? String) ?? ((obj["error"] as? JSONObject)?["message"] as? String) ?? "HTTP \((r as? HTTPURLResponse)?.statusCode ?? 0)"
            throw AgentError(code, "ChatGPT sign-in failed: \(desc)")
        }
        return obj
    }
}
