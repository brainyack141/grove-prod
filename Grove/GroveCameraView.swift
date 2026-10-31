import AVFoundation
import SwiftUI
import UIKit

// MARK: - Camera engine

/// Owns the AVFoundation capture graph. All hardware access is confined to a private
/// serial queue, so the class is safe to hand across concurrency domains under Swift 6.
final class CameraEngine: NSObject, @unchecked Sendable {
    enum ConfigurationResult: Sendable {
        case success
        case notAuthorized
        case noDevice
        case failed(String)
    }

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "nz.co.thinkingai.Grove.camera.session")
    private let photoOutput = AVCapturePhotoOutput()
    /// Live-frame side channel for the scan HUD. The output is part of the
    /// graph from configuration, but costs nothing until a tap installs a
    /// delegate — AVFoundation only delivers frames while one is set.
    private let videoOutput = AVCaptureVideoDataOutput()
    private let frameQueue = DispatchQueue(label: "nz.co.thinkingai.Grove.camera.frames")
    private var frameTap: FrameTapDelegate?
    private var videoInput: AVCaptureDeviceInput?
    private var currentPosition: AVCaptureDevice.Position = .back
    private var isConfigured = false
    /// The session may stop because iOS interrupted it or because the owning
    /// view deliberately left the camera. Only the former should auto-restart.
    /// Without this bit, a late interruption-ended notification could turn the
    /// camera back on behind a review/result screen after `stop()` had run.
    private var shouldBeRunning = false

    /// Tracks the device-relative rotation so captured photos and the preview stay
    /// horizon-level in every supported interface orientation, not just portrait.
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?

    /// Notification tokens kept alive so the session can recover from interruptions
    /// (phone calls, Control Center camera, another app grabbing the camera) and
    /// transient runtime errors instead of silently freezing.
    private var observerTokens: [NSObjectProtocol] = []

    /// Delegates are retained by the output only weakly, so keep them alive here.
    private var activeCaptureDelegates: [Int64: PhotoCaptureDelegate] = [:]

    var isRunning: Bool { session.isRunning }

    deinit {
        observerTokens.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: Configuration

    func configure(completion: @escaping @Sendable (ConfigurationResult) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isConfigured else {
                completion(.success)
                return
            }

            let status = AVCaptureDevice.authorizationStatus(for: .video)
            guard status == .authorized else {
                completion(.notAuthorized)
                return
            }

            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            guard let device = Self.captureDevice(for: self.currentPosition) else {
                self.session.commitConfiguration()
                completion(.noDevice)
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    completion(.failed("This device can't give Grove a camera feed."))
                    return
                }
                self.session.addInput(input)
                self.videoInput = input

                guard self.session.canAddOutput(self.photoOutput) else {
                    self.session.removeInput(input)
                    self.videoInput = nil
                    self.session.commitConfiguration()
                    completion(.failed("Grove couldn't start the camera. Try again in a moment."))
                    return
                }
                self.session.addOutput(self.photoOutput)
                self.photoOutput.maxPhotoQualityPrioritization = .quality

                // Live frames ride alongside the photo output. BGRA because the
                // analyzer reads pixels directly; late frames are dropped —
                // a live readout wants the newest frame, never a backlog.
                if self.session.canAddOutput(self.videoOutput) {
                    self.videoOutput.videoSettings = [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                    ]
                    self.videoOutput.alwaysDiscardsLateVideoFrames = true
                    self.session.addOutput(self.videoOutput)
                }

                self.session.commitConfiguration()
                self.rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
                self.registerSessionObservers()
                self.isConfigured = true
                completion(.success)
            } catch {
                self.session.commitConfiguration()
                completion(.failed(error.localizedDescription))
            }
        }
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.shouldBeRunning = true
            guard self.isConfigured, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.shouldBeRunning = false
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    // MARK: Capture

    func capturePhoto(
        flashMode: AVCaptureDevice.FlashMode,
        completion: @escaping @Sendable (Result<UIImage, Error>) -> Void
    ) {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, self.session.isRunning else {
                // A stopped session (interruption / runtime error) would never deliver a
                // photo callback, hanging the shutter — fail fast instead.
                completion(.failure(CameraError.notReady))
                return
            }

            let settings = AVCapturePhotoSettings()
            if self.photoOutput.supportedFlashModes.contains(flashMode) {
                settings.flashMode = flashMode
            }
            settings.photoQualityPrioritization = .quality

            if let connection = self.photoOutput.connection(with: .video) {
                let angle = self.rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
                if connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
            }

            let identifier = settings.uniqueID
            // Each closure takes its own weak capture. Reaching through the
            // outer closure's captured `self` from inside the nested one is a
            // mutable capture read across concurrency domains — a warning
            // today, an error under strict concurrency, and a real race on the
            // delegate table either way.
            let delegate = PhotoCaptureDelegate { [weak self] result in
                completion(result)
                guard let self else { return }
                self.sessionQueue.async { [weak self] in
                    self?.activeCaptureDelegates[identifier] = nil
                }
            }
            self.activeCaptureDelegates[identifier] = delegate
            self.photoOutput.capturePhoto(with: settings, delegate: delegate)
            // AVFoundation normally resolves the delegate promptly, including
            // interruption errors. A device handoff at exactly the wrong time
            // can still omit the callback; never leave the UI's checked
            // continuation (and shutter) suspended forever.
            self.sessionQueue.asyncAfter(deadline: .now() + 15) { [weak self, weak delegate] in
                guard let self,
                      self.activeCaptureDelegates[identifier] != nil,
                      let delegate else { return }
                delegate.finish(.failure(CameraError.captureTimedOut))
                self.activeCaptureDelegates[identifier] = nil
            }
        }
    }

    // MARK: Flip / focus

    func flipCamera(completion: @escaping @Sendable (Bool) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self, let currentInput = self.videoInput else {
                completion(false)
                return
            }
            let targetPosition: AVCaptureDevice.Position = self.currentPosition == .back ? .front : .back
            guard let newDevice = Self.captureDevice(for: targetPosition),
                  let newInput = try? AVCaptureDeviceInput(device: newDevice) else {
                completion(false)
                return
            }

            self.session.beginConfiguration()
            self.session.removeInput(currentInput)
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.videoInput = newInput
                self.currentPosition = targetPosition
                self.rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: newDevice, previewLayer: nil)
            } else {
                self.session.addInput(currentInput)
            }
            self.session.commitConfiguration()
            completion(self.currentPosition == .front)
        }
    }

    /// `point` is in the preview layer's device coordinate space (0...1, 0...1).
    func focus(at point: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()
            } catch {
                // Focus is a best-effort refinement; ignore hardware failures.
            }
        }
    }

    // MARK: Live frame tap

    /// Starts delivering downstream-owned preview frames to `handler` on a
    /// background queue. One tap at a time; installing replaces the previous.
    func installFrameTap(_ handler: @escaping @Sendable (CVPixelBuffer) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let delegate = FrameTapDelegate(handler: handler)
            self.frameTap = delegate
            if let connection = self.videoOutput.connection(with: .video) {
                let angle = self.rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
                if connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
            }
            self.videoOutput.setSampleBufferDelegate(delegate, queue: self.frameQueue)
        }
    }

    func removeFrameTap() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
            self.frameTap = nil
        }
    }

    // MARK: Interruption / error recovery

    private func registerSessionObservers() {
        guard observerTokens.isEmpty else { return }
        let center = NotificationCenter.default

        observerTokens.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.restartIfStopped()
        })

        // When an interruption ends (call finished, Control Center dismissed, other app
        // released the camera), AVFoundation leaves the session stopped — restart it so
        // the preview resumes instead of staying frozen.
        observerTokens.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.restartIfStopped()
        })
    }

    private func restartIfStopped() {
        sessionQueue.async { [weak self] in
            guard let self,
                  self.shouldBeRunning,
                  self.isConfigured,
                  !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    private static func captureDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInDualCamera,
            .builtInWideAngleCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: position
        )
        return discovery.devices.first
    }
}

