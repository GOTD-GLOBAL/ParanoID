export const BRAND_MARK = "../../assets/brand/paranoid-fingerprint-p.svg";
export const MEDIA_PHOTO = "assets/coast-weekend.webp";

const ICONS = {
  "alert-circle": '<circle cx="12" cy="12" r="9"/><path d="M12 8v5"/><path d="M12 16h.01"/>',
  archive: '<path d="M4 7h16v13H4z"/><path d="M3 3h18v4H3z"/><path d="M9 11h6"/>',
  bell: '<path d="M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9"/><path d="M10 21h4"/>',
  block: '<circle cx="12" cy="12" r="9"/><path d="m6 6 12 12"/>',
  camera: '<path d="M4 8h3l2-3h6l2 3h3v11H4z"/><circle cx="12" cy="13" r="3.5"/>',
  check: '<path d="m5 12 4 4L19 6"/>',
  "chevron-left": '<path d="m15 18-6-6 6-6"/>',
  "chevron-right": '<path d="m9 18 6-6-6-6"/>',
  cloud: '<path d="M7 18h10a4 4 0 0 0 .6-8A6 6 0 0 0 6 8.5 4.5 4.5 0 0 0 7 18Z"/>',
  contact: '<circle cx="12" cy="8" r="3"/><path d="M5 20c.5-4 3-6 7-6s6.5 2 7 6"/>',
  copy: '<rect x="8" y="8" width="11" height="11" rx="2"/><path d="M16 8V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h3"/>',
  database: '<ellipse cx="12" cy="5" rx="8" ry="3"/><path d="M4 5v7c0 1.7 3.6 3 8 3s8-1.3 8-3V5"/><path d="M4 12v7c0 1.7 3.6 3 8 3s8-1.3 8-3v-7"/>',
  download: '<path d="M12 3v12"/><path d="m7 10 5 5 5-5"/><path d="M5 21h14"/>',
  edit: '<path d="M12 20h9"/><path d="m16.5 3.5 4 4L9 19l-5 1 1-5Z"/>',
  eye: '<path d="M2 12s3.5-6 10-6 10 6 10 6-3.5 6-10 6S2 12 2 12Z"/><circle cx="12" cy="12" r="2.5"/>',
  "eye-off": '<path d="m3 3 18 18"/><path d="M10.6 6.2A11 11 0 0 1 12 6c6.5 0 10 6 10 6a17 17 0 0 1-3 3.8"/><path d="M6.6 6.6C3.5 8.5 2 12 2 12s3.5 6 10 6c1.4 0 2.6-.3 3.7-.7"/>',
  file: '<path d="M6 3h8l4 4v14H6z"/><path d="M14 3v5h5"/><path d="M9 13h6M9 17h6"/>',
  forward: '<path d="m15 8 5 4-5 4v-3c-5 0-8 2-11 6 1-6 4-10 11-10Z"/>',
  globe: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c3 3 3 15 0 18M12 3c-3 3-3 15 0 18"/>',
  group: '<circle cx="9" cy="8" r="3"/><circle cx="17" cy="10" r="2.5"/><path d="M3 20c.3-4 2.7-6 6-6s5.7 2 6 6"/><path d="M15 15c3 0 5 1.7 5.5 5"/>',
  "hard-drive": '<rect x="3" y="5" width="18" height="14" rx="3"/><path d="M7 15h.01M11 15h6"/>',
  headphones: '<path d="M4 14v-2a8 8 0 0 1 16 0v2"/><path d="M4 14h3v6H5a1 1 0 0 1-1-1ZM20 14h-3v6h2a1 1 0 0 0 1-1Z"/>',
  home: '<path d="m3 11 9-8 9 8"/><path d="M5 10v11h14V10"/><path d="M9 21v-7h6v7"/>',
  image: '<rect x="3" y="4" width="18" height="16" rx="3"/><circle cx="9" cy="10" r="2"/><path d="m21 15-5-5L5 20"/>',
  info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7h.01"/>',
  key: '<circle cx="8" cy="15" r="4"/><path d="m11 12 9-9M16 7l2 2M14 9l2 2"/>',
  laptop: '<rect x="4" y="4" width="16" height="12" rx="2"/><path d="M2 20h20"/>',
  link: '<path d="M10 13a5 5 0 0 0 7.5.5l2-2a5 5 0 0 0-7-7l-1.2 1.2"/><path d="M14 11a5 5 0 0 0-7.5-.5l-2 2a5 5 0 0 0 7 7l1.2-1.2"/>',
  lock: '<rect x="5" y="10" width="14" height="11" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/>',
  menu: '<path d="M4 7h16M4 12h16M4 17h16"/>',
  message: '<path d="M21 12a8 8 0 0 1-8 8H6l-4 2 1.5-4A9 9 0 1 1 21 12Z"/>',
  mic: '<rect x="9" y="3" width="6" height="12" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3M9 21h6"/>',
  "mic-off": '<path d="m3 3 18 18"/><path d="M9 5v6a3 3 0 0 0 4.8 2.4M15 9V6a3 3 0 0 0-4.6-2.5M5 11a7 7 0 0 0 11.8 5.1M19 11a7 7 0 0 1-.7 3M12 18v3M9 21h6"/>',
  more: '<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>',
  paperclip: '<path d="m20 11-8 8a5 5 0 0 1-7-7l9-9a3.5 3.5 0 0 1 5 5l-9 9a2 2 0 0 1-3-3l8-8"/>',
  pause: '<path d="M9 5v14M15 5v14"/>',
  phone: '<path d="M7 3h3l2 5-2 2c1.3 2.8 3.2 4.7 6 6l2-2 5 2v3c0 1.1-.9 2-2 2C11 20.3 3.7 13 3 5a2 2 0 0 1 2-2Z"/>',
  "phone-incoming": '<path d="M7 3h3l2 5-2 2c1.3 2.8 3.2 4.7 6 6l2-2 5 2v3c0 1.1-.9 2-2 2C11 20.3 3.7 13 3 5a2 2 0 0 1 2-2Z"/><path d="m15 3 4 4M19 3v4h-4"/>',
  "phone-off": '<path d="m3 3 18 18"/><path d="M10.5 10.5c1.3 2.6 3.2 4.3 5.5 5.5l2-2 4 2v3c0 1.1-.9 2-2 2C11 20.3 3.7 13 3 5a2 2 0 0 1 2-2h3l1.7 4.1"/>',
  "phone-outgoing": '<path d="M7 3h3l2 5-2 2c1.3 2.8 3.2 4.7 6 6l2-2 5 2v3c0 1.1-.9 2-2 2C11 20.3 3.7 13 3 5a2 2 0 0 1 2-2Z"/><path d="m15 7 4-4M15 3h4v4"/>',
  play: '<path d="m9 6 9 6-9 6Z"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  qr: '<path d="M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4zM15 15h2v2h-2zM18 14h2v3M14 19h3M20 19v1"/>',
  refresh: '<path d="M20 7V3l-3 3a8 8 0 1 0 2.4 8"/>',
  reply: '<path d="m9 8-5 4 5 4v-3c5 0 8 2 11 6-1-6-4-10-11-10Z"/>',
  rocket: '<path d="M14 5c3-3 6-2 6-2s1 3-2 6l-6 6-4-4Z"/><path d="m8 11-4 1-2 3 5 1M12 15l-1 4 2 3 2-5M7 17l-2 2"/>',
  rotate: '<path d="M20 7V3l-3 3a8 8 0 1 0 2.4 8"/><path d="M12 8v4l3 2"/>',
  search: '<circle cx="11" cy="11" r="7"/><path d="m20 20-4-4"/>',
  send: '<path d="m22 2-7 20-4-9-9-4Z"/><path d="M22 2 11 13"/>',
  server: '<rect x="4" y="3" width="16" height="7" rx="2"/><rect x="4" y="14" width="16" height="7" rx="2"/><path d="M8 7h.01M8 18h.01M12 7h4M12 18h4"/>',
  settings: '<circle cx="12" cy="12" r="3"/><path d="M19 13.5V10l2-1-2-4-2 1a8 8 0 0 0-3-2l-.5-2h-4L9 4a8 8 0 0 0-3 2L4 5 2 9l2 1v3.5l-2 1L4 19l2-1a8 8 0 0 0 3 2l.5 2h4l.5-2a8 8 0 0 0 3-2l2 1 2-4.5Z"/>',
  share: '<circle cx="18" cy="5" r="2.5"/><circle cx="6" cy="12" r="2.5"/><circle cx="18" cy="19" r="2.5"/><path d="m8 11 7.5-4.5M8 13l7.5 4.5"/>',
  shield: '<path d="M12 3 20 6v6c0 5-3 8-8 10-5-2-8-5-8-10V6Z"/><path d="m9 12 2 2 4-5"/>',
  smartphone: '<rect x="7" y="2" width="10" height="20" rx="2"/><path d="M11 18h2"/>',
  smile: '<circle cx="12" cy="12" r="9"/><path d="M8 14s1.5 2 4 2 4-2 4-2M9 9h.01M15 9h.01"/>',
  trash: '<path d="M4 7h16M9 7V4h6v3M7 7l1 14h8l1-14M10 11v6M14 11v6"/>',
  user: '<circle cx="12" cy="8" r="3.5"/><path d="M4 21c.5-5 3-7 8-7s7.5 2 8 7"/>',
  "user-plus": '<circle cx="9" cy="8" r="3"/><path d="M3 20c.5-4 2.5-6 6-6 2 0 3.5.7 4.5 2M18 12v6M15 15h6"/>',
  users: '<circle cx="9" cy="8" r="3"/><circle cx="17" cy="9" r="2.5"/><path d="M3 20c.4-4 2.7-6 6-6s5.6 2 6 6M15 15c3.2 0 5.2 1.7 5.5 5"/>',
  video: '<rect x="3" y="6" width="13" height="12" rx="2"/><path d="m16 10 5-3v10l-5-3Z"/>',
  "video-off": '<path d="m3 3 18 18"/><path d="M10 6H5a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h11V12M16 10l5-3v10l-2-1.2"/>',
  volume: '<path d="M5 10v4h4l5 4V6l-5 4Z"/><path d="M17 9c1.5 1.6 1.5 4.4 0 6M19.5 6.5c3 3 3 8 0 11"/>',
  "volume-off": '<path d="M5 10v4h4l5 4V6l-5 4Z"/><path d="m18 10 4 4M22 10l-4 4"/>',
  wifi: '<path d="M3 9a14 14 0 0 1 18 0M6 13a9 9 0 0 1 12 0M9.5 16.5a4 4 0 0 1 5 0M12 20h.01"/>',
  "wifi-off": '<path d="m3 3 18 18"/><path d="M6.5 7.5A14 14 0 0 1 21 9M3 9a14 14 0 0 1 1.8-1.2M8.5 12.5A9 9 0 0 1 18 13M6 13a9 9 0 0 1 .8-.7M11 16.2a4 4 0 0 1 3.5.3M12 20h.01"/>',
  wrench: '<path d="M14 6a5 5 0 0 0-7-3l3 3-4 4-3-3a5 5 0 0 0 6 7l7 7 4-4-7-7a5 5 0 0 0 1-4Z"/>',
  x: '<path d="m6 6 12 12M18 6 6 18"/>'
};

