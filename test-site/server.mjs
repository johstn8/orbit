// Local test site for Safari Agent end-to-end tests (http://127.0.0.1:8765).
// Pages report user-visible state changes to /event so tests can verify that
// browser actions really happened, independently of the extension.
import { createServer } from "node:http";
import { readFileSync, existsSync } from "node:fs";
import { extname, join, normalize } from "node:path";

const root = new URL(".", import.meta.url).pathname;
const port = Number(process.env.PORT || 8765);
let events = [];

const types = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css" };

createServer((req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${port}`);
  if (url.pathname === "/event" && req.method === "POST") {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      try { events.push({ ...JSON.parse(body), at: Date.now() }); } catch {}
      res.writeHead(204).end();
    });
    return;
  }
  if (url.pathname === "/events") {
    res.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" });
    return res.end(JSON.stringify(events));
  }
  if (url.pathname === "/reset") {
    events = [];
    return res.writeHead(204).end();
  }
  if (url.pathname === "/submit") {
    events.push({ type: "form_submitted", query: Object.fromEntries(url.searchParams), at: Date.now() });
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    return res.end(`<!doctype html><title>Order received</title><h1>Order received</h1><p>Thanks, ${String(url.searchParams.get("name") || "").replace(/[<>&]/g, "")}.</p>`);
  }
  let p = normalize(url.pathname === "/" ? "/index.html" : url.pathname);
  const file = join(root, p);
  if (!file.startsWith(root) || !existsSync(file)) return res.writeHead(404).end("not found");
  res.writeHead(200, { "content-type": types[extname(file)] || "application/octet-stream", "cache-control": "no-store" });
  res.end(readFileSync(file));
}).listen(port, "127.0.0.1", () => console.log(`test site on http://127.0.0.1:${port}`));
