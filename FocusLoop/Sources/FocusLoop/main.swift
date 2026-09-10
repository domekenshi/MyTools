import AppKit
import SwiftUI

private enum TimerPhase: String {
    case focus
    case rest

    var title: String { self == .focus ? "集中" : "休憩" }
    var symbol: String { self == .focus ? "clock.fill" : "cup.and.saucer.fill" }
    var color: Color { self == .focus ? Color(red: 0.25, green: 0.47, blue: 0.36) : .orange }
}

private enum PresentationMode {
    case menuBar
    case window
}

private enum PreferredDisplay: String {
    case menuBar
    case window
}

private enum RunningWindowSize {
    case minimum
    case small
    case medium

    var title: String {
        switch self {
        case .minimum: "最小"
        case .small: "小"
        case .medium: "中"
        }
    }
    var contentSize: NSSize {
        switch self {
        case .minimum: NSSize(width: 250, height: 300)
        case .small: NSSize(width: 320, height: 440)
        case .medium: NSSize(width: 420, height: 560)
        }
    }
}

private enum PreferenceKey {
    static let preferredDisplay = "FocusLoop.preferredDisplay"
}

private struct MovableWindowConfigurator: NSViewRepresentable {
    final class Coordinator {
        var configuredWindowNumber: Int?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configureWhenAttached(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureWhenAttached(nsView, coordinator: context.coordinator)
    }

    private func configureWhenAttached(_ view: NSView, coordinator: Coordinator) {
        DispatchQueue.main.async {
            guard let window = view.window,
                  coordinator.configuredWindowNumber != window.windowNumber else { return }
            coordinator.configuredWindowNumber = window.windowNumber
            configure(window)
        }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable])
        window.title = "集中ループタイマー"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovable = true
        window.isMovableByWindowBackground = true
        window.level = .normal
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct TimerChoiceButtonStyle: ButtonStyle {
    let isSelected: Bool
    let selectionColor: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? selectionColor : Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(
                        isSelected ? selectionColor : Color.secondary.opacity(0.65),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
            .contentShape(Rectangle())
    }
}

@MainActor
private final class FocusTimer: ObservableObject {
    @Published private(set) var phase: TimerPhase = .focus
    @Published private(set) var isRunning = false
    @Published private(set) var remainingSeconds = 30 * 60
    @Published private(set) var completedSets = 0
    @Published var selectedMinutes = 30 { didSet { resetIfIdle() } }
    @Published var customMinutes = 45 { didSet { resetIfIdle() } }
    @Published var usesCustomMinutes = false { didSet { resetIfIdle() } }
    @Published var restMinutes = 5 { didSet { resetIfIdle() } }
    @Published var usesCustomRestMinutes = false
    @Published var alarmDuration = 5
    @Published var runningWindowSize: RunningWindowSize = .small
    @Published var preferredDisplay: PreferredDisplay {
        didSet {
            UserDefaults.standard.set(preferredDisplay.rawValue, forKey: PreferenceKey.preferredDisplay)
        }
    }

    private var deadline: Date?
    private var timer: Timer?
    private var alarmTimer: Timer?
    private var alarmStopTask: Task<Void, Never>?
    private var activityToken: NSObjectProtocol?
    private let alarmSound = NSSound(named: NSSound.Name("Glass"))

    init() {
        let savedDisplay = UserDefaults.standard.string(forKey: PreferenceKey.preferredDisplay)
        preferredDisplay = PreferredDisplay(rawValue: savedDisplay ?? "") ?? .menuBar
    }

    var focusSeconds: Int { (usesCustomMinutes ? customMinutes : selectedMinutes) * 60 }
    var restSeconds: Int { restMinutes * 60 }
    var phaseTotalSeconds: Int { phase == .focus ? focusSeconds : restSeconds }
    var progress: Double {
        guard phaseTotalSeconds > 0 else { return 0 }
        return 1 - Double(remainingSeconds) / Double(phaseTotalSeconds)
    }
    var timeText: String { Self.format(remainingSeconds) }
    var menuTitle: String { isRunning ? "\(phase.title) \(timeText)" : "集中タイマー" }

