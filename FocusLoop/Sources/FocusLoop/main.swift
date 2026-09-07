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
        window.styleMask.insert([.titled, .closable, .miniaturizable])
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
    @Published var preferredDisplay: PreferredDisplay = .menuBar

    private var deadline: Date?
    private var timer: Timer?
    private var alarmTimer: Timer?
    private var alarmStopTask: Task<Void, Never>?
    private var activityToken: NSObjectProtocol?
    private let alarmSound = NSSound(named: NSSound.Name("Glass"))

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

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Label(model.isRunning ? "\(model.phase.title)中" : "準備完了", systemImage: model.phase.symbol)
                    .font(.headline)
                    .foregroundStyle(model.phase.color)
                Spacer()
                Text("\(model.completedSets) セット完了")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ZStack {
                Circle().stroke(model.phase.color.opacity(0.14), lineWidth: 11)
                Circle()
                    .trim(from: 0, to: model.progress)
                    .stroke(model.phase.color, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 6) {
                    Text(model.timeText)
                        .font(.system(size: 52, weight: .semibold, design: .monospaced))
                        .contentTransition(.numericText())
                    Text(model.phase == .focus ? "次は\(model.restMinutes)分休憩" : "次は集中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 230, height: 230)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(model.phase.title)、残り\(model.timeText)")

            if model.isRunning {
                Button(role: .destructive) { model.stop() } label: {
                    Text("停止する").frame(maxWidth: .infinity)
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                settings
                Button { model.start() } label: {
                    Text("集中をはじめる").frame(maxWidth: .infinity)
                }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.25, green: 0.47, blue: 0.36))
                    .controlSize(.large)
            }

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
        .padding(22)
        .frame(width: 340)
        .background {
            if presentation == .window {
                MovableWindowConfigurator()
            }
        }
        .onAppear {
            if presentation == .menuBar && model.preferredDisplay == .window {
                openWindow(id: "timer-window")
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingLabel("集中時間")
            HStack {
                presetButton(30)
                presetButton(60)
                presetButton(75)
            }
            HStack {
                presetButton(150)
                Button { model.selectCustom() } label: {
                    choiceLabel("カスタム", selected: model.usesCustomMinutes)
                }
                    .buttonStyle(TimerChoiceButtonStyle(
                        isSelected: model.usesCustomMinutes,
                        selectionColor: model.phase.color
                    ))
            }
            if model.usesCustomMinutes {
                Stepper("集中時間：\(model.customMinutes)分", value: $model.customMinutes, in: 1...180)
            }

            settingLabel("休憩時間")
            HStack {
                restPresetButton(5)
                restPresetButton(10)
                Button { model.selectCustomRest() } label: {
                    choiceLabel("カスタム", selected: model.usesCustomRestMinutes)
                }
                    .buttonStyle(TimerChoiceButtonStyle(
                        isSelected: model.usesCustomRestMinutes,
                        selectionColor: model.phase.color
                    ))
            }
            if model.usesCustomRestMinutes {
                Stepper("休憩時間：\(model.restMinutes)分", value: $model.restMinutes, in: 1...60)
            }

            settingLabel("アラーム")
            HStack {
                alarmButton(5)
                alarmButton(10)
            }

            settingLabel("表示方法")
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

@main
private struct FocusLoopApp: App {
    @StateObject private var model = FocusTimer()

    var body: some Scene {
        MenuBarExtra {
            TimerView(model: model, presentation: .menuBar)
        } label: {
            Label(model.menuTitle, systemImage: model.phase.symbol)
        }
        .menuBarExtraStyle(.window)

        Window("集中ループタイマー", id: "timer-window") {
            TimerView(model: model, presentation: .window)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}
