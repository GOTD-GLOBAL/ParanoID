import {
  MEDIA_PHOTO,
  appMain,
  avatar,
  avatarOrbit,
  bottomNav,
  button,
  chatHeader,
  conversationComposer,
  featureIcon,
  icon,
  iconButton,
  listRow,
  mediaThumb,
  qrCode,
  screenFrame,
  section,
  statusChip,
  systemStatus,
  toast,
  topBar,
  trustRail,
  waveform
} from "./ui.js";

function mainHeader(title, { search = true, add = true, profile = false } = {}) {
  const leading = profile ? avatar("Алина Коваль", "coral", true, 36) : "";
  return `<header class="main-header"><div class="main-header-row"><div style="display:flex;align-items:center;gap:10px">${leading}<h1>${title}</h1></div><div class="main-header-actions">${search ? iconButton("search", "Поиск", "search") : ""}${add ? iconButton("edit", "Новый чат", "search") : ""}</div></div><div class="server-strip">${trustRail("home.paranoid.test")}</div></header>`;
}

function chatRow({ name, preview, time, nav, variant = "", online = false, unread = 0, prefix = "", muted = false }) {
  return `<button class="chat-row ${unread ? "unread" : ""}" type="button" data-nav="${nav}">
    ${avatar(name, variant, online, 50)}
    <span class="chat-row-copy">
      <span class="chat-row-title"><strong>${name}</strong><time>${time}</time></span>
      <span class="chat-row-preview"><span>${prefix ? `<b>${prefix}</b> ` : ""}${preview}</span>${unread ? `<span class="badge" aria-label="${unread} непрочитанных">${unread}</span>` : muted ? icon("bell", "icon-sm") : ""}</span>
    </span>
  </button>`;
}

function chats() {
  const body = `<div class="filter-row" aria-label="Фильтры чатов"><button class="pill" aria-pressed="true">Все</button><button class="pill" aria-pressed="false">Непрочитанные</button><button class="pill" aria-pressed="false">Группы</button><button class="pill" aria-pressed="false">Запросы · 1</button></div>
    <div class="chat-list">
      ${chatRow({ name: "Мира Соколова", preview: "Да, в субботу утром идеально", time: "09:38", nav: "chat-personal", variant: "mint", online: true, unread: 2 })}
      ${chatRow({ name: "Северный маршрут", preview: "Добавил файл с точками ночёвки", time: "09:12", nav: "chat-group", variant: "navy", unread: 1, prefix: "Даня:" })}
      ${chatRow({ name: "Лев Орлов", preview: "Голосовое сообщение · 0:42", time: "вчера", nav: "chat-personal", variant: "gold" })}
      ${chatRow({ name: "Продуктовая команда", preview: "Вы: Обновила макет onboarding", time: "вчера", nav: "chat-group", variant: "coral", muted: true })}
      ${chatRow({ name: "Ника Волкова", preview: "Фото", time: "пн", nav: "chat-personal", variant: "" })}
      ${chatRow({ name: "Дом", preview: "Сервер снова доступен локально", time: "пн", nav: "servers", variant: "mint" })}
    </div>`;
  const fab = `<button class="fab" type="button" data-nav="search" aria-label="Начать новый чат">${icon("edit", "icon-lg")}</button>`;
  return appMain(body, "chats", { header: mainHeader("Чаты", { profile: true }), fab });
}

function messageTicks() {
  return `${icon("check", "icon-sm")}${icon("check", "icon-sm")}`;
}