enum CameraError: LocalizedError {
    case notReady
    case captureInProgress
    case captureTimedOut
    case noImageData

    var errorDescription: String? {
        switch self {
        case .notReady: "The camera is still waking up. One moment."
        case .captureInProgress: "The last photo is still saving. One moment."
        case .captureTimedOut: "The camera was interrupted before it finished. Take the photo again."
        case .noImageData: "That photo didn't save. Take it again."
        }
    }
}

/// Hands each preview frame's pixel buffer to the live analyzer. The buffer is
/// only valid for the duration of the callback plus whatever the handler
/// retains — the analyzer copies what it needs and drops the reference fast.
private final class FrameTapDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let handler: @Sendable (CVPixelBuffer) -> Void

    init(handler: @escaping @Sendable (CVPixelBuffer) -> Void) {
        self.handler = handler
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        handler(buffer)
    }
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: @Sendable (Result<UIImage, Error>) -> Void
    private let completionLock = NSLock()
    private var hasFinished = false

    init(completion: @escaping @Sendable (Result<UIImage, Error>) -> Void) {
        self.completion = completion
    }

    /// Exactly-once even when the timeout races AVFoundation's late callback.
    func finish(_ result: Result<UIImage, Error>) {
        completionLock.lock()
        guard !hasFinished else {
            completionLock.unlock()
            return
        }
        hasFinished = true
        completionLock.unlock()
        completion(result)
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            finish(.failure(error))
            return
        }
        guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
            finish(.failure(CameraError.noImageData))
            return
        }
        finish(.success(image.normalizedUp()))
    }
}

