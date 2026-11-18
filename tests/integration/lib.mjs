// Shared helpers for integration tests that talk to the running Safari Agent helper.
import { readFileSync } from "node:fs";
import { homedir } from "node:os";

export function connectionInfo() {
  return JSON.parse(readFileSync(`${homedir()}/Library/Application Support/SafariAgent/connection.json`, "utf8"));
}

export async function connect(role, extra = {}) {
  const { port, token } = connectionInfo();
  const ws = new WebSocket(`ws://127.0.0.1:${port}/${role}`);
  const listeners = new Set();
  const pending = new Map();
  let seq = 0;
  await new Promise((resolve, reject) => {
    ws.onopen = () => ws.send(JSON.stringify({ type: "hello", role, token, ...extra }));
    ws.onerror = (e) => reject(new Error("websocket error"));
    ws.onmessage = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.type === "welcome") return resolve();
      if (m.type === "rejected") return reject(new Error(m.reason));
      if (m.type === "res" && pending.has(m.id)) {
        const p = pending.get(m.id); pending.delete(m.id);
        return m.error ? p.reject(new Error(m.error.message)) : p.resolve(m.result);
      }
      for (const l of listeners) l(m);
    };
  });
  return {
    ws,
    on: (fn) => listeners.add(fn),
    send: (m) => ws.send(JSON.stringify(m)),
    request(method, params = {}, timeout = 60000) {
      const id = `t${++seq}`;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error(`timeout: ${method}`)), timeout);
        pending.set(id, { resolve: (v) => { clearTimeout(timer); resolve(v); }, reject: (e) => { clearTimeout(timer); reject(e); } });
        ws.send(JSON.stringify({ type: "req", id, method, params }));
      });
    },
    close: () => ws.close(),
  };
}

/** Send a chat message and collect events until done. */
export async function chat(client, params, { timeout = 240000, onEvent } = {}) {
  const events = [];
  let text = "";
  let convId = null;
  const done = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("chat timeout")), timeout);
    client.on((m) => {
      if (m.type !== "event" || (convId && m.conversationId !== convId)) return;
      events.push(m.event);
      onEvent?.(m.event);
      if (m.event.kind === "text_delta") text += m.event.text;
      if (m.event.kind === "done") { clearTimeout(timer); resolve(); }
    });
  });
  const res = await client.request("chat.send", params);
  convId = res.conversationId;
  await done;
  return { conversationId: convId, events, text, errors: events.filter((e) => e.kind === "error") };
}

export function assert(cond, msg) {
  if (!cond) throw new Error("ASSERTION FAILED: " + msg);
  console.log("  ✓ " + msg);
}
