import AVFoundation
import ParanoidKit
import SwiftUI

/// The private in-app scanner, the port of `QrScanActivity.java`.
///
/// It is the same promise as on Android: no external scanner application, no
/// URI, no upload and no frame that outlives the moment it was decoded
/// (`QrScanActivity.java:14`). The session carries one
/// `AVCaptureMetadataOutput` and nothing else — no photo output, no video data
/// output, no movie file output — so a frame is never handed to this process at
/// all; what arrives is the decoded string of a QR symbol. Cancelling touches
/// no state: the screen owns a capture session and two closures, and the
/// identity, the snapshot and the network are somewhere else entirely.
///
/// The dense-QR fix of Android v15 is the reason for the preset. A
/// `paranoid-contact-v2` code is around 900 bytes, which is roughly 115
/// modules across; at 640×480 a code that fills the frame falls below the
/// resolution a decoder needs and add-contact fails on a real phone
/// (`QrScanActivity.java:42-47`, `QrDenseSmoke.java:3-6`). Android answers it
/// by choosing the largest bounded preview size; here the session asks for
/// `.hd1920x1080` and `rectOfInterest` is left alone, so the whole frame is
/// searched at full resolution.
///
/// The first accepted payload ends the session and is handed over verbatim:
/// `QrCodec.checkedPayload` measures the 2048-byte bound of
/// `docs/protocol/key-enrollment-v1.md:91-96` and returns the very string the
/// code carried, so the text that reaches the core is the text the peer's
/// core signed. A longer payload is
/// refused and the session keeps scanning, exactly as a frame ZXing rejects
/// leaves Android's scanner running.
@MainActor
struct QrScannerView: View {
    /// The exact payload of the first accepted QR, never re-encoded.
    let onScanned: (String) -> Void
    /// "Вставить контакт" — the way out when the camera is unavailable.
    let onPaste: () -> Void
    /// "Отмена". Nothing has changed by the time this is called.
    let onCancel: () -> Void

    /// The guidance line, word for word Android's status text
    /// (`QrScanActivity.java:26`).
    static let guidance = "Наведите камеру на публичный QR ParanoID. Снимки не сохраняются."
    /// A payload that is not a ParanoID contact QR at all. The same sentence
    /// answers the core's `invalid_contact`.
    static let refused = "Это не контакт ParanoID. Попросите собеседника показать QR из «Мой ID»."
    /// No camera to open (`QrScanActivity.java:63`), which is also what the
    /// simulator reports.
    static let unavailable = "Камера недоступна. Данные не изменены; можно отменить и вставить публичный код."

    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var camera = QrScannerCamera()
    @State private var message = QrScannerView.guidance
    @State private var delivered = false

    var body: some View {
        switch access {
        case .denied, .restricted:
            // The system will not ask again; Настройки is the only way back.
            ScanDeniedView(onPaste: onPaste, onCancel: onCancel)
        default:
            scanner
        }
    }

    private var scanner: some View {
        VStack(spacing: 0) {
            QrScannerBar(onCancel: onCancel)
            Text(message)
                .font(.system(size: 15))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .accessibilityIdentifier("scan-status")
            viewfinder
            Button(action: onCancel) {
                Text("Отмена")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .accessibilityIdentifier("scan")
        .task { await open() }
        .onDisappear { camera.stop() }
    }

    /// The preview and the frame of the mock-up's `scan` screen: a dark
    /// surface, the picture the camera is producing and a square guide. The
    /// guide is decoration — `rectOfInterest` is untouched, so a code outside
    /// it is decoded just as well.
    private var viewfinder: some View {
        ZStack {
            Color.black
            QrCameraPreview(camera: camera)
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.85), lineWidth: 2)
                .frame(width: 240, height: 240)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    /// Asks for the camera when the answer is not known yet, then starts the
    /// session. `.notDetermined` is the one status that may change while this
    /// screen is on screen, and the alert it raises is a `willResignActive`
    /// that `LifecyclePolicy` deliberately does not treat as a pause.
    private func open() async {
        if access == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            access = AVCaptureDevice.authorizationStatus(for: .video)
        }
        guard access == .authorized else { return }
        camera.onPayload = { payload in accept(payload) }
        if !camera.start() {
            message = Self.unavailable
        }
    }

    /// The first payload wins: the session stops before the string leaves this
    /// screen, so a second code cannot arrive behind the caller's back. A
    /// payload above the QR bound is refused and the session keeps looking.
    private func accept(_ payload: String) {
        guard !delivered else { return }
        guard let checked = try? QrCodec.checkedPayload(payload) else {
            message = Self.refused
            return
        }
        delivered = true
        camera.stop()
        onScanned(checked)
    }
}

/// The navigation bar of the `scan` and `scan-denied` screens: the title and
/// the cancel affordance, nothing that could change state.
@MainActor
struct QrScannerBar: View {
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Text("Сканировать QR")
                .font(.system(size: 17, weight: .semibold))
            HStack {
                Spacer()
                Button("Отмена", action: onCancel)
                    .font(.system(size: 17))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }
}

/// The picture of the running session, and only the picture: an
/// `AVCaptureVideoPreviewLayer` renders frames straight from the capture
/// pipeline, so no frame is ever copied into a buffer this process owns.
@MainActor
struct QrCameraPreview: UIViewRepresentable {
    let camera: QrScannerCamera