// MARK: - Camera model (UI facing)

@MainActor
@Observable
final class CameraCaptureModel {
    enum Status: Equatable {
        case idle
        case ready
        case denied
        case unavailable(String)
    }

    enum FlashSetting: CaseIterable {
        case auto, on, off

        var mode: AVCaptureDevice.FlashMode {
            switch self {
            case .auto: .auto
            case .on: .on
            case .off: .off
            }
        }

        var icon: String {
            switch self {
            case .auto: "bolt.badge.a.fill"
            case .on: "bolt.fill"
            case .off: "bolt.slash.fill"
            }
        }

        var next: FlashSetting {
            switch self {
            case .auto: .on
            case .on: .off
            case .off: .auto
            }
        }
    }

    let engine = CameraEngine()
    private(set) var status: Status = .idle
    var flash: FlashSetting = .auto
    var isCapturing = false
    var isFrontCamera = false
    var showsGrid = true
    /// Mirrors the owning view's intent across suspension points in permission
    /// and hardware configuration. A view can disappear while either await is
    /// outstanding; that stale completion must not start the camera afterward.
    private var wantsCameraRunning = false

    var isSimulator: Bool {
#if targetEnvironment(simulator)
        true
#else
        false
#endif
    }

    func prepare() async {
        wantsCameraRunning = true
        if isSimulator {
            status = .unavailable("The Simulator has no camera. Use a sample photo or your library to walk the scan flow.")
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else {
                status = .denied
                return
            }
            guard wantsCameraRunning else { return }
        case .denied:
            status = .denied
            return
        case .restricted:
            status = .unavailable("Camera access is restricted on this device. Your photo library still works.")
            return
        @unknown default:
            status = .denied
            return
        }

        let result: CameraEngine.ConfigurationResult = await withCheckedContinuation { continuation in
            engine.configure { continuation.resume(returning: $0) }
        }

        switch result {
        case .success:
            status = .ready
            if wantsCameraRunning {
                engine.start()
            } else {
                engine.stop()
            }
        case .notAuthorized:
            status = .denied
        case .noDevice:
            status = .unavailable("No camera on this device. Your photo library still works.")
        case .failed(let message):
            status = .unavailable(message)
        }
    }

