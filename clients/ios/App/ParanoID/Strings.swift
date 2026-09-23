import ParanoidKit
import Foundation

/// Every Russian caption of this client, in one place.
///
/// The rule for this file is the rule of the whole client: a caption is
/// Android's, character for character
/// (`clients/android/src/org/paranoid/text/MainActivity.java`), unless the
/// screen it belongs to does not exist on Android. There are exactly three
/// kinds of exception, and each one is marked where it stands:
///
/// - **the foreground rule.** This client has no background delivery, so
///   Android's «Получать в фоне» block and its «Входящие в фоне отключены —
///   включить» banner have no counterpart. In their place stands one line —
///   «Входящие приходят, пока приложение открыто» — and the paragraph behind
///   it, from the screen mock-up the owner approved (its `dialogs` and
///   `connection` screens).
/// - **no in-app updates.** Builds are installed by hand and no TestFlight
///   build exists yet, so «Проверить обновления», the update block of
///   «Мой ID» and «Доступна версия …» do not exist here at all.
/// - **screens iOS has and Android does not**: the frozen screen, the
///   stand guard and the contact-flow alert, whose wording is the mock-up's.
///
/// `clients/ios/test/captions.txt` is the list this file is checked against by
/// `clients/ios/test_ui_contract.py`, so a caption cannot quietly drift from
/// the Android one or disappear from a screen.
///
/// Nothing here is localized: the client ships in Russian, exactly as the
/// Android build does, and a localization table would be a second place for a
/// caption to differ from the phone the fingerprint is compared against.
enum Strings {
    /// The product name, as it is written everywhere: never «Paranoid», never
    /// «ParanoId».
    static let product = "ParanoID"

