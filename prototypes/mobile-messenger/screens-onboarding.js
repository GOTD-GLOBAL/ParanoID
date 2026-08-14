import {
  BRAND_MARK,
  avatar,
  avatarOrbit,
  button,
  cardButton,
  featureIcon,
  icon,
  iconButton,
  progressLine,
  qrCode,
  screenFrame,
  statusChip,
  systemStatus,
  topBar,
  trustRail,
  wordGrid
} from "./ui.js";

function authFrame({ body, footer = "", back = "", step = 0, total = 6, centered = false }) {
  const top = back ? topBar({ back }) : "";
  return screenFrame(`<div class="auth-screen ${centered ? "centered" : ""}"><div class="auth-main">${step ? progressLine(step, total) : ""}${body}</div>${footer ? `<div class="auth-footer">${footer}</div>` : ""}</div>`, { top });
}

function splash() {
  return `${systemStatus()}<div class="splash-screen screen-enter"><div class="splash-lockup">
    <div class="hero-orbit"><i class="orbit-node"></i><img class="brand-mark" src="${BRAND_MARK}" alt="" /></div>
    <h1>ParanoID</h1><p>Связь на ваших условиях</p>
    <button class="btn btn-quiet" type="button" data-nav="welcome">Открыть прототип</button>
  </div><span class="splash-version">UX experiment · 2026-08-14</span></div>`;
}

function welcome() {
  return authFrame({ centered: true, body: `
    <div class="wordmark-row"><img src="${BRAND_MARK}" alt="" />ParanoID</div>
    <div class="hero-orbit"><i class="orbit-node"></i><img class="brand-mark" src="${BRAND_MARK}" alt="" /></div>
    <h1 class="large-title">Ваши разговоры.<br />Ваш сервер.</h1>
    <p class="body-copy">Создайте аккаунт без номера телефона и выберите, где будет работать ваш мессенджер.</p>`,
    footer: `${button("Создать аккаунт", "server-choice", "primary", "btn-full")}${button("Войти", "sign-in", "secondary", "btn-full")}<p class="caption" style="text-align:center;margin:3px 8px 0">Интерактивная концепция: реальные данные не отправляются.</p>`
  });
}

function serverChoice() {
  return authFrame({ back: "welcome", step: 1, body: `
    <h1 class="large-title">Выберите сервер</h1>
    <p class="body-copy">Сервер хранит и доставляет данные по будущим правилам проекта. Перед подключением проверьте, кто им управляет.</p>
    <div style="margin-top:18px">
      <button class="card interactive trust-card" type="button" data-nav="server-connect">
        <span class="trust-card-head"><span class="server-mark">${icon("home")}</span>${statusChip("Симуляция", "")}</span>
        <span class="card-copy"><strong>Домашний сервер</strong><p class="mono">home.paranoid.test</p></span>
        <span style="display:block;margin-top:12px">${trustRail("home.paranoid.test")}</span>
      </button>
      ${cardButton({ iconName: "wifi", tone: "signal", title: "studio.local", text: "Найден в локальной сети · администратор Studio", nav: "server-connect" })}
      ${cardButton({ iconName: "link", title: "Подключить по адресу", text: "Введите адрес или отсканируйте QR-код", nav: "server-connect" })}
      ${cardButton({ iconName: "rocket", tone: "warning", title: "Развернуть новый", text: "Пошаговая концепция для дома или Linux/VPS", nav: "server-deploy" })}
    </div>`
  });
}

function serverConnect() {
  return authFrame({ back: "server-choice", step: 1, body: `
    <h1 class="large-title">Подключить сервер</h1>
    <div class="field"><label for="server-url">Адрес сервера</label><input id="server-url" value="home.paranoid.test" autocomplete="url" inputmode="url" /><span class="field-help">Используйте адрес, полученный от администратора.</span></div>
    <article class="card trust-card">
      <div class="trust-card-head"><span class="server-mark">${icon("server")}</span>${statusChip("Симуляция связи")}</div>
      <div class="card-copy"><strong>ParanoID Home</strong><p class="mono">home.paranoid.test</p></div>
      <div class="detail-grid">
        <div class="detail-row"><span>Оператор</span><strong>Вы · домашний сервер</strong></div>
        <div class="detail-row"><span>Доступ</span><strong>Интернет и локальная сеть</strong></div>
        <div class="detail-row"><span>Версия</span><strong>UX prototype</strong></div>
      </div>
    </article>
    <div class="info-panel" style="margin-top:12px">${icon("info", "icon-sm")}<span>Прототип не проверяет сертификат, версию или политику сервера. Эти контракты ещё не определены.</span></div>`,
    footer: button("Проверить и продолжить", "nickname", "primary", "btn-full")
  });
}

