import AppKit
import AVFoundation
import ColorSync
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct ScreenRecorderApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate

    var body: some Scene {
        WindowGroup {
            ContentViewContainer().frame(width: 460, height: 500)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
private final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        applyBundledIcon()
        // SwiftUI completes some application setup after this callback. Apply
        // once more on the next run-loop turn so Mission Control and Dock use it.
        DispatchQueue.main.async { [weak self] in self?.applyBundledIcon() }
    }

    private func applyBundledIcon() {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let iconImage = NSImage(contentsOf: iconURL) else { return }
        NSApplication.shared.applicationIconImage = iconImage
    }
}

private struct ContentViewContainer: View {
    @StateObject private var recorder = RecorderModel()
    var body: some View {
        ContentView(recorder: recorder)
            .task {
                let arguments = CommandLine.arguments
                let smokeTestFlags: [(flag: String, mode: CaptureMode)] = [
                    ("--smoke-test", .screen),
                    ("--smoke-test-audio", .audioOnly)
                ]
                let smokeTestRequest = smokeTestFlags.compactMap { entry -> (URL, CaptureMode)? in
                    guard let flagIndex = arguments.firstIndex(of: entry.flag),
                          arguments.indices.contains(flagIndex + 1) else { return nil }
                    return (URL(fileURLWithPath: arguments[flagIndex + 1]), entry.mode)
                }.first
                if let smokeTestRequest {
                    let displayNumber = arguments.firstIndex(of: "--display")
                        .flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil }
                    let succeeded = await recorder.runSmokeTest(
                        destination: smokeTestRequest.0,
                        mode: smokeTestRequest.1,
                        includeSystemAudio: !arguments.contains("--no-system-audio"),
                        includeMicrophone: arguments.contains("--mic"),
                        displayNumber: displayNumber
                    )
                    fputs(succeeded ? "SMOKE_TEST_OK\n" : "SMOKE_TEST_FAILED\n", stderr)
                    NSApplication.shared.terminate(nil)
                } else {
                    await recorder.refreshDisplays()
                }
            }
    }
}

private enum CaptureMode: Hashable, CaseIterable {
    case screen, audioOnly

    var title: String {
        switch self {
        case .screen: "画面＋音声"
        case .audioOnly: "音声のみ"
        }
    }

    /// 「録画」と「録音」を文面で使い分けるための語。
    var actionNoun: String {
        switch self {
        case .screen: "録画"
        case .audioOnly: "録音"
        }
    }

    var fileExtension: String {
        switch self {
        case .screen: "mp4"
        case .audioOnly: "m4a"
        }
    }

    var contentType: UTType {
        switch self {
        case .screen: .mpeg4Movie
        case .audioOnly: .mpeg4Audio
        }
    }
}

private struct DisplayOption: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
}

@MainActor
private final class RecorderModel: ObservableObject {
    enum State {
        case idle, starting, recording, stopping
    }

    @Published private(set) var state: State = .idle
    @Published var errorMessage: String?
    @Published private(set) var mode: CaptureMode = .screen
    @Published var screenDestinationURL: URL?
    @Published var audioDestinationURL: URL?
    @Published private(set) var lastSavedURL: URL?
    @Published private(set) var displayOptions: [DisplayOption] = []
    @Published private(set) var selectedDisplayID: CGDirectDisplayID?
    @Published private(set) var elapsedSeconds: Int = 0
    @Published private(set) var lastDurationSeconds: Int?
    @Published private(set) var includeSystemAudio: Bool = AudioSourceStore.includeSystemAudio
    @Published private(set) var includeMicrophone: Bool = AudioSourceStore.includeMicrophone

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var recordingDelegate: RecordingDelegate?
    private var recordingBorder: RecordingBorderOverlay?
    private var elapsedTimer: Timer?
    private var startedAt: Date?
    /// 音声のみモードで、停止後に一時動画から音声を取り出すための行き先。
    private var pendingAudioExport: (temporaryURL: URL, destinationURL: URL)?

