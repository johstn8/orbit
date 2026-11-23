// What the sidebar can attach to a message (the Orbit app checks this again).
const TEXT_EXT = /\.(txt|md|markdown|csv|tsv|json|xml|ya?ml|html?|css|js|jsx|ts|tsx|py|swift|java|kt|c|h|cpp|hpp|cs|go|rs|rb|php|sh|zsh|sql|tex|bib|log|ini|toml)$/i;
export const IMAGE_TYPES = new Set(["image/png", "image/jpeg", "image/gif", "image/webp"]);
export const MAX_FILES = 5, MAX_FILE = 20 * 1024 * 1024, MAX_TOTAL = 30 * 1024 * 1024, MAX_TEXT = 1024 * 1024;

/** The kind Orbit can send, or an error text. */
export function classifyFile(name: string, type: string, size: number): { type: string } | { error: string } {
  if (IMAGE_TYPES.has(type)) return size <= MAX_FILE ? { type } : { error: `“${name}” is larger than 20 MB.` };
  if (type === "application/pdf" || /\.pdf$/i.test(name)) return size <= MAX_FILE ? { type: "application/pdf" } : { error: `“${name}” is larger than 20 MB.` };
  if (type.startsWith("text/") || type === "application/json" || TEXT_EXT.test(name)) {
    return size <= MAX_TEXT ? { type: type || "text/plain" } : { error: `“${name}” is larger than 1 MB (text files).` };
  }
  return { error: `“${name}” can't be attached. Images, PDFs and text files work.` };
}