    /// `CFBundleShortVersionString (CFBundleVersion)`, the counterpart of
    /// Android's `versionName` (`MainActivity.java:182,281`).
    static var version: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        guard !build.isEmpty else { return marketing }
        return "\(marketing) (\(build))"
    }

    // MARK: - navigation (`MainActivity.java:240,258`)

    enum Tab {
        static let dialogs = "Чаты"
        static let contacts = "Контакты"
        static let identity = "Мой ID"
    }

    /// The navigation-bar affordances (`MainActivity.java:119,123,260-262`).
    enum Bar {
        static let identity = "Мой ID"
        static let back = "Назад в чаты"
        static let addContact = "Добавить контакт"
        static let contactDetails = "Сведения о контакте"
        static let connection = "Статус подключения. Подробнее"
    }

    // MARK: - welcome (`MainActivity.java:134-142`)

    enum Welcome {
        static let title = "Ваш ID.\nВаши разговоры."
        static let body = "Создайте ID на этом телефоне и начните переписку. Номер телефона, email и пароль не нужны."
        static let create = "Создать ID"
        static let creating = "Создаём ID…"
        static let keys = "Ключи остаются на этом телефоне. Регистрация на общем сервере выполняется автоматически."
        static let alpha = "Закрытая альфа · только тестовые сообщения. Восстановление ID пока недоступно: не удаляйте приложение с нужными данными."
    }

    // MARK: - the status line (`MainActivity.java:598-623`)

    enum Status {
        /// The line under the title, before anything has been read
        /// (`MainActivity.java:130`).
        static let opening = "Открываем данные…"
        /// What the connection sheet shows before anything has been read
        /// (`MainActivity.java:61`).
        static let openingDetails = "Открываем сохранённые данные…"
        static let frozen = "Данные недоступны · подробнее"
        static let alpha = "Закрытая альфа · тестовые сообщения"
        static let registering = "Регистрируем ID · ключи сохранены"
        static let connected = "Сервер подключён"
        static let queued = "Сообщение в очереди"
        static let connecting = "Подключение · подробнее"
        static let rejected = "Есть непринятые сообщения · подробнее"
        /// The two texts the sheet shows in place of the last published one
        /// (`MainActivity.java:607`).
        static let unsupportedSnapshot = "Сохранённые данные относятся к предыдущей тестовой версии. Эта сборка предназначена для новой установки. Данные не изменены."
        static let brokenDetails = "Локальные данные недоступны. Ключи и история не сброшены. Не удаляйте приложение."
        /// What a local enqueue publishes (`TextEngine.java:188`); the status
        /// line turns it into `queued`.
        static let messageQueued = "Сообщение сохранено в очередь"
        /// What a failed local enqueue publishes (`TextEngine.java:190`).
        static let sendUnfinished = "Отправка не завершена; сохранённая очередь не удалена."
        /// What a failed commit publishes (`TextEngine.java:167`).
        static let storageStopped = "Ошибка локального хранения. Операции остановлены; данные не удалены."
        /// The generic failure of `TextEngine.userError` (`:205`).
        static let unfinished = "Подключение или проверка контакта не завершены. Повторим подключение автоматически. ID, очередь и история сохранены."
    }

    // MARK: - dialogs (`MainActivity.java:144-156,548-575`)

    enum Dialogs {
        static let title = "Чаты"
        static let section = "Личные диалоги"
        static let emptyTitle = "Первый разговор начинается здесь"
        static let emptyBody = "Сообщения собеседников появятся здесь автоматически. Чтобы написать первым, добавьте контакт."
        static let startConversation = "Начать переписку"
        /// The «Вы: » prefix of a preview written on this device
        /// (`MainActivity.java:556`).
        static let ownPreviewPrefix = "Вы: "
        static let verifiedBadge = "Проверен"
        static let blockedBadge = "Блок"
    }

    // MARK: - contacts (`MainActivity.java:158-163,550`)

    enum Contacts {
        static let title = "Контакты"
        static let add = "Добавить контакт"
        static let explanation = "Сканируйте QR собеседника или вставьте его контакт. Входящие сообщения появятся в чатах автоматически."
        static let emptyTitle = "Пока нет контактов"
        static let emptyBody = "Контакт можно добавить по QR или вставить из сообщения собеседника."
    }

    // MARK: - my ID (`MainActivity.java:187-214`)

    enum Identity {
        static let title = "Мой ID"
        static let heading = "Поделитесь контактом"
        static let explanation = "Собеседник сможет написать вам по этому QR. Для проверки личности сравните отпечатки отдельно."
        static let caption = "ВАШ ID"
        static let placeholder = "Создайте ID, чтобы начать"
        static let share = "Поделиться контактом"
        static let copy = "Копировать контакт"
        static let fingerprint = "Отпечаток контакта"
        static let fingerprintPlaceholder = "Появится после регистрации"
        static let application = "Приложение"
        static let about = "О приложении"

        /// The alpha notice, without a numeric history promise. Receipt and
        /// replay budgets are independent, not a total-message ceiling.
        /// Removing this sentence changes no core limits (RFC-0022 remains
        /// proposed). Android's matching caption is a separate follow-up.
        static var alpha: String {
            "\(product) · \(version)\nЗакрытая альфа, только тестовые сообщения. Восстановление ID пока недоступно."
        }

        /// The iOS difference, from the mock-up's `identity` screen: neither
        /// an update check nor a background connection exists here. The
        /// mock-up said builds come through TestFlight and the App Store; no
        /// such build exists yet (`docs/clients/ios/build-and-testflight.md`),
        /// so the sentence says how a build actually arrives today.
        static let platform = "Сборки пока устанавливаются вручную — проверки обновлений в приложении нет. Фонового подключения нет: см. «Входящие приходят, пока приложение открыто»."
    }

    /// The about sheet (`MainActivity.java:302-308`).
    enum About {
        static let title = "О приложении"
        static let close = "Закрыть"
        static let fingerprintHeading = "Отпечаток идентичности"
        static let fingerprintPlaceholder = "появится после регистрации"
        static let alpha = "Закрытая альфа, только тестовые сообщения. Восстановление ID пока недоступно."

        static var version: String { "\(product) · версия \(Strings.version)" }
    }

    // MARK: - chat (`MainActivity.java:216-236,341-352,577-595`)

    // MARK: - what a finished call leaves in the chat (`CallRecord`)

    enum CallRow {
        static let outgoing = "Исходящий звонок"
        static let outgoingVideo = "Исходящий видеозвонок"
        static let incoming = "Входящий звонок"
        static let incomingVideo = "Входящий видеозвонок"
        static let missed = "Пропущенный звонок"
        static let missedVideo = "Пропущенный видеозвонок"
        static let declined = "Вы отклонили звонок"
        static let rejected = "Собеседник отклонил звонок"
        static let cancelled = "Вызов отменён"
        static let unanswered = "Нет ответа"
        static let busy = "Собеседник занят"
        static let failed = "Связь не установилась"
        static let callBack = "Перезвонить"

        /// What the row says happened.
        static func title(kind: CallRecord.Kind, video: Bool) -> String {
            switch kind {
            case .outgoing: return video ? outgoingVideo : outgoing
            case .incoming: return video ? incomingVideo : incoming
            case .missed: return video ? missedVideo : missed
            case .declined: return declined
            case .rejected: return rejected
            case .cancelled: return cancelled
            case .unanswered: return unanswered
            case .busy: return busy
            case .failed: return failed
            }
        }

        /// `3:12`, the way the call screen counts (`MainActivity.callLabel`).
        static func duration(seconds: Int64) -> String {
            String(format: "%d:%02d", seconds / 60, seconds % 60)
        }

        /// The whole line: what happened and, when the call was answered, how
        /// long it lasted.
        static func line(kind: CallRecord.Kind, video: Bool, seconds: Int64) -> String {
            let title = title(kind: kind, video: video)
            guard seconds > 0 else { return title }
            return title + " · " + duration(seconds: seconds)
        }
    }

    enum Chat {
        static let placeholder = "Сообщение"
        static let send = "Отправить"
        static let sendAction = "Отправить сообщение"
        static let empty = "Начните переписку. Сообщения защищены сквозным шифрованием."
        static let details = "Подробнее"
        static let blocked = "Заблокирован"
        static let blockedHint = "Контакт заблокирован. Откройте сведения, чтобы разблокировать."
        static let brokenHint = "Локальное хранение недоступно. Сообщения не отправляются."
        static let savingHint = "Сохраняем сообщение…"

        /// Shown once, under the first own message that reaches the second
        /// mark. It is the sentence the contact sheet carries
        /// (`Details.receiptsBody`), in the place it is about.
        static let receiptHint = "Две отметки — сообщение доставлено на телефон собеседника. Прочитал ли он его, ParanoID не показывает."
        static let receiptHintAction = "Понятно"

        /// `MainActivity.java:350`.
        static func tooLong(bytes: Int) -> String {
            "Сообщение слишком длинное: \(bytes) из 2048 байт."
        }

        /// The composer's byte counter, from the mock-up's `chat` screen.
        static func counter(bytes: Int) -> String { "\(bytes) из 2048 байт" }
    }

    // MARK: - adding a contact (`MainActivity.java:485-504`)

    enum AddContact {
        static let title = "Добавить контакт"
        static let scan = "Сканировать QR"
        static let paste = "Вставить контакт"
        static let cancel = "Отмена"
        static let confirmTitle = "Проверка контакта"
        static let confirmBody = "Сравните полный отпечаток с экраном собеседника лично или по доверенному каналу. Один пересланный QR не доказывает личность."
        static let confirm = "Отпечаток совпадает"
    }

    // MARK: - contact details (`MainActivity.java:563-575`)

    enum Details {
        static let trust = "Доверие"
        static let account = "Account"
        static let encryption = "Шифрование"
        /// `MainActivity.java:567`, including the sentence Android's v22 added
        /// beside the local name: the name is this phone's, not the contact's.
        static let encryptionBody = "Сообщения защищены сквозным шифрованием. Проверка ключей при доставке не подтверждает, кому они принадлежат. Имя контакта хранится только на этом телефоне."
        static let receipts = "Отметки доставки"
        static let receiptsBody = "✓ Сохранено сервером\n✓✓ Доставлено, не прочитано"
        /// The way into «Имя контакта» — Android's positive button, so it
        /// stands above «Проверить QR» here too (`MainActivity.java:568`).
        static let rename = "Переименовать"
        static let verifyQr = "Проверить QR"
        static let block = "Заблокировать контакт"
        static let unblock = "Разблокировать контакт"
        static let close = "Закрыть"
        static let blockTitle = "Заблокировать контакт?"
        static let blockBody = "Новые сообщения и подтверждения доставки для этого контакта будут отключены. История останется на телефоне."
        static let blockConfirm = "Заблокировать"
        static let cancel = "Отмена"
    }

    // MARK: - the local contact name (`MainActivity.renameContact()`,
    // `MainActivity.java:576-583`)

    /// «Имя контакта»: the one name this client writes anywhere, and it is
    /// written only on this phone (`ContactNames`).
    enum Rename {
        /// The dialog's title and the field's placeholder, as Android uses the
        /// same words for both (`MainActivity.java:577,580`).
        static let title = "Имя контакта"
        static let body = "Отображается только на этом телефоне. Оставьте пустым, чтобы вернуть имя по умолчанию."
        static let save = "Сохранить"
        static let cancel = "Отмена"
    }

    // MARK: - connection (`MainActivity.java:517-520` and the mock-up)

    enum Connection {
        static let title = "Подключение"
        /// `MainActivity.java:518`.
        static let body = "ID и история сохраняются на этом телефоне. Статус сервера не показывает, находится ли собеседник в сети."
        /// The foreground rule of this client, from the mock-up's
        /// `connection` screen. Messages wait on the server, but call controls
        /// expire and do not provide durable missed-call history. A preserved
        /// readiness slot can still admit a queued offer/end after resuming;
        /// neither guaranteed presence nor guaranteed absence of a row is true.
        /// See `CallCaptionLifecycleTests` and the iOS voice-call document.
        static let foreground = "Входящие сообщения и звонки приходят, пока приложение открыто. Сообщения, отправленные, пока приложение закрыто или iPhone заблокирован, появятся после открытия. Для входящих звонков держите приложение открытым. После открытия запись о пропущенном звонке может отсутствовать."
        static let lastEvent = "Последнее событие"
        static let queue = "Очередь"
        static let rejected = "Непринятые сообщения"
        static let none = "Нет"
        static let retry = "Повторить подключение"
        static let close = "Закрыть"

        /// The outbox line of the mock-up's `connection` screen, agreeing with
        /// its number: 1 and 21 but not 11, then 2-4 and 22-24 but not 12-14,
        /// then everything else.
        static func queued(_ count: Int) -> String {
            let (ones, tens) = (count % 10, count % 100)
            if ones == 1, tens != 11 { return "\(count) сообщение ожидает отправки" }
            if (2...4).contains(ones), !(12...14).contains(tens) {
                return "\(count) сообщения ожидают отправки"
            }
            return "\(count) сообщений ожидают отправки"
        }
    }

    /// The one-line hint under the status line of «Чаты», in the place
    /// Android keeps its background banner (`MainActivity.java:150-153`).
    static let foregroundHint = "Входящие приходят, пока приложение открыто"

    // MARK: - the frozen screen (the mock-up's `frozen`)

    enum Frozen {
        static let title = "Не удалось открыть локальное состояние. Данные сохранены; ключи не сбрасываются."
        static let reinstall = "Переустановка приложения начнёт с нового ID."
        static let hint = "Сообщения не отправляются. Не удаляйте приложение."
        static let retry = "Повторить открытие"
    }

    // MARK: - the stand guard (Debug builds only)

    enum NoStand {
        static let title = "Стенд не задан. Запустите с параметрами локального сервера."
    }

    // MARK: - the bottom banner

    enum Notice {
        /// `MainActivity.java:177` — the confirmation of «Копировать контакт».
        static let contactCopied = "Контакт скопирован. Сравните отпечаток отдельно."
        /// `MainActivity.java:394` — no connection to place a call with.
        static let callOffline = "Нет подключения для звонка. Повторите после восстановления связи."
        static let audioUnavailable = "Не удалось подготовить звук. Попробуйте позвонить ещё раз."
        /// `MainActivity.java:534` — the microphone was refused.
        static let microphoneDenied = "Для звонка нужен доступ к микрофону. Переписка доступна без него."
        /// `MainActivity.java:609` — the camera was refused during a call. It
        /// is a downgrade, never a failure: the call continues as audio.
        static let cameraDenied = "Без доступа к камере звонок продолжается как аудио."
    }

    /// «Открыть Настройки» — the only page this client ever opens outside
    /// itself, and the one place a refused microphone or camera can be given
    /// back (the mock-up's `scan-denied`).
    static let openSettings = "Открыть Настройки"

    // MARK: - voice and video calls (`MainActivity.java:375-382,443-545`)

    /// `MainActivity.VOICE_PRIVACY` (`MainActivity.java:51`), verbatim.
    ///
    /// It stands **before** «Позвонить» in the confirmation and **before**
    /// «Ответить» on the ringing screen, never after either: a sentence that
    /// arrives once the call is already up explains nothing that could still
    /// be declined.
    static let voicePrivacy = "Звук защищён сквозным шифрованием. При соединении через ретранслятор оператор ретранслятора видит ваш IP-адрес, время и объём трафика. Если сервер не поддерживает ретрансляцию, используется прямое соединение: собеседник может видеть ваш IP-адрес. В некоторых сетях прямое соединение недоступно."

    /// `MainActivity.VIDEO_PRIVACY` (`MainActivity.java:56`), verbatim: the
    /// same sentence for a call that also carries a camera, and it is the one
    /// shown before «Видеозвонок».
    static let videoPrivacy = "Видео и звук защищены сквозным шифрованием: сервер и ретранслятор не могут их расшифровать. Камера включается только по вашему нажатию и выключается, когда приложение свёрнуто. Оператор ретранслятора видит IP-адрес, время и объём трафика; при прямом соединении IP-адрес видит собеседник."

    /// The foreground rule as the call screen states it (mock-up, `call-in`).
    static let callForegroundHint = "Звонок держится, пока приложение открыто"

    /// Every caption of the call screen and of the two ways into it.
    ///
    /// The wording is `MainActivity.showCall()` / `callLabel()` /
    /// `renderCall()` (`MainActivity.java:443-545`) character for character,
    /// including the words that only a camera can produce: this client shows
    /// the same call to the same person as the phone beside it.
    enum Call {
        /// The heading of the screen (`MainActivity.java:450`).
        static let title = "Звонок"
        /// The two affordances in the chat's toolbar, by the labels Android
        /// gives them (`MainActivity.java:143-144`).
        static let audioAction = "Аудиозвонок"
        static let videoAction = "Видеозвонок"
        /// The confirmation that carries the privacy sentence
        /// (`MainActivity.java:380-382`). The title says which call it is, the
        /// message is the privacy sentence, and the positive button repeats
        /// the kind.
        static let audioPrompt = "Позвонить собеседнику?"
        static let videoPrompt = "Видеозвонок собеседнику?"
        static let audioConfirm = "Позвонить"
        static let videoConfirm = "Видеозвонок"
        static let cancel = "Отмена"
        /// The ringing screen (`MainActivity.java:463`).
        static let answer = "Ответить"
        /// What the red button says in each of the three situations
        /// (`MainActivity.java:541`).
        static let reject = "Отклонить"
        static let hangup = "Завершить"
        static let close = "Закрыть"
        /// Leaving the call on screen and going back to the conversation
        /// (`MainActivity.java:474`).
        static let back = "К переписке"
        /// The two audio controls (`MainActivity.java:466-467,524-525`).
        static let mute = "Выключить микрофон"
        static let unmute = "Включить микрофон"
        static let speaker = "Громкая связь"
        static let earpiece = "Телефонный динамик"
        /// The two camera controls (`MainActivity.java:470,529`).
        static let cameraOn = "Включить камеру"
        static let cameraOff = "Выключить камеру"
        static let switchCamera = "Сменить камеру"

        /// iOS has no `FLAG_SECURE` (`MainActivity.java:478` puts it on the
        /// Android call window), so the video stage hides itself while the
        /// screen is being recorded, mirrored or AirPlayed, and says why.
        static let captured = "Видео скрыто: идёт запись или трансляция экрана."
        /// The closing note under the buttons (`MainActivity.java:475`).
        static let note = "До ответа микрофон входящего звонка выключен. Звук защищён сквозным шифрованием."

        // `callLabel(JSONObject)` (`MainActivity.java:493-514`), branch for
        // branch and in the same order.
        static let reconnecting = "Восстанавливаем соединение…"
        static let starting = "Проверяем доступность…"
        static let authorizing = "Подготавливаем защищённое соединение…"
        static let outgoing = "Вызываем…"
        static let incoming = "Входящий звонок"
        static let connecting = "Устанавливаем соединение…"
        /// The right-hand half of a connected call's line: «Видео» as soon as
        /// either camera is on, «Соединение установлено» otherwise.
        static let video = "Видео"
        static let connected = "Соединение установлено"
        static let busy = "Собеседник занят"
        static let rejected = "Звонок отклонён"
        static let timeout = "Нет ответа или связь потеряна"
        static let failed = "Не удалось установить связь"
        static let cancelled = "Вызов отменён"
        static let ended = "Звонок завершён"

        /// `"%02d:%02d · %s"` (`MainActivity.java:504`), on the invariant
        /// locale, so the separator and the digits are the phone's.
        static func elapsed(seconds: Int64, kind: String) -> String {
            String(format: "%02d:%02d · %@", seconds / 60, seconds % 60, kind)
        }
    }
}