    var isRecording: Bool { state != .idle }

    var hasAudioSource: Bool { includeSystemAudio || includeMicrophone }

    /// 画面や説明文で使う音源の呼び名。
    var audioSourceSummary: String {
        switch (includeSystemAudio, includeMicrophone) {
        case (true, true): "PCの音とマイク"
        case (true, false): "PCの音"
        case (false, true): "マイク"
        case (false, false): "音声なし"
        }
    }

    var destinationURL: URL? {
        mode == .screen ? screenDestinationURL : audioDestinationURL
    }

    var statusLabel: String {
        switch state {
        case .idle: "待機中"
        case .starting: "準備中..."
        case .recording: mode.actionNoun + "中"
        case .stopping: "保存中..."
        }
    }

    /// 経過時間の主表示。停止後は直前の録画・録音時間を残す。
    var elapsedDisplay: String {
        Self.durationText(state == .idle ? (lastDurationSeconds ?? 0) : elapsedSeconds)
    }

    /// 「何秒か」を秒数そのままで見せる補助表示。
    var elapsedCaption: String {
        if state == .idle {
            guard let lastDurationSeconds else { return "まだ\(mode.actionNoun)していません" }
            return "前回の\(mode.actionNoun) \(lastDurationSeconds)秒"
        }
        return "\(elapsedSeconds)秒"
    }

    private static func durationText(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%02d:%02d", minutes, remainder)
    }