export function icon(name, className = "") {
  const paths = ICONS[name] || ICONS.info;
  return `<svg class="icon ${className}" viewBox="0 0 24 24" aria-hidden="true">${paths}</svg>`;
}

export function systemStatus() {
  return `<div class="system-status" aria-hidden="true">
    <span>9:41</span>
    <span class="status-icons">
      <span class="status-signal"><i></i><i></i><i></i><i></i></span>
      ${icon("wifi", "icon-sm")}
      <span class="status-battery"></span>
    </span>
  </div>`;
}

export function iconButton(name, label, nav = "", extraClass = "") {
  const navAttr = nav ? ` data-nav="${nav}"` : "";
  return `<button class="icon-btn ${extraClass}" type="button" aria-label="${label}"${navAttr}>${icon(name)}</button>`;
}

export function topBar({ title = "", subtitle = "", back = "", actions = "", center = "", className = "" } = {}) {
  const leading = back ? iconButton("chevron-left", "Назад", back) : `<span aria-hidden="true"></span>`;
  const middle = center || `<div class="topbar-title"><strong>${title}</strong>${subtitle ? `<small>${subtitle}</small>` : ""}</div>`;
  return `<header class="app-topbar glass ${className}">${leading}${middle}<div class="topbar-actions">${actions}</div></header>`;
}

