// Background → page calls.
//
// Safari sometimes stops delivering runtime/tabs.sendMessage to a tab's content
// script (observed after extension reloads and on some sites), while
// scripting.executeScript keeps working. So requests are delivered by executing
// a tiny function in the content script's isolated world that calls the
// handler the content script registered (window.__safariAgentHandle). If the
// handler is missing or belongs to an orphaned instance, content.js is injected
// again and the call retried.

declare const browser: any;

function callHandler(msg: any) {
  const h = (window as any).__safariAgentHandle;
  return typeof h === "function" ? h(msg) : { __missing: true };
}

async function exec(tabId: number, msg: any): Promise<any> {
  const res = await browser.scripting.executeScript({ target: { tabId }, func: callHandler, args: [msg] });
  return res?.[0]?.result;
}

export class NoPageAccess extends Error {}

/**
 * Send a request to the content script in a tab and return its reply.
 * @param inject re-inject content.js when no live handler exists (default true)
 */
export async function tabRpc(tabId: number, msg: any, inject = true): Promise<any> {
  let r: any;
  try {
    r = await exec(tabId, msg);
  } catch (e: any) {
    throw new NoPageAccess(String(e?.message || e));
  }
  if ((r === undefined || r?.__missing) && inject) {
    try {
      await browser.scripting.executeScript({ target: { tabId }, files: ["content.js"] });
    } catch (e: any) {
      throw new NoPageAccess(String(e?.message || e));
    }
    r = await exec(tabId, msg);
  }
  if (r === undefined || r?.__missing) return undefined;
  return r;
}
