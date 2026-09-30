// ATFM Bridge — keeps a WebSocket to the ATFM app on this Mac (ws://127.0.0.1:47831) and
// (1) reports the tabs / active tab, (2) runs scripts ATFM asks for in matching tabs.
// Nothing leaves the machine: the socket is loopback only.
const PORT = 47831;
const BROWSER = (navigator.userAgent.includes("Zen/") || navigator.userAgent.includes("Zen ")) ? "zen" : "firefox";
let socket = null;
let retryTimer = null;

function log(...args) { try { console.debug("[ATFM Bridge]", ...args); } catch (_) {} }

function connect() {
  if (socket && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)) return;
  try {
    socket = new WebSocket(`ws://127.0.0.1:${PORT}/`);
  } catch (e) { scheduleRetry(); return; }
  socket.onopen = async () => {
    log("connected");
    send({ type: "hello", browser: BROWSER, version: browser.runtime.getManifest().version });
    await sendTabs();
  };
  socket.onmessage = (event) => { handle(event.data).catch((e) => log("handle error", e)); };
  socket.onclose = () => { socket = null; scheduleRetry(); };
  socket.onerror = () => { try { socket && socket.close(); } catch (_) {} };
}

function scheduleRetry() {
  if (retryTimer) return;
  retryTimer = setTimeout(() => { retryTimer = null; connect(); }, 3000);
}

function send(message) {
  if (socket && socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
}

async function sendTabs() {
  const tabs = await browser.tabs.query({});
  const active = tabs.find((t) => t.active && t.windowId === lastFocusedWindow) || tabs.find((t) => t.active) || null;
  send({
    type: "tabs",
    active: active ? { id: active.id, url: active.url || "", title: active.title || "" } : null,
    tabs: tabs.map((t) => ({ id: t.id, url: t.url || "", title: t.title || "", active: !!t.active, windowId: t.windowId })),
  });
}

let lastFocusedWindow = browser.windows.WINDOW_ID_NONE;
browser.windows.getLastFocused().then((w) => { lastFocusedWindow = w.id; }).catch(() => {});
browser.windows.onFocusChanged.addListener((id) => { if (id !== browser.windows.WINDOW_ID_NONE) lastFocusedWindow = id; sendTabs(); });

let tabsTimer = null;
function scheduleTabs() { if (tabsTimer) return; tabsTimer = setTimeout(() => { tabsTimer = null; sendTabs(); }, 250); }
browser.tabs.onActivated.addListener(scheduleTabs);
browser.tabs.onUpdated.addListener((id, info) => { if (info.url || info.title || info.status === "complete") scheduleTabs(); });
browser.tabs.onRemoved.addListener(scheduleTabs);
browser.tabs.onCreated.addListener(scheduleTabs);

async function handle(raw) {
  const message = JSON.parse(raw);
  switch (message.type) {
    case "ping": send({ type: "pong" }); break;
    case "tabs": await sendTabs(); break;
    case "exec": {
      // Run `code` in every tab whose URL contains `needle` (or in `tabId`), reply with one result per tab.
      const results = [];
      let targets = [];
      if (message.tabId != null) {
        try { targets = [await browser.tabs.get(message.tabId)]; } catch (_) { targets = []; }
      } else {
        const all = await browser.tabs.query({});
        targets = all.filter((t) => (t.url || "").includes(message.needle || ""));
      }
      for (const tab of targets) {
        try {
          const value = await browser.tabs.executeScript(tab.id, { code: message.code, runAt: "document_idle" });
          results.push({ tabId: tab.id, url: tab.url || "", value: value && value.length ? value[0] : null });
        } catch (e) {
          results.push({ tabId: tab.id, url: tab.url || "", error: String(e && e.message ? e.message : e) });
        }
      }
      send({ type: "result", id: message.id, results });
      break;
    }
    default: break;
  }
}

connect();
setInterval(() => { if (!socket) connect(); else send({ type: "ping" }); }, 15000);
