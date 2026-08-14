import {
  appMain,
  avatar,
  avatarOrbit,
  bottomNav,
  button,
  featureIcon,
  icon,
  iconButton,
  listRow,
  offlineBanner,
  screenFrame,
  section,
  settingRow,
  statusChip,
  systemStatus,
  toast,
  toggle,
  topBar,
  trustRail
} from "./ui.js";

function mainHeader(title, actions = "") {
  return `<header class="main-header"><div class="main-header-row"><h1>${title}</h1><div class="main-header-actions">${actions}</div></div><div class="server-strip">${trustRail("home.paranoid.test")}</div></header>`;
}

function calls() {
  const body = `<div class="chip-row"><button class="pill" aria-pressed="true">Все</button><button class="pill">Пропущенные</button><button class="pill">Запланированные</button></div>
    <div class="call-list">
      ${listRow({ avatarHtml: avatar("Мира Соколова", "mint", true, 47), title: "Мира Соколова", subtitle: `<span class="call-direction">${icon("phone-outgoing", "icon-sm")}Исходящий · 12 мин</span>`, meta: `<span>сегодня<br />09:18</span>${icon("video")}`, nav: "call-video", trailing: "" })}
      ${listRow({ avatarHtml: avatar("Лев Орлов", "gold", false, 47), title: "Лев Орлов", subtitle: `<span class="call-direction missed">${icon("phone-incoming", "icon-sm")}Пропущенный</span>`, meta: `<span>вчера<br />21:04</span>${icon("phone")}`, nav: "call-outgoing", trailing: "" })}
      ${listRow({ avatarHtml: avatar("Северный маршрут", "navy", false, 47), title: "Северный маршрут", subtitle: `<span class="call-direction">${icon("users", "icon-sm")}Групповой · 38 мин</span>`, meta: `<span>вчера<br />18:00</span>${icon("video")}`, nav: "call-group", trailing: "" })}
      ${listRow({ avatarHtml: avatar("Ника Волкова", "", false, 47), title: "Ника Волкова", subtitle: `<span class="call-direction">${icon("phone-incoming", "icon-sm")}Входящий · 4 мин</span>`, meta: `<span>пн<br />14:22</span>${icon("phone")}`, nav: "call-audio", trailing: "" })}
    </div>`;
  const fab = `<button class="fab" type="button" data-nav="contacts" aria-label="Начать новый звонок">${icon("phone", "icon-lg")}</button>`;
  return appMain(body, "calls", { header: mainHeader("Звонки", iconButton("search", "Искать звонок", "search")), fab });
}

function callIncoming() {
  return `<div class="call-screen screen-enter">${systemStatus()}<div class="call-head">
    <span class="pill" style="color:white;background:oklch(1 0 0 / .1)">Входящий аудиозвонок</span>
    ${avatarOrbit("Мира Соколова", "mint", true)}
    <h1>Мира Соколова</h1><p>@mira · home.paranoid.test</p>
    <div class="call-route">${icon("server", "icon-sm")} home.paranoid.test · симуляция связи</div>
  </div>
  <div><div class="incoming-actions">
    <button class="incoming-action" type="button" data-nav="calls"><span>${icon("phone-off", "icon-lg")}</span><span>Отклонить</span></button>
    <button class="incoming-action accept" type="button" data-nav="call-audio"><span>${icon("phone", "icon-lg")}</span><span>Ответить</span></button>
  </div><p class="caption" style="color:oklch(.84 .02 260);text-align:center;margin:12px 0 0">Системный экран адаптируется через CallKit / Android Telecom</p></div></div>`;
}

function callOutgoing() {
  return `<div class="call-screen screen-enter">${systemStatus()}<div class="call-head">
    <span class="pill" style="color:white;background:oklch(1 0 0 / .1)">Исходящий аудиозвонок</span>
    ${avatarOrbit("Мира Соколова", "mint", true)}
    <h1>Мира Соколова</h1><p>Вызываем…</p>
    <div class="call-route">${icon("server", "icon-sm")} home.paranoid.test · сценарий подключения</div>
  </div>
  <div class="call-controls">
    <button class="call-control" type="button" data-toast="Микрофон выключен"><span>${icon("mic")}</span><span>Микрофон</span></button>
    <button class="call-control" type="button" data-toast="Динамик включён"><span>${icon("volume")}</span><span>Динамик</span></button>
    <button class="call-control end" type="button" data-nav="calls"><span>${icon("phone-off")}</span><span>Завершить</span></button>
  </div>
  <button class="btn btn-quiet" style="color:white" type="button" data-nav="call-audio">Показать сценарий звонка</button></div>`;
}

