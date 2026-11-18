// Integration test: helper + real Claude Code (subscription) + MCP bridge, with a
// scripted stand-in for the Safari extension. Verifies the agent loop wiring.
// (The real-Safari end-to-end test is tests/e2e/safari-e2e.test.mjs.)
import { connect, chat, assert } from "./lib.mjs";

const fakePage = { status: "inactive", field: "" };
const ext = await connect("extension", { version: "test", tools: undefined });
const calls = [];
ext.on((m) => {
  if (m.type !== "tool_call") return;
  calls.push(m.name);
  let text;
  if (m.name === "read_page" || m.name === "get_page_text") {
    text = `<page_content untrusted="true">\nPage: Fake test page\nheading "Control panel"\nbutton "Activate" [abc_1]\ntextbox "Your name" [abc_2] ${fakePage.field ? `value="${fakePage.field}"` : "empty"}\nstatus "Status: ${fakePage.status}"\n</page_content>`;
  } else if (m.name === "click" && m.args.ref === "abc_1") {
    fakePage.status = "ACTIVE-4417"; text = "Clicked. Now at: Fake test page — http://fake.test/";
  } else if (m.name === "type_text" && m.args.ref === "abc_2") {
    fakePage.field = m.args.text; text = `Field now contains: "${m.args.text}"`;
  } else if (m.name === "find") {
    text = 'button "Activate" [abc_1]\ntextbox "Your name" [abc_2]';
  } else {
    text = `Unsupported in fake page: ${m.name}`;
  }
  ext.send({ type: "tool_result", callId: m.callId, result: { content: [{ type: "text", text }] }, summary: `${m.name} ok` });
});

const driver = await connect("driver");
const providers = await driver.request("providers.list", { refresh: true });
const claude = providers.find((p) => p.id === "claude");
console.log("Claude provider:", claude.state, "-", claude.detail);
assert(claude.available, "Claude provider is available via the CLI subscription login");

console.log("Turn 1: act on the page");
const r1 = await chat(driver, {
  provider: "claude", model: "sonnet",
  text: "On the current page, type 'Ada' into the name field, then click the Activate button, then read the page and tell me the exact status text.",
  context: { tabId: 1, url: "http://fake.test/", title: "Fake test page" },
});
console.log("  tools called:", calls.join(", "));
console.log("  answer:", r1.text.trim().slice(0, 300));
assert(r1.errors.length === 0, "no errors in turn 1");
assert(calls.includes("click") && calls.includes("type_text"), "Claude called click and type_text");
assert(fakePage.field === "Ada" && fakePage.status === "ACTIVE-4417", "fake page state changed by tool calls");
assert(r1.text.includes("ACTIVE-4417"), "answer reports the observed status after acting");

console.log("Turn 2: follow-up uses conversation context");
const r2 = await chat(driver, { conversationId: r1.conversationId, provider: "claude", model: "sonnet", text: "What name did you type, in one word?", context: { tabId: 1 } });
console.log("  answer:", r2.text.trim().slice(0, 200));
assert(/ada/i.test(r2.text), "follow-up remembers previous turn");

console.log("Turn 3: cancellation");
let started = false;
const p3 = chat(driver, { conversationId: r1.conversationId, provider: "claude", model: "sonnet", text: "Write a 1500-word essay about the history of buttons. No tools.", context: {} }, {
  onEvent: (e) => { if (e.kind === "text_delta" && !started) { started = true; setTimeout(() => driver.request("chat.cancel", { conversationId: r1.conversationId }), 1500); } },
});
const r3 = await p3;
const done = r3.events.find((e) => e.kind === "done");
assert(done?.cancelled === true, "turn reported as cancelled");
assert(r3.text.length < 6000, `generation stopped early (${r3.text.length} chars)`);

const conv = await driver.request("conversations.get", { id: r1.conversationId });
assert(conv.messages.length >= 6, `conversation persisted with ${conv.messages.length} messages`);
await driver.request("conversations.delete", { id: r1.conversationId });
console.log("PASS claude-pipeline");
ext.close(); driver.close();
process.exit(0);
