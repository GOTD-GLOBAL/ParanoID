import ParanoidKit
import SwiftUI
import UIKit
import WebRTC

/// The call screen: the mock-up's `call-out`, `call-in` and `call-on` as one
/// view, and `MainActivity.showCall()` / `renderCall()`
/// (`clients/android/src/org/paranoid/text/MainActivity.java:443-545`) caption
/// for caption.
///
/// ## What it shows and in which order
///
/// The privacy sentence and «Ответить» exist **only** while the call is
/// ringing, and the sentence stands above the button: it is the last thing a
/// user reads before a microphone is opened, and once the call is up it would
/// explain a decision that has already been taken. The same sentence stands
/// above «Позвонить» in the confirmation this screen is never reached without
/// (`AppModel.CallPrompt`).
///
/// ## Video
///
/// The stage appears only when a camera is actually on — this one or the
/// peer's — and disappears with it. The camera itself is opened by nothing but
/// «Включить камеру»: not by arriving here, not by answering, not by the peer
/// claiming anything. A `media` control says what the peer's camera is doing
/// and nothing else; frames come only from the authenticated transport
/// (`docs/protocol/call-v2.md`).
///
/// A refused camera keeps the call. It is announced in the banner — «Без
/// доступа к камере звонок продолжается как аудио.» — and changes nothing
/// about the description: the video section was negotiated `a=sendrecv` and
/// stays `a=sendrecv`, carrying no frames until the camera is granted.
///
/// ## What a recording gets
///
/// Android puts `FLAG_SECURE` on the call window and on no other
/// (`MainActivity.java:478`), which takes that window out of screenshots,
/// screen recordings and mirroring. iOS has no such flag and no way to give a
/// recorder different pixels from the ones the user sees, so this screen does
/// the one thing the platform does allow: while `UIScreen.isCaptured` — a
/// screen recording, AirPlay or a wired mirror — the video stage is covered
/// and says so. The rest of the screen is left alone, because covering the
/// controls would take the call away from the person on it, and the stage is
/// the part that carries the peer's camera at full frame.
///
/// Two things this cannot reach, recorded here rather than left to be
/// discovered: a **screenshot** (iOS has no API that refuses one — a client
/// only learns afterwards, and there is nothing useful to do with that), and
/// the **app-switcher snapshot** the system takes as the application leaves
/// the screen. Neither is in `clients/ios/README.md` as a claim of parity;
/// both are in `docs/clients/ios/verification.md` as what this client does
/// not do.
struct CallScreen: View {
    @Bindable var model: AppModel

    /// Whether this screen is being recorded, mirrored or AirPlayed right now.
    ///
    /// It is read once when the screen appears and then only from
    /// `UIScreen.capturedDidChangeNotification`, so nothing polls.
    @State private var captured = false

