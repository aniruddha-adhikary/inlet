// Runs the in-page store reader against fake app stores. `node --test extension/tests`
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(here, "..", "pagestore.js"), "utf8");
const profile = (name) => JSON.parse(readFileSync(join(here, "..", "..", "profiles", name), "utf8"));

function read(windowProps, store) {
  const listeners = [];
  const posted = [];
  const window = {
    ...windowProps,
    addEventListener: (_type, fn) => listeners.push(fn),
    postMessage: (msg) => posted.push(msg),
  };
  new Function("window", "location", source)(window, { origin: "https://example.test" });
  listeners[0]({ source: window, data: { tag: "chatbridge", dir: "req", id: "t", store } });
  return posted[0];
}

test("telegram web k: reads mirrored messages, read-only", () => {
  let calls = 0;
  const trap = () => { calls += 1; };
  const reply = read({
    apiManagerProxy: {
      sendMessage: trap, invokeApi: trap,
      mirrors: {
        messages: {
          "777_history": {
            11: { _: "message", id: 11, peerId: "777", fromId: "777", date: 1789900000, message: "See you at the docks", pFlags: {} },
            12: { _: "message", id: 12, peerId: "777", fromId: "42", date: 1789900060, message: "On my way", pFlags: { out: true } },
            13: { _: "messageService", id: 13, peerId: "777", date: 1789900100, pFlags: {} },
          },
          "-100500_history": {
            11: { _: "message", id: 11, peerId: "-100500", fromId: "901", date: 1789900200, message: "Release is tagged", pFlags: {} },
          },
        },
        peers: { 777: { first_name: "Mira" }, 42: { first_name: "Me" }, "-100500": { title: "Build crew" }, 901: { username: "tessa" } },
      },
    },
  }, profile("telegram-web-k-store.json").store);

  assert.equal(reply.ok, true, reply.error);
  assert.equal(calls, 0, "the reader must never call into the app");
  assert.equal(reply.items.length, 3, "service messages are filtered out");
  const byId = Object.fromEntries(reply.items.map((r) => [r.sourceId, r]));
  assert.deepEqual(Object.keys(byId).sort(), ["-100500_11", "777_11", "777_12"], "ids are unique across chats");
  assert.equal(byId["777_11"].direction, "incoming");
  assert.equal(byId["777_12"].direction, "outgoing");
  assert.equal(byId["777_11"].sender, "Mira");
  assert.equal(byId["777_11"].conversationName, "Mira");
  assert.equal(byId["-100500_11"].conversationName, "Build crew");
  assert.equal(byId["-100500_11"].sender, "tessa");
  assert.equal(byId["777_11"].body, "See you at the docks");
  assert.equal(byId["777_11"].sentAt, new Date(1789900000 * 1000).toISOString());
});

test("whatsapp web: module-store path still works and thumbnails never become the body", () => {
  const wid = (s) => ({ server: s.split("@")[1], toString: () => s });
  const coll = (rows) => ({ getModelsArray: () => rows, get: (id) => rows.find((r) => String(r.id) === String(id)) });
  const msgs = [
    { id: { id: "A1", fromMe: false, remote: wid("1@c.us") }, type: "chat", body: "hello", from: wid("1@c.us"), t: 1789900000 },
    { id: { id: "A2", fromMe: true, remote: wid("1@c.us") }, type: "image", body: "/9j/THUMBNAIL", caption: "the receipt", from: wid("9@c.us"), t: 1789900060 },
    { id: { id: "A3", fromMe: false, remote: wid("1@c.us") }, type: "call_log", body: "", from: wid("1@c.us"), t: 1789900090 },
  ];
  const modules = { WAWebCollections: { Msg: coll(msgs), Chat: coll([{ id: wid("1@c.us"), formattedTitle: "Noor" }]), Contact: coll([{ id: wid("1@c.us"), name: "Noor" }, { id: wid("9@c.us"), pushname: "Me" }]) } };
  const reply = read({ require: (n) => modules[n] }, profile("whatsapp-web-store.json").store);
  assert.equal(reply.ok, true, reply.error);
  assert.equal(reply.items.length, 2);
  assert.equal(reply.items[1].body, "the receipt");
  assert.equal(reply.items[0].sender, "Noor");
});

test("a missing store is an error, not an empty success", () => {
  const reply = read({}, profile("telegram-web-k-store.json").store);
  assert.equal(reply.ok, false);
});