export function screenFrame(body, { top = "", bottom = "", className = "", banner = "", toast = "" } = {}) {
  return `${systemStatus()}${top}${banner}<div class="screen-enter ${className}" style="display:flex;flex:1;min-height:0;flex-direction:column">${body}</div>${bottom}${toast}`;
}

export function progressLine(step, total = 6) {
  const items = Array.from({ length: total }, (_, index) => `<i class="${index + 1 < step ? "done" : index + 1 === step ? "active" : ""}"></i>`).join("");
  return `<div class="progress-line" aria-label="Шаг ${step} из ${total}">${items}<span class="progress-label">${step}/${total}</span></div>`;
}

export function button(label, nav, variant = "primary", extra = "") {
  return `<button type="button" class="btn btn-${variant} ${extra}" data-nav="${nav}">${label}</button>`;
}

export function avatar(name, variant = "", online = false, size = "") {
  const initials = name.split(/\s+/).slice(0, 2).map((part) => part[0]).join("").toUpperCase();
  const style = size ? ` style="--avatar-size:${size}px"` : "";
  return `<span class="avatar ${variant} ${online ? "online" : "no-status"}" aria-label="${name}"${style}>${initials}</span>`;
}

export function avatarOrbit(name, variant = "", online = true) {
  return `<div class="avatar-orbit">${avatar(name, variant, online)}</div>`;
}