    func refreshDisplays() async {
        // NSScreen does not require Screen Recording permission, so the user
        // can choose a display even before granting TCC access.
        displayOptions = NSScreen.screens.enumerated().compactMap { index, screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return DisplayOption(
                id: number.uint32Value,
                name: "\(screen.localizedName)（画面 \(index + 1)）"
            )
        }
        if selectedDisplayID == nil || !displayOptions.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = displayOptions.first?.id
        }
    }

    func selectMode(_ newMode: CaptureMode) {
        guard !isRecording, newMode != mode else { return }
        if newMode == .audioOnly {
            recordingBorder?.dismiss()
            recordingBorder = nil
        }
        mode = newMode
    }

    func setIncludeSystemAudio(_ isOn: Bool) {
        guard !isRecording else { return }
        includeSystemAudio = isOn
        AudioSourceStore.includeSystemAudio = isOn
    }

    func setIncludeMicrophone(_ isOn: Bool) {
        guard !isRecording else { return }
        includeMicrophone = isOn
        AudioSourceStore.includeMicrophone = isOn
    }

    func selectDisplay(_ displayID: CGDirectDisplayID) {
        guard !isRecording else { return }
        recordingBorder?.dismiss()
        recordingBorder = nil
        selectedDisplayID = displayID
    }

    func showCaptureArea() {
        guard !isRecording, mode == .screen, let displayID = selectedDisplayID else { return }
        if let recordingBorder, recordingBorder.displayID == displayID {
            recordingBorder.unlockForAdjustment()
        } else {
            recordingBorder?.dismiss()
            recordingBorder = RecordingBorderOverlay(displayID: displayID, adjustable: true)
        }
    }

    func toggleRecording() {
        switch state {
        case .idle: Task { await startRecording() }
        case .recording: Task { await stopRecording() }
        case .starting, .stopping: break
        }
    }

    func chooseDestination() {
        guard !isRecording else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [mode.contentType]
        panel.nameFieldStringValue = defaultFileName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch mode {
        case .screen: screenDestinationURL = url
        case .audioOnly: audioDestinationURL = url
        }
    }

    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func runSmokeTest(
        destination: URL,
        mode: CaptureMode,
        includeSystemAudio: Bool,
        includeMicrophone: Bool,
        displayNumber: Int? = nil
    ) async -> Bool {
        await refreshDisplays()
        if let displayNumber, displayOptions.indices.contains(displayNumber - 1) {
            selectedDisplayID = displayOptions[displayNumber - 1].id
        }
        self.mode = mode
        self.includeSystemAudio = includeSystemAudio
        self.includeMicrophone = includeMicrophone
        switch mode {
        case .screen: screenDestinationURL = destination
        case .audioOnly: audioDestinationURL = destination
        }
        await startRecording()
        guard state == .recording else {
            reportSmokeTest("START_ERROR: \(errorMessage ?? "unknown")", destination: destination)
            return false
        }
        try? await Task.sleep(for: .seconds(3))
        await stopRecording()
        if let errorMessage {
            reportSmokeTest("STOP_ERROR: \(errorMessage)", destination: destination)
        }
        return state == .idle && errorMessage == nil
    }

    /// GUI から起動したスモークテストは stderr が届かないので、結果を
    /// 保存先の隣に .log として残す。
    private func reportSmokeTest(_ message: String, destination: URL) {
        fputs(message + "\n", stderr)
        let logURL = destination.appendingPathExtension("log")
        try? message.write(to: logURL, atomically: true, encoding: .utf8)
    }

    private var defaultFileName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let prefix = mode == .screen ? "画面録画" : "音声録音"
        return "\(prefix)-\(formatter.string(from: Date())).\(mode.fileExtension)"
    }

    private func startRecording() async {
        state = .starting
        errorMessage = nil

        do {
            switch mode {
            case .screen: try await startScreenRecording()
            case .audioOnly: try await startAudioRecording()
            }
            startElapsedTimer()
            state = .recording
        } catch {
            await discardActiveRecording()
            state = .idle
            errorMessage = userMessage(for: error)
        }
    }

    private func startScreenRecording() async throws {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == selectedDisplayID }) ?? content.displays.first else {
                throw RecorderError.noDisplay
            }

            if recordingBorder?.displayID != display.displayID {
                recordingBorder?.dismiss()
                recordingBorder = RecordingBorderOverlay(displayID: display.displayID, adjustable: true)
                // 生成直後の NSPanel は frame がまだ確定していないことがあり、
                // そのまま読むと録画範囲が空と判定される。1周だけ待って確定させる。
                try await Task.sleep(for: .milliseconds(200))
            }
            guard let recordingBorder,
                  let sourceRect = recordingBorder.sourceRect else {
                throw RecorderError.invalidCaptureArea
            }
            recordingBorder.lockForRecording()

            // Refresh after showing the overlay so its window can be excluded
            // from the captured video while remaining visible to the user.
            let refreshedContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let captureDisplay = refreshedContent.displays.first(where: { $0.displayID == display.displayID }) ?? display
            let excludedWindows = refreshedContent.windows.filter {
                $0.windowID == CGWindowID(recordingBorder.windowNumber)
            }

            let outputURL = destinationURL ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(defaultFileName)
            guard !FileManager.default.fileExists(atPath: outputURL.path) else {
                throw RecorderError.destinationAlreadyExists(outputURL)
            }

            let configuration = SCStreamConfiguration()
            let screen = recordingBorder.screen
            let scale = CGFloat(captureDisplay.width) / max(screen.frame.width, 1)
            let outputWidth = max(2, Int(sourceRect.width * scale))
            let outputHeight = max(2, Int(sourceRect.height * scale))
            configuration.sourceRect = sourceRect
            configuration.width = outputWidth - (outputWidth % 2)
            configuration.height = outputHeight - (outputHeight % 2)
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.queueDepth = 5
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = true
            configuration.capturesAudio = includeSystemAudio
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            // SCRecordingOutput はPCの音とマイクを1つの音声トラックに
            // ミックスして書き出す。
            configuration.captureMicrophone = includeMicrophone

            let stream = SCStream(
                filter: SCContentFilter(display: captureDisplay, excludingWindows: excludedWindows),
                configuration: configuration,
                delegate: nil
            )

            let outputConfiguration = SCRecordingOutputConfiguration()
            outputConfiguration.outputURL = outputURL
            outputConfiguration.outputFileType = .mp4
            outputConfiguration.videoCodecType = .h264

            let delegate = RecordingDelegate()
            let output = SCRecordingOutput(configuration: outputConfiguration, delegate: delegate)
            try stream.addRecordingOutput(output)

            self.stream = stream
            recordingOutput = output
            recordingDelegate = delegate
            try await stream.startCapture()

            lastSavedURL = outputURL
        }
    }

    private func startAudioRecording() async throws {
        guard hasAudioSource else { throw RecorderError.noAudioSource }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == selectedDisplayID }) ?? content.displays.first else {
            throw RecorderError.noDisplay
        }

        let outputURL = destinationURL ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(defaultFileName)
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw RecorderError.destinationAlreadyExists(outputURL)
        }

        // ScreenCaptureKit は必ず映像を伴うので、いったん最小サイズの動画として
        // 録り、停止時に音声トラックだけを M4A へ取り出す。PCの音とマイクの
        // ミックスは SCRecordingOutput 側が行う。
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenrecorder-audio-\(UUID().uuidString).mp4")

        let configuration = SCStreamConfiguration()
        configuration.width = 16
        configuration.height = 16
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = includeSystemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.captureMicrophone = includeMicrophone

        let stream = SCStream(
            filter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration,
            delegate: nil
        )

        let outputConfiguration = SCRecordingOutputConfiguration()
        outputConfiguration.outputURL = temporaryURL
        outputConfiguration.outputFileType = .mp4
        outputConfiguration.videoCodecType = .h264

        let delegate = RecordingDelegate()
        let output = SCRecordingOutput(configuration: outputConfiguration, delegate: delegate)
        try stream.addRecordingOutput(output)

        self.stream = stream
        recordingOutput = output
        recordingDelegate = delegate
        pendingAudioExport = (temporaryURL, outputURL)
        try await stream.startCapture()

        lastSavedURL = outputURL
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        startedAt = Date()
        elapsedSeconds = 0
        // .common so the count keeps running while a menu or a drag is active.
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateElapsedSeconds() }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func updateElapsedSeconds() {
        guard let startedAt else { return }
        elapsedSeconds = max(0, Int(Date().timeIntervalSince(startedAt)))
    }

    private func stopElapsedTimer() {
        updateElapsedSeconds()
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        startedAt = nil
        lastDurationSeconds = elapsedSeconds
    }

    private func stopRecording() async {
        state = .stopping
        stopElapsedTimer()
        recordingBorder?.dismiss()
        recordingBorder = nil

        var finalError: Error?
        do { try await stream?.stopCapture() } catch { finalError = error }
        do { try await recordingDelegate?.waitForFinish() } catch { finalError = error }
        if finalError == nil, let pendingAudioExport {
            do {
                try await AudioTrackExporter.export(
                    from: pendingAudioExport.temporaryURL,
                    to: pendingAudioExport.destinationURL
                )
                try? FileManager.default.removeItem(at: pendingAudioExport.temporaryURL)
            } catch {
                finalError = error
            }
        }

        stream = nil
        recordingOutput = nil
        recordingDelegate = nil
        pendingAudioExport = nil
        state = .idle
        if let finalError { errorMessage = userMessage(for: finalError) }
    }

    private func discardActiveRecording() async {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        startedAt = nil
        recordingBorder?.dismiss()
        recordingBorder = nil
        try? await stream?.stopCapture()
        if let pendingAudioExport {
            try? FileManager.default.removeItem(at: pendingAudioExport.temporaryURL)
        }
        stream = nil
        recordingOutput = nil
        recordingDelegate = nil
        pendingAudioExport = nil
    }

    private func userMessage(for error: Error) -> String {
        if let recorderError = error as? RecorderError { return recorderError.localizedDescription }
        return "録画できませんでした。\n\(error.localizedDescription)"
    }
}

