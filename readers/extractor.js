// Profile interpreter. Pure function of (profile, document) -> batch.
// No chrome.* APIs here so the same file runs in the extension, in the
// fixture page, and pasted into a devtools console.
(function (root) {
  "use strict";

  const ENGINE_VERSION = 1;

  function fnv1a(str) {
    let h = 0x811c9dc5;
    for (let i = 0; i < str.length; i++) {
      h ^= str.charCodeAt(i);
      h = Math.imul(h, 0x01000193);
    }
    return (h >>> 0).toString(16).padStart(8, "0");
  }

  function compareVersions(a, b) {
    const pa = String(a).split(".").map((n) => parseInt(n, 10) || 0);
    const pb = String(b).split(".").map((n) => parseInt(n, 10) || 0);
    for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
      const d = (pa[i] || 0) - (pb[i] || 0);
      if (d !== 0) return d < 0 ? -1 : 1;
    }
    return 0;
  }

  function readRaw(scope, spec) {
    if ("const" in spec) return spec.const;
    const el = spec.selector ? scope.querySelector(spec.selector) : scope;
    const get = spec.get || "text";
    if (get === "exists") return el ? "true" : "false";
    if (get.startsWith("matches:")) return el && el.matches(get.slice(8)) ? "true" : "false";
    if (!el || el.nodeType === 9) return null;
    if (get === "text") return (el.innerText ?? el.textContent ?? "").trim();
    if (get.startsWith("attr:")) return el.getAttribute(get.slice(5));
    throw new Error(`unknown get: ${get}`);
  }

  // Returns either a final string, or {pending: "datetime", ...} which is
  // resolved once the whole batch is known (D/M vs M/D needs batch context).
  function readField(scope, spec) {
    let value = readRaw(scope, spec);
    if (value == null) return null;
    let match = null;
    if (spec.regex) {
      match = new RegExp(spec.regex).exec(value);
      if (!match) return null;
      value = match[spec.group ?? 0];
    }
    if (spec.map) value = spec.map[value] ?? null;
    if (spec.parse === "epochSeconds") {
      const n = Number(value);
      return Number.isFinite(n) ? new Date(n * 1000).toISOString() : null;
    }
    if (spec.parse === "datetime") {
      if (!match || !match.groups) return null;
      return { pending: "datetime", groups: match.groups, order: spec.dateOrder || "auto" };
    }
    return value === "" ? null : value;
  }

  function resolveDateOrder(pendings) {
    let order = null;
    for (const p of pendings) {
      if (p.order !== "auto") return p.order;
      if (Number(p.groups.d1) > 12) order = "DMY";
      else if (Number(p.groups.d2) > 12) order = "MDY";
    }
    if (order) return order;
    const lang = (root.navigator && root.navigator.language) || "en-GB";
    return /^en-(US|CA|PH)$/.test(lang) ? "MDY" : "DMY";
  }

  function finishDatetime(p, order) {
    const g = p.groups;
    let hour = Number(g.h);
    const ampm = (g.ampm || "").toLowerCase().replace(/\W/g, "");
    if (ampm === "pm" && hour < 12) hour += 12;
    if (ampm === "am" && hour === 12) hour = 0;
    const day = Number(order === "DMY" ? g.d1 : g.d2);
    const month = Number(order === "DMY" ? g.d2 : g.d1);
    let year = Number(g.y);
    if (year < 100) year += 2000;
    const d = new Date(year, month - 1, day, hour, Number(g.min));
    return Number.isNaN(d.getTime()) ? null : d.toISOString();
  }

  // Shape of the DOM around extracted items, ignoring class names (which
  // obfuscated apps churn constantly) and text. A change here means the
  // upstream app restructured and the profile deserves a second look.
  function fingerprint(items) {
    const shapes = new Set();
    const walk = (el, path, depth) => {
      const data = Array.from(el.attributes || [])
        .map((a) => a.name)
        .filter((n) => n.startsWith("data-") || n === "role")
        .sort();
      const here = `${path}/${el.tagName.toLowerCase()}[${data.join(",")}]`;
      shapes.add(here);
      if (depth < 4) for (const c of el.children) walk(c, here, depth + 1);
    };
    items.slice(0, 5).forEach((el) => walk(el, "", 0));
    return fnv1a(Array.from(shapes).sort().join("\n"));
  }

  function probeVersion(profile, doc) {
    if (!profile.versionProbe) return null;
    try {
      return readField(doc, profile.versionProbe);
    } catch {
      return null;
    }
  }

  function profileApplies(profile, doc, host, path) {
    const m = profile.match || {};
    if (m.hosts && !m.hosts.includes(host)) return false;
    if (m.paths && !m.paths.some((prefix) => (path || "/").startsWith(prefix))) return false;
    const v = probeVersion(profile, doc);
    if (m.versions && v) {
      if (m.versions.min && compareVersions(v, m.versions.min) < 0) return false;
      if (m.versions.max && compareVersions(v, m.versions.max) > 0) return false;
    }
    return true;
  }

  // Every applicable profile, best first. Later entries are fallbacks for
  // when a higher-ranked profile's extraction method is unavailable.
  function rankProfiles(profiles, doc, host, path) {
    return profiles
      .filter((p) => profileApplies(p, doc, host, path))
      .sort((a, b) => b.profileVersion - a.profileVersion);
  }

  function extract(profile, doc) {
    const ex = profile.extract;
    const context = {};
    for (const [name, spec] of Object.entries(ex.context || {})) {
      const v = readField(doc, spec);
      context[name] = v && v.pending ? null : v;
    }

    const elements = Array.from(doc.querySelectorAll(ex.item));
    const pendings = [];
    const items = elements.map((el) => {
      const rec = {};
      for (const [name, spec] of Object.entries(ex.fields)) {
        const v = readField(el, spec);
        if (v && v.pending) pendings.push(v);
        rec[name] = v;
      }
      for (const [name, v] of Object.entries(context)) {
        if (rec[name] == null) rec[name] = v;
      }
      return rec;
    });

    if (pendings.length) {
      const order = resolveDateOrder(pendings);
      for (const rec of items) {
        for (const [k, v] of Object.entries(rec)) {
          if (v && v.pending === "datetime") rec[k] = finishDatetime(v, order);
        }
      }
    }

    return {
      engineVersion: ENGINE_VERSION,
      profile: profile.profile,
      profileVersion: profile.profileVersion,
      appVersion: probeVersion(profile, doc),
      fingerprint: elements.length ? fingerprint(elements) : null,
      items,
    };
  }

  root.ChatbridgeExtractor = { extract, rankProfiles, compareVersions, ENGINE_VERSION };
})(typeof globalThis !== "undefined" ? globalThis : this);
