// @ts-nocheck — Node APIs are available in vitest.
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { patternMatches, routeTarget } from "../src/shared/routing";

const cases = JSON.parse(readFileSync(resolve(process.cwd(), "../tests/fixtures/routing-cases.json"), "utf8"));

describe("routing patterns (shared fixture)", () => {
  for (const c of cases.matches) {
    it(`${c.pattern || "(empty)"} ${c.expect ? "matches" : "doesn't match"} ${c.url}`, () => {
      expect(patternMatches(c.pattern, c.url)).toBe(c.expect);
    });
  }
  for (const [i, c] of cases.targets.entries()) {
    it(`first matching rule wins (${i})`, () => {
      expect(routeTarget(c.url, c.rules)).toBe(c.expect);
    });
  }
});
