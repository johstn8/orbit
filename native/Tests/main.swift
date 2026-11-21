// Unit tests for the native helper. Built and run by scripts/test-native.sh
// (main.swift; compiled together with the app's Core and Providers sources).
import Foundation
import Security
import Network

var failures = 0
var passes = 0
func check(_ cond: @autoclosure () -> Bool, _ name: String, file: String = #file, line: Int = #line) {
    if cond() { passes += 1 } else { failures += 1; print("  ✗ \(name) (line \(line))") }
}
func section(_ s: String) { print("• \(s)") }

// MARK: JWT / RSA

section("RS256 ID token verification primitives")
do {
    let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
    var err: Unmanaged<CFError>?
    let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &err)!
    let pub = SecKeyCopyPublicKey(priv)!
    let der = SecKeyCopyExternalRepresentation(pub, nil)! as Data   // PKCS#1 RSAPublicKey
    // Parse modulus/exponent out of the DER to simulate a JWK.
    func readTLV(_ b: [UInt8], _ i: inout Int) -> [UInt8] {
        i += 1
        var len = Int(b[i]); i += 1
        if len & 0x80 != 0 { let n = len & 0x7f; len = 0; for _ in 0..<n { len = (len << 8) | Int(b[i]); i += 1 } }
        let v = Array(b[i..<(i + len)]); i += len
        return v
    }
    let bytes = [UInt8](der)
    var i = 0
    let seq = readTLV(bytes, &i)
    var j = 0
    let n = readTLV(seq, &j), e = readTLV(seq, &j)
    let rebuilt = OIDC.rsaPublicKey(modulus: Data(n), exponent: Data(e))
    check(rebuilt != nil, "rebuild RSA key from n/e")
    let header = Data(#"{"alg":"RS256","kid":"k1"}"#.utf8).base64URLEncoded()
    let payload = Data(#"{"sub":"user-1"}"#.utf8).base64URLEncoded()
    let input = Data("\(header).\(payload)".utf8)
    let sig = SecKeyCreateSignature(priv, .rsaSignatureMessagePKCS1v15SHA256, input as CFData, nil)! as Data
    check(SecKeyVerifySignature(rebuilt!, .rsaSignatureMessagePKCS1v15SHA256, input as CFData, sig as CFData, nil), "valid signature verifies with rebuilt key")
    var tampered = input; tampered[tampered.count - 1] ^= 1
    check(!SecKeyVerifySignature(rebuilt!, .rsaSignatureMessagePKCS1v15SHA256, tampered as CFData, sig as CFData, nil), "tampered payload fails")
    check(OIDC.derInteger(Data([0x80])) == Data([0x02, 0x02, 0x00, 0x80]), "DER integer adds sign byte")
    check(OIDC.derLength(300) == Data([0x82, 0x01, 0x2c]), "DER long length")
}

section("ID token claims")
do {
    let now = 1_800_000_000.0
    let good: JSONObject = ["iss": SIWC.issuer, "aud": "oaiapp_1", "exp": now + 100, "sub": "u1", "nonce": "n1"]
    check((try? OIDC.validateClaims(good, clientId: "oaiapp_1", nonce: "n1", now: now)) != nil, "valid claims accepted")
    func rejects(_ mod: (inout JSONObject) -> Void, _ name: String, nonce: String? = "n1") {
        var c = good; mod(&c)
        check((try? OIDC.validateClaims(c, clientId: "oaiapp_1", nonce: nonce, now: now)) == nil, name)
    }
    rejects({ $0["iss"] = "https://evil.test" }, "wrong issuer rejected")
    rejects({ $0["aud"] = "other" }, "wrong audience rejected")
    rejects({ $0["exp"] = now - 60 }, "expired token rejected")
    rejects({ $0["nonce"] = "n2" }, "wrong nonce rejected")
    rejects({ $0["sub"] = "" }, "empty subject rejected")
    rejects({ $0["aud"] = ["oaiapp_1", "x"] }, "multi-audience without azp rejected")
}

// MARK: OAuth callback & token response

section("Loopback OAuth callback validation")
do {
    let cb = LoopbackCallback(state: "STATE123")
    // port is 0 before start; requests must carry Host 127.0.0.1:0
    let ok = cb.process(request: "GET /auth/callback?code=abc&state=STATE123&client_id=oaiapp_9 HTTP/1.1\r\nHost: 127.0.0.1:0\r\n\r\n")
    if case .success(let q)? = ok.2 { check(q["code"] == "abc" && q["client_id"] == "oaiapp_9", "valid callback returns code + client id") } else { check(false, "valid callback accepted") }
    check(cb.process(request: "GET /auth/callback?code=abc&state=WRONG HTTP/1.1\r\nHost: 127.0.0.1:0\r\n\r\n").2 == nil, "wrong state ignored (does not consume sign-in)")
    check(cb.process(request: "GET /auth/callback?code=abc&state=STATE123 HTTP/1.1\r\nHost: evil.test\r\n\r\n").2 == nil, "foreign Host rejected (DNS rebinding)")
    check(cb.process(request: "GET /auth/callback?code=a&code=b&state=STATE123 HTTP/1.1\r\nHost: 127.0.0.1:0\r\n\r\n").2 == nil, "duplicate params rejected")
    check(cb.process(request: "POST /auth/callback?code=a&state=STATE123 HTTP/1.1\r\nHost: 127.0.0.1:0\r\n\r\n").2 == nil, "POST rejected")
    if case .failure(let e)? = cb.process(request: "GET /auth/callback?error=access_denied&state=STATE123 HTTP/1.1\r\nHost: 127.0.0.1:0\r\n\r\n").2 {
        check(e.code == "access_denied", "denial reported")
    } else { check(false, "denial reported") }
}

section("Token response handling")
do {
    let ident = OIDC.Identity(subject: "u", email: "a@b.c", name: nil)
    let full: JSONObject = ["access_token": "at", "refresh_token": "rt", "token_type": "Bearer", "expires_in": 3600, "scope": "openid offline_access chatgpt.tokens.use.direct"]
    let c = try? ChatGPTOAuth.credentials(from: full, clientId: "oaiapp_1", identity: ident, requireRefresh: false)
    check(c?.scopes.contains("chatgpt.tokens.use.direct") == true && c?.refreshToken == "rt", "credentials parsed")
    var noRefresh = full; noRefresh["refresh_token"] = nil
    check((try? ChatGPTOAuth.credentials(from: noRefresh, clientId: "x", identity: ident, requireRefresh: false)) == nil, "offline_access without refresh token rejected")
    var badType = full; badType["token_type"] = "mac"
    check((try? ChatGPTOAuth.credentials(from: badType, clientId: "x", identity: ident, requireRefresh: false)) == nil, "non-bearer rejected")
    let form = String(decoding: ChatGPTOAuth.form(["a": "x+y&z=1 /", "b": "ok"]), as: UTF8.self)
    check(form == "a=x%2By%26z%3D1%20%2F&b=ok", "form encoding escapes reserved characters (\(form))")
    check(ChatGPTOAuth.pkceChallenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "PKCE S256 matches RFC 7636 example")
}

// MARK: Responses API helpers

section("SSE parsing and history handling")
do {
    var p = SSEParser()
    check(p.feed("event: response.output_text.delta") == nil, "event line ignored")
    check(p.feed("data: {\"a\":1}") == nil, "data buffered")
    check(p.feed("") == "{\"a\":1}", "blank line completes event")
    _ = p.feed(": keepalive")
    _ = p.feed("data: x"); _ = p.feed("data: y")
    check(p.flush() == "x\ny", "multi-line data joined")

    let items: [JSONObject] = [
        ["role": "user", "content": "hi"],
        ["type": "function_call", "call_id": "c1", "name": "read_page", "arguments": "{}"],
        ["type": "function_call_output", "call_id": "c1", "output": [["type": "input_image", "image_url": "data:image/jpeg;base64,AAAA"], ["type": "input_text", "text": "shot"]]],
        ["type": "function_call", "call_id": "c2", "name": "click", "arguments": "{}"],
    ]
    let closed = ChatGPTProvider.closeDanglingCalls(items)
    check(closed.count == 5 && closed.last?["call_id"] as? String == "c2", "dangling function call gets an output")
    let compacted = ChatGPTProvider.compact(closed)
    check(!JSON.string(compacted).contains("base64"), "screenshots removed from persisted history")
    let img = ChatGPTProvider.outputPayload(ToolOutcome(content: [["type": "image", "data": "AAAA", "mediaType": "image/png"], ["type": "text", "text": "t"]], isError: false))
    check((img as? [JSONObject])?.first?["type"] as? String == "input_image", "image tool output becomes input_image")
    check(ChatGPTProvider.outputPayload(.error("nope")) as? String == "Error: nope", "error output prefixed")
    let usage = ChatGPTProvider.apiError(["error": ["code": "subscription_sharing_usage_limit_exceeded"]], status: 200)
    check(usage.message.contains("usage limit"), "plan usage limit mapped to friendly message")
}

// MARK: Claude

section("Claude error mapping and prompts")
do {
    check(ClaudeProvider.mapError(result: "Invalid API key · Please run /login", subtype: "error", stderr: "").code == "auth", "auth error mapped")
    check(ClaudeProvider.mapError(result: nil, subtype: "error_max_turns", stderr: "").code == "max_turns", "max turns mapped")
    let msg = Prompts.userMessage(text: "Summarize", context: ["tabId": 5, "url": "https://a.test", "title": "A", "selection": "picked"])
    check(msg.contains("tabId=5") && msg.contains("picked") && msg.hasSuffix("Summarize"), "user message carries tab context and selection")
    check(Prompts.system.contains("untrusted"), "system prompt marks web content untrusted")
    let env = ClaudeCLI.cleanEnvironment()
    check(env["ANTHROPIC_API_KEY"] == nil && env["ANTHROPIC_BASE_URL"] == nil && env["CLAUDECODE"] == nil, "CLI runs with a clean environment (no API keys / host overrides)")
}

// MARK: Conversation transcript

section("Conversation event application")
do {
    var c = Conversation(id: "c", title: "t", provider: "claude", model: nil, createdAt: 0, updatedAt: 0, messages: [], claudeSessionId: nil)
    c.apply(["kind": "message_start", "messageId": "m"])
    c.apply(["kind": "text_delta", "messageId": "m", "text": "Hel"])
    c.apply(["kind": "text_delta", "messageId": "m", "text": "lo"])
    c.apply(["kind": "tool_start", "messageId": "m", "toolId": "t1", "name": "click", "summary": "Clicking"])
    c.apply(["kind": "tool_end", "messageId": "m", "toolId": "t1", "status": "done", "detail": "ok"])
    c.apply(["kind": "tool_start", "messageId": "m", "toolId": "t2", "name": "read_page", "summary": "Reading"])
    c.apply(["kind": "done", "messageId": "m", "cancelled": true])
    let b = c.messages[0].blocks
    check(b.count == 4 && b[0].text == "Hello", "text deltas merged")
    check(b[1].status == "done" && b[2].status == "error", "unfinished tool marked on cancel")
    check(b[3].type == "notice", "cancel notice appended")
}

// MARK: WebSocket origin policy (live listener)

section("Loopback WebSocket server rejects web origins")
do {
    check(WebSocketServer.isAllowedOrigin(nil), "native clients (no Origin) allowed")
    check(WebSocketServer.isAllowedOrigin("safari-web-extension://ABCD-1234"), "extension origin allowed")
    check(!WebSocketServer.isAllowedOrigin("https://evil.example"), "web origin refused")
    check(!WebSocketServer.isAllowedOrigin("http://127.0.0.1:8765"), "localhost web page refused")

    let q = DispatchQueue(label: "t")
    let server = WebSocketServer(queue: q)
    let sem = DispatchSemaphore(value: 0)
    var port: UInt16 = 0
    var retained: [WSClient] = []   // the Hub normally retains clients
    server.onClient = { c in retained.append(c); c.onMessage = { cl, m in cl.send(["echo": m["x"] ?? ""]) } }
    server.start { r in if case .success(let p) = r { port = p }; sem.signal() }
    _ = sem.wait(timeout: .now() + 5)
    check(port > 0, "server listening")
    func attempt(origin: String?) -> Bool {
        var req = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/")!)
        if let origin { req.setValue(origin, forHTTPHeaderField: "Origin") }
        let task = URLSession.shared.webSocketTask(with: req)
        task.resume()
        let done = DispatchSemaphore(value: 0)
        var ok = false
        task.send(.string("{\"x\":\"hi\"}")) { _ in }
        task.receive { r in if case .success(.string(let s)) = r { ok = s.contains("hi") }; done.signal() }
        _ = done.wait(timeout: .now() + 4)
        task.cancel()
        return ok
    }
    check(attempt(origin: nil), "native client can talk")
    check(!attempt(origin: "https://evil.example"), "handshake from web origin fails")
    server.stop()
}


// MARK: Orbit features

section("Website routing patterns (shared fixture with the extension)")
do {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../tests/fixtures/routing-cases.json").standardizedFileURL
    let data = try! Data(contentsOf: fixture)
    let obj = JSON.parse(data)!
    for c in obj["matches"] as! [JSONObject] {
        let pattern = c["pattern"] as! String, url = c["url"] as! String, expect = c["expect"] as! Bool
        let got = URL(string: url).map { RoutePattern.matches(pattern, $0) } ?? false
        check(got == expect, "\(pattern) vs \(url) → \(expect)")
    }
    for c in obj["targets"] as! [JSONObject] {
        let rules = (c["rules"] as! [JSONObject]).map { RoutingRule(pattern: $0["pattern"] as! String, profileId: $0["profileId"] as! String, enabled: $0["enabled"] as? Bool ?? true) }
        let expect = c["expect"] as? String
        check(RoutePattern.target(for: URL(string: c["url"] as! String)!, rules: rules) == expect, "first matching rule for \(c["url"]!)")
    }
}

section("Computer access path policy")
do {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("orbit-tests-\(UUID().uuidString)").resolvingSymlinksInPath()
    let allowed = base.appendingPathComponent("allowed"), outside = base.appendingPathComponent("outside")
    try! fm.createDirectory(at: allowed, withIntermediateDirectories: true)
    try! fm.createDirectory(at: outside, withIntermediateDirectories: true)
    try! "secret".write(to: outside.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
    try! fm.createSymbolicLink(at: allowed.appendingPathComponent("escape"), withDestinationURL: outside)
    let policy = PathPolicy(access: "folders", folders: [allowed.path])
    check((try? policy.resolve(allowed.appendingPathComponent("a.txt").path, write: true)) != nil, "file inside an allowed folder")
    check((try? policy.resolve("notes/new.md", write: true))?.path == allowed.appendingPathComponent("notes/new.md").path, "relative path resolves into the first folder")
    check((try? policy.resolve(outside.appendingPathComponent("s.txt").path, write: false)) == nil, "file outside the allowed folders is refused")
    check((try? policy.resolve(allowed.appendingPathComponent("escape/s.txt").path, write: false)) == nil, "symlink escaping the folder is refused")
    check((try? policy.resolve(allowed.appendingPathComponent("../outside/s.txt").path, write: false)) == nil, "../ escaping the folder is refused")
    check((try? policy.resolve(allowed.path + "-sibling/x", write: false)) == nil, "sibling folder with the same prefix is refused")
    let full = PathPolicy(access: "full", folders: [])
    check((try? full.resolve("~/.ssh/id_ed25519", write: false)) == nil, "SSH keys are never available")
    check((try? full.resolve("~/Library/Keychains/login.keychain-db", write: false)) == nil, "Keychains are never available")
    check((try? full.resolve("~/Library/Application Support/SafariAgent/settings.json", write: false)) == nil, "Orbit's own data is never available")
    check((try? full.resolve("/etc/hosts", write: false)) != nil, "full access can read outside home")
    check((try? full.resolve("/etc/hosts", write: true)) == nil, "full access can't change files outside home")
    check((try? PathPolicy(access: "none", folders: []).resolve("~/x", write: false)) == nil, "no access refuses everything")
    try? fm.removeItem(at: base)
}

section("Tool catalog follows the computer-access setting")
do {
    var a = AgentSettings()
    check(NativeTools.catalog(a).isEmpty, "no file tools without computer access")
    a.computerAccess = "folders"
    let names = NativeTools.catalog(a).compactMap { $0["name"] as? String }
    check(names.contains("fs_read") && names.contains("fs_edit") && !names.contains("run_command"), "folder access: file tools, no commands")
    a.computerAccess = "full"; a.allowCommands = true
    check(NativeTools.catalog(a).contains { $0["name"] as? String == "run_command" }, "full access with commands offers run_command")
    check(NativeTools.handles("fs_write") && !NativeTools.handles("click"), "native vs browser tool routing")
    check(NativeTools.readsLocalData("fs_read") && !NativeTools.readsLocalData("fs_write"), "reading files marks a chat for the exfiltration guard")
}

section("Settings decoding keeps defaults for missing fields")
do {
    let old = Data(##"{"profiles":[{"id":"A","name":"Uni","symbol":"star","color":"#FF0000","order":0}],"routing":{"enabled":false}}"##.utf8)
    let s = AppSettings.decode(old)
    check(s.profiles.first?.name == "Uni", "profiles kept")
    check(s.routing.enabled == false && s.routing.typedNavigation == "keep", "missing routing fields get defaults")
    check(s.picker.design == "dock" && s.agent.computerAccess == "none", "missing sections get defaults")
    check(s.extensionConfig(for: "A")["profileId"] as? String == "A", "extension config carries the profile id")
}

section("Profile names from Safari's New Window menu")
do {
    check(SafariAX.extractNames(["New Personal Window", "New University Window", "New Work Window"]) == ["Personal", "University", "Work"], "English menu titles")
    check(SafariAX.extractNames(["Neues Fenster „Privat“", "Neues Fenster „Uni“"]) == ["Privat", "Uni"], "quoted (German) menu titles")
    check(SafariAX.extractNames(["New Side Project Window", "New Personal Window"]) == ["Side Project", "Personal"], "multi-word names")
    check(ProfileRegistry.guessSymbol("University") == "graduationcap.fill", "symbol guess for a university profile")
}

section("Prompt context describes permissions")
do {
    let t = Prompts.userMessage(text: "hi", context: ["tabId": 3, "url": "https://x.y/", "title": "X"],
                                env: Prompts.Environment(profileName: "Uni", otherProfiles: ["Work"], tabScope: "all", computerAccess: "folders", folders: ["/tmp/a"]))
    check(t.contains("Safari profile: Uni") && t.contains("other profiles: Work") && t.contains("Computer access: files in /tmp/a"), "browser_context lists profile, scope and folders")
}


section("Safari profile identity from Safari's UI")
do {
    check(SafariAX.menuIdentifierProfile("NewUniversit%C3%A4tWindow?isDefaultProfile=false")! == ("Universität", false), "menu identifier with umlaut")
    check(SafariAX.menuIdentifierProfile("NewPersonalWindow?isDefaultProfile=true")! == ("Personal", true), "default profile flag")
    check(SafariAX.menuIdentifierProfile("NewPrivateWindow") == nil, "private window item is ignored")
    let p = SafariAX.params("TabGroupPickerButton?Profile=Quant&Icon=bag.fill")
    check(p["Profile"] == "Quant" && p["Icon"] == "bag.fill", "window profile button identifier")
    var st = AppSettings()
    st.profiles = [ProfileConfig(id: "safari:Uni", name: "Uni", symbol: "star", color: "#000000", order: 1, detectedName: "Uni")]
    st.routing.rules = [RoutingRule(pattern: "uni.de", profileId: "safari:Uni")]
    st.sharing = [SharedSite(domain: "google.com", sourceProfileId: "A", targets: ["safari:Uni"])]
    ProfileRegistry.rename(&st, from: "safari:Uni", to: "UUID-1")
    check(st.profiles.first?.id == "UUID-1" && st.routing.rules[0].profileId == "UUID-1" && st.sharing[0].targets == ["UUID-1"], "placeholder → extension id keeps rules and shared logins")
}

section("Shared logins: several accounts per website")
do {
    var st = AppSettings()
    st.profiles = ["A", "B", "C", "D"].enumerated().map { ProfileConfig(id: $0.element, name: $0.element, symbol: "star", color: "#000000", order: $0.offset, detectedName: $0.element) }
    let g1 = SharedSite(domain: "google.com", sourceProfileId: "A", targets: ["B"])
    let g2 = SharedSite(domain: "google.com", sourceProfileId: "C", targets: ["D"])
    st.sharing = [g1, g2]
    check(SessionSharing.conflicts(for: g1, in: st).isEmpty, "two Google entries with different sources and targets don't conflict")
    st.sharing[1].targets = ["B"]
    check(SessionSharing.conflicts(for: st.sharing[0], in: st) == ["B"], "same target from two sources is flagged")
    st.sharing[1].targets = []
    check(SessionSharing.conflicts(for: st.sharing[0], in: st).contains("B"), "“all other profiles” overlaps too")
}

do {
    // A Safari profile's instance got a new id: the old entries (same name) are folded in.
    var st = AppSettings()
    st.profiles = [
        ProfileConfig(id: "OLD-UNI", name: "Uni", symbol: "star", color: "#000000", order: 1),
        ProfileConfig(id: "local-old", name: "Uni", symbol: "star", color: "#000000", order: 2),
        ProfileConfig(id: "NEW-UNI", name: "Uni", symbol: "star", color: "#000000", order: 3, detectedName: "Uni"),
        ProfileConfig(id: "LIVE-UNI", name: "Uni", symbol: "star", color: "#000000", order: 4),
        ProfileConfig(id: "QUANT", name: "Quant", symbol: "star", color: "#000000", order: 5, detectedName: "Quant"),
    ]
    st.routing.rules = [RoutingRule(pattern: "tum.de", profileId: "OLD-UNI"), RoutingRule(pattern: "q.com", profileId: "QUANT")]
    st.sharing = [SharedSite(domain: "tum.de", sourceProfileId: "local-old", targets: ["OLD-UNI", "QUANT"])]
    ProfileRegistry.absorbStale(&st, into: "NEW-UNI", name: "Uni", connected: ["LIVE-UNI"])
    check(st.routing.rules[0].profileId == "NEW-UNI" && st.routing.rules[1].profileId == "QUANT", "rule pointing at a stale profile id is redirected")
    check(st.sharing[0].sourceProfileId == "NEW-UNI" && st.sharing[0].targets == ["NEW-UNI", "QUANT"], "shared login ids are redirected")
    check(st.profile("OLD-UNI") == nil && st.profile("local-old") == nil, "stale entries are removed")
    check(st.profile("LIVE-UNI") != nil && st.profile("QUANT") != nil, "connected and unrelated profiles are kept")
}

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
