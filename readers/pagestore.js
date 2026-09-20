// MAIN-world reader for apps that keep their data in an in-page module
// store (e.g. WhatsApp Web's WAWebCollections). Driven entirely by the
// profile's "store" spec.
//
// Read-only by construction: the interpreter can resolve a module or a path
// on window, enumerate a collection or a plain object's values, look a model
// up by id, and read properties. It has no way to express a call to anything
// else, so a profile cannot send, mutate, mark as read, or trigger a fetch.
(function () {
  "use strict";

  const TAG = "inlet";
  const MAX_STRING = 64000;

  function fnv1a(str) {
    let h = 0x811c9dc5;
    for (let i = 0; i < str.length; i++) {
      h ^= str.charCodeAt(i);
      h = Math.imul(h, 0x01000193);
    }
    return (h >>> 0).toString(16).padStart(8, "0");
  }

  function getPath(obj, path) {
    let cur = obj;
    for (const key of path.split(".")) {
      if (cur == null) return null;
      cur = cur[key];
    }
    return cur ?? null;
  }

  function models(collection) {
    if (!collection) return [];
    if (typeof collection.getModelsArray === "function") return collection.getModelsArray();
    return Array.isArray(collection.models) ? collection.models : [];
  }

  function scalar(value, spec) {
    if (value == null) return null;
    if (typeof value === "object" || typeof value === "function") {
      if (spec.as !== "string") return null;
      value = String(value);
    }
    value = String(value);
    return value === "" || value.length > MAX_STRING ? null : value;
  }

  function readField(model, spec, collections) {
    if ("const" in spec) return spec.const;
    if (spec.anyOf) {
      for (const option of spec.anyOf) {
        const v = readField(model, option, collections);
        if (v != null) return v;
      }
      return null;
    }
    if (spec.switch) {
      const branch = spec.cases[String(getPath(model, spec.switch))] || spec.cases.default;
      return branch ? readField(model, branch, collections) : null;
    }
    if (spec.join) {
      const parts = spec.join.map((p) => scalar(getPath(model, p), { as: "string" }));
      return parts.some((v) => v == null) ? null : parts.join(spec.sep ?? "_");
    }
    let raw = null;
    for (const p of spec.paths || [spec.path]) {
      raw = getPath(model, p);
      if (raw != null) break;
    }
    if (raw == null) return spec.default ?? null;

    if (spec.lookup) {
      const target = spec.lookup.target ? getPath(window, spec.lookup.target) : collections[spec.lookup.collection];
      const key = String(raw);
      const hit = !target ? null : typeof target.get === "function" ? target.get(key)
        : Object.prototype.hasOwnProperty.call(target, key) ? target[key] : null;
      raw = null;
      for (const p of spec.lookup.paths) {
        raw = hit ? getPath(hit, p) : null;
        if (raw != null && raw !== "") break;
      }
    }

    let value = scalar(raw, spec);
    if (value == null) return spec.default ?? null;
    if (spec.map) value = spec.map[value] ?? spec.default ?? null;
    if (spec.parse === "epochSeconds") {
      const n = Number(value);
      return Number.isFinite(n) ? new Date(n * 1000).toISOString() : null;
    }
    return value;
  }

  function read(store) {
    let collections = {};
    let list;
    if (store.root === "window") {
      const node = getPath(window, store.path);
      if (node == null || typeof node !== "object") throw new Error(`window.${store.path} not found`);
      list = [node];
      for (let depth = 0; depth < (store.depth ?? 1); depth++) {
        list = list.flatMap((v) => (v && typeof v === "object" ? Object.values(v) : []));
      }
      list = list.filter((v) => v && typeof v === "object");
    } else {
      if (typeof window.require !== "function") throw new Error("no module loader on this page");
      collections = window.require(store.require);
      const source = collections && collections[store.collection];
      if (!source) throw new Error(`collection ${store.collection} not found`);
      list = models(source);
    }
    for (const [path, allowed] of Object.entries(store.where || {})) {
      list = list.filter((m) => allowed.includes(getPath(m, path)));
    }

    const items = list.map((m) => {
      const rec = {};
      for (const [name, spec] of Object.entries(store.fields)) rec[name] = readField(m, spec, collections);
      return rec;
    });

    // Key names of the model, not values: a rename upstream shows up here.
    const first = list[0];
    const shape = first ? Object.keys(first.attributes || first).sort().join(",") : "";
    const version = store.versionPath ? getPath(window, store.versionPath) : null;
    return {
      items,
      fingerprint: first ? fnv1a(shape) : null,
      appVersion: typeof version === "string" ? version : null,
    };
  }

  window.addEventListener("message", (event) => {
    const msg = event.data;
    if (event.source !== window || !msg || msg.tag !== TAG || msg.dir !== "req") return;
    let reply;
    try {
      reply = { ok: true, ...read(msg.store) };
    } catch (e) {
      reply = { ok: false, error: String(e && e.message ? e.message : e) };
    }
    window.postMessage({ tag: TAG, dir: "res", id: msg.id, ...reply }, location.origin);
  });
})();
