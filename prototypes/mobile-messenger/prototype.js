import { onboardingGroups } from "./screens-onboarding.js";
import { messagingGroups } from "./screens-messaging.js";
import { callsSettingsGroups } from "./screens-calls-settings.js";
import { BRAND_MARK, icon, toast } from "./ui.js";

export const SCREEN_GROUPS = [
  ...onboardingGroups,
  ...messagingGroups,
  ...callsSettingsGroups
];

export const SCREENS = SCREEN_GROUPS.flatMap((group) => group.screens.map((screen) => ({ ...screen, group: group.title })));
export const SCREEN_IDS = SCREENS.map((screen) => screen.id);
export const PROTOTYPE_PROVENANCE = "UX-ЭКСПЕРИМЕНТ · СИНТЕТИЧЕСКИЕ ДАННЫЕ · НЕ РЕАЛИЗОВАНО";

export const CRITICAL_FLOWS = {
  createIdentity: ["splash", "welcome", "server-choice", "server-connect", "nickname", "public-metadata", "recovery-warning", "recovery-words", "recovery-confirm", "profile-create", "permissions", "ready", "chats"],
  deployServer: ["server-choice", "server-deploy", "server-preflight", "server-progress", "server-ready", "nickname"],
  dailyMessaging: ["chats", "chat-personal", "message-actions", "forward", "attachments", "media-preview", "voice-recording"],
  groupMessaging: ["chats", "chat-group", "profile-group", "group-create"],
  calling: ["calls", "call-incoming", "call-outgoing", "call-audio", "call-video", "call-group"],
  trustAndSettings: ["settings", "settings-privacy", "settings-notifications", "settings-data", "devices", "servers"],
  resilientStates: ["state-loading", "state-empty", "state-error", "state-offline", "state-permission"]
};

const screenById = new Map(SCREENS.map((screen) => [screen.id, screen]));
const root = typeof document !== "undefined" ? document.querySelector("#app") : null;
let toastTimer = null;

let state = {
  screen: "splash",
  platform: "ios",
  theme: "light",
  chrome: true,
  toast: ""
};

function readUrl() {
  const params = new URLSearchParams(window.location.search);
  const requestedScreen = params.get("screen") || "splash";
  state.screen = screenById.has(requestedScreen) ? requestedScreen : "splash";
  state.platform = params.get("platform") === "android" ? "android" : "ios";
  state.theme = params.get("theme") === "dark" ? "dark" : "light";
  state.chrome = params.get("chrome") !== "0";
  state.toast = "";
}

function writeUrl({ replace = false } = {}) {
  const url = new URL(window.location.href);
  url.searchParams.set("screen", state.screen);
  url.searchParams.set("platform", state.platform);
  url.searchParams.set("theme", state.theme);
  if (state.chrome) url.searchParams.delete("chrome");
  else url.searchParams.set("chrome", "0");
  const method = replace ? "replaceState" : "pushState";
  window.history[method]({ screen: state.screen }, "", url);
}

function focusRenderedView() {
  window.requestAnimationFrame(() => {
    const dialog = document.querySelector('[role="dialog"][aria-modal="true"]');
    const target = dialog?.querySelector('button, input, textarea, select, [tabindex]:not([tabindex="-1"])')
      || document.querySelector("#phone-screen");
    target?.focus({ preventScroll: true });
  });
}

function navigate(screen, { replace = false } = {}) {
  if (!screenById.has(screen)) return;
  state.screen = screen;
  state.toast = "";
  writeUrl({ replace });
  render();
  focusRenderedView();
}

function setPreference(key, value) {
  state[key] = value;
  writeUrl({ replace: true });
  render();
}

function showToast(message) {
  state.toast = message;
  render();
  window.clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => {
    state.toast = "";
    const toastElement = document.querySelector(".prototype-toast[data-global-toast]");
    if (toastElement) toastElement.remove();
  }, 2600);
}

function explorerControl(label, key, choices) {
  return `<div><div class="control-label"><span>${label}</span></div><div class="segmented-control" role="group" aria-label="${label}">${choices.map(([value, title]) => `<button type="button" data-preference="${key}" data-value="${value}" aria-pressed="${state[key] === value}">${title}</button>`).join("")}</div></div>`;
}