function callAudio() {
  return `<div class="call-screen screen-enter">${systemStatus()}<div class="call-head">
    <span class="mono" style="font-size:13px;font-variant-numeric:tabular-nums">12:48</span>
    ${avatarOrbit("Мира Соколова", "mint", true)}
    <h1>Мира Соколова</h1><p>Аудиозвонок</p>
    <div class="call-route">${icon("server", "icon-sm")} home.paranoid.test · симуляция стабильной связи</div>
  </div>
  <div class="call-controls">
    <button class="call-control" type="button" data-toast="Микрофон выключен"><span>${icon("mic")}</span><span>Микрофон</span></button>
    <button class="call-control active" type="button" data-toast="Динамик включён"><span>${icon("volume")}</span><span>Динамик</span></button>
    <button class="call-control" type="button" data-nav="call-video"><span>${icon("video")}</span><span>Камера</span></button>
    <button class="call-control" type="button" data-toast="Участники открыты"><span>${icon("user-plus")}</span><span>Добавить</span></button>
    <button class="call-control" type="button" data-nav="chat-personal"><span>${icon("message")}</span><span>Сообщения</span></button>
    <button class="call-control end" type="button" data-nav="calls"><span>${icon("phone-off")}</span><span>Завершить</span></button>
  </div></div>`;
}

function callVideo() {
  return `<div class="video-call-screen screen-enter">${systemStatus()}<div class="video-stage" aria-label="Синтетический видеопоток Миры"></div>
    <div class="video-top">${iconButton("chevron-left", "Свернуть звонок", "chat-personal")}<div class="video-top-copy"><strong>Мира Соколова</strong><span class="mono">12:48 · симуляция связи</span></div>${iconButton("more", "Дополнительные настройки", "call-video")}</div>
    <div class="self-preview" role="img" aria-label="Синтетическое локальное превью"></div>
    <div class="video-controls">
      <button class="call-control" type="button" data-toast="Микрофон выключен"><span>${icon("mic")}</span><span>Микрофон</span></button>
      <button class="call-control" type="button" data-toast="Камера переключена"><span>${icon("rotate")}</span><span>Повернуть</span></button>
      <button class="call-control" type="button" data-toast="Камера выключена"><span>${icon("video")}</span><span>Камера</span></button>
      <button class="call-control end" type="button" data-nav="calls"><span>${icon("phone-off")}</span><span>Завершить</span></button>
    </div></div>`;
}

function callGroup() {
  const participants = [
    ["Мира", true, ""], ["Лев", false, ""], ["Ника", false, "mic-off"], ["Вы", false, ""]
  ];
  return `<div class="video-call-screen screen-enter">${systemStatus()}<div class="group-video-grid">${participants.map(([name, speaking, muted]) => `<div class="video-tile ${speaking ? "speaking" : ""}" role="img" aria-label="Синтетический видеопоток: ${name}"><span class="video-tile-name"><b>${name}</b>${muted ? icon(muted, "icon-sm") : ""}</span></div>`).join("")}</div>
    <div class="video-top">${iconButton("chevron-left", "Свернуть звонок", "chat-group")}<div class="video-top-copy"><strong>Северный маршрут</strong><span>4 из 8 · Мира говорит</span></div>${iconButton("users", "Участники", "profile-group")}</div>
    <div class="video-controls">
      <button class="call-control" type="button" data-toast="Микрофон выключен"><span>${icon("mic")}</span><span>Микрофон</span></button>
      <button class="call-control" type="button" data-toast="Камера выключена"><span>${icon("video")}</span><span>Камера</span></button>
      <button class="call-control" type="button" data-nav="chat-group"><span>${icon("message")}</span><span>Чат</span></button>
      <button class="call-control end" type="button" data-nav="calls"><span>${icon("phone-off")}</span><span>Завершить</span></button>
    </div></div>`;
}

