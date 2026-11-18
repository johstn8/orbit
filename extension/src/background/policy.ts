// Approval policy: decides which agent actions need explicit user approval.
// Pure functions so they can be unit tested.
import type { ApprovalMode } from "../shared/protocol";

export interface ElementFacts {
  tag: string;
  role: string;
  name: string;
  type?: string;
  href?: string;
  inForm: boolean;
  formMethod?: string;
  submits: boolean;
  sensitiveField: boolean;
}

export const SENSITIVE_WORDS =
  /\b(send|submit|post|publish|tweet|reply|comment|delete|remove|erase|destroy|discard|trash|buy|purchase|order|checkout|check out|pay|payment|donate|subscribe|unsubscribe|confirm|transfer|withdraw|deposit|sign out|log out|logout|signout|deactivate|close account|apply|book|reserve|share|invite|accept|approve|grant|authori[sz]e|install|uninstall|reset|save|update|upload|merge|deploy|absenden|senden|abschicken|löschen|entfernen|kaufen|bestellen|bezahlen|zahlen|veröffentlichen|posten|bestätigen|abmelden|abonnieren|kündigen|speichern|teilen|einladen|überweisen)\b/i;

const SENSITIVE_HREF = /(logout|log-out|signout|sign-out|delete|remove|unsubscribe|deactivate|checkout|purchase|\/pay\b)/i;

export const ACTION_TOOLS = new Set(["click", "type_text", "form_input", "press_key", "navigate", "open_tab", "close_tab", "switch_tab"]);

export interface ApprovalDecision {
  reason: string;
}

/** Decide whether a click needs approval. */
export function clickNeedsApproval(mode: ApprovalMode, el: ElementFacts | null): ApprovalDecision | null {
  if (mode === "never") return null;
  if (mode === "always") return { reason: "You asked to approve every browser action." };
  if (!el) return null;
  if (el.submits) return { reason: "This button submits a form." };
  if (SENSITIVE_WORDS.test(el.name)) return { reason: `“${el.name.slice(0, 60)}” looks like it sends, publishes, buys, deletes or changes something.` };
  if (el.href && SENSITIVE_HREF.test(el.href)) return { reason: "This link looks like it signs out, deletes, unsubscribes or pays." };
  if (el.type === "submit" && el.inForm) return { reason: "This submits a form." };
  return null;
}

/** Decide for key presses / typing with submit. */
export function submitNeedsApproval(mode: ApprovalMode, submits: boolean): ApprovalDecision | null {
  if (mode === "never") return null;
  if (mode === "always") return { reason: "You asked to approve every browser action." };
  if (submits) return { reason: "Pressing Enter here submits a form." };
  return null;
}

export function genericActionNeedsApproval(mode: ApprovalMode, tool: string): ApprovalDecision | null {
  // Closing tabs always asks, in every mode.
  if (tool === "close_tab") return { reason: "Closing a tab can discard unsaved work." };
  if (mode === "never") return null;
  if (mode === "always" && ACTION_TOOLS.has(tool)) return { reason: "You asked to approve every browser action." };
  return null;
}

/** Only allow web URLs for navigation. */
export function validateNavigationUrl(raw: string): string {
  const s = raw.trim();
  let url: URL;
  try {
    url = new URL(/^[a-z][a-z0-9+.-]*:/i.test(s) ? s : `https://${s}`);
  } catch {
    throw new Error(`Invalid URL: ${s}`);
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new Error(`Only http and https URLs can be opened (got ${url.protocol}).`);
  }
  return url.toString();
}