function serverDeploy() {
  return authFrame({ back: "server-choice", step: 1, body: `
    <h1 class="large-title">Новый сервер</h1>
    <p class="body-copy">Выберите место. Точные поддерживаемые профили и автоматизация пока не утверждены.</p>
    <div style="margin-top:18px">
      ${cardButton({ iconName: "home", title: "Домашний компьютер", text: "Локальная сеть, внешний доступ по желанию", nav: "server-preflight" })}
      ${cardButton({ iconName: "cloud", title: "Свой Linux или VPS", text: "Домен, защищённый доступ и резервная копия", nav: "server-preflight" })}
      <div class="card" aria-disabled="true" style="opacity:.58"><span class="card-row">${featureIcon("rocket")}<span class="card-copy"><strong>Партнёрский хостинг</strong><p>Появится после выбора поддерживаемых провайдеров</p></span><span class="pill">Позже</span></span></div>
    </div>
    <div class="warning-panel" style="margin-top:14px">${icon("alert-circle", "icon-sm")}<span>Это UX-концепция. Она ничего не устанавливает и не создаёт production-сервер.</span></div>`
  });
}

function serverPreflight() {
  return authFrame({ back: "server-deploy", step: 2, body: `
    <h1 class="large-title">Проверка перед запуском</h1>
    <p class="body-copy">Ниже — данные UX-сценария, а не результаты реальных проверок.</p>
    <div class="check-list">
      <div class="check-row"><span class="check-dot">${icon("check", "icon-sm")}</span><span><strong style="color:var(--text)">Пример Linux-машины</strong><br />4 ядра · 8 ГБ · 120 ГБ</span></div>
      <div class="check-row"><span class="check-dot">${icon("check", "icon-sm")}</span><span><strong style="color:var(--text)">Пример домена</strong><br /><span class="mono">home.paranoid.test</span></span></div>
      <div class="check-row"><span class="check-dot">${icon("check", "icon-sm")}</span><span><strong style="color:var(--text)">Сценарий сетевой проверки</strong><br />Результат не проверялся</span></div>
      <div class="check-row"><span class="check-dot warning">${icon("hard-drive", "icon-sm")}</span><span><strong style="color:var(--text)">Резервная копия</strong><br />Выберите независимое хранилище до запуска</span></div>
    </div>
    <div class="field"><label for="backup-target">Куда сохранять копии</label><input id="backup-target" value="backup-box.local/paranoid" autocomplete="off" /><span class="field-help">Будущий поддерживаемый сценарий обязан включать проверку восстановления.</span></div>`,
    footer: `${button("Начать развёртывание", "server-progress", "primary", "btn-full")}${button("Сохранить и выйти", "server-choice", "quiet", "btn-full")}`
  });
}

function serverProgress() {
  return authFrame({ back: "server-preflight", step: 3, body: `
    <h1 class="large-title">Симуляция запуска сервера</h1>
    <article class="card progress-card">
      <div class="card-row">${featureIcon("rocket")}<div class="card-copy"><strong>Симулируем настройку входа</strong><p>Шаг 4 из 6 · около 2 минут в макете</p></div></div>
      <div class="linear-progress" style="--progress:68%"><span></span></div>
      <div class="check-list" style="margin:0">
        <div class="check-row"><span class="check-dot">${icon("check", "icon-sm")}</span><span>Макет проверки системы</span></div>
        <div class="check-row"><span class="check-dot">${icon("check", "icon-sm")}</span><span>Макет подготовки хранилища</span></div>
        <div class="check-row"><span class="check-dot">${icon("check", "icon-sm")}</span><span>Имитируем проверку сертификата</span></div>
        <div class="check-row"><span class="check-dot pending">4</span><span>Проверяем кандидатные настройки</span></div>
        <div class="check-row"><span class="check-dot pending">5</span><span>Имитируем проверку копии</span></div>
      </div>
    </article>
    <div class="info-panel" style="margin-top:12px">${icon("info", "icon-sm")}<span>Можно закрыть этот экран. Концепция предполагает продолжение с того же шага.</span></div>`,
    footer: button("Показать результат", "server-ready", "primary", "btn-full")
  });
}