    func stop() {
        wantsCameraRunning = false
        engine.stop()
    }

    /// Restarts a camera that was only stopped (navigating away and back),
    /// falling back to a full `prepare()` when it never came up.
    func resume() async {
        wantsCameraRunning = true
        if status == .ready {
            engine.start()
        } else {
            await prepare()
        }
    }

    func toggleFlash() {
        flash = flash.next
    }

    func flip() {
        engine.flipCamera { [weak self] isFront in
            Task { @MainActor in self?.isFrontCamera = isFront }
        }
    }

    func focus(at devicePoint: CGPoint) {
        engine.focus(at: devicePoint)
    }

    func capture() async throws -> UIImage {
        guard status == .ready else { throw CameraError.notReady }
        guard !isCapturing else { throw CameraError.captureInProgress }
        isCapturing = true
        defer { isCapturing = false }
        let mode = flash.mode
        return try await withCheckedThrowingContinuation { continuation in
            engine.capturePhoto(flashMode: mode) { result in
                continuation.resume(with: result)
            }
        }
    }
}

// MARK: - Preview layer

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let onFocusTap: (CGPoint, CGPoint) -> Void // (devicePoint 0-1, viewPoint)

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        context.coordinator.previewView = view
        context.coordinator.startRotationTracking(for: view.videoPreviewLayer, session: session)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        context.coordinator.startRotationTracking(for: uiView.videoPreviewLayer, session: session)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFocusTap: onFocusTap) }

    final class Coordinator: NSObject {
        weak var previewView: PreviewUIView?
        let onFocusTap: (CGPoint, CGPoint) -> Void
        private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
        private var rotationObservation: NSKeyValueObservation?

        init(onFocusTap: @escaping (CGPoint, CGPoint) -> Void) {
            self.onFocusTap = onFocusTap
        }

        deinit { rotationObservation?.invalidate() }

        /// Keeps the live preview horizon-level in landscape as well as portrait. Waits
        /// until the session actually has a video device (added during `configure`).
        func startRotationTracking(for previewLayer: AVCaptureVideoPreviewLayer, session: AVCaptureSession) {
            guard rotationCoordinator == nil else { return }
            let device = session.inputs
                .compactMap { ($0 as? AVCaptureDeviceInput)?.device }
                .first { $0.hasMediaType(.video) }
            guard let device else { return }

            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            rotationCoordinator = coordinator
            apply(coordinator.videoRotationAngleForHorizonLevelPreview, to: previewLayer)
            // Applied directly on the KVO thread: only AVCaptureConnection state
            // is touched (no @MainActor types), and hopping to the main actor
            // would mean sending the non-Sendable layer across isolation, which
            // Swift 6.2 rejects.
            //
            // `AVCaptureVideoPreviewLayer` is not `Sendable`, so capturing it in
            // the `@Sendable` observation closure needs the exemption spelled
            // out rather than left as a warning. It is safe here because the
            // only writer is this one observation and the only state written is
            // the connection's rotation angle.
            // Captured strongly: `[weak layer]` would re-introduce the optional
            // non-Sendable type the exemption is here to cover, and there is no
            // cycle to break — the layer does not own the coordinator, and the
            // observation is invalidated on teardown.
            nonisolated(unsafe) let layer = previewLayer
            rotationObservation = coordinator.observe(
                \.videoRotationAngleForHorizonLevelPreview,
                options: [.new]
            ) { _, change in
                guard let angle = change.newValue else { return }
                Coordinator.apply(angle, to: layer)
            }
        }

        private func apply(_ angle: CGFloat, to previewLayer: AVCaptureVideoPreviewLayer) {
            Coordinator.apply(angle, to: previewLayer)
        }

        private static func apply(_ angle: CGFloat, to previewLayer: AVCaptureVideoPreviewLayer) {
            guard let connection = previewLayer.connection,
                  connection.isVideoRotationAngleSupported(angle) else { return }
            connection.videoRotationAngle = angle
        }

        /// UIKit always delivers gesture callbacks on the main thread, but the
        /// Coordinator is a plain `NSObject`, so the compiler had no way to know
        /// that and saw a nonisolated function touching `location(in:)` and the
        /// preview layer — both main-actor state. Stating the isolation makes
        /// the guarantee explicit instead of implied.
        @MainActor
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let previewView else { return }
            let viewPoint = gesture.location(in: previewView)
            let devicePoint = previewView.videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: viewPoint)
            onFocusTap(devicePoint, viewPoint)
        }
    }

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