function settings() {
  const body = `<div class="screen-pad" style="padding-top:0">
    <button class="settings-profile-card" type="button" data-nav="profile-user" style="width:100%;color:inherit;text-align:left">
      ${avatar("Алина Коваль", "coral", true, 58)}<span class="settings-profile-copy"><strong>Алина Коваль</strong><span>@alina · 2 сервера</span>${trustRail("home.paranoid.test")}</span>${icon("chevron-right", "icon-sm")}
    </button>
    ${section("Аккаунт и доверие", `${settingRow({ iconName: "smartphone", title: "Устройства и сессии", subtitle: "2 устройства", nav: "devices" })}${settingRow({ iconName: "server", title: "Серверы", subtitle: "2 подключено · 1 локально", nav: "servers" })}${settingRow({ iconName: "key", title: "Восстановление", subtitle: "Seed-only paranoid mode", nav: "recovery-warning", tone: "warning" })}`)}
    ${section("Приложение", `${settingRow({ iconName: "shield", title: "Приватность", nav: "settings-privacy" })}${settingRow({ iconName: "bell", title: "Уведомления", subtitle: "Превью скрыто", nav: "settings-notifications" })}${settingRow({ iconName: "database", title: "Данные и хранилище", subtitle: "1,8 ГБ на устройстве", nav: "settings-data" })}${settingRow({ iconName: "settings", title: "Внешний вид", subtitle: "Как в системе", nav: "settings" })}`)}
    ${section("Поддержка", `${settingRow({ iconName: "info", title: "О ParanoID", subtitle: "UX prototype · не production", nav: "settings" })}${settingRow({ iconName: "file", title: "Помощь и документация", nav: "settings" })}`)}
    <button class="btn btn-quiet btn-full danger-text" type="button" data-nav="welcome" style="margin-top:15px">Выйти на этом устройстве</button>
  </div>`;
  return appMain(body, "settings", { header: mainHeader("Настройки") });
}

function settingsPrivacy() {
  const top = topBar({ back: "settings", title: "Приватность" });
  const body = `<div class="screen-pad" style="padding-top:2px">
    <div class="info-panel">${icon("shield", "icon-sm")}<span>Эти переключатели — UX-предложения. Они не подтверждают существование E2EE или гарантий метаданных.</span></div>
    ${section("Видимость", `${settingRow({ iconName: "check", title: "Отчёты о прочтении", subtitle: "В группах правила могут отличаться", control: toggle(true, "Отчёты о прочтении") })}${settingRow({ iconName: "eye", title: "Время последнего посещения", subtitle: "Только контакты", nav: "settings-privacy" })}${settingRow({ iconName: "wifi", title: "Статус в сети", control: toggle(true, "Показывать статус в сети") })}${settingRow({ iconName: "image", title: "Фото профиля", subtitle: "Только контакты", nav: "settings-privacy" })}`)}
    ${section("Контакты и звонки", `${settingRow({ iconName: "phone", title: "Кто может звонить", subtitle: "Контакты и общие группы", nav: "settings-privacy" })}${settingRow({ iconName: "user-plus", title: "Запросы сообщений", subtitle: "Разрешить по никнейму", control: toggle(true, "Разрешить запросы сообщений") })}${settingRow({ iconName: "block", title: "Заблокированные", subtitle: "2 человека", nav: "settings-privacy" })}`)}
    ${section("Метаданные", `${settingRow({ iconName: "server", title: "Данные, видимые серверу", subtitle: "Инвентарь ещё не утверждён", nav: "settings-privacy" })}${settingRow({ iconName: "globe", title: "Публичный реестр", subtitle: "Потенциально постоянные данные", nav: "public-metadata", tone: "warning" })}`)}
  </div>`;
  return screenFrame(`<div class="app-scroll">${body}</div>`, { top });
}