function serverReady() {
  return authFrame({ back: "server-progress", step: 4, body: `
    <div class="state-center" style="padding-top:4px">
      <div class="state-illustration" style="width:84px;height:84px;border-radius:28px;margin-bottom:14px">${icon("check", "icon-lg")}</div>
      <h1 class="large-title" style="margin-bottom:6px">Макет сервера готов</h1>
      <p class="body-copy" style="text-align:center">Подключите первый телефон и сохраните данные администратора отдельно.</p>
    </div>
    <div class="qr-wrap">${qrCode()}<span class="mono caption">home.paranoid.test</span></div>
    <div class="warning-panel">${icon("hard-drive", "icon-sm")}<span>Production-путь должен подтвердить рабочую резервную копию и процедуру восстановления.</span></div>`,
    footer: `${button("Подключить этот телефон", "nickname", "primary", "btn-full")}${button("Скопировать адрес", "server-ready", "secondary", "btn-full")}`
  });
}

function nickname() {
  return authFrame({ back: "server-choice", step: 2, body: `
    <h1 class="large-title">Выберите никнейм</h1>
    <p class="body-copy">Он должен быть понятным людям и, по текущему направлению, будет связан с публичным реестром.</p>
    <div class="field"><label for="nickname">Никнейм</label><input id="nickname" value="alina" autocomplete="username" autocapitalize="none" spellcheck="false" /><span class="field-status">${icon("check", "icon-sm")}@alina свободен в макете</span></div>
    <article class="card"><div class="detail-row"><span>Отображение</span><strong>@alina</strong></div><div class="detail-row" style="margin-top:9px"><span>Регистрация</span><strong>Сеть и комиссия не утверждены</strong></div><div class="detail-row" style="margin-top:9px"><span>Обычный вход</span><strong>Без транзакции по предложению RFC</strong></div></article>
    <div class="info-panel" style="margin-top:12px">${icon("globe", "icon-sm")}<span>Правила символов, переименования и споров пока открыты. Макет использует узкий ASCII-пример.</span></div>`,
    footer: button("Продолжить", "public-metadata", "primary", "btn-full")
  });
}

function publicMetadata() {
  return authFrame({ back: "nickname", step: 3, body: `
    <h1 class="large-title">Что может стать публичным</h1>
    <p class="body-copy">До регистрации важно понимать: данные в блокчейне могут быть постоянными и сопоставимыми.</p>
    <h2 class="section-title">Потенциально видно всем</h2>
    <div class="list-section">
      <div class="list-row">${featureIcon("user")}<span class="list-row-copy"><strong>@alina</strong><span>Канонический никнейм</span></span></div>
      <div class="list-row">${featureIcon("key")}<span class="list-row-copy"><strong>Публичный идентификатор</strong><span>Точный формат ещё не принят</span></span></div>
      <div class="list-row">${featureIcon("database", "warning")}<span class="list-row-copy"><strong>Время и плательщик комиссии</strong><span>Могут связывать действия между собой</span></span></div>
    </div>
    <div class="warning-panel" style="margin-top:14px">${icon("alert-circle", "icon-sm")}<span>Наблюдатели UX-сценария: блокчейн — никнейм, версия и история изменений; RPC — IP и запросы аккаунта; домашний сервер — вход и сессия; federation peer — отношения и трафик; платформа — разрешения и метаданные уведомлений или звонков. Блокчейн-идентичность не анонимна. Точные поля не утверждены.</span></div>`,
    footer: `${button("Понимаю, продолжить", "recovery-warning", "primary", "btn-full")}${button("Вернуться к никнейму", "nickname", "quiet", "btn-full")}`
  });
}

function recoveryWarning() {
  return authFrame({ back: "public-metadata", step: 4, body: `
    <div class="state-center" style="padding-top:10px">
      <div class="state-illustration warning">${icon("key", "icon-lg")}</div>
      <h1 class="large-title" style="text-align:center">Слова — единственный путь восстановления</h1>
      <p class="body-copy" style="text-align:center">Если вы потеряете их, никто — ни сервер, ни администратор, ни поддержка — не сможет вернуть аккаунт в paranoid mode.</p>
    </div>
    <div class="check-list">
      <div class="check-row"><span class="check-dot warning">1</span><span>Запишите слова на бумаге или другом офлайн-носителе.</span></div>
      <div class="check-row"><span class="check-dot warning">2</span><span>Не делайте скриншот и не вставляйте слова в облачные заметки.</span></div>
      <div class="check-row"><span class="check-dot warning">3</span><span>Храните копию отдельно от телефона.</span></div>
    </div>`,
    footer: button("Показать учебные метки", "recovery-words", "primary", "btn-full")
  });
}

