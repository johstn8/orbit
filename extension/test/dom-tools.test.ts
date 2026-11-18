import { beforeEach, describe, expect, it, vi } from "vitest";
import { fakeLayout } from "./setup-dom";
import {
  buildTree, findElements, pageText, resolveRef, typeInto, setFormValue, pressKey, keySubmitsForm, describeElement,
  controlFor, isSensitiveField, refFor, clickElement, getSelectionText,
} from "../src/content/dom-tools";

const FIXTURE = `
<header><nav><a href="https://site.test/docs">Docs</a></nav></header>
<main>
  <h1>Shop</h1>
  <p>${"Long article text about widgets. ".repeat(12)}</p>
  <table><tr><th>Plan</th><th>Price</th></tr><tr><td>Basic</td><td>$5</td></tr></table>
  <form id="f" action="/buy">
    <label for="name">Full name</label><input id="name" name="name">
    <label for="pw">Password</label><input id="pw" type="password" value="secret">
    <select id="size"><option value="">Choose</option><option value="m">Medium</option></select>
    <label><input type="checkbox" id="news"> Newsletter</label>
    <button type="submit">Place order</button>
  </form>
  <button id="plain" type="button">Increment</button>
  <div contenteditable="true" id="ed" aria-label="Editor"></div>
  <script>window.bad = 1</script>
</main>
<safari-agent-panel><div>panel</div></safari-agent-panel>`;

beforeEach(() => {
  fakeLayout();
  document.body.innerHTML = FIXTURE;
});

const refOf = (text: string, re: RegExp) => re.exec(text)?.[1] as string;

describe("accessibility tree", () => {
  it("lists landmarks, headings, controls with refs and state; redacts passwords; skips the panel", () => {
    const t = buildTree({ filter: "all" });
    expect(t).toMatch(/heading "Shop" level=1/);
    expect(t).toMatch(/textbox "Full name" \[\w+_\d+\] empty/);
    expect(t).toMatch(/textbox "Password" \[\w+_\d+\] type=password value="\[redacted\]"/);
    expect(t).not.toContain("secret");
    expect(t).toMatch(/combobox .* options=\["Choose", "Medium"\]/);
    expect(t).toMatch(/button "Place order"/);
    expect(t).not.toContain("panel");
    expect(t).not.toContain("window.bad");
  });
  it("interactive filter only returns actionable elements", () => {
    const t = buildTree({ filter: "interactive" });
    expect(t).not.toMatch(/heading/);
    expect(t).toMatch(/button "Increment"/);
  });
  it("refs are stable and stale refs are rejected", () => {
    const btn = document.getElementById("plain")!;
    const r = refFor(btn);
    expect(refFor(btn)).toBe(r);
    expect(resolveRef(r)).toBe(btn);
    btn.remove();
    expect(() => resolveRef(r)).toThrow(/no longer exists/);
    expect(() => resolveRef("zzz_1")).toThrow(/previous version of this page/);
  });
});

describe("find", () => {
  it("ranks the control above its label", () => {
    const out = findElements("password");
    expect(out.split("\n")[0]).toMatch(/^textbox "Password"/);
  });
  it("finds buttons by role words", () => {
    expect(findElements("place order button").split("\n")[0]).toMatch(/button "Place order"/);
  });
});

describe("actions", () => {
  it("types into text fields with input/change events", () => {
    const input = document.getElementById("name") as HTMLInputElement;
    const events: string[] = [];
    input.addEventListener("input", () => events.push("input"));
    input.addEventListener("change", () => events.push("change"));
    expect(typeInto(input, "Ada", false)).toContain('"Ada"');
    expect(input.value).toBe("Ada");
    typeInto(input, " L.", true);
    expect(input.value).toBe("Ada L.");
    expect(events).toEqual(["input", "change", "input", "change"]);
  });
  it("refuses password fields and resolves labels to controls", () => {
    const pw = document.getElementById("pw")!;
    expect(isSensitiveField(pw)).toBe(true);
    expect(() => typeInto(pw, "x", false)).toThrow(/password/i);
    const label = document.querySelector('label[for="pw"]')!;
    expect(controlFor(label)).toBe(pw);
  });
  it("sets selects by text and checkboxes by boolean", () => {
    expect(setFormValue(document.getElementById("size")!, "medium")).toContain("Medium");
    expect((document.getElementById("size") as HTMLSelectElement).value).toBe("m");
    expect(setFormValue(document.getElementById("news")!, true)).toContain("checked");
    expect((document.getElementById("news") as HTMLInputElement).checked).toBe(true);
  });
  it("detects that Enter in a form field submits, and Enter submits via requestSubmit", () => {
    const input = document.getElementById("name")!;
    expect(keySubmitsForm(input, "Enter")).toBe(true);
    expect(keySubmitsForm(document.getElementById("plain"), "Enter")).toBe(false);
    const form = document.getElementById("f") as HTMLFormElement;
    const spy = vi.fn((e: Event) => e.preventDefault());
    form.addEventListener("submit", spy);
    pressKey(input, "Enter");
    expect(spy).toHaveBeenCalledTimes(1);
  });
  it("describes submit buttons for the approval policy", () => {
    const b = document.querySelector('button[type="submit"]')!;
    const info = describeElement(b);
    expect(info.submits).toBe(true);
    expect(info.name).toBe("Place order");
  });
  it("clicks dispatch pointer + click events", () => {
    const b = document.getElementById("plain")!;
    const seen: string[] = [];
    for (const t of ["pointerdown", "mousedown", "mouseup", "click"]) b.addEventListener(t, () => seen.push(t));
    clickElement(b);
    expect(seen).toEqual(["pointerdown", "mousedown", "mouseup", "click"]);
  });
  it("rejects unknown keys", () => {
    expect(() => pressKey(null, "F13")).toThrow(/Unsupported key/);
  });
});

describe("page text", () => {
  it("extracts main content as markdown with tables and nav links", () => {
    const t = pageText(true, 0, 30000);
    expect(t).toContain("# Shop");
    expect(t).toContain("| Plan | Price |");
    expect(t).toContain("[Docs](https://site.test/docs)");
    expect(t).not.toContain("window.bad");
  });
  it("pages long content with offsets", () => {
    const t = pageText(false, 0, 50);
    expect(t).toMatch(/offset=50/);
  });
  it("returns empty selection when nothing is selected", () => {
    expect(getSelectionText()).toBe("");
  });
});