function settingsNotifications() {
  const top = topBar({ back: "settings", title: "Уведомления" });
  const body = `<div class="screen-pad" style="padding-top:2px">
    ${section("Сообщения", `${settingRow({ iconName: "message", title: "Личные чаты", control: toggle(true, "Личные чаты") })}${settingRow({ iconName: "group", title: "Группы", subtitle: "Только упоминания", nav: "settings-notifications" })}${settingRow({ iconName: "user-plus", title: "Запросы сообщений", control: toggle(true, "Запросы сообщений") })}`)}
    ${section("Содержимое", `${settingRow({ iconName: "eye-off", title: "Показывать текст", subtitle: "Скрыто на заблокированном экране", control: toggle(false, "Показывать текст") })}${settingRow({ iconName: "volume", title: "Звук сообщений", subtitle: "Signal glass", nav: "settings-notifications" })}${settingRow({ iconName: "smartphone", title: "Вибрация", subtitle: "Как в системе", nav: "settings-notifications" })}`)}
    ${section("Звонки", `${settingRow({ iconName: "phone", title: "Входящие звонки", control: toggle(true, "Входящие звонки") })}${settingRow({ iconName: "volume", title: "Рингтон", subtitle: "Orbit", nav: "settings-notifications" })}${settingRow({ iconName: "bell", title: "Пропущенные", control: toggle(true, "Пропущенные звонки") })}`)}
    <div class="info-panel" style="margin-top:15px">${icon("info", "icon-sm")}<span>Push-уведомления могут раскрывать платформе метаданные. Точная политика ещё не определена.</span></div>
  </div>`;
  return screenFrame(`<div class="app-scroll">${body}</div>`, { top });
}

function settingsData() {
  const top = topBar({ back: "settings", title: "Данные и хранилище" });
  const body = `<div class="screen-pad" style="padding-top:2px">
    <article class="card"><div class="card-row">${featureIcon("database")}<div class="card-copy"><strong>1,8 ГБ на устройстве</strong><p>Медиа 1,2 ГБ · файлы 420 МБ · прочее 180 МБ</p></div></div><div class="storage-meter" style="margin-top:14px"><span></span></div><div class="detail-row" style="margin-top:9px"><span>Свободно</span><strong>46,7 ГБ</strong></div></article>
    ${section("Автозагрузка", `${settingRow({ iconName: "wifi", title: "Через Wi‑Fi", subtitle: "Фото, видео до 25 МБ, файлы", nav: "settings-data" })}${settingRow({ iconName: "smartphone", title: "Мобильная сеть", subtitle: "Только фото", nav: "settings-data" })}${settingRow({ iconName: "video", title: "Качество отправки", subtitle: "Оптимизированное", nav: "settings-data" })}`)}
    ${section("Локальные данные", `${settingRow({ iconName: "archive", title: "Хранить медиа", subtitle: "30 дней после просмотра", nav: "settings-data" })}${settingRow({ iconName: "trash", title: "Очистить кэш", subtitle: "Освободить до 1,4 ГБ", nav: "settings-data" })}${settingRow({ iconName: "download", title: "Экспорт данных", subtitle: "Требует отдельного контракта", nav: "settings-data" })}`)}
    <div class="warning-panel" style="margin-top:15px">${icon("alert-circle", "icon-sm")}<span>Сроки хранения, синхронизация и удаление сообщений ещё не определены требованиями.</span></div>
  </div>`;
  return screenFrame(`<div class="app-scroll">${body}</div>`, { top });
}

function devices() {
  const top = topBar({ back: "settings", title: "Устройства и сессии", actions: iconButton("plus", "Добавить устройство", "sign-in") });
  const body = `<div class="screen-pad" style="padding-top:2px">
    <div class="info-panel">${icon("key", "icon-sm")}<span>Каждое устройство должно иметь отдельную отзывную authority. Точная синхронизация отзыва ещё открыта.</span></div>
    <h2 class="section-title">Это устройство</h2><article class="card"><div class="card-row">${featureIcon("smartphone", "signal")}<div class="card-copy"><strong>iPhone 17 Pro</strong><p>Сейчас · Berlin · home.paranoid.test</p></div>${statusChip("Активно")}</div><div class="detail-grid"><div class="detail-row"><span>Добавлено</span><strong>12 августа 2026</strong></div><div class="detail-row"><span>Локальная защита</span><strong>Биометрия устройства</strong></div></div></article>
    <h2 class="section-title">Другие устройства</h2><div class="list-section">
      ${listRow({ iconName: "laptop", title: "Pixel Fold", subtitle: "2 часа назад · studio.local", nav: "devices", meta: statusChip("Доверено") })}
      ${listRow({ iconName: "smartphone", title: "Старый iPhone", subtitle: "Неактивно 34 дня", nav: "devices", meta: `<span class="danger-text">Отозвать</span>` })}
    </div>
    <h2 class="section-title">Сессии серверов</h2><div class="list-section">
      ${listRow({ iconName: "server", title: "home.paranoid.test", subtitle: "Обновлено сейчас", nav: "servers", meta: statusChip("Активна") })}
      ${listRow({ iconName: "server", title: "studio.local", subtitle: "Обновлено 2 часа назад", nav: "servers", meta: statusChip("Активна") })}
    </div>
    <button class="btn btn-quiet btn-full danger-text" type="button" data-nav="settings" style="margin-top:15px">Завершить другие сессии</button>
  </div>`;
  return screenFrame(`<div class="app-scroll">${body}</div>`, { top });
}