private enum RecorderError: LocalizedError {
    case noDisplay
    case destinationAlreadyExists(URL)
    case writerFailed(String)
    case invalidCaptureArea
    case noAudioCaptured
    case noAudioSource

    var errorDescription: String? {
        switch self {
        case .noDisplay: "録画できるディスプレイが見つかりません。"
        case .destinationAlreadyExists(let url):
            "同名の動画がすでにあります。別のファイル名を指定してください。\n\(url.path)"
        case .writerFailed(let message):
            "動画ファイルを作成できませんでした。\n\(message)"
        case .invalidCaptureArea:
            "録画範囲が小さすぎます。赤枠を広げてください。"
        case .noAudioCaptured:
            "音声が1つも録れませんでした。PCの音が鳴っているか、マイクが使えるかを確認してください。"
        case .noAudioSource:
            "音源が選ばれていません。「PCの音」か「マイク」のどちらかを有効にしてください。"
        }
    }
}

/// 音声のみモードの仕上げ。一時的に録った動画から音声トラックだけを取り出して
/// M4A にする。再エンコードなしのパススルーなので、長い録音でも一瞬で終わる。
private enum AudioTrackExporter {
    static func export(from source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw RecorderError.noAudioCaptured
        }
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw RecorderError.writerFailed("音声トラックを作成できませんでした。")
        }
        let timeRange = try await audioTrack.load(.timeRange)
        try compositionTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)

        // まず再エンコードなしで書き出す。マイク単独など、そのままでは
        // パススルーできない構成のときだけ AAC で焼き直す。
        do {
            try await write(composition, to: destination, preset: AVAssetExportPresetPassthrough)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            do {
                try await write(composition, to: destination, preset: AVAssetExportPresetAppleM4A)
            } catch {
                throw RecorderError.writerFailed(
                    "音声を保存できませんでした。\n\(error.localizedDescription)\n録音した一時ファイル: \(source.path)"
                )
            }
        }
    }

    private static func write(_ asset: AVAsset, to destination: URL, preset: String) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw RecorderError.writerFailed("音声の書き出しを準備できませんでした。")
        }
        try await session.export(to: destination, as: .m4a)
    }
}