function personalMessages() {
  return `<div class="message-list">
    <div class="date-divider">Сегодня</div>
    <div class="message-line in"><div class="bubble"><p>Нашла тихий маршрут вдоль берега. Там почти нет связи — как раз то, что нужно.</p><span class="bubble-meta">09:24</span></div></div>
    <div class="message-line out"><button class="bubble message-trigger" type="button" data-nav="message-actions" aria-label="Открыть действия с сообщением"><div class="reply-preview">Мира · «маршрут вдоль берега»</div><p>Покажешь точку старта? Я проверю электричку.</p><span class="bubble-meta">09:27 ${messageTicks()}</span></button></div>
    <div class="message-line in" style="margin-bottom:15px"><div class="bubble media-message">${mediaThumb()}<div class="media-caption"><p>Вот этот участок. Снимала в прошлые выходные.</p><span class="bubble-meta">09:31</span></div><span class="reaction-chip">♥ <b>2</b></span></div></div>
    <div class="message-line out"><div class="bubble"><div class="voice-message"><button class="voice-play" type="button" aria-label="Воспроизвести голосовое">${icon("play", "icon-sm")}</button>${waveform(20)}<span class="voice-time">0:18</span></div><span class="bubble-meta">09:35 ${messageTicks()}</span></div></div>
    <div class="message-line in"><div class="bubble"><div class="file-message">${featureIcon("file")}<div><div class="file-name">coast-route.gpx</div><div class="file-size">1,8 МБ · файл маршрута</div></div></div><span class="bubble-meta">09:37</span></div></div>
    <div class="message-line in"><div class="bubble"><p>Да, в субботу утром идеально</p><span class="bubble-meta">09:38</span></div></div>
  </div>`;
}

function personalBase(mode = "normal") {
  const header = chatHeader({ name: "Мира Соколова", subtitle: "в сети · home.paranoid.test", avatarVariant: "mint" });
  return screenFrame(`<div class="conversation">${personalMessages()}${conversationComposer(mode === "recording" ? "" : "Сообщение", mode)}</div>`, { top: header });
}

function chatPersonal() {
  return personalBase();
}

function groupMessages() {
  return `<div class="message-list">
    <div class="date-divider">Сегодня</div>
    <div class="message-line in">${avatar("Даня", "gold", false, 27)}<div class="bubble"><div class="sender-name">Даня</div><p>Собрал точки ночёвки и воду в один файл.</p><span class="bubble-meta">08:42</span></div></div>
    <div class="message-line in">${avatar("Даня", "gold", false, 27)}<div class="bubble"><div class="file-message">${featureIcon("file")}<div><div class="file-name">north-route-v3.pdf</div><div class="file-size">4,2 МБ · 12 страниц</div></div></div><span class="bubble-meta">08:43</span></div></div>
    <div class="message-line out"><div class="bubble"><div class="reply-preview">Даня · «точки ночёвки»</div><p>Супер. Я отмечу место, где ловит локальный сервер.</p><span class="bubble-meta">08:55 ${messageTicks()}</span></div></div>
    <div class="message-line in" style="margin-bottom:15px">${avatar("Мира", "mint", false, 27)}<div class="bubble"><div class="sender-name">Мира</div><p>Тогда стартуем в 07:20?</p><span class="bubble-meta">09:02</span><span class="reaction-chip">👍 <b>4</b></span></div></div>
    <div class="message-line in">${avatar("Лев", "navy", false, 27)}<div class="bubble"><p>Я за. Сделал групповой звонок на 18:00.</p><span class="bubble-meta">09:05</span></div></div>
  </div>`;
}

function chatGroup() {
  const header = chatHeader({ name: "Северный маршрут", subtitle: "8 участников · 4 в сети", avatarVariant: "navy", group: true });
  return screenFrame(`<div class="conversation">${groupMessages()}${conversationComposer()}</div>`, { top: header });
}

function messageActions() {
  return `${personalBase()}<div class="sheet-layer" role="dialog" aria-modal="true" aria-label="Действия с сообщением">
    <div class="sheet"><div class="sheet-handle"></div><h1 class="sheet-title">Действия с сообщением</h1>
      <div class="reaction-row" aria-label="Реакции">
        <button class="reaction-option" type="button" data-nav="chat-personal" aria-label="Реакция нравится">♥</button>
        <button class="reaction-option" type="button" data-nav="chat-personal" aria-label="Реакция огонь">🔥</button>
        <button class="reaction-option" type="button" data-nav="chat-personal" aria-label="Реакция улыбка">😊</button>
        <button class="reaction-option" type="button" data-nav="chat-personal" aria-label="Реакция удивление">😮</button>
        <button class="reaction-option" type="button" data-nav="chat-personal" aria-label="Реакция грусть">😢</button>
        <button class="reaction-option" type="button" data-nav="chat-personal" aria-label="Другие реакции">＋</button>
      </div>
      <div class="list-section">
        ${listRow({ iconName: "reply", title: "Ответить", nav: "chat-personal" })}
        ${listRow({ iconName: "forward", title: "Переслать", nav: "forward" })}
        ${listRow({ iconName: "copy", title: "Скопировать текст", nav: "chat-personal" })}
        ${listRow({ iconName: "info", title: "Сведения о сообщении", nav: "chat-personal" })}
        ${listRow({ iconName: "trash", title: "Удалить у себя", nav: "chat-personal", extraClass: "danger-text" })}
      </div>
      <button class="btn btn-quiet btn-full" type="button" data-nav="chat-personal" style="margin-top:8px">Закрыть</button>
    </div></div>`;
}

