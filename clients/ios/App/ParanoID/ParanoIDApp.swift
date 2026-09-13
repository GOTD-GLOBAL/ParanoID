import ParanoidKit
import SwiftUI

/// Application entry point of the ParanoID iOS client (RFC-0021).
///
/// It owns the one `AppModel`, which owns the one runtime: the snapshot store,
/// the client, the state owner, the pinned transport and the realtime lanes.
/// Nothing else in the application builds any of those.
@main
struct ParanoIDApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}

/// What is on screen: one of the four stages, the banner over it, and the
/// sheets over that.
///
/// The layout is the approved screen mock-up's: a header with «Мой ID» and
/// «Добавить контакт», a large title, the status line, the screen itself and
/// the three tabs. The chat is pushed over all of it and brings the system's
/// own navigation bar with it, which is where its back button comes from.
struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        stage
            .overlay(alignment: .bottom) {
                if let notice = model.notice {
                    NoticeBanner(text: notice)
                        .padding(.bottom, 96)
                        .transition(.opacity)
                }
            }
            .animation(.default, value: model.notice)
            .task {
                model.start()
                model.setForeground(scenePhase == .active)
            }
            .onChange(of: scenePhase) { _, phase in
                model.setForeground(phase == .active)
            }
    }

    @ViewBuilder
    private var stage: some View {
        switch model.stage {
        case .opening:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("opening")
        case .noStand(let reason):
            NoStandScreen(reason: reason)
        case .frozen:
            FrozenScreen(detail: model.frozenDetail, onRetry: model.retryOpen)
        case .running:
            running
        }
    }

    private var running: some View {
        NavigationStack {
            Group {
                if model.view.hasIdentity {
                    tabs
                } else {
                    WelcomeScreen(model: model)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: chatSelection) { _ in
                ChatScreen(model: model)
            }
        }
        .sheet(item: $model.sheet) { sheet in
            content(of: sheet)
        }
    }

    /// The push and the pop of the chat. Popping it goes through the model, so
    /// that the draft written in that conversation is kept.
    private var chatSelection: Binding<String?> {
        Binding(get: { model.chatAccount },
                set: { account in
                    if let account { model.chatAccount = account } else { model.closeChat() }
                })
    }

    // MARK: - the three tabs

    private var tabs: some View {
        VStack(spacing: 0) {
            header
            Text(title)
                .font(.system(size: 34, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
            statusLine
            if model.tab == .dialogs {
                Button { model.sheet = .connection } label: {
                    Text(Strings.foregroundHint)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                        .padding(.horizontal, 12)
                }
                .background(Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .accessibilityIdentifier("foreground-hint")
            }
            switch model.tab {
            case .dialogs: DialogsScreen(model: model)
            case .contacts: ContactsScreen(model: model)
            case .identity: IdentityScreen(model: model)
            }
            tabBar
        }
    }

    /// The two affordances of Android's header (`MainActivity.java:119,123`).
    private var header: some View {
        HStack {
            Button { model.tab = .identity } label: {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 22))
            }
            .accessibilityLabel(Strings.Bar.identity)
            .accessibilityIdentifier("bar-identity")
            Spacer()
            Button { model.sheet = .add } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 20))
            }
            .disabled(model.isBroken)
            .accessibilityLabel(Strings.Bar.addContact)
            .accessibilityIdentifier("bar-add-contact")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
    }

    /// The status line, which is also the way into the connection sheet
    /// (`MainActivity.java:131`).
    private var statusLine: some View {
        Button { model.sheet = .connection } label: {
            Text(model.statusLine)
                .font(.system(size: 13))
                .foregroundStyle(model.isBroken ? Color.red : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }
        .accessibilityLabel(model.statusLine)
        .accessibilityHint(Strings.Bar.connection)
        .accessibilityIdentifier("status-line")
    }

    private var tabBar: some View {
        HStack {
            tab(.dialogs, Strings.Tab.dialogs, "bubble.left.and.bubble.right")
            tab(.contacts, Strings.Tab.contacts, "person.2")
            tab(.identity, Strings.Tab.identity, "qrcode")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Color(.secondarySystemBackground))
    }

    private func tab(_ value: AppModel.Tab, _ title: String, _ symbol: String) -> some View {
        Button { model.tab = value } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 22))
                Text(title)
                    .font(.system(size: 10))
            }
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .foregroundStyle(model.tab == value ? Color.accentColor : Color.secondary)
        .accessibilityIdentifier("tab-\(value.rawValue)")
    }

    private var title: String {
        switch model.tab {
        case .dialogs: return Strings.Dialogs.title
        case .contacts: return Strings.Contacts.title
        case .identity: return Strings.Identity.title
        }
    }

    // MARK: - the sheets

    @ViewBuilder
    private func content(of sheet: AppModel.Sheet) -> some View {
        switch sheet {
        case .add:
            AddContactSheet(onScan: { model.sheet = .scan },
                            onPaste: { model.sheet = .paste },
                            onCancel: { model.sheet = nil })
        case .scan:
            QrScannerView(onScanned: { model.submitContact($0) },
                          onPaste: { model.sheet = .paste },
                          onCancel: { model.cancelContact() })
                .modifier(ContactRefusal(model: model))
        case .paste:
            PasteContactSheet(onContinue: { model.submitContact($0) },
                              onCancel: { model.cancelContact() })
                .modifier(ContactRefusal(model: model))
        case .confirm:
            ConfirmContactSheet(fingerprint: model.pendingContact?.fingerprint ?? "",
                                onConfirm: { model.pairPendingContact() },
                                onCancel: { model.cancelContact() })
                .modifier(ContactRefusal(model: model))
        case .details(let account):
            ContactDetailsSheet(account: account,
                                dialog: model.view.dialog(account),
                                title: model.title(for: account),
                                name: model.name(for: account),
                                onRename: { model.rename(account: account, to: $0) },
                                onBlock: { blocked in
                                    model.block(account: account, blocked: blocked)
                                    model.sheet = nil
                                },
                                onVerify: { model.sheet = .add },
                                onClose: { model.sheet = nil })
        case .connection:
            ConnectionSheet(status: model.statusLine,
                            lastStatus: model.lastStatus,
                            outbox: model.outboxCount,
                            rejected: model.view.rejectedCount,
                            onRetry: { model.reconnect() },
                            onClose: { model.sheet = nil })
        case .about:
            AboutSheet(fingerprint: model.view.fingerprint, onClose: { model.sheet = nil })
        case .share:
            ContactShareSheet(contact: model.view.contact ?? "")
        }
    }
}

/// The refusal of a scanned or pasted contact, shown **inside** the sheet it
/// happened in.
///
/// A status line behind a sheet is a status line nobody reads, and a contact
/// that was silently not added is one that gets scanned again. The sheet
/// therefore stays where it is until «Понятно», and the wording comes from
/// `ContactFlowError`, which is the one place a core rejection becomes a
/// sentence.
private struct ContactRefusal: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        content.alert(ContactFlowError.title,
                      isPresented: Binding(get: { model.contactAlert != nil },
                                           set: { shown in
                                               if !shown { model.contactAlert = nil }
                                           }),
                      presenting: model.contactAlert) { _ in
            Button(ContactFlowError.dismiss) { model.contactAlert = nil }
        } message: { failure in
            Text(failure.message)
        }
    }
}
