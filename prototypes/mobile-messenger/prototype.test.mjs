import test from "node:test";
import assert from "node:assert/strict";
import { CRITICAL_FLOWS, PROTOTYPE_PROVENANCE, SCREENS, SCREEN_IDS } from "./prototype.js";

const requiredScreens = [
  "splash", "welcome", "sign-in", "nickname", "profile-create", "permissions", "ready",
  "server-choice", "server-connect", "server-deploy", "server-preflight", "server-progress", "server-ready",
  "chats", "chat-personal", "chat-group", "message-actions", "attachments", "media-preview", "voice-recording", "forward",
  "search", "contacts", "contact-add", "group-create", "profile-user", "profile-group",
  "settings", "settings-privacy", "settings-notifications", "settings-data", "devices", "servers",
  "calls", "call-incoming", "call-outgoing", "call-audio", "call-video", "call-group",
  "state-loading", "state-empty", "state-error", "state-offline", "state-permission"
];

const screenMarkup = (id) => SCREENS.find((screen) => screen.id === id)?.render() || "";

test("screen registry is unique and covers the requested product journey", () => {
  assert.equal(SCREEN_IDS.length, 49);
  assert.equal(new Set(SCREEN_IDS).size, SCREEN_IDS.length);
  for (const screen of requiredScreens) assert.ok(SCREEN_IDS.includes(screen), `missing screen: ${screen}`);
});

test("every rendered navigation target resolves to a real screen", () => {
  const known = new Set(SCREEN_IDS);
  for (const screen of SCREENS) {
    const markup = screen.render();
    assert.ok(markup.length > 80, `${screen.id} rendered too little markup`);
    assert.ok(!markup.includes("undefined"), `${screen.id} rendered an undefined value`);
    for (const match of markup.matchAll(/data-nav="([^"]+)"/g)) {
      assert.ok(known.has(match[1]), `${screen.id} points to unknown screen ${match[1]}`);
    }
  }
});

test("critical flows only reference registered screens", () => {
  const known = new Set(SCREEN_IDS);
  for (const [name, flow] of Object.entries(CRITICAL_FLOWS)) {
    assert.ok(flow.length >= 4, `${name} is not a meaningful flow`);
    for (const screen of flow) assert.ok(known.has(screen), `${name} references unknown screen ${screen}`);
  }
});

test("all routes share persistent experimental and synthetic provenance", () => {
  assert.match(PROTOTYPE_PROVENANCE, /UX-ЭКСПЕРИМЕНТ/);
  assert.match(PROTOTYPE_PROVENANCE, /СИНТЕТИЧЕСКИЕ ДАННЫЕ/);
  assert.match(PROTOTYPE_PROVENANCE, /НЕ РЕАЛИЗОВАНО/);
});

test("protected-boundary screens carry threat-linked qualifiers", () => {
  assert.match(screenMarkup("recover"), /только на устройстве.*никогда не передаются серверу/s);
  assert.match(screenMarkup("recover"), /локально выводит ключ.*отдельным шагом/s);
  assert.match(screenMarkup("public-metadata"), /RPC.*домашний сервер.*federation peer.*платформа/s);
  assert.match(screenMarkup("public-metadata"), /не анонимна/);
  assert.match(screenMarkup("server-progress"), /Симуляция.*Имитируем.*кандидатные/s);
  assert.match(screenMarkup("state-offline"), /Симуляция офлайн-режима.*18 минут · макет/s);
  assert.match(screenMarkup("state-permission"), /UX-концепции.*Реальный клиент/s);
});

test("prototype copy avoids unsupported production security claims", () => {
  const rendered = SCREENS.map((screen) => screen.render()).join("\n").toLowerCase();
  for (const unsupportedClaim of [
    "гарантированно защищено",
    "абсолютная приватность",
    "доказанное сквозное шифрование",
    "полностью анонимно",
    " · соединение",
    " · стабильно",
    "получен сертификат",
    "создаются безопасные настройки"
  ]) {
    assert.ok(!rendered.includes(unsupportedClaim), `unsupported claim found: ${unsupportedClaim}`);
  }
});

test("running prototype serves its core assets", async () => {
  const base = process.env.PROTOTYPE_URL || "http://127.0.0.1:4173/prototypes/mobile-messenger";
  for (const asset of ["/", "/styles.css", "/qa-polish.css", "/security-polish.css", "/prototype.js", "/assets/coast-weekend.webp"]) {
    const response = await fetch(`${base}${asset}`);
    assert.equal(response.status, 200, `${asset} returned ${response.status}`);
    await response.arrayBuffer();
  }
});