function attachments() {
  return `${personalBase()}<div class="sheet-layer" role="dialog" aria-modal="true" aria-label="Добавить вложение"><div class="sheet">
    <div class="sheet-handle"></div><h1 class="sheet-title">Добавить</h1>
    <div class="sheet-grid">
      <button class="sheet-action" type="button" data-nav="media-preview">${featureIcon("image")}Фото</button>
      <button class="sheet-action" type="button" data-nav="media-preview">${featureIcon("video")}Видео</button>
      <button class="sheet-action" type="button" data-nav="media-preview">${featureIcon("camera", "signal")}Камера</button>
      <button class="sheet-action" type="button" data-nav="chat-personal">${featureIcon("file")}Файл</button>
      <button class="sheet-action" type="button" data-nav="contacts">${featureIcon("contact")}Контакт</button>
      <button class="sheet-action" type="button" data-nav="chat-personal">${featureIcon("more")}Ещё</button>
    </div>
    <div class="info-panel" style="margin-top:12px">${icon("shield", "icon-sm")}<span>Системный выбор фото и файлов сокращает ненужные разрешения.</span></div>
    <button class="btn btn-quiet btn-full" type="button" data-nav="chat-personal" style="margin-top:8px">Отмена</button>
  </div></div>`;
}

function mediaPreview() {
  const top = topBar({ back: "attachments", title: "Предпросмотр", actions: iconButton("edit", "Редактировать", "media-preview") });
  return `${systemStatus()}<div class="video-call-screen media-preview-screen screen-enter">${top}<div class="media-preview">${mediaThumb("Три человека идут по северному побережью")}</div><div class="preview-composer"><button class="composer-field" type="button" data-toast="Добавьте подпись">Добавить подпись…</button>${iconButton("send", "Отправить фото", "chat-personal", "send-button")}</div></div>`;
}

function voiceRecording() {
  return personalBase("recording");
}

function forward() {
  const top = topBar({ back: "message-actions", title: "Переслать", actions: `<button class="btn btn-quiet" data-nav="chat-personal" type="button">Готово</button>` });
  const body = `<div class="search-box-wrap"><span>${icon("search")}</span><input class="search-field" aria-label="Найти получателя" placeholder="Люди и чаты" /></div>
    <div class="screen-pad" style="padding-top:0"><div class="selected-people">
      <div class="selected-person">${avatar("Лев Орлов", "gold", false, 42)}<span>Лев</span></div>
      <div class="selected-person">${avatar("Северный маршрут", "navy", false, 42)}<span>Маршрут</span></div>
    </div>
    <h2 class="section-title" style="margin-top:3px">Недавние</h2><div class="list-section">
      ${listRow({ avatarHtml: avatar("Лев Орлов", "gold", false, 43), title: "Лев Орлов", subtitle: "@lev", trailing: "", meta: `<span class="checkbox">${icon("check", "icon-sm")}</span>` })}
      ${listRow({ avatarHtml: avatar("Северный маршрут", "navy", false, 43), title: "Северный маршрут", subtitle: "8 участников", trailing: "", meta: `<span class="checkbox">${icon("check", "icon-sm")}</span>` })}
      ${listRow({ avatarHtml: avatar("Ника Волкова", "", false, 43), title: "Ника Волкова", subtitle: "@nika", trailing: "", meta: `<span class="checkbox empty">${icon("check", "icon-sm")}</span>` })}
      ${listRow({ avatarHtml: avatar("Продуктовая команда", "coral", false, 43), title: "Продуктовая команда", subtitle: "14 участников", trailing: "", meta: `<span class="checkbox empty">${icon("check", "icon-sm")}</span>` })}
    </div></div>`;
  return screenFrame(`<div class="app-scroll">${body}</div><div style="padding:8px 12px 14px">${button("Переслать в 2 чата", "chat-personal", "primary", "btn-full")}</div>`, { top });
}

