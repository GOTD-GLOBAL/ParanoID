import assert from "node:assert/strict";
import { PROTOTYPE_PROVENANCE, SCREEN_IDS } from "./prototype.js";

const debugBase = process.env.CHROME_DEBUG_URL || "http://127.0.0.1:9223";
const prototypeBase = process.env.PROTOTYPE_URL || "http://127.0.0.1:4173/prototypes/mobile-messenger/";
const targets = await (await fetch(`${debugBase}/json`)).json();
const target = targets.find((item) => item.type === "page");
assert.ok(target, "No debuggable Chromium page found");

const socket = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
  socket.addEventListener("open", resolve, { once: true });
  socket.addEventListener("error", reject, { once: true });
});

let nextId = 0;
const pending = new Map();
socket.addEventListener("message", (event) => {
  const message = JSON.parse(event.data);
  if (!message.id || !pending.has(message.id)) return;
  const { resolve, reject } = pending.get(message.id);
  pending.delete(message.id);
  if (message.error) reject(new Error(message.error.message));
  else resolve(message.result);
});

function command(method, params = {}) {
  const id = ++nextId;
  socket.send(JSON.stringify({ id, method, params }));
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}

async function evaluate(expression) {
  const result = await command("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
  if (result.exceptionDetails) throw new Error(result.exceptionDetails.text);
  return result.result.value;
}

async function waitForRoute(screen) {
  for (let attempt = 0; attempt < 80; attempt += 1) {
    const current = await evaluate(`({ screen: new URLSearchParams(location.search).get('screen'), ready: document.readyState })`);
    if (current.screen === screen && current.ready === "complete") return;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`Route did not become ready: ${screen}`);
}

async function navigateTo(screen, query = "") {
  await command("Page.navigate", { url: `${prototypeBase}?screen=${screen}${query}` });
  await waitForRoute(screen);
}

await command("Runtime.enable");
await command("Page.enable");
await navigateTo("welcome");

const preferences = await evaluate(`(() => {
  document.querySelector('[data-preference="platform"][data-value="android"]').click();
  document.querySelector('[data-preference="theme"][data-value="dark"]').click();
  const device = document.querySelector('.device');
  return { platform: device.dataset.platform, theme: device.dataset.theme };
})()`);
assert.deepEqual(preferences, { platform: "android", theme: "dark" });

const navigation = await evaluate(`(() => {
  document.querySelector('[data-nav="server-choice"]').click();
  return {
    screen: new URLSearchParams(location.search).get('screen'),
    heading: document.querySelector('.phone-screen h1, .phone-screen h2')?.textContent.trim()
  };
})()`);
assert.equal(navigation.screen, "server-choice");
assert.match(navigation.heading, /сервер/i);

await navigateTo("settings-privacy", "&platform=android&theme=dark");
const toggle = await evaluate(`(() => {
  const control = document.querySelector('[data-action="toggle"]');
  const before = control.getAttribute('aria-checked');
  control.click();
  return { before, after: control.getAttribute('aria-checked') };
})()`);
assert.notEqual(toggle.before, toggle.after);

await navigateTo("chat-personal", "&platform=ios&theme=light&chrome=0");
await evaluate(`document.querySelector('[data-nav="message-actions"]').click()`);
await new Promise((resolve) => setTimeout(resolve, 40));
const dialogFocused = await evaluate(`document.querySelector('[role="dialog"]')?.contains(document.activeElement) || false`);
assert.equal(dialogFocused, true, "Modal navigation did not move focus into the dialog");

await command("Emulation.setDeviceMetricsOverride", {
  width: 390,
  height: 844,
  deviceScaleFactor: 1,
  mobile: true
});

const provenanceResults = [];
for (const [index, screen] of SCREEN_IDS.entries()) {
  const platform = index % 2 ? "android" : "ios";
  const theme = Math.floor(index / 2) % 2 ? "dark" : "light";
  await navigateTo(screen, `&platform=${platform}&theme=${theme}&chrome=0`);
  const result = await evaluate(`(() => {
    const marker = document.querySelector('.prototype-provenance');
    const phone = document.querySelector('.phone-screen');
    if (!marker || !phone) return { exists: false };
    const style = getComputedStyle(marker);
    const rect = marker.getBoundingClientRect();
    const phoneRect = phone.getBoundingClientRect();
    return {
      exists: true,
      text: marker.textContent.trim(),
      fontSize: Number.parseFloat(style.fontSize),
      visible: style.display !== 'none' && style.visibility !== 'hidden' && Number.parseFloat(style.opacity) > 0 && rect.width > 0 && rect.height > 0,
      withinPhone: rect.left >= phoneRect.left - 0.5 && rect.right <= phoneRect.right + 0.5 && rect.top >= phoneRect.top - 0.5 && rect.bottom <= phoneRect.bottom + 0.5,
      unclipped: marker.scrollWidth <= marker.clientWidth + 1 && marker.scrollHeight <= marker.clientHeight + 1
    };
  })()`);
  assert.equal(result.exists, true, `${screen}: provenance missing`);
  assert.equal(result.text, PROTOTYPE_PROVENANCE, `${screen}: provenance text changed`);
  assert.ok(result.fontSize >= 12, `${screen}: provenance is below caption size`);
  assert.equal(result.visible, true, `${screen}: provenance is hidden`);
  assert.equal(result.withinPhone, true, `${screen}: provenance is outside the phone`);
  assert.equal(result.unclipped, true, `${screen}: provenance is clipped`);
  provenanceResults.push(screen);
}

socket.close();
console.log(JSON.stringify({
  preferences,
  navigation,
  toggle,
  dialogFocused,
  provenanceRoutes: provenanceResults.length
}, null, 2));
