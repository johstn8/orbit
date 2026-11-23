import { describe, it, expect } from "vitest";
import { shiftMedia, shiftSheetText } from "../src/content/media";

describe("shiftMedia", () => {
  it("shifts min/max width by the reserve", () => {
    expect(shiftMedia("(min-width: 1012px)", 440)).toBe("(min-width: 1452px)");
    expect(shiftMedia("screen and (max-width: 767.98px)", 440)).toBe("screen and (max-width: 1207.98px)");
  });
  it("converts em/rem (16px) and handles range syntax", () => {
    expect(shiftMedia("(min-width: 48em)", 100)).toBe("(min-width: 868px)");
    expect(shiftMedia("(768px <= width < 1012px)", 10)).toBe("(778px <= width < 1022px)");
  });
  it("leaves heights, device widths and other features alone", () => {
    expect(shiftMedia("(min-height: 600px)", 440)).toBe("(min-height: 600px)");
    expect(shiftMedia("(min-device-width: 600px)", 440)).toBe("(min-device-width: 600px)");
    expect(shiftMedia("(prefers-color-scheme: dark) and (min-width: 600px)", 40)).toBe("(prefers-color-scheme: dark) and (min-width: 640px)");
    expect(shiftMedia("print", 40)).toBe("print");
  });
  it("is the identity without a reserve", () => {
    expect(shiftMedia("(min-width: 1012px)", 0)).toBe("(min-width: 1012px)");
  });
});

describe("shiftSheetText", () => {
  it("shifts @media and @import and makes urls absolute", () => {
    const css = `@media (min-width:768px){.a{background:url(img/a.png)}}@import url("x.css") (max-width: 500px);.b{background:url(data:x)}`;
    const out = shiftSheetText(css, 100, "https://cdn.example.com/css/site.css");
    expect(out).toContain("@media (min-width:868px){");
    expect(out).toContain("url(https://cdn.example.com/css/img/a.png)");
    expect(out).toContain("(max-width: 600px);");
    expect(out).toContain("url(data:x)");
  });
});