function search() {
  const top = topBar({ back: "chats", title: "Поиск" });
  const body = `<div class="search-box-wrap"><span>${icon("search")}</span><input class="search-field" value="маршрут" aria-label="Поиск" /></div>
    <div class="chip-row"><button class="pill" aria-pressed="true">Везде</button><button class="pill">Сообщения</button><button class="pill">Люди</button><button class="pill">Файлы</button></div>
    <div class="screen-pad" style="padding-top:0">
      <h2 class="section-title" style="margin-top:4px">Люди и чаты</h2><div class="list-section">
        ${listRow({ avatarHtml: avatar("Северный маршрут", "navy", false, 43), title: "Северный маршрут", subtitle: "Группа · 8 участников", nav: "chat-group" })}
        ${listRow({ avatarHtml: avatar("Мария Маршрут", "mint", true, 43), title: "Мария Маршрут", subtitle: "@maria · nearby.local", nav: "profile-user" })}
      </div>
      <h2 class="section-title">Сообщения</h2><div class="list-section">
        ${listRow({ iconName: "message", title: "Мира · сегодня, 09:24", subtitle: "Нашла тихий маршрут вдоль берега…", nav: "chat-personal" })}
        ${listRow({ iconName: "file", title: "Даня · сегодня, 08:42", subtitle: "Собрал точки маршрута и воду…", nav: "chat-group" })}
        ${listRow({ iconName: "image", title: "Ника · понедельник", subtitle: "Фото с прошлогоднего маршрута", nav: "chat-personal" })}
      </div>
    </div>`;
  return screenFrame(`<div class="app-scroll">${body}</div>`, { top });
}

function contacts() {
  const body = `<div class="screen-pad" style="padding-top:0">
    <button class="card interactive" type="button" data-nav="contact-add"><span class="card-row">${featureIcon("user-plus")}<span class="card-copy"><strong>1 новый запрос</strong><p>Проверьте никнейм и сервер перед добавлением</p></span>${icon("chevron-right", "icon-sm")}</span></button>
    <h2 class="section-title">В сети</h2><div class="list-section">
      ${listRow({ avatarHtml: avatar("Мира Соколова", "mint", true, 43), title: "Мира Соколова", subtitle: "@mira · home.paranoid.test", nav: "profile-user" })}
      ${listRow({ avatarHtml: avatar("Лев Орлов", "gold", true, 43), title: "Лев Орлов", subtitle: "@lev · studio.local", nav: "profile-user" })}
      ${listRow({ avatarHtml: avatar("Ника Волкова", "", true, 43), title: "Ника Волкова", subtitle: "@nika · home.paranoid.test", nav: "profile-user" })}
    </div>
    <h2 class="section-title">Все контакты</h2><div class="list-section">
      ${listRow({ avatarHtml: avatar("Артём Ясный", "navy", false, 43), title: "Артём Ясный", subtitle: "@artem", nav: "profile-user" })}
      ${listRow({ avatarHtml: avatar("Даня Ветров", "coral", false, 43), title: "Даня Ветров", subtitle: "@danya", nav: "profile-user" })}
      ${listRow({ avatarHtml: avatar("Саша Рэй", "mint", false, 43), title: "Саша Рэй", subtitle: "@ray", nav: "profile-user" })}
    </div></div>`;
  const fab = `<button class="fab" type="button" data-nav="contact-add" aria-label="Добавить контакт">${icon("user-plus", "icon-lg")}</button>`;
  return appMain(body, "contacts", { header: mainHeader("Контакты", { profile: false }), fab });
}

