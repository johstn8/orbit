import { describe, it, expect } from "vitest";
import { classifyFile } from "../src/panel/files";

describe("classifyFile", () => {
  it("accepts images, PDFs and text files within the limits", () => {
    expect(classifyFile("a.png", "image/png", 1000)).toEqual({ type: "image/png" });
    expect(classifyFile("slides.pdf", "", 5_000_000)).toEqual({ type: "application/pdf" });
    expect(classifyFile("notes.md", "", 2000)).toEqual({ type: "text/plain" });
  });
  it("rejects other types and oversized files", () => {
    expect("error" in classifyFile("a.zip", "application/zip", 10)).toBe(true);
    expect("error" in classifyFile("big.pdf", "application/pdf", 21 * 1024 * 1024)).toBe(true);
    expect("error" in classifyFile("big.txt", "text/plain", 2 * 1024 * 1024)).toBe(true);
  });
});