function recoveryWords() {
  return authFrame({ back: "recovery-warning", step: 4, body: `
    <h1 class="large-title">Запишите 24 метки</h1>
    <p class="body-copy">В реальном продукте здесь будут recovery words после утверждения протокола. Ниже — только синтетические подписи.</p>
    ${wordGrid()}
    <div class="info-panel">${icon("shield", "icon-sm")}<span>Буфер обмена и снимок экрана намеренно не предлагаются.</span></div>`,
    footer: button("Я записал метки", "recovery-confirm", "primary", "btn-full")
  });
}

function recoveryConfirm() {
  return authFrame({ back: "recovery-words", step: 4, body: `
    <h1 class="large-title">Проверьте запись</h1>
    <p class="body-copy">Введите метки в указанных позициях. Это снижает риск неполной офлайн-копии.</p>
    <div class="word-slot-grid">
      <div class="word-slot">Метка 03<strong>метка-03</strong></div>
      <div class="word-slot">Метка 08<strong>метка-08</strong></div>
      <div class="word-slot">Метка 17<strong>метка-17</strong></div>
      <div class="word-slot">Метка 24<strong>метка-24</strong></div>
    </div>
    <div class="field-status">${icon("check", "icon-sm")}Все позиции совпадают в макете</div>
    <div class="warning-panel" style="margin-top:14px">${icon("info", "icon-sm")}<span>Подтверждение не доказывает безопасное хранение. UX требует отдельного пользовательского исследования.</span></div>`,
    footer: button("Продолжить", "profile-create", "primary", "btn-full")
  });
}

function profileCreate() {
  return authFrame({ back: "recovery-confirm", step: 5, body: `
    <h1 class="large-title">Создайте профиль</h1>
    <p class="body-copy">Имя помогает друзьям узнать вас. Оно не обязано совпадать с уникальным никнеймом.</p>
    <div style="display:grid;justify-items:center;margin:18px 0 6px">${avatar("Алина Коваль", "coral", false, 88)}<button class="btn btn-quiet" type="button" data-toast="Выбор фото открыт">Выбрать фото</button></div>
    <div class="field"><label for="display-name">Имя</label><input id="display-name" value="Алина Коваль" autocomplete="name" /></div>
    <div class="field"><label for="profile-about">О себе <span class="caption">необязательно</span></label><textarea id="profile-about" rows="2">Продуктовый дизайнер · UTC+2</textarea><span class="field-help">Показывается людям, которые открывают ваш профиль.</span></div>`,
    footer: button("Сохранить профиль", "permissions", "primary", "btn-full")
  });
}

function permissions() {
  return authFrame({ back: "profile-create", step: 6, body: `
    <h1 class="large-title">Разрешения — по необходимости</h1>
    <p class="body-copy">Включите только то, что полезно сейчас. Камеру и микрофон приложение запросит в момент действия.</p>
    <div style="margin-top:17px">
      <div class="card"><span class="card-row">${featureIcon("bell")}<span class="card-copy"><strong>Уведомления</strong><p>Узнавайте о сообщениях и звонках. Превью можно скрыть.</p></span><button class="btn btn-secondary" type="button" data-toast="Системный запрос уведомлений">Включить</button></span></div>
      <div class="card"><span class="card-row">${featureIcon("contact")}<span class="card-copy"><strong>Контакты</strong><p>Необязательно. Можно искать только по никнейму.</p></span><button class="btn btn-quiet" type="button" data-toast="Системный запрос контактов">Позже</button></span></div>
      <div class="card"><span class="card-row">${featureIcon("camera", "signal")}<span class="card-copy"><strong>Камера и микрофон</strong><p>Запросим при фото, голосовом или звонке.</p></span>${statusChip("По действию")}</span></div>
    </div>`,
    footer: `${button("Завершить настройку", "ready", "primary", "btn-full")}${button("Настроить позже", "ready", "quiet", "btn-full")}`
  });
}