function contactAdd() {
  const top = topBar({ back: "contacts", title: "Добавить контакт" });
  const body = `<div class="screen-pad-wide">
    <div class="field"><label for="contact-name">Никнейм или адрес</label><input id="contact-name" value="@mira" autocomplete="off" autocapitalize="none" /><span class="field-help">Для другого сервера добавьте его адрес после никнейма.</span></div>
    <button class="btn btn-primary btn-full" type="button" data-nav="profile-user">Найти человека</button>
    <div class="qr-wrap">${qrCode()}<strong>Показать мой QR</strong><span class="caption" style="text-align:center">QR содержит синтетический идентификатор и сервер для этого макета.</span></div>
    <div class="list-section">
      ${listRow({ iconName: "qr", title: "Сканировать QR-код", subtitle: "Камера будет запрошена только сейчас", nav: "profile-user" })}
      ${listRow({ iconName: "wifi", tone: "signal", title: "Найти рядом", subtitle: "Локальная сеть · требуется явное подтверждение", nav: "profile-user" })}
      ${listRow({ iconName: "share", title: "Поделиться моей ссылкой", subtitle: "Проверьте, какие данные попадут в ссылку", nav: "contacts" })}
    </div>
    <div class="info-panel" style="margin-top:12px">${icon("info", "icon-sm")}<span>Совпадение имени не подтверждает личность. Будущий продукт должен дать проверяемый способ сверки.</span></div>
  </div>`;
  return screenFrame(`<div class="app-scroll">${body}</div>`, { top });
}

function groupCreate() {
  const top = topBar({ back: "chats", title: "Новая группа", subtitle: "Шаг 2 из 3", actions: `<button class="btn btn-quiet" data-nav="chat-group" type="button">Создать</button>` });
  const body = `<div class="screen-pad" style="padding-top:4px">
    <div class="field"><label for="group-name">Название группы</label><input id="group-name" value="Северный маршрут" /></div>
    <div class="selected-people">
      <div class="selected-person">${avatar("Мира Соколова", "mint", false, 42)}<span>Мира</span></div>
      <div class="selected-person">${avatar("Лев Орлов", "gold", false, 42)}<span>Лев</span></div>
      <div class="selected-person">${avatar("Ника Волкова", "", false, 42)}<span>Ника</span></div>
    </div>
    <div class="search-box-wrap" style="margin:0 0 10px"><span>${icon("search")}</span><input class="search-field" aria-label="Найти контакт" placeholder="Добавить участников" /></div>
    <div class="list-section">
      ${listRow({ avatarHtml: avatar("Мира Соколова", "mint", false, 43), title: "Мира Соколова", subtitle: "@mira", trailing: "", meta: `<span class="checkbox">${icon("check", "icon-sm")}</span>` })}
      ${listRow({ avatarHtml: avatar("Лев Орлов", "gold", false, 43), title: "Лев Орлов", subtitle: "@lev", trailing: "", meta: `<span class="checkbox">${icon("check", "icon-sm")}</span>` })}
      ${listRow({ avatarHtml: avatar("Ника Волкова", "", false, 43), title: "Ника Волкова", subtitle: "@nika", trailing: "", meta: `<span class="checkbox">${icon("check", "icon-sm")}</span>` })}
      ${listRow({ avatarHtml: avatar("Артём Ясный", "navy", false, 43), title: "Артём Ясный", subtitle: "@artem", trailing: "", meta: `<span class="checkbox empty">${icon("check", "icon-sm")}</span>` })}
    </div>
    <h2 class="section-title">Кто может приглашать</h2><div class="segmented-control" role="group" aria-label="Права приглашения"><button aria-pressed="true">Администраторы</button><button aria-pressed="false">Все</button></div>
  </div>`;
  return screenFrame(`<div class="app-scroll">${body}</div>`, { top });
}