    func select(minutes: Int) {
        usesCustomMinutes = false
        selectedMinutes = minutes
    }

    func selectCustom() {
        usesCustomMinutes = true
    }

    func selectRest(minutes: Int) {
        usesCustomRestMinutes = false
        restMinutes = minutes
    }

    func selectCustomRest() {
        usesCustomRestMinutes = true
    }

    func start() {
        guard !isRunning else { return }
        stopAlarm()
        runningWindowSize = .small
        phase = .focus
        completedSets = 0
        remainingSeconds = focusSeconds
        deadline = Date().addingTimeInterval(TimeInterval(focusSeconds))
        isRunning = true
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "集中タイマーのアラームを確実に鳴らす"
        )
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        deadline = nil
        isRunning = false
        phase = .focus
        completedSets = 0
        remainingSeconds = focusSeconds
        stopAlarm()
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
            self.activityToken = nil
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let newTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
        tick()
    }

    private func tick() {
        guard isRunning, let deadline else { return }
        remainingSeconds = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
        if remainingSeconds == 0 { moveToNextPhase() }
    }

    private func moveToNextPhase() {
        playAlarm()
        if phase == .focus {
            phase = .rest
            remainingSeconds = restSeconds
            deadline = Date().addingTimeInterval(TimeInterval(restSeconds))
        } else {
            phase = .focus
            completedSets += 1
            remainingSeconds = focusSeconds
            deadline = Date().addingTimeInterval(TimeInterval(focusSeconds))
        }
    }