function ready() {
  return authFrame({ centered: true, body: `
    <div class="state-center">
      <div class="hero-orbit" style="width:170px;height:170px"><i class="orbit-node"></i>${avatar("Алина Коваль", "coral", true, 94)}</div>
      <h1 class="large-title" style="text-align:center">Всё готово</h1>
      <p class="body-copy" style="text-align:center">Профиль создан в интерактивном макете. Начните разговор или добавьте ещё один сервер.</p>
      <div style="margin-top:15px">${trustRail("home.paranoid.test")}</div>
    </div>`,
    footer: button("Открыть чаты", "chats", "primary", "btn-full")
  });
}

function signIn() {
  return authFrame({ back: "welcome", centered: true, body: `
    <div class="wordmark-row"><img src="${BRAND_MARK}" alt="" />ParanoID</div>
    <h1 class="large-title">Войти</h1>
    <p class="body-copy">Выберите понятный способ. Ни телефон, ни email не требуются.</p>
    <div style="margin-top:18px">
      <button class="card interactive" type="button" data-nav="chats"><span class="card-row">${avatar("Алина Коваль", "coral", true, 48)}<span class="card-copy"><strong>Алина · @alina</strong><p>Разблокировать на этом устройстве</p></span>${icon("chevron-right", "icon-sm")}</span></button>
      ${cardButton({ iconName: "qr", title: "Подключить новое устройство", text: "Подтвердите на уже авторизованном устройстве", nav: "server-connect" })}
      ${cardButton({ iconName: "key", tone: "warning", title: "Восстановить словами", text: "Для чистого устройства или потерянного телефона", nav: "recover" })}
    </div>`,
    footer: button("Создать новый аккаунт", "server-choice", "quiet", "btn-full")
  });
}

function recover() {
  return authFrame({ back: "sign-in", body: `
    <h1 class="large-title">Восстановить аккаунт</h1>
    <p class="body-copy">Введите recovery words только на доверенном устройстве. В этой концепции слова обрабатываются только на устройстве и никогда не передаются серверу.</p>
    <div class="warning-panel" style="margin-top:14px">${icon("alert-circle", "icon-sm")}<span>Сначала устройство локально выводит ключ; поиск сервера начинается отдельным шагом. Никогда не передавайте слова администратору или «поддержке».</span></div>
    <div class="field"><label for="recovery-entry">24 recovery words</label><textarea id="recovery-entry" rows="6" autocomplete="off" autocapitalize="none" spellcheck="false" placeholder="метка-01 метка-02 …"></textarea><span class="field-help">В макете вставка доступна для accessibility. Реальный клиент должен предупредить о буфере, удалить данные после чтения и проверить screenshot и accessibility lifecycle.</span></div>
    <h2 class="section-title">После локального восстановления</h2><div class="field"><label for="recovery-server">Найти домашний сервер</label><input id="recovery-server" value="home.paranoid.test" autocomplete="url" /><span class="field-help">Адрес используется после локального вывода ключа; recovery words в запрос не входят.</span></div>`,
    footer: `${button("Проверить и восстановить", "profile-create", "primary", "btn-full")}${button("Нужна помощь", "recover", "quiet", "btn-full")}`
  });
}

export const onboardingGroups = [
  { title: "Запуск и аккаунт", screens: [
    { id: "splash", title: "Splash screen", render: splash },
    { id: "welcome", title: "Регистрация и вход", render: welcome },
    { id: "sign-in", title: "Способы входа", render: signIn },
    { id: "recover", title: "Восстановление", render: recover }
  ]},
  { title: "Сервер", screens: [
    { id: "server-choice", title: "Выбор сервера", render: serverChoice },
    { id: "server-connect", title: "Подключение", render: serverConnect },
    { id: "server-deploy", title: "Новое развёртывание", render: serverDeploy },
    { id: "server-preflight", title: "Preflight", render: serverPreflight },
    { id: "server-progress", title: "Ход развёртывания", render: serverProgress },
    { id: "server-ready", title: "Сервер готов", render: serverReady }
  ]},
  { title: "Регистрация и onboarding", screens: [
    { id: "nickname", title: "Никнейм", render: nickname },
    { id: "public-metadata", title: "Публичные данные", render: publicMetadata },
    { id: "recovery-warning", title: "Предупреждение recovery", render: recoveryWarning },
    { id: "recovery-words", title: "Recovery words", render: recoveryWords },
    { id: "recovery-confirm", title: "Проверка recovery", render: recoveryConfirm },
    { id: "profile-create", title: "Создание профиля", render: profileCreate },
    { id: "permissions", title: "Разрешения", render: permissions },
    { id: "ready", title: "Onboarding завершён", render: ready }
  ]}
];