function profileUser() {
  const top = topBar({ back: "chat-personal", title: "Профиль", actions: iconButton("more", "Другие действия", "profile-user") });
  const body = `<div class="profile-hero">${avatarOrbit("Мира Соколова", "mint", true)}<h1>Мира Соколова</h1><p>@mira · home.paranoid.test</p><div style="margin-top:9px">${trustRail("home.paranoid.test")}</div>
    <div class="profile-actions">
      <button class="profile-action" type="button" data-nav="chat-personal">${icon("message")}Сообщение</button>
      <button class="profile-action" type="button" data-nav="call-outgoing">${icon("phone")}Аудио</button>
      <button class="profile-action" type="button" data-nav="call-video">${icon("video")}Видео</button>
    </div></div>
    <div class="screen-pad" style="padding-top:0">
      <div class="card"><div class="card-copy"><strong>О себе</strong><p>Люблю длинные маршруты, северный ветер и хорошие карты.</p></div></div>
      ${section("Общее", `${listRow({ iconName: "group", title: "2 общие группы", nav: "profile-group" })}${listRow({ iconName: "image", title: "Медиа, ссылки и файлы", subtitle: "48 элементов", nav: "profile-user" })}${listRow({ iconName: "bell", title: "Уведомления", subtitle: "По умолчанию", nav: "settings-notifications" })}`)}
      ${section("Безопасность", `${listRow({ iconName: "info", title: "Сведения о соединении", subtitle: "Без неподтверждённых E2EE-обещаний", nav: "profile-user" })}${listRow({ iconName: "block", title: "Заблокировать", nav: "profile-user", extraClass: "danger-text" })}`)}
    </div>`;
  return screenFrame(`<div class="app-scroll">${body}</div>`, { top });
}

function profileGroup() {
  const top = topBar({ back: "chat-group", title: "Группа", actions: iconButton("more", "Другие действия", "profile-group") });
  const body = `<div class="profile-hero">${avatarOrbit("Северный маршрут", "navy", true)}<h1>Северный маршрут</h1><p>8 участников · создана Мирой</p>
    <div class="profile-actions">
      <button class="profile-action" type="button" data-nav="chat-group">${icon("message")}Чат</button>
      <button class="profile-action" type="button" data-nav="call-group">${icon("video")}Звонок</button>
      <button class="profile-action" type="button" data-nav="contact-add">${icon("user-plus")}Добавить</button>
    </div></div>
    <div class="screen-pad" style="padding-top:0">
      <div class="card"><div class="card-copy"><strong>Выход к морю · 24–26 августа</strong><p>Планы, файлы и договорённости команды.</p></div></div>
      ${section("Участники · 8", `${listRow({ avatarHtml: avatar("Мира Соколова", "mint", true, 40), title: "Мира Соколова", subtitle: "Создатель", nav: "profile-user" })}${listRow({ avatarHtml: avatar("Алина Коваль", "coral", true, 40), title: "Вы", subtitle: "Администратор", nav: "profile-user" })}${listRow({ avatarHtml: avatar("Лев Орлов", "gold", true, 40), title: "Лев Орлов", subtitle: "Участник", nav: "profile-user" })}${listRow({ iconName: "users", title: "Показать всех участников", nav: "profile-group" })}`)}
      ${section("Содержимое", `${listRow({ iconName: "image", title: "Медиа, ссылки и файлы", subtitle: "126 элементов", nav: "profile-group" })}${listRow({ iconName: "link", title: "Ссылка-приглашение", subtitle: "Выключена", nav: "profile-group" })}${listRow({ iconName: "bell", title: "Уведомления", subtitle: "Только упоминания", nav: "settings-notifications" })}`)}
      <button class="btn btn-quiet btn-full danger-text" type="button" data-nav="chats" style="margin-top:15px">Покинуть группу</button>
    </div>`;
  return screenFrame(`<div class="app-scroll">${body}</div>`, { top });
}

export const messagingGroups = [
  { title: "Чаты и сообщения", screens: [
    { id: "chats", title: "Список чатов", render: chats },
    { id: "chat-personal", title: "Личный чат", render: chatPersonal },
    { id: "chat-group", title: "Групповой чат", render: chatGroup },
    { id: "message-actions", title: "Реакции и действия", render: messageActions },
    { id: "attachments", title: "Вложения", render: attachments },
    { id: "media-preview", title: "Фото и видео", render: mediaPreview },
    { id: "voice-recording", title: "Голосовое сообщение", render: voiceRecording },
    { id: "forward", title: "Пересылка", render: forward }
  ]},
  { title: "Поиск, контакты и группы", screens: [
    { id: "search", title: "Поиск", render: search },
    { id: "contacts", title: "Контакты", render: contacts },
    { id: "contact-add", title: "Добавить контакт", render: contactAdd },
    { id: "group-create", title: "Создание группы", render: groupCreate },
    { id: "profile-user", title: "Профиль пользователя", render: profileUser },
    { id: "profile-group", title: "Профиль группы", render: profileGroup }
  ]}
];
