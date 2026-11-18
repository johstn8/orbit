import { describe, expect, it } from "vitest";
import { clickNeedsApproval, genericActionNeedsApproval, submitNeedsApproval, validateNavigationUrl, SENSITIVE_WORDS } from "../src/background/policy";

const el = (o: any) => ({ tag: "button", role: "button", name: "", inForm: false, submits: false, sensitiveField: false, ...o });

describe("approval policy", () => {
  it("requires approval for form submission buttons", () => {
    expect(clickNeedsApproval("sensitive", el({ name: "Continue", submits: true, inForm: true }))).not.toBeNull();
  });
  it("requires approval for sensitive labels in English and German", () => {
    for (const n of ["Send", "Delete account", "Place order", "Publish", "Sign out", "Jetzt kaufen", "Löschen", "Absenden"]) {
      expect(clickNeedsApproval("sensitive", el({ name: n })), n).not.toBeNull();
    }
  });
  it("does not ask for ordinary navigation clicks", () => {
    for (const n of ["Increment counter", "Next page", "Documentation", "Comments", "Posts"]) {
      expect(clickNeedsApproval("sensitive", el({ name: n })), n).toBeNull();
    }
  });
  it("flags sign-out / delete links by href", () => {
    expect(clickNeedsApproval("sensitive", el({ tag: "a", role: "link", name: "Bye", href: "https://x.test/logout" }))).not.toBeNull();
  });
  it("modes: always asks for everything, never asks for nothing except closing tabs", () => {
    expect(clickNeedsApproval("always", el({ name: "Next" }))).not.toBeNull();
    expect(clickNeedsApproval("never", el({ name: "Delete", submits: true }))).toBeNull();
    expect(genericActionNeedsApproval("never", "close_tab")).not.toBeNull();
    expect(genericActionNeedsApproval("sensitive", "navigate")).toBeNull();
    expect(genericActionNeedsApproval("always", "navigate")).not.toBeNull();
    expect(submitNeedsApproval("sensitive", true)).not.toBeNull();
    expect(submitNeedsApproval("sensitive", false)).toBeNull();
  });
  it("word matching is whole-word", () => {
    expect(SENSITIVE_WORDS.test("Repost history")).toBe(false);
    expect(SENSITIVE_WORDS.test("Post")).toBe(true);
  });
});

describe("navigation URL validation", () => {
  it("accepts http(s) and bare hosts", () => {
    expect(validateNavigationUrl("https://example.com/a")).toBe("https://example.com/a");
    expect(validateNavigationUrl("example.com")).toBe("https://example.com/");
  });
  it("rejects dangerous schemes", () => {
    for (const u of ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,hi", "safari-web-extension://x/panel.html"]) {
      expect(() => validateNavigationUrl(u), u).toThrow();
    }
  });
});