private enum AudioSourceStore {
    private static let systemAudioKey = "include-system-audio"
    private static let microphoneKey = "include-microphone"

    static var includeSystemAudio: Bool {
        get { UserDefaults.standard.object(forKey: systemAudioKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: systemAudioKey) }
    }

    static var includeMicrophone: Bool {
        get { UserDefaults.standard.bool(forKey: microphoneKey) }
        set { UserDefaults.standard.set(newValue, forKey: microphoneKey) }
    }
}

private final class RecordingDelegate: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var didFinish = false
    private var finishError: Error?
    private var continuation: CheckedContinuation<Void, Error>?

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        resolve(with: error)
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        resolve(with: nil)
    }

    func waitForFinish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if didFinish {
                let error = finishError
                lock.unlock()
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    private func resolve(with error: Error?) {
        lock.lock()
        guard !didFinish else { lock.unlock(); return }
        didFinish = true
        finishError = error
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        if let continuation {
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
    }
}

/// タイトルバーを持つウィンドウは、指定した枠がその画面に収まらないと AppKit が
/// 別の画面へ移動・縮小してしまう。赤枠は位置と大きさ自体が設定なので、
/// 与えた枠をそのまま使わせる。
private final class RecordingBorderPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
private final class RecordingBorderOverlay: NSObject {
    private let panel: RecordingBorderPanel
    private let doneButton: NSButton
    let displayID: CGDirectDisplayID
    let screen: NSScreen

    var windowNumber: Int { panel.windowNumber }

    var sourceRect: CGRect? {
        // The overlay is transparent, so ScreenCaptureKit may still capture
        // its visible stroke even when the window is excluded. Capture from
        // the inside edge of the 6pt red stroke to guarantee it is omitted.
        let selectedFrame = panel.frame.intersection(screen.frame).insetBy(dx: 8, dy: 8)
        guard selectedFrame.width >= 8, selectedFrame.height >= 8 else { return nil }
        return CGRect(
            x: selectedFrame.minX - screen.frame.minX,
            y: screen.frame.maxY - selectedFrame.maxY,
            width: selectedFrame.width,
            height: selectedFrame.height
        )
    }

    init(displayID: CGDirectDisplayID, adjustable: Bool) {
        self.displayID = displayID
        self.screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        } ?? NSScreen.main
            ?? NSScreen.screens[0]
        let initialFrame = CaptureAreaStore.frame(for: displayID, on: screen)
            ?? screen.visibleFrame.insetBy(dx: 32, dy: 32)
        panel = RecordingBorderPanel(
            contentRect: initialFrame,
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        doneButton = NSButton(title: "完了", target: nil, action: nil)
        super.init()
        panel.delegate = self
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Keep the guide visible locally while WindowServer supplies the
        // unobscured pixels underneath it to screen-capture clients.
        panel.sharingType = .none
        panel.ignoresMouseEvents = !adjustable
        panel.isMovableByWindowBackground = adjustable
        panel.minSize = NSSize(width: 64, height: 48)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let borderView = RecordingBorderView(frame: panel.contentView?.bounds ?? .zero)
        borderView.autoresizingMask = [.width, .height]
        panel.contentView = borderView
        doneButton.target = self
        doneButton.action = #selector(finishAdjustment)
        doneButton.bezelStyle = .rounded
        doneButton.sizeToFit()
        doneButton.frame.origin = NSPoint(
            x: max(8, (borderView.bounds.width - doneButton.frame.width) / 2),
            y: max(8, borderView.bounds.height - doneButton.frame.height - 12)
        )
        doneButton.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        borderView.addSubview(doneButton)
        // init(contentRect:) の初期配置は AppKit 側でメイン画面に寄せられることが
        // あるため、生成後に狙った枠をあらためて指定する。
        panel.setFrame(panel.frameRect(forContentRect: initialFrame), display: false)
        panel.orderFrontRegardless()
    }

    func lockForRecording() {
        doneButton.isHidden = true
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = false
    }

    func unlockForAdjustment() {
        doneButton.isHidden = false
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true
        panel.orderFrontRegardless()
    }

    @objc private func finishAdjustment() {
        lockForRecording()
    }

    func dismiss() {
        saveFrameIfUsable()
        panel.orderOut(nil)
    }

    /// 画面から外れた枠を保存すると、次回そのディスプレイを選んだときに
    /// 録画範囲なしとして開始できなくなるので、重なりがあるときだけ残す。
    fileprivate func saveFrameIfUsable() {
        let visiblePart = panel.frame.intersection(screen.frame)
        guard visiblePart.width >= 8, visiblePart.height >= 8 else { return }
        CaptureAreaStore.save(panel.frame, for: displayID)
    }
}

extension RecordingBorderOverlay: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        saveFrameIfUsable()
    }

    func windowDidResize(_ notification: Notification) {
        saveFrameIfUsable()
    }
}