function servers() {
  const top = topBar({ back: "settings", title: "Серверы", actions: iconButton("plus", "Добавить сервер", "server-choice") });
  const body = `<div class="screen-pad" style="padding-top:2px">
    <article class="card trust-card server-node-card"><div class="trust-card-head"><span class="server-mark">${icon("home")}</span>${statusChip("Основной")}</div><div class="card-copy"><strong>ParanoID Home</strong><p class="mono">home.paranoid.test</p></div><div style="margin-top:12px">${trustRail("home.paranoid.test")}</div><div class="detail-grid"><div class="detail-row"><span>Оператор</span><strong>Вы</strong></div><div class="detail-row"><span>Доступ</span><strong>Интернет + LAN</strong></div></div></article>
    <article class="card server-node-card"><div class="trust-card-head"><span class="server-mark">${icon("server")}</span>${statusChip("Только LAN", "warning")}</div><div class="card-copy"><strong>Studio</strong><p class="mono">studio.local</p></div><div style="margin-top:12px">${trustRail("studio.local", "offline")}</div><div class="detail-grid"><div class="detail-row"><span>Оператор</span><strong>Studio collective</strong></div><div class="detail-row"><span>Интернет</span><strong class="warning-text">Недоступен</strong></div></div></article>
    <div class="info-panel" style="margin-top:12px">${icon("info", "icon-sm")}<span>Как одна identity участвует через несколько серверов — открытый вопрос REQ-MULTI-001.</span></div>
    ${section("Действия", `${settingRow({ iconName: "plus", title: "Подключить сервер", subtitle: "Адрес или QR-код", nav: "server-choice" })}${settingRow({ iconName: "rocket", title: "Развернуть новый", subtitle: "Экспериментальный путь", nav: "server-deploy" })}${settingRow({ iconName: "refresh", title: "Проверить соединения", nav: "servers" })}`)}
  </div>`;
  return screenFrame(`<div class="app-scroll">${body}</div>`, { top });
}

function stateLoading() {
  const header = mainHeader("Чаты", iconButton("edit", "Новый чат", "search"));
  const rows = Array.from({ length: 7 }, (_, index) => `<div class="skeleton-row"><div class="skeleton-avatar"></div><div class="skeleton-copy"><div class="skeleton-line" style="--skeleton-w:${62 + (index % 3) * 8}%"></div><div class="skeleton-line small"></div></div></div>`).join("");
  return screenFrame(`${header}<div class="app-scroll"><div class="screen-pad"><div class="skeleton-line" style="height:38px;--skeleton-w:100%;margin-bottom:20px"></div><div class="skeleton-list" aria-label="Загрузка чатов">${rows}</div></div></div>`, { bottom: bottomNav("chats") });
}

function stateEmpty() {
  const header = mainHeader("Чаты", iconButton("edit", "Новый чат", "search"));
  return screenFrame(`${header}<div class="state-screen"><div class="state-center"><div class="state-illustration">${icon("message", "icon-lg")}</div><h1>Начните первый разговор</h1><p>Найдите человека по никнейму или создайте группу для друзей.</p>${button("Найти человека", "contact-add", "primary")}</div></div>`, { bottom: bottomNav("chats") });
}

function stateError() {
  const top = topBar({ back: "chats", title: "Чаты" });
  return screenFrame(`<div class="state-screen"><div class="state-center"><div class="state-illustration danger">${icon("alert-circle", "icon-lg")}</div><h1>Не удалось обновить чаты</h1><p>Сервер ответил слишком поздно. Проверьте соединение или попробуйте ещё раз.</p><div class="button-stack">${button("Повторить", "state-loading", "primary")}${button("Открыть параметры сервера", "servers", "secondary")}</div></div></div>`, { top });
}