// MARK: - Camera screen

struct GroveCameraView: View {
    @Environment(\.dismiss) private var dismiss
    let stage: ScanCaptureStage
    let onCapture: (UIImage) -> Void
    var onPickFromLibrary: (() -> Void)? = nil
    var onUseSample: (() -> Void)? = nil
    /// The previous check-in photo, floated over the viewfinder so the user can
    /// line up pot, angle, and framing. Matched framing is what turns a plant's
    /// photo history into a real time-lapse.
    var ghostImage: UIImage? = nil
    /// When the ghost is a dated check-in photo, the hint names the day. Grove
    /// cannot measure alignment, so the hint asks for it rather than claiming it.
    var ghostDate: Date? = nil
    /// The plant this photo is for, shown beside the step count.
    var plantName: String? = nil
    /// Where this capture sits in a longer flow, 1-based ("2 of 4").
    var stepNumber: Int? = nil
    var stepCount: Int? = nil

    @State private var model = CameraCaptureModel()
    @State private var focusIndicator: FocusIndicator?
    @State private var captureError: String?
    @State private var ghostOpacity: Double = 0.3

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch model.status {
            case .ready:
                cameraContent
            case .denied:
                permissionState(
                    icon: "camera.fill",
                    title: "Camera access is off",
                    message: "Turn on camera access in Settings to photograph a plant, or choose one from your library.",
                    showsSettings: true
                )
            case .unavailable(let message):
                permissionState(
                    icon: "camera.badge.ellipsis",
                    title: "Camera unavailable",
                    message: message,
                    showsSettings: false
                )
            case .idle:
                ProgressView().controlSize(.large).tint(.white)
            }