/// CGDirectDisplayID はディスプレイの抜き差しや再起動で入れ替わるため、
/// 設定の保存キーにはディスプレイ自身に紐づく識別子を使う。
private enum DisplayIdentity {
    static func key(for displayID: CGDirectDisplayID) -> String {
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
           let text = CFUUIDCreateString(nil, uuid) as String? {
            return text
        }
        // UUID が取れない場合は EDID 由来の番号で代用する。
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        if vendor != 0 || model != 0 || serial != 0 {
            return "\(vendor)-\(model)-\(serial)"
        }
        return "id-\(displayID)"
    }
}

private enum CaptureAreaStore {
    private static let keyPrefix = "capture-area-"

    static func save(_ frame: NSRect, for displayID: CGDirectDisplayID) {
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: key(for: displayID))
        UserDefaults.standard.removeObject(forKey: legacyKey(for: displayID))
    }

    static func frame(for displayID: CGDirectDisplayID, on screen: NSScreen) -> NSRect? {
        // 以前は CGDirectDisplayID をキーにしていたので、その値も引き継ぐ。
        // 別のディスプレイの枠を拾ってしまっても、下の重なり判定で捨てられる。
        let value = UserDefaults.standard.string(forKey: key(for: displayID))
            ?? UserDefaults.standard.string(forKey: legacyKey(for: displayID))
        guard let value else { return nil }
        let savedFrame = NSRectFromString(value)
        let visiblePart = savedFrame.intersection(screen.frame)
        guard visiblePart.width >= 8, visiblePart.height >= 8 else { return nil }
        return visiblePart
    }

    private static func key(for displayID: CGDirectDisplayID) -> String {
        keyPrefix + DisplayIdentity.key(for: displayID)
    }

    private static func legacyKey(for displayID: CGDirectDisplayID) -> String {
        keyPrefix + String(displayID)
    }
}

