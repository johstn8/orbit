// Bundles the extension into ./dist (stable file names, referenced by the Xcode project).
import { build, context } from "esbuild";
import { cpSync, mkdirSync, rmSync } from "node:fs";

const watch = process.argv.includes("--watch");
const out = new URL("./dist/", import.meta.url).pathname;
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
cpSync(new URL("./static/", import.meta.url).pathname, out, { recursive: true });

const common = {
  bundle: true,
  loader: { ".css": "css" },
  target: ["safari16"],
  format: "iife",
  legalComments: "none",
  minify: !watch,
  sourcemap: watch ? "inline" : false,
  define: { "process.env.NODE_ENV": watch ? '"development"' : '"production"' },
  logLevel: "info",
};
const entries = [
  { entryPoints: ["src/background/background.ts"], outfile: `${out}background.js` },
  { entryPoints: ["src/content/content.ts"], outfile: `${out}content.js` },
  { entryPoints: ["src/panel/panel.tsx"], outfile: `${out}panel.js` },
];
// Export the tool catalog for the native helper (fallback when the extension is not connected).
{
  const tools = await build({ entryPoints: ["src/shared/tools.ts"], bundle: true, format: "esm", write: false, logLevel: "silent" });
  const mod = await import("data:text/javascript;base64," + Buffer.from(tools.outputFiles[0].text).toString("base64"));
  const { writeFileSync, mkdirSync: mk } = await import("node:fs");
  const dest = new URL("../native/SafariAgent/Resources/", import.meta.url).pathname;
  mk(dest, { recursive: true });
  writeFileSync(dest + "tools.json", JSON.stringify(mod.TOOLS, null, 1));
}
if (watch) {
  for (const e of entries) await (await context({ ...common, ...e })).watch();
} else {
  await Promise.all(entries.map((e) => build({ ...common, ...e })));
}