export function featureIcon(name, tone = "") {
  return `<span class="feature-icon ${tone}">${icon(name)}</span>`;
}

export function cardButton({ iconName, tone = "", title, text, nav, trailing = "chevron-right", extraClass = "" }) {
  return `<button type="button" class="card interactive ${extraClass}" data-nav="${nav}">
    <span class="card-row">${featureIcon(iconName, tone)}<span class="card-copy"><strong>${title}</strong><p>${text}</p></span>${trailing ? icon(trailing, "icon-sm") : ""}</span>
  </button>`;
}

export function trustRail(server = "home.paranoid.test", state = "connected") {
  const label = state === "offline" ? "локальный режим" : state === "stale" ? "кэш устарел" : "симуляция связи";
  return `<span class="trust-rail"><b></b><i></i><span>${server} · ${label}</span></span>`;
}

export function statusChip(label, tone = "") {
  return `<span class="status-chip ${tone}">${label}</span>`;
}

export function bottomNav(active = "chats") {
  const entries = [
    ["chats", "message", "Чаты", "3"],
    ["calls", "phone", "Звонки", ""],
    ["contacts", "users", "Контакты", ""],
    ["settings", "settings", "Настройки", ""]
  ];
  return `<nav class="bottom-nav" aria-label="Основные разделы">${entries.map(([route, iconName, label, badge]) => `
    <button type="button" class="nav-item" data-nav="${route}" ${active === route ? 'aria-current="page"' : ""}>
      <span class="icon-wrap">${icon(iconName)}${badge ? `<span class="badge" aria-label="${badge} непрочитанных">${badge}</span>` : ""}</span>
      <span>${label}</span>
    </button>`).join("")}</nav>`;
}

export function listRow({ iconName = "", tone = "", avatarHtml = "", title, subtitle = "", meta = "", nav = "", trailing = "chevron-right", extraClass = "" }) {
  const tag = nav ? "button" : "div";
  const navAttr = nav ? ` type="button" data-nav="${nav}"` : "";
  const lead = avatarHtml || (iconName ? `<span class="list-icon ${tone}">${icon(iconName)}</span>` : "");
  return `<${tag} class="list-row ${nav ? "interactive" : ""} ${extraClass}"${navAttr}>${lead}<span class="list-row-copy"><strong>${title}</strong>${subtitle ? `<span>${subtitle}</span>` : ""}</span>${meta ? `<span class="list-row-meta">${meta}</span>` : trailing ? `<span class="chevron">${icon(trailing, "icon-sm")}</span>` : ""}</${tag}>`;
}