    private func playAlarm() {
        stopAlarm()
        alarmSound?.play()
        alarmTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.alarmSound?.play() }
        }
        let duration = alarmDuration
        alarmStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.stopAlarm()
        }
    }

    private func stopAlarm() {
        alarmTimer?.invalidate()
        alarmTimer = nil
        alarmStopTask?.cancel()
        alarmStopTask = nil
        alarmSound?.stop()
    }

    private func resetIfIdle() {
        if !isRunning { remainingSeconds = focusSeconds }
    }

    private static func format(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct TimerView: View {
    @ObservedObject var model: FocusTimer
    let presentation: PresentationMode
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var usesMinimumLayout: Bool {
        presentation == .window && model.isRunning && model.runningWindowSize == .minimum
    }

    var body: some View {
        VStack(spacing: usesMinimumLayout ? 10 : 18) {
            HStack {
                Label(model.isRunning ? "\(model.phase.title)中" : "準備完了", systemImage: model.phase.symbol)
                    .font(.headline)
                    .foregroundStyle(model.phase.color)
                Spacer()
                Text("\(model.completedSets) セット完了")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                let diameter = min(geometry.size.width, geometry.size.height)
                ZStack {
                    Circle().stroke(model.phase.color.opacity(0.14), lineWidth: 11)
                    Circle()
                        .trim(from: 0, to: model.progress)
                        .stroke(model.phase.color, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 6) {
                        Text(model.timeText)
                            .font(.system(size: 52, weight: .semibold, design: .monospaced))
                            .minimumScaleFactor(0.58)
                            .lineLimit(1)
                            .contentTransition(.numericText())
                        Text(model.phase == .focus ? "次は\(model.restMinutes)分休憩" : "次は集中")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                }
                .frame(width: diameter, height: diameter)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(
                minHeight: usesMinimumLayout ? 110 : (presentation == .window ? 140 : 230),
                idealHeight: 230,
                maxHeight: 230
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(model.phase.title)、残り\(model.timeText)")

            if model.isRunning {
                Button(role: .destructive) { model.stop() } label: {
                    Text("停止する").frame(maxWidth: .infinity)
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                if presentation == .window {
                    HStack(spacing: 8) {
                        runningSizeButton(.minimum)
                        runningSizeButton(.small)
                        runningSizeButton(.medium)
                    }
                }
            } else {
                settings
                Button { model.start() } label: {
                    Text("集中をはじめる").frame(maxWidth: .infinity)
                }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.25, green: 0.47, blue: 0.36))
                    .controlSize(.large)
            }

            if !usesMinimumLayout {
                Divider()
                HStack {
                    Text("タイマー中はMacの自動スリープを抑えます")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("終了") { NSApplication.shared.terminate(nil) }
                        .buttonStyle(.plain)
                        .font(.caption)
                }
            }
        }
        .padding(usesMinimumLayout ? 12 : 22)
        .frame(
            minWidth: presentation == .window && model.isRunning ? 250 : 340,
            idealWidth: 340,
            maxWidth: presentation == .window ? .infinity : 340,
            minHeight: presentation == .window && model.isRunning ? 300 : nil,
            maxHeight: presentation == .window ? .infinity : nil
        )
        .background {
            if presentation == .window {
                MovableWindowConfigurator()
            }
        }
        .onAppear {
            if presentation == .menuBar && model.preferredDisplay == .window {
                openWindow(id: "timer-window")
            } else if presentation == .window && model.isRunning {
                DispatchQueue.main.async {
                    resizeWindow(to: model.runningWindowSize.contentSize)
                }
            }
        }
        .onChange(of: model.isRunning) { _, isRunning in
            guard presentation == .window else { return }
            DispatchQueue.main.async {
                resizeWindow(to: isRunning
                    ? model.runningWindowSize.contentSize
                    : NSSize(width: 374, height: 640))
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingLabel("集中時間")
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    presetButton(15)
                    presetButton(30)
                    presetButton(45)
                    presetButton(60)
                }
                GridRow {
                    presetButton(75)
                    presetButton(150)
                    Button { model.selectCustom() } label: {
                        choiceLabel("カスタム", selected: model.usesCustomMinutes)
                    }
                        .buttonStyle(TimerChoiceButtonStyle(
                            isSelected: model.usesCustomMinutes,
                            selectionColor: model.phase.color
                        ))
                        .gridCellColumns(2)
                }
            }
            if model.usesCustomMinutes {
                customTimeInput(
                    title: "集中時間",
                    value: clampedBinding($model.customMinutes, range: 1...180),
                    range: 1...180
                )
            }

            settingLabel("休憩時間")
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    restPresetButton(1)
                    restPresetButton(3)
                    restPresetButton(5)
                }
                GridRow {
                    restPresetButton(10)
                    restPresetButton(15)
                    Button { model.selectCustomRest() } label: {
                        choiceLabel("カスタム", selected: model.usesCustomRestMinutes)
                    }
                        .buttonStyle(TimerChoiceButtonStyle(
                            isSelected: model.usesCustomRestMinutes,
                            selectionColor: model.phase.color
                        ))
                }
            }
            if model.usesCustomRestMinutes {
                customTimeInput(
                    title: "休憩時間",
                    value: clampedBinding($model.restMinutes, range: 1...60),
                    range: 1...60
                )
            }

            settingLabel("アラーム")
            HStack {
                alarmButton(5)
                alarmButton(10)
                alarmButton(15)
                alarmButton(20)
            }

            settingLabel("起動時の表示")
            HStack {
                displayButton(.menuBar, title: "メニューバー", symbol: "menubar.rectangle")
                displayButton(.window, title: "ウインドウ", symbol: "macwindow")
            }
        }
    }

    private func settingLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }

    private func customTimeInput(
        title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            TextField("分数", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 62)
                .accessibilityLabel("\(title)の分数")
            Text("分")
                .font(.caption)
            Stepper("", value: value, in: range)
                .labelsHidden()
        }
    }

    private func clampedBinding(_ value: Binding<Int>, range: ClosedRange<Int>) -> Binding<Int> {
        Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = min(range.upperBound, max(range.lowerBound, $0)) }
        )
    }

    private func presetButton(_ minutes: Int) -> some View {
        let isSelected = !model.usesCustomMinutes && model.selectedMinutes == minutes
        return Button { model.select(minutes: minutes) } label: {
            choiceLabel("\(minutes)分", selected: isSelected)
        }
            .buttonStyle(TimerChoiceButtonStyle(isSelected: isSelected, selectionColor: model.phase.color))
    }

    private func restPresetButton(_ minutes: Int) -> some View {
        let isSelected = !model.usesCustomRestMinutes && model.restMinutes == minutes
        return Button { model.selectRest(minutes: minutes) } label: {
            choiceLabel("\(minutes)分", selected: isSelected)
        }
            .buttonStyle(TimerChoiceButtonStyle(isSelected: isSelected, selectionColor: model.phase.color))
    }

    private func alarmButton(_ seconds: Int) -> some View {
        let isSelected = model.alarmDuration == seconds
        return Button { model.alarmDuration = seconds } label: {
            choiceLabel("\(seconds)秒", selected: isSelected)
        }
            .buttonStyle(TimerChoiceButtonStyle(isSelected: isSelected, selectionColor: model.phase.color))
    }

    private func runningSizeButton(_ size: RunningWindowSize) -> some View {
        let isSelected = model.runningWindowSize == size
        return Button {
            model.runningWindowSize = size
            resizeWindow(to: size.contentSize)
        } label: {
            choiceLabel(size.title, selected: isSelected)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(TimerChoiceButtonStyle(isSelected: isSelected, selectionColor: model.phase.color))
    }

    private func resizeWindow(to contentSize: NSSize) {
        guard let window = NSApplication.shared.keyWindow
            ?? NSApplication.shared.windows.first(where: { $0.title == "集中ループタイマー" && $0.isVisible })
        else { return }

        let oldFrame = window.frame
        let contentRect = NSRect(origin: .zero, size: contentSize)
        let targetFrame = window.frameRect(forContentRect: contentRect)
        let topAnchoredFrame = NSRect(
            x: oldFrame.minX,
            y: oldFrame.maxY - targetFrame.height,
            width: targetFrame.width,
            height: targetFrame.height
        )
        window.setFrame(topAnchoredFrame, display: true, animate: true)
    }

    private func displayButton(_ display: PreferredDisplay, title: String, symbol: String) -> some View {
        let isSelected = model.preferredDisplay == display
        return Button {
            model.preferredDisplay = display
            if display == .window {
                let menuPopover = NSApplication.shared.keyWindow
                openWindow(id: "timer-window")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    menuPopover?.orderOut(nil)
                }
            } else if presentation == .window {
                dismissWindow(id: "timer-window")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : symbol)
                Text(title)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(TimerChoiceButtonStyle(isSelected: isSelected, selectionColor: model.phase.color))
    }

    private func choiceLabel(_ title: String, selected: Bool) -> some View {
        HStack(spacing: 5) {
            if selected { Image(systemName: "checkmark") }
            Text(title)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MenuBarLabelView: View {
    @ObservedObject var model: FocusTimer
    @Environment(\.openWindow) private var openWindow
    @State private var handledInitialDisplay = false

    var body: some View {
        Label(model.menuTitle, systemImage: model.phase.symbol)
            .onAppear {
                guard !handledInitialDisplay else { return }
                handledInitialDisplay = true
                if model.preferredDisplay == .window {
                    DispatchQueue.main.async {
                        openWindow(id: "timer-window")
                    }
                }
            }
    }
}

@main
private struct FocusLoopApp: App {
    @StateObject private var model = FocusTimer()

    var body: some Scene {
        MenuBarExtra {
            TimerView(model: model, presentation: .menuBar)
        } label: {
            MenuBarLabelView(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("集中ループタイマー", id: "timer-window") {
            TimerView(model: model, presentation: .window)
        }
        .defaultSize(width: 374, height: 640)
        .defaultLaunchBehavior(.suppressed)
    }
}
