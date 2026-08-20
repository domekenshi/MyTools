import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI

@main
struct ScreenRecorderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentViewContainer().frame(width: 460, height: 370)
        }
        .windowResizability(.contentSize)
    }
}

private struct ContentViewContainer: View {
    @StateObject private var recorder = RecorderModel()
    var body: some View {
        ContentView(recorder: recorder)
            .task {
                let arguments = CommandLine.arguments
                if let flagIndex = arguments.firstIndex(of: "--smoke-test"),
                   arguments.indices.contains(flagIndex + 1) {
                    let succeeded = await recorder.runSmokeTest(
                        destination: URL(fileURLWithPath: arguments[flagIndex + 1])
                    )
                    fputs(succeeded ? "SMOKE_TEST_OK\n" : "SMOKE_TEST_FAILED\n", stderr)
                    NSApplication.shared.terminate(nil)
                } else {
                    await recorder.refreshDisplays()
                }
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

        var label: String {
            switch self {
            case .idle: "待機中"
            case .starting: "準備中..."
            case .recording: "録画中"
            case .stopping: "保存中..."
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published var errorMessage: String?
    @Published var destinationURL: URL?
    @Published private(set) var lastSavedURL: URL?
    @Published private(set) var displayOptions: [DisplayOption] = []
    @Published private(set) var selectedDisplayID: CGDirectDisplayID?

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var recordingDelegate: RecordingDelegate?
    private var recordingBorder: RecordingBorderOverlay?

    var isRecording: Bool { state != .idle }

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

    func selectDisplay(_ displayID: CGDirectDisplayID) {
        guard !isRecording else { return }
        recordingBorder?.dismiss()
        recordingBorder = nil
        selectedDisplayID = displayID
    }

    func showCaptureArea() {
        guard !isRecording, let displayID = selectedDisplayID else { return }
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
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = defaultFileName
        panel.canCreateDirectories = true
        if panel.runModal() == .OK { destinationURL = panel.url }
    }

    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func runSmokeTest(destination: URL) async -> Bool {
        destinationURL = destination
        await startRecording()
        guard state == .recording else {
            fputs("START_ERROR: \(errorMessage ?? "unknown")\n", stderr)
            return false
        }
        try? await Task.sleep(for: .seconds(3))
        await stopRecording()
        if let errorMessage { fputs("STOP_ERROR: \(errorMessage)\n", stderr) }
        return state == .idle && errorMessage == nil
    }

    private var defaultFileName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "画面録画-\(formatter.string(from: Date())).mp4"
    }

    private func startRecording() async {
        state = .starting
        errorMessage = nil

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == selectedDisplayID }) ?? content.displays.first else {
                throw RecorderError.noDisplay
            }

            if recordingBorder?.displayID != display.displayID {
                recordingBorder?.dismiss()
                recordingBorder = RecordingBorderOverlay(displayID: display.displayID, adjustable: true)
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
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2

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
            state = .recording
        } catch {
            await discardActiveRecording()
            state = .idle
            errorMessage = userMessage(for: error)
        }
    }

    private func stopRecording() async {
        state = .stopping
        recordingBorder?.dismiss()
        recordingBorder = nil

        var finalError: Error?
        do { try await stream?.stopCapture() } catch { finalError = error }
        do { try await recordingDelegate?.waitForFinish() } catch { finalError = error }

        stream = nil
        recordingOutput = nil
        recordingDelegate = nil
        state = .idle
        if let finalError { errorMessage = userMessage(for: finalError) }
    }

    private func discardActiveRecording() async {
        recordingBorder?.dismiss()
        recordingBorder = nil
        try? await stream?.stopCapture()
        stream = nil
        recordingOutput = nil
        recordingDelegate = nil
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

    var errorDescription: String? {
        switch self {
        case .noDisplay: "録画できるディスプレイが見つかりません。"
        case .destinationAlreadyExists(let url):
            "同名の動画がすでにあります。別のファイル名を指定してください。\n\(url.path)"
        case .writerFailed(let message):
            "動画ファイルを作成できませんでした。\n\(message)"
        case .invalidCaptureArea:
            "録画範囲が小さすぎます。赤枠を広げてください。"
        }
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

@MainActor
private final class RecordingBorderOverlay: NSObject {
    private let panel: NSPanel
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
            ?? screen.frame.insetBy(dx: 32, dy: 32)
        panel = NSPanel(
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
        CaptureAreaStore.save(panel.frame, for: displayID)
        panel.orderOut(nil)
    }
}

extension RecordingBorderOverlay: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        CaptureAreaStore.save(panel.frame, for: displayID)
    }

    func windowDidResize(_ notification: Notification) {
        CaptureAreaStore.save(panel.frame, for: displayID)
    }
}

private enum CaptureAreaStore {
    private static let keyPrefix = "capture-area-"

    static func save(_ frame: NSRect, for displayID: CGDirectDisplayID) {
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: keyPrefix + String(displayID))
    }

    static func frame(for displayID: CGDirectDisplayID, on screen: NSScreen) -> NSRect? {
        guard let value = UserDefaults.standard.string(forKey: keyPrefix + String(displayID)) else {
            return nil
        }
        let savedFrame = NSRectFromString(value)
        let visiblePart = savedFrame.intersection(screen.frame)
        guard visiblePart.width >= 8, visiblePart.height >= 8 else { return nil }
        return visiblePart
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
            HStack {
                Circle().fill(recorder.state == .recording ? .red : .secondary).frame(width: 10, height: 10)
                Text(recorder.state.label).font(.headline)
                Spacer()
            }

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

            Button(action: recorder.toggleRecording) {
                Label(
                    recorder.state == .recording ? "録画を停止" : "録画を開始",
                    systemImage: recorder.state == .recording ? "stop.fill" : "record.circle"
                ).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(recorder.state == .starting || recorder.state == .stopping)

            HStack {
                Image(systemName: "folder")
                Text(recorder.destinationURL?.path ?? recorder.lastSavedURL?.path ?? "デスクトップに保存")
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("変更", action: recorder.chooseDestination).disabled(recorder.isRecording)
            }.font(.caption)

            Text("赤枠内の映像とPC内の音声をMP4に録画します。赤枠自体は動画に入りません。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage = recorder.errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                Button("画面収録の設定を開く", action: recorder.openPrivacySettings).font(.caption)
            }
        }.padding(24)
    }
}