export function toggle(on = true, label = "Переключить") {
  return `<button type="button" class="switch" role="switch" aria-label="${label}" aria-checked="${on}" data-action="toggle"></button>`;
}

export function settingRow({ iconName, title, subtitle = "", nav = "", control = "", tone = "" }) {
  return listRow({ iconName, tone, title, subtitle, nav, trailing: control ? "" : "chevron-right", meta: control });
}

export function qrCode() {
  const pattern = [
    1,1,1,0,1,0,1,1,1, 1,0,1,1,0,1,1,0,1, 1,1,1,0,1,0,1,1,1,
    0,1,0,1,1,1,0,1,0, 1,0,1,1,0,0,1,0,1, 0,1,0,0,1,1,0,1,0,
    1,1,1,0,1,0,1,0,1, 1,0,1,1,0,1,0,1,0, 1,1,1,0,1,1,1,0,1
  ];
  return `<div class="qr-code" role="img" aria-label="Синтетический QR-код подключения">${pattern.map((cell) => `<i class="${cell ? "" : "blank"}"></i>`).join("")}</div>`;
}

export function wordGrid() {
  return `<div class="word-grid" aria-label="24 синтетических метки восстановления">${Array.from({ length: 24 }, (_, i) => `<span class="word-chip"><b>${String(i + 1).padStart(2, "0")}</b>метка-${String(i + 1).padStart(2, "0")}</span>`).join("")}</div>`;
}

export function waveform(count = 22) {
  const heights = [25,48,70,35,88,52,30,65,92,44,74,30,58,82,36,64,95,45,70,38,55,80,42,66];
  return `<span class="waveform" aria-hidden="true">${Array.from({ length: count }, (_, i) => `<i style="--h:${heights[i % heights.length]}%"></i>`).join("")}</span>`;
}

export function mediaThumb(alt = "Синтетическая фотография северного побережья") {
  return `<img src="${MEDIA_PHOTO}" alt="${alt}" width="1024" height="768" />`;
}

export function toast(message, iconName = "check") {
  return `<div class="prototype-toast" role="status">${featureIcon(iconName, "signal")}<span>${message}</span></div>`;
}

export function offlineBanner(text = "Нет интернета · локальный сервер доступен") {
  return `<div class="offline-banner" role="status">${icon("wifi-off", "icon-sm")}<span>${text}</span></div>`;
}

export function appMain(body, active, { header = "", banner = "", fab = "", toastHtml = "" } = {}) {
  return screenFrame(`${header}<div class="app-scroll">${body}</div>${fab}`, { bottom: bottomNav(active), banner, toast: toastHtml });
}

export function section(title, rows) {
  return `<h2 class="section-title">${title}</h2><div class="list-section">${rows}</div>`;
}

export function chatHeader({ name, subtitle, back = "chats", avatarVariant = "", group = false }) {
  const center = `<button class="chat-header-person" type="button" data-nav="${group ? "profile-group" : "profile-user"}" aria-label="Открыть профиль ${name}">
    ${avatar(name, avatarVariant, true, 35)}
    <span class="topbar-title"><strong>${name}</strong><small>${subtitle}</small></span>
  </button>`;
  const actions = `${iconButton("phone", "Аудиозвонок", "call-outgoing")}${iconButton("video", "Видеозвонок", group ? "call-group" : "call-video")}`;
  return topBar({ back, center, actions });
}

export function conversationComposer(value = "Сообщение", mode = "normal") {
  if (mode === "recording") {
    return `<div class="composer voice-recorder"><button class="btn btn-quiet" data-nav="chat-personal" type="button">Отмена</button><div class="recording-status"><i class="record-dot"></i><span class="record-time">00:18</span>${waveform(12)}</div>${iconButton("send", "Отправить голосовое", "chat-personal", "send-button")}</div>`;
  }
  return `<div class="composer">${iconButton("plus", "Добавить вложение", "attachments")}<button class="composer-field" type="button" data-toast="Поле ввода активно">${value}</button>${iconButton("mic", "Записать голосовое", "voice-recording", "send-button")}</div>`;
}