function stateOffline() {
  const header = mainHeader("Чаты", iconButton("edit", "Новый чат", "search"));
  const body = `<div class="screen-pad" style="padding-top:4px"><article class="card"><div class="card-row">${featureIcon("wifi-off", "warning")}<div class="card-copy"><strong>Симуляция офлайн-режима</strong><p>Макет предполагает, что home.paranoid.test виден в локальной сети. Поддерживаемые операции ещё не приняты.</p></div></div><div class="detail-grid"><div class="detail-row"><span>Пример возраста кэша</span><strong class="warning-text">18 минут · макет</strong></div><div class="detail-row"><span>Пример очереди сообщений</span><strong>3</strong></div></div></article>
    <h2 class="section-title">Сценарий доступности</h2><div class="list-section">
      ${listRow({ iconName: "message", title: "Локальные чаты", subtitle: "Сообщения внутри home.paranoid.test", nav: "chats", meta: statusChip("Сценарий") })}
      ${listRow({ iconName: "archive", title: "История на устройстве", subtitle: "Ранее загруженные сообщения и файлы", nav: "chats", meta: statusChip("Сценарий") })}
      ${listRow({ iconName: "globe", title: "Регистрация и recovery", subtitle: "Нужна свежая публичная state", nav: "servers", meta: statusChip("Недоступно", "warning") })}
    </div>
    <div class="warning-panel" style="margin-top:14px">${icon("alert-circle", "icon-sm")}<span>Точный срок допустимого кэша и набор offline-операций ещё не приняты.</span></div></div>`;
  return screenFrame(`${header}<div class="app-scroll">${body}</div>`, { bottom: bottomNav("chats"), banner: offlineBanner("UX-сценарий · домашний сервер виден локально") });
}

function statePermission() {
  return screenFrame(`<div class="state-screen" style="background:linear-gradient(160deg,var(--surface-raised),var(--canvas));filter:saturate(.8)"><div class="state-center" style="opacity:.34">${avatarOrbit("Мира Соколова", "mint", true)}<h1>Записать голосовое</h1><p>Нажмите на микрофон, чтобы начать.</p></div></div><div class="sheet-layer" style="align-items:center"><div class="permission-dialog" role="dialog" aria-modal="true" aria-labelledby="permission-title">${featureIcon("mic")}<h1 id="permission-title">Разрешить доступ к микрофону?</h1><p>В этой UX-концепции доступ нужен для действий, которые начинаете вы. Реальный клиент должен подтвердить отсутствие фонового захвата и утечек в диагностике.</p><div class="permission-actions"><button class="btn btn-quiet" type="button" data-nav="chat-personal">Не сейчас</button><button class="btn btn-primary" type="button" data-nav="voice-recording">Разрешить</button></div></div></div>`);
}

export const callsSettingsGroups = [
  { title: "Звонки", screens: [
    { id: "calls", title: "История звонков", render: calls },
    { id: "call-incoming", title: "Входящий аудиозвонок", render: callIncoming },
    { id: "call-outgoing", title: "Исходящий аудиозвонок", render: callOutgoing },
    { id: "call-audio", title: "Активный аудиозвонок", render: callAudio },
    { id: "call-video", title: "Видеозвонок 1:1", render: callVideo },
    { id: "call-group", title: "Групповой видеозвонок", render: callGroup }
  ]},
  { title: "Настройки и доверие", screens: [
    { id: "settings", title: "Настройки", render: settings },
    { id: "settings-privacy", title: "Приватность", render: settingsPrivacy },
    { id: "settings-notifications", title: "Уведомления", render: settingsNotifications },
    { id: "settings-data", title: "Данные и хранилище", render: settingsData },
    { id: "devices", title: "Устройства и сессии", render: devices },
    { id: "servers", title: "Несколько серверов", render: servers }
  ]},
  { title: "Loading, empty, error, offline", screens: [
    { id: "state-loading", title: "Loading", render: stateLoading },
    { id: "state-empty", title: "Empty", render: stateEmpty },
    { id: "state-error", title: "Error", render: stateError },
    { id: "state-offline", title: "Offline", render: stateOffline },
    { id: "state-permission", title: "Permission prompt", render: statePermission }
  ]}
];