            overlayChrome
        }
        .preferredColorScheme(.dark)
        .task {
            await model.prepare()
        }
        .onDisappear {
            model.stop()
        }
    }

    // MARK: Live camera

    private var cameraContent: some View {
        GeometryReader { proxy in
            ZStack {
                CameraPreviewView(session: model.engine.session) { devicePoint, viewPoint in
                    model.focus(at: devicePoint)
                    showFocusIndicator(at: viewPoint)
                }
                .ignoresSafeArea()

                if let ghostImage {
                    Image(uiImage: ghostImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .opacity(ghostOpacity)
                        .allowsHitTesting(false)
                        .ignoresSafeArea()
                }

                if model.showsGrid {
                    GridOverlay().allowsHitTesting(false)
                }

                // The ghost is the framing guide when there is one; the dashed
                // frame only stands in when there is nothing to line up with.
                if ghostImage == nil {
                    RoundedRectangle(cornerRadius: GroveTheme.heroRadius, style: .continuous)
                        .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 2.5, dash: [11]))
                        .padding(.horizontal, 26)
                        .padding(.vertical, proxy.size.height * 0.14)
                        .allowsHitTesting(false)
                }

                if let focusIndicator {
                    FocusRing()
                        .position(focusIndicator.point)
                        .transition(.scale.combined(with: .opacity))
                        .id(focusIndicator.id)
                }
            }
        }
    }

    /// Fade control for the ghost: at full strength it hides the live preview,
    /// so the user needs to be able to dial it back while framing.
    private var ghostFadeControl: some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .accessibilityHidden(true)
            Slider(value: $ghostOpacity, in: 0...0.7)
                .tint(.white)
                .accessibilityLabel("Previous photo strength")
                .accessibilityIdentifier("cameraGhostOpacity")
        }
    }

    // MARK: Overlay (chrome is shared across states)

    private var overlayChrome: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            // In non-ready states (denied / simulator) the centered permission view supplies
            // its own actions, so the bottom control bar is only shown for a live camera.
            if model.status == .ready {
                VStack(alignment: .leading, spacing: 18) {
                    if let captureError {
                        Label(captureError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(GroveTheme.danger.opacity(0.9), in: Capsule())
                            .frame(maxWidth: .infinity)
                    }
                    if ghostImage != nil {
                        ghostFadeControl
                    }
                    captionBlock
                    bottomBar
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .background(alignment: .bottom) {
                    CaptureBottomScrim()
                        .padding(.top, -70)
                }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                CaptureGlassChip(systemImage: "xmark")
            }
            .buttonStyle(GroveTilePressStyle())
            .accessibilityLabel("Close camera")

            Spacer(minLength: 0)

            if ghostImage != nil, model.status == .ready {
                CaptureHintCapsule(text: ghostHint, dot: GroveTheme.mapThriving)
                    .lineLimit(2)
                    .layoutPriority(1)
            }

            Spacer(minLength: 0)

            if model.status == .ready {
                Button {
                    model.toggleFlash()
                } label: {
                    CaptureGlassChip(
                        systemImage: model.flash.icon,
                        tint: model.flash == .off ? .white : GroveTheme.gold
                    )
                }
                .buttonStyle(GroveTilePressStyle())
                .accessibilityLabel("Flash \(flashLabel)")
                .accessibilityIdentifier("cameraFlashToggle")
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// Asks for alignment rather than claiming it: Grove has no measure of how
    /// well the two frames match.
    private var ghostHint: String {
        guard let ghostDate else { return "Match last time's outline" }
        return "Match the outline from \(ghostDate.formatted(.dateTime.day().month(.abbreviated)))"
    }

    /// "2 of 4 · Phil", or whichever half is known.
    private var stepLine: String? {
        var parts: [String] = []
        if let stepNumber, let stepCount { parts.append("\(stepNumber) of \(stepCount)") }
        if let plantName, !plantName.isEmpty { parts.append(plantName) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var instructionLine: String {
        ghostImage == nil
            ? stage.instruction
            : "Match the faint outline from last time. Same spot, same angle, whole pot in frame."
    }

    private var captionBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let stepNumber, let stepCount {
                CaptureStepCapsules(total: stepCount, lit: stepNumber)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    stageTitle
                    Spacer(minLength: 8)
                    stepLabel
                }
                VStack(alignment: .leading, spacing: 4) {
                    stageTitle
                    stepLabel
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(instructionLine)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    model.showsGrid.toggle()
                } label: {
                    Label("Grid", systemImage: model.showsGrid ? "grid" : "square")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("cameraGridToggle")
            }
        }
    }

    private var stageTitle: some View {
        Text(stage.title)
            .font(.title2.weight(.bold))
            .foregroundStyle(.white)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var stepLabel: some View {
        if let stepLine {
            Text(stepLine.uppercased())
                .font(.footnote.weight(.medium))
                .tracking(0.6)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
        }
    }

    private var bottomBar: some View {
        HStack(alignment: .center) {
            leadingTile
                .frame(width: 56)

            Spacer()

            // Shutter
            Button(action: captureTapped) {
                CaptureShutterLabel(isBusy: model.isCapturing)
            }
            .buttonStyle(GroveCardPressStyle(scale: 0.92, haptics: false))
            .disabled(model.isCapturing)
            .accessibilityLabel("Capture \(stage.title) photo")
            .accessibilityIdentifier("cameraShutter")

            Spacer()

            // Flip
            Button {
                model.flip()
            } label: {
                CaptureGlassChip(systemImage: "arrow.triangle.2.circlepath.camera")
            }
            .buttonStyle(GroveTilePressStyle())
            .accessibilityLabel("Switch camera")
            .accessibilityIdentifier("cameraFlipButton")
            .frame(width: 56)
        }
        .padding(.horizontal, 12)
    }

    /// Last time's photo when there is one, so the comparison is in reach of
    /// the thumb; otherwise the library, when the caller offers it.
    @ViewBuilder private var leadingTile: some View {
        if let ghostImage {
            CapturePhotoTile(image: ghostImage)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ghostDate.map {
                    "Last check-in photo, \($0.formatted(date: .long, time: .omitted))"
                } ?? "Last photo of this plant")
        } else if onPickFromLibrary != nil {
            Button {
                model.stop()
                dismiss()
                onPickFromLibrary?()
            } label: {
                CaptureLibraryTile()
            }
            .buttonStyle(GroveTilePressStyle())
            .accessibilityLabel("Choose from library")
            .accessibilityIdentifier("cameraLibraryButton")
        } else {
            Color.clear.frame(width: 50, height: 50)
        }
    }

    // MARK: Non-ready state

    private func permissionState(icon: String, title: String, message: String, showsSettings: Bool) -> some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 54, weight: .thin))
                .foregroundStyle(.white.opacity(0.85))
            Text(title).font(.title2.bold()).foregroundStyle(.white)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(spacing: 12) {
                if let onUseSample {
                    Button {
                        model.stop(); dismiss(); onUseSample()
                    } label: {
                        GroveCTALabel(title: "Use a sample photo", systemImage: "wand.and.stars", onDark: true)
                    }
                    .buttonStyle(GrovePressStyle())
                    .accessibilityIdentifier("cameraUseSample")
                }
                if let onPickFromLibrary {
                    GroveOutlineButton(title: "Choose from library", systemImage: "photo.on.rectangle", onDark: true) {
                        model.stop(); dismiss(); onPickFromLibrary()
                    }
                }
                if showsSettings {
                    Button("Open Settings") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                    .font(.subheadline.weight(.semibold))
                    .tint(.white)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Actions

    private func captureTapped() {
        Task {
            captureError = nil
            // The shutter of a camera-first app said nothing at all when it
            // fired. It now snaps the instant the capture starts, not when the
            // image comes back — a shutter you feel after the fact is not a
            // shutter.
            Haptics.shutter()
            do {
                let image = try await model.capture()
                model.stop()
                dismiss()
                onCapture(image)
            } catch {
                Haptics.error()
                captureError = error.localizedDescription
            }
        }
    }

    private func showFocusIndicator(at point: CGPoint) {
        withAnimation(.easeOut(duration: 0.2)) {
            focusIndicator = FocusIndicator(point: point)
        }
        let current = focusIndicator?.id
        Task {
            try? await Task.sleep(for: .seconds(1))
            if focusIndicator?.id == current {
                withAnimation(.easeIn(duration: 0.25)) { focusIndicator = nil }
            }
        }
    }

    private var flashLabel: String {
        switch model.flash {
        case .auto: "auto"
        case .on: "on"
        case .off: "off"
        }
    }

    private struct FocusIndicator: Equatable {
        let id = UUID()
        let point: CGPoint
    }
}

// MARK: - Overlay shapes

struct GridOverlay: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                let w = proxy.size.width
                let h = proxy.size.height
                for i in 1...2 {
                    let x = w / 3 * CGFloat(i)
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: h))
                    let y = h / 3 * CGFloat(i)
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(.white.opacity(0.28), lineWidth: 0.75)
        }
    }
}

struct FocusRing: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(GroveTheme.gold, lineWidth: 1.5)
            .frame(width: 78, height: 78)
    }
}

// MARK: - Image orientation helper

extension UIImage {
    /// Redraws the image so its pixel buffer is upright (`.up`), dropping EXIF orientation
    /// so downstream JPEG re-encoding and the analysis service always receive an upright frame.
    func normalizedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// Identifies the camera cover so it can be driven by an `item:` binding.
enum CaptureSheet: String, Identifiable {
    case camera
    var id: String { rawValue }
}