function renderExplorer() {
  return `<aside class="explorer" aria-label="Навигация по прототипу">
    <div class="explorer-head">
      <div class="explorer-brand"><img src="${BRAND_MARK}" alt="" /><span><strong>ParanoID</strong><span>Mobile UX prototype</span></span></div>
      <p class="prototype-note">High-fidelity концепция. Нет реальной регистрации, сообщений, звонков или privacy-гарантий.</p>
    </div>
    <div class="explorer-controls">
      ${explorerControl("Платформа", "platform", [["ios", "iOS"], ["android", "Android"]])}
      ${explorerControl("Тема", "theme", [["light", "Светлая"], ["dark", "Тёмная"]])}
    </div>
    <nav class="screen-index" aria-label="Карта экранов">${SCREEN_GROUPS.map((group) => {
      const isOpen = group.screens.some((screen) => screen.id === state.screen);
      return `<details class="screen-group" ${isOpen ? "open" : ""}><summary>${group.title}</summary><div class="screen-links">${group.screens.map((screen) => `<button class="screen-link" type="button" data-nav="${screen.id}" ${screen.id === state.screen ? 'aria-current="page"' : ""}>${screen.title}</button>`).join("")}</div></details>`;
    }).join("")}</nav>
  </aside>`;
}

function renderStage() {
  const active = screenById.get(state.screen);
  const screenMarkup = active.render();
  const globalToast = state.toast ? toast(state.toast, "check").replace('class="prototype-toast"', 'class="prototype-toast" data-global-toast') : "";
  const provenance = `<div class="prototype-provenance" role="note" aria-label="UX-эксперимент. Синтетические данные. Функции не реализованы.">${PROTOTYPE_PROVENANCE}</div>`;
  const directUrl = `?screen=${state.screen}&platform=${state.platform}&theme=${state.theme}`;
  return `<main class="stage"><div class="stage-inner">
    <div class="device platform-${state.platform}" data-theme="${state.theme}" data-platform="${state.platform}" aria-label="${active.title}: ${state.platform === "ios" ? "iOS" : "Android"}, ${state.theme === "dark" ? "тёмная" : "светлая"} тема">
      <section class="phone-screen" id="phone-screen" tabindex="-1">${screenMarkup}${globalToast}${provenance}</section>
    </div>
    <div class="stage-meta"><span>${active.group} · ${active.title}</span><code>${directUrl}</code><span>Клавиши [ и ] переключают экраны</span></div>
  </div></main>`;
}

function render() {
  if (!root) return;
  document.body.classList.toggle("capture-mode", !state.chrome);
  document.documentElement.dataset.prototypeTheme = state.theme;
  const active = screenById.get(state.screen);
  document.title = `${active.title} · ParanoID prototype`;
  root.innerHTML = `<div class="prototype-shell">${state.chrome ? renderExplorer() : ""}${renderStage()}</div>`;
}

function adjacentScreen(direction) {
  const currentIndex = SCREEN_IDS.indexOf(state.screen);
  const nextIndex = (currentIndex + direction + SCREEN_IDS.length) % SCREEN_IDS.length;
  navigate(SCREEN_IDS[nextIndex]);
}

function handleClick(event) {
  const preference = event.target.closest("[data-preference]");
  if (preference) {
    setPreference(preference.dataset.preference, preference.dataset.value);
    return;
  }

  const toggleControl = event.target.closest('[data-action="toggle"]');
  if (toggleControl) {
    const next = toggleControl.getAttribute("aria-checked") !== "true";
    toggleControl.setAttribute("aria-checked", String(next));
    return;
  }

  const pressedControl = event.target.closest(".segmented-control button");
  if (pressedControl && !pressedControl.dataset.preference) {
    pressedControl.parentElement.querySelectorAll("button").forEach((buttonElement) => buttonElement.setAttribute("aria-pressed", String(buttonElement === pressedControl)));
    return;
  }

  const toastControl = event.target.closest("[data-toast]");
  if (toastControl) {
    showToast(toastControl.dataset.toast);
    return;
  }

  const nav = event.target.closest("[data-nav]");
  if (nav) navigate(nav.dataset.nav);
}

function handleKeydown(event) {
  if (event.target.matches("input, textarea, select")) return;
  const dialog = document.querySelector('[role="dialog"][aria-modal="true"]');
  if (event.key === "Tab" && dialog) {
    const focusable = [...dialog.querySelectorAll('button:not([disabled]), input:not([disabled]), textarea:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"])')];
    if (focusable.length) {
      const first = focusable[0];
      const last = focusable.at(-1);
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    }
  }
  if (event.key === "]") adjacentScreen(1);
  if (event.key === "[") adjacentScreen(-1);
  if (event.key === "Escape" && !state.chrome) {
    state.chrome = true;
    writeUrl({ replace: true });
    render();
  }
}

function init() {
  readUrl();
  render();
  document.addEventListener("click", handleClick);
  document.addEventListener("keydown", handleKeydown);
  window.addEventListener("popstate", () => {
    readUrl();
    render();
  });
}

if (root) init();