private final class RecordingBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 2, yRadius: 2)
        NSColor.systemRed.setStroke()
        path.lineWidth = 6
        path.stroke()
    }
}

private struct ContentView: View {
    @ObservedObject var recorder: RecorderModel

    var body: some View {
        VStack(spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Circle().fill(recorder.state == .recording ? .red : .secondary).frame(width: 10, height: 10)
                Text(recorder.statusLabel).font(.headline)
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(recorder.elapsedDisplay)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(recorder.state == .recording ? Color.primary : Color.secondary)
                    Text(recorder.elapsedCaption)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Picker(
                "モード",
                selection: Binding(get: { recorder.mode }, set: { recorder.selectMode($0) })
            ) {
                ForEach(CaptureMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(recorder.isRecording)

            HStack(spacing: 20) {
                Toggle("PCの音", isOn: Binding(
                    get: { recorder.includeSystemAudio },
                    set: { recorder.setIncludeSystemAudio($0) }
                ))
                Toggle("マイク", isOn: Binding(
                    get: { recorder.includeMicrophone },
                    set: { recorder.setIncludeMicrophone($0) }
                ))
                Spacer()
                if !recorder.hasAudioSource {
                    Text(recorder.mode == .screen ? "音なしで録画します" : "音源を選んでください")
                        .font(.caption)
                        .foregroundStyle(recorder.mode == .screen ? Color.secondary : Color.red)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(recorder.isRecording)

            if recorder.mode == .screen {
                HStack {
                    Picker(
                        "録画画面",
                        selection: Binding(
                            get: { recorder.selectedDisplayID ?? recorder.displayOptions.first?.id ?? 0 },
                            set: { recorder.selectDisplay($0) }
                        )
                    ) {
                        ForEach(recorder.displayOptions) { display in
                            Text(display.name).tag(display.id)
                        }
                    }
                    .frame(minWidth: 210)
                    .disabled(recorder.isRecording || recorder.displayOptions.isEmpty)

                    Button("赤枠を調整", action: recorder.showCaptureArea)
                        .disabled(recorder.isRecording || recorder.selectedDisplayID == nil)
                }

                Text("赤枠を調整後「調整完了」を押すと、枠内を通常どおり操作できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(action: recorder.toggleRecording) {
                Label(
                    recorder.state == .recording ? "\(recorder.mode.actionNoun)を停止" : "\(recorder.mode.actionNoun)を開始",
                    systemImage: recorder.state == .recording
                        ? "stop.fill"
                        : (recorder.mode == .screen ? "record.circle" : "waveform.circle")
                ).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(
                recorder.state == .starting
                    || recorder.state == .stopping
                    || (recorder.state == .idle && recorder.mode == .audioOnly && !recorder.hasAudioSource)
            )

            HStack {
                Image(systemName: "folder")
                Text(recorder.destinationURL?.path ?? recorder.lastSavedURL?.path ?? "デスクトップに保存")
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("変更", action: recorder.chooseDestination).disabled(recorder.isRecording)
            }.font(.caption)

            Text(
                recorder.mode == .screen
                    ? "赤枠内の映像と\(recorder.audioSourceSummary)をMP4に録画します。赤枠自体は動画に入りません。"
                    : "\(recorder.audioSourceSummary)をM4Aに録音します（映像は保存しません）。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if let errorMessage = recorder.errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                Button("画面収録の設定を開く", action: recorder.openPrivacySettings).font(.caption)
            }
        }.padding(24)
    }
}
