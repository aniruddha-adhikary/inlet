// Runs in the source app's page: rank the applicable profiles, read via the
// best one that works (in-page store, else DOM), and ship only new/changed
// records to the local bridge host. Strictly one-way: page -> bridge.
(function () {
  "use strict";

  const TAG = "inlet";
  const DEBOUNCE_MS = 1500;
  const POLL_MS = 15000; // in-page stores change without touching the DOM
  const CHUNK = 300;
  const STORE_TIMEOUT_MS = 5000;
  const inExtension = !!(globalThis.chrome && chrome.runtime && chrome.runtime.id);

  // Inside the extension, requests go through the service worker (the page's
  // CSP blocks a direct fetch to localhost). The fixture pages are served by
  // the bridge host itself, so they can fetch same-origin.
  function request(method, path, body) {
    // Embedded in the Mac app's WKWebView: the app relays for us.
    const native = globalThis.webkit && webkit.messageHandlers && webkit.messageHandlers.inlet;
    if (native) return native.postMessage({ method, path, body: body || null });
    if (inExtension) {
      return chrome.runtime.sendMessage({ type: "bridge-request", method, path, body });
    }
    return fetch(path, {
      method,
      headers: body ? { "Content-Type": "application/json" } : undefined,
      body: body ? JSON.stringify(body) : undefined,
    }).then(async (r) => ({ ok: r.ok, status: r.status, data: await r.json().catch(() => null) }));
  }

  const sent = new Map(); // sourceId -> JSON of last record sent
  const dead = new Set(); // profile keys the host has quarantined
  let candidates = [];
  let timer = null;
  let running = false;
  let seq = 0;

  function log(...args) {
    console.debug("[inlet]", ...args);
  }

  const keyOf = (p) => `${p.profile}@${p.profileVersion}`;

  // Ask the MAIN-world reader (pagestore.js) to interpret profile.store.
  function readPageStore(profile) {
    return new Promise((resolve, reject) => {
      const id = `${Date.now()}-${++seq}`;
      const timeout = setTimeout(() => {
        removeEventListener("message", onMessage);
        reject(new Error("page-store reader did not answer"));
      }, STORE_TIMEOUT_MS);
      function onMessage(event) {
        const msg = event.data;
        if (event.source !== window || !msg || msg.tag !== TAG || msg.dir !== "res" || msg.id !== id) return;
        clearTimeout(timeout);
        removeEventListener("message", onMessage);
        if (!msg.ok) return reject(new Error(msg.error));
        resolve({
          engineVersion: InletExtractor.ENGINE_VERSION,
          profile: profile.profile,
          profileVersion: profile.profileVersion,
          appVersion: msg.appVersion,
          fingerprint: msg.fingerprint,
          items: msg.items,
        });
      }
      addEventListener("message", onMessage);
      window.postMessage({ tag: TAG, dir: "req", id, store: profile.store }, location.origin);
    });
  }

  function readWith(profile) {
    if ((profile.method || "dom") === "page-store") return readPageStore(profile);
    return Promise.resolve(InletExtractor.extract(profile, document));
  }

  function fillStats(items) {
    const filled = {};
    for (const rec of items) {
      for (const [k, v] of Object.entries(rec)) if (v != null) filled[k] = (filled[k] || 0) + 1;
    }
    return { total: items.length, filled };
  }

  async function ship(batch) {
    const total = batch.items.length;
    // The canary is judged on the whole view, but only the delta is stored.
    const viewStats = fillStats(batch.items);
    const delta = batch.items.filter((rec) => !rec.sourceId || sent.get(rec.sourceId) !== JSON.stringify(rec));
    if (!delta.length) return null;

    let last = null;
    for (let i = 0; i < delta.length; i += CHUNK) {
      const items = delta.slice(i, i + CHUNK);
      last = await request("POST", "/ingest", { ...batch, items, viewStats, pageHost: location.host });
      if (!last || !last.ok) break;
      for (const rec of items) if (rec.sourceId) sent.set(rec.sourceId, JSON.stringify(rec));
    }
    log(`${keyOf(batch)}: ${delta.length} changed of ${total}`, last && last.data);
    return last;
  }

  async function tick() {
    if (running) return;
    running = true;
    try {
      for (const profile of candidates) {
        if (dead.has(keyOf(profile))) continue;
        let batch;
        try {
          batch = await readWith(profile);
        } catch (e) {
          log(`${keyOf(profile)} unavailable, trying next:`, e.message);
          continue;
        }
        if (!batch.items.length) continue; // nothing visible to this method right now
        const res = await ship(batch);
        if (res && res.status === 423) dead.add(keyOf(profile));
        if (res) globalThis.dispatchEvent(new CustomEvent("inlet-result", { detail: res }));
        if (!res || res.ok) return; // a failed canary falls through to the next profile
      }
    } finally {
      running = false;
    }
  }

  function schedule() {
    clearTimeout(timer);
    timer = setTimeout(() => tick().catch((e) => log("tick failed", e)), DEBOUNCE_MS);
  }

  async function start() {
    let res;
    try {
      res = await request("GET", `/profiles?host=${encodeURIComponent(location.host)}`);
    } catch (e) {
      return log("bridge host unreachable", e);
    }
    if (!res || !res.ok) return log("profile fetch failed", res && res.status);
    candidates = InletExtractor.rankProfiles(res.data.profiles, document, location.host, location.pathname);
    if (!candidates.length) return log("no profile for", location.host);
    log("profiles:", candidates.map(keyOf).join(" > "));
    new MutationObserver(schedule).observe(document.body, { childList: true, subtree: true, characterData: true });
    setInterval(schedule, POLL_MS);
    schedule();
  }

  start();
})();