    private var call: CallPresentation? { model.call }
    private var state: CallController.State { call?.state ?? .ended }
    private var isRinging: Bool { state == .incoming }
    /// Whether the two audio controls may be used: Android enables them from
    /// the moment media authority is being asked for (`MainActivity.java:523`).
    private var isLive: Bool { call?.mediaActive == true || state == .authorizing }
    private var showsStage: Bool {
        isLive && (call?.localVideo == true || call?.remoteVideo == true)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text(Strings.Call.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)
                if showsStage { stage } else { orbit }
                Text(model.title(for: call?.account ?? ""))
                    .font(.system(size: 26, weight: .bold))
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 12)
                Text(model.callLabel)
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.updatesFrequently)
                    .accessibilityIdentifier("call-status")
                    .padding(.bottom, 12)
                Text(model.callTrust)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 24)
                    .accessibilityIdentifier("call-trust")
                if isRinging { ringing }
                controls
                cameraControls
                terminal
                Button(action: model.closeCallScreen) {
                    Text(Strings.Call.back)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.bordered)
                .padding(.top, 12)
                .accessibilityIdentifier("call-back")
                Text(Strings.Call.note)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 24)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemBackground))
        // The banner and the microphone refusal are repeated here because this
        // screen is a full-screen cover: an overlay or an alert attached to the
        // root below it never reaches the screen, and «Без доступа к камере
        // звонок продолжается как аудио.» is shown during a call by
        // definition.
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                NoticeBanner(text: notice)
                    .padding(.bottom, 32)
                    .transition(.opacity)
            }
        }
        .animation(.default, value: model.notice)
        .modifier(MicrophoneRefusal(model: model, overCall: true))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("call")
        .onAppear { captured = CallScreen.isScreenCaptured }
        .onReceive(NotificationCenter.default
            .publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            captured = CallScreen.isScreenCaptured
        }
        .onDisappear { model.detachCallVideo() }
    }

    // MARK: - the ringing block (the mock-up's `call-in`)

    /// The privacy sentence, the foreground rule and «Ответить» — in that
    /// order, and only while the call is ringing
    /// (`MainActivity.java:462-463,520-521`).
    private var ringing: some View {
        VStack(spacing: 0) {
            Text(Strings.voicePrivacy)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("call-privacy")
            Text(Strings.callForegroundHint)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 12)
            Button(action: model.answerCall) {
                Text(Strings.Call.answer)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 12)
            .accessibilityIdentifier("call-answer")
        }
        .padding(.bottom, 12)
    }

    // MARK: - the controls

    /// «Выключить микрофон» / «Громкая связь» (`MainActivity.java:465-468`).
    private var controls: some View {
        HStack(spacing: 12) {
            Button(action: model.toggleMute) {
                Text(call?.muted == true ? Strings.Call.unmute : Strings.Call.mute)
                    .font(.system(size: 15))
                    .frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(.bordered)
            .disabled(!isLive)
            .accessibilityIdentifier("call-mute")
            Button(action: model.toggleSpeaker) {
                Text(call?.speaker == true ? Strings.Call.earpiece : Strings.Call.speaker)
                    .font(.system(size: 15))
                    .frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(.bordered)
            .disabled(!isLive)
            .accessibilityIdentifier("call-speaker")
        }
    }

    /// «Включить камеру» / «Сменить камеру» (`MainActivity.java:469-472`).
    ///
    /// «Сменить камеру» needs a running capture, so it is enabled only while
    /// this device's own camera is on.
    private var cameraControls: some View {
        HStack(spacing: 12) {
            Button(action: model.toggleCamera) {
                Text(call?.localVideo == true ? Strings.Call.cameraOff : Strings.Call.cameraOn)
                    .font(.system(size: 15))
                    .frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(.bordered)
            .disabled(!isLive)
            .accessibilityIdentifier("call-camera")
            Button(action: model.switchCamera) {
                Text(Strings.Call.switchCamera)
                    .font(.system(size: 15))
                    .frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(.bordered)
            .disabled(call?.localVideo != true)
            .accessibilityIdentifier("call-switch-camera")
        }
        .padding(.top, 12)
    }

    /// The red button: «Отклонить» while ringing, «Завершить» during a call,
    /// «Закрыть» once it is over (`MainActivity.java:541`).
    private var terminal: some View {
        Button(role: .destructive, action: model.endCall) {
            Text(isRinging ? Strings.Call.reject
                 : model.isCallActive ? Strings.Call.hangup : Strings.Call.close)
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .padding(.top, 16)
        .accessibilityIdentifier("call-end")
    }

    // MARK: - the picture

    /// The placeholder a call without video shows (the mock-up's `orbit`).
    private var orbit: some View {
        Image(systemName: "person.crop.circle.fill")
            .font(.system(size: 72))
            .foregroundStyle(Color.accentColor)
            .frame(width: 144, height: 144)
            .background(Color.accentColor.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
            .padding(.bottom, 24)
    }

    /// The remote camera at full frame with this device's own in the corner
    /// (`MainActivity.java:451-456`).
    private var stage: some View {
        ZStack(alignment: .topTrailing) {
            CallVideoView(model: model, isLocal: false)
                .frame(maxWidth: .infinity)
                .frame(height: 320)
            if call?.localVideo == true {
                CallVideoView(model: model, isLocal: true)
                    .frame(width: 96, height: 128)
                    .padding(8)
            }
        }
        .background(Color.black)
        // The one thing iOS allows in place of Android's `FLAG_SECURE`: the
        // stage is covered while the screen is being captured. It covers
        // rather than removes the surfaces, so the renderers stay attached to
        // the tracks they were given and a recording that starts and stops
        // does not re-attach a second renderer to the same track.
        .overlay { if captured { curtain } }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.bottom, 16)
        .accessibilityIdentifier("call-stage")
    }

    /// What a screen recording, a mirror or an AirPlay receiver gets instead
    /// of the call's video.
    private var curtain: some View {
        ZStack {
            Color.black
            Text(Strings.Call.captured)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(16)
        }
        .accessibilityIdentifier("call-captured")
    }

    /// Whether any scene of this application is on a screen that is being
    /// recorded, mirrored or AirPlayed.
    ///
    /// It is read from the connected scenes rather than from `UIScreen.main`,
    /// which has been deprecated since iOS 16.
    @MainActor
    private static var isScreenCaptured: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .contains { $0.screen.isCaptured }
    }
}

/// One libwebrtc video surface inside SwiftUI.
///
/// The view is a UIKit object on the main actor and the media engine runs on
/// its own queue, so the renderer crosses as an opaque reference and is only
/// ever touched by libwebrtc. Nothing of a frame reaches this process any
/// other way: there is no capture output, no snapshot and no recording.
struct CallVideoView: UIViewRepresentable {
    let model: AppModel
    /// Whether this is this device's own camera (the small corner) or the
    /// peer's (the full frame).
    let isLocal: Bool

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        model.attachCallVideo(view, local: isLocal)
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {}
}