    func makeUIView(context: Context) -> QrPreviewView {
        let view = QrPreviewView()
        view.backgroundColor = .black
        view.attach(camera.session)
        return view
    }

    func updateUIView(_ view: QrPreviewView, context: Context) {
        view.attach(camera.session)
    }
}

/// A view whose layer *is* the preview layer, so the picture resizes with the
/// screen without a layout pass of its own.
final class QrPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    private var preview: AVCaptureVideoPreviewLayer {
        // Safe by construction: `layerClass` above is the layer's type.
        layer as! AVCaptureVideoPreviewLayer
    }

    func attach(_ session: AVCaptureSession) {
        preview.videoGravity = .resizeAspectFill
        if preview.session !== session {
            preview.session = session
        }
    }
}

/// The capture session of the scanner and every rule that shapes it.
///
/// It lives on the main actor: `AVCaptureSession` is not `Sendable`, the
/// preview layer has to be attached on the main thread, and this client never
/// runs a capture session anywhere but on a screen the user opened, so one
/// actor for the session, the preview and the delegate is both correct and the
/// whole story. Configuration and `startRunning()` therefore run on the main
/// actor; they take a noticeable moment on a cold camera, and that moment is
/// the scanner screen appearing.
@MainActor
final class QrScannerCamera: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureMetadataOutput()
    private var input: AVCaptureDeviceInput?
    private var configured = false

    /// The decoded string of a QR symbol, on the main actor.
    var onPayload: ((String) -> Void)?

    /// Starts the session, answering whether there is a camera to run at all.
    /// A simulator, a denied permission and hardware another process holds
    /// all answer `false`, and the screen then says so instead of showing a
    /// black rectangle.
    @discardableResult
    func start() -> Bool {
        guard configure() else { return false }
        if !session.isRunning {
            session.startRunning()
        }
        #if DEBUG
        // The v15 lesson, one line: the format the camera actually settled on.
        // Never the payload itself.
        if let device = input?.device {
            print("QrScannerCamera: preset=\(session.sessionPreset.rawValue) "
                + "activeFormat=\(device.activeFormat.formatDescription)")
        }
        #endif
        return session.isRunning
    }

    func stop() {
        if session.isRunning {
            session.stopRunning()
        }
    }

    /// One-time configuration, in the order the metadata output demands:
    /// `metadataObjectTypes` may only name `.qr` once the output belongs to a
    /// session, so it is set after `addOutput`.
    private func configure() -> Bool {
        if configured { return true }
        guard let device = Self.camera(),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return false }
        session.beginConfiguration()
        // 1080p for the dense contact QR of Android v15; `.high` is the
        // fallback the session itself is willing to run.
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        session.addOutput(output)
        // The delegate queue is the main queue, this actor's own, so the
        // callback below can assume that isolation instead of hopping.
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        // `rectOfInterest` is deliberately left at its default: the whole
        // frame is searched, and a contact code that fills it still decodes.
        session.commitConfiguration()
        self.input = input
        configureFocus(device)
        configured = true
        return true
    }

    /// A contact QR is read from a hand's distance, so the lens is told to
    /// look near and to keep focusing — Android asks for
    /// `FOCUS_MODE_CONTINUOUS_PICTURE` for the same reason
    /// (`QrScanActivity.java:48`).
    private func configureFocus(_ device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isAutoFocusRangeRestrictionSupported {
            device.autoFocusRangeRestriction = .near
        }
        device.unlockForConfiguration()
    }

    private static func camera() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video)
    }

    /// The decoded symbols of one frame. The objects themselves are left here:
    /// what leaves this method is a `String`, and the corners, the frame and
    /// the image behind it are released with the call.
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                                    didOutput objects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        // The string is taken out here, where the objects are: only it — a
        // `String` — crosses into the actor, never the metadata object, its
        // corners or the frame they were measured in.
        guard let payload = objects
            .compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
            .first(where: { $0.type == .qr })?
            .stringValue
        else { return }
        #if DEBUG
        // The v15 lesson, second line: the size of what was decoded, never
        // the payload itself.
        print("QrScannerCamera: payload bytes=\(payload.utf8.count)")
        #endif
        // Delivered on `.main`, the queue this class was given above.
        MainActor.assumeIsolated {
            onPayload?(payload)
        }
    }
}
