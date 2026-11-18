// Connection to the native helper (Safari Agent.app).
//
// Bootstrap: the background asks the Safari web extension handler (native
// app extension) for the helper's loopback port and a per-launch secret via
// browser.runtime.sendNativeMessage. It then opens a WebSocket to
// ws://127.0.0.1:<port> and authenticates with the secret. The helper rejects
// connections whose Origin is a web page, so websites cannot talk to it.

declare const browser: any;

export type HelperListener = (msg: any) => void;

export class HelperConnection {
  private ws: WebSocket | null = null;
  private pending = new Map<string, { resolve: (v: any) => void; reject: (e: Error) => void; timer: any }>();
  private seq = 0;
  private connecting: Promise<void> | null = null;
  private backoff = 500;
  private reconnectTimer: any = null;
  state: "connecting" | "connected" | "helper_unavailable" | "error" = "connecting";
  detail = "";

  constructor(
    private hello: () => any,
    private onMessage: HelperListener,
    private onState: () => void,
  ) {}

  get connected() {
    return this.ws?.readyState === WebSocket.OPEN && this.state === "connected";
  }

  ensure(): Promise<void> {
    if (this.connected) return Promise.resolve();
    if (!this.connecting) {
      this.connecting = this.connect().finally(() => {
        this.connecting = null;
      });
    }
    return this.connecting;
  }

  private setState(s: HelperConnection["state"], detail = "") {
    this.state = s;
    this.detail = detail;
    this.onState();
  }

  private async connect(): Promise<void> {
    clearTimeout(this.reconnectTimer);
    this.setState("connecting");
    let info: any;
    try {
      info = await browser.runtime.sendNativeMessage("dev.local.SafariAgent", { type: "connection_info" });
    } catch (e: any) {
      this.setState("helper_unavailable", "Safari could not reach the Safari Agent app extension. Make sure Safari Agent.app is installed and the extension is enabled.");
      this.scheduleReconnect();
      throw e;
    }
    if (!info || !info.port || !info.token) {
      this.setState("helper_unavailable", info?.error || "The Safari Agent helper app is not running. Open Safari Agent.app.");
      this.scheduleReconnect();
      throw new Error("helper unavailable");
    }
    await new Promise<void>((resolve, reject) => {
      const ws = new WebSocket(`ws://127.0.0.1:${info.port}/extension`);
      let settled = false;
      const fail = (why: string) => {
        if (settled) return;
        settled = true;
        try { ws.close(); } catch { /* ignore */ }
        this.setState("helper_unavailable", why);
        this.scheduleReconnect();
        reject(new Error(why));
      };
      const timer = setTimeout(() => fail("Timed out connecting to the Safari Agent helper."), 6000);
      ws.onopen = () => {
        ws.send(JSON.stringify({ type: "hello", token: info.token, role: "extension", ...this.hello() }));
      };
      ws.onmessage = (ev) => {
        let msg: any;
        try { msg = JSON.parse(String(ev.data)); } catch { return; }
        if (!settled) {
          if (msg.type === "welcome") {
            settled = true;
            clearTimeout(timer);
            this.ws = ws;
            this.backoff = 500;
            this.setState("connected");
            resolve();
          } else if (msg.type === "rejected") {
            clearTimeout(timer);
            fail(msg.reason || "The helper rejected the connection.");
          }
          if (msg.type === "welcome") this.onMessage(msg);
          return;
        }
        if (msg.type === "res" && msg.id && this.pending.has(msg.id)) {
          const p = this.pending.get(msg.id)!;
          this.pending.delete(msg.id);
          clearTimeout(p.timer);
          if (msg.error) p.reject(new Error(msg.error.message || String(msg.error)));
          else p.resolve(msg.result);
          return;
        }
        this.onMessage(msg);
      };
      ws.onerror = () => fail("Could not connect to the Safari Agent helper.");
      ws.onclose = () => {
        clearTimeout(timer);
        if (!settled) return fail("The Safari Agent helper closed the connection.");
        if (this.ws === ws) {
          this.ws = null;
          for (const [, p] of this.pending) {
            clearTimeout(p.timer);
            p.reject(new Error("Lost connection to the Safari Agent helper."));
          }
          this.pending.clear();
          this.setState("helper_unavailable", "Lost connection to the Safari Agent helper. Reconnecting…");
          this.scheduleReconnect();
        }
      };
    });
  }

  private scheduleReconnect() {
    clearTimeout(this.reconnectTimer);
    this.reconnectTimer = setTimeout(() => this.ensure().catch(() => {}), this.backoff);
    this.backoff = Math.min(this.backoff * 2, 15000);
  }

  reconnectNow() {
    this.backoff = 500;
    try { this.ws?.close(); } catch { /* ignore */ }
    this.ws = null;
    return this.ensure();
  }

  send(msg: any) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) throw new Error("Not connected to the Safari Agent helper.");
    this.ws.send(JSON.stringify(msg));
  }

  async request<T = any>(method: string, params: any = {}, timeoutMs = 30000): Promise<T> {
    await this.ensure();
    const id = `r${++this.seq}`;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`The helper did not answer (${method}).`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      try {
        this.send({ type: "req", id, method, params });
      } catch (e: any) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(e);
      }
    });
  }
}
