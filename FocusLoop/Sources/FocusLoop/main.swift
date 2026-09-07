import AppKit
import SwiftUI

private enum TimerPhase: String {
    case focus
    case rest

    var title: String { self == .focus ? "集中" : "休憩" }
    var symbol: String { self == .focus ? "clock.fill" : "cup.and.saucer.fill" }
    var color: Color { self == .focus ? Color(red: 0.25, green: 0.47, blue: 0.36) : .orange }
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
    @Published var alarmDuration = 5

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
                Button("停止する", role: .destructive) { model.stop() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            } else {
                settings
                Button("集中をはじめる") { model.start() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.25, green: 0.47, blue: 0.36))
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
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
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("集中時間").font(.caption).foregroundStyle(.secondary)
            HStack {
                presetButton(30)
                presetButton(60)
                Button("カスタム") { model.selectCustom() }
                    .buttonStyle(.bordered)
                    .tint(model.usesCustomMinutes ? model.phase.color : .secondary)
            }
            if model.usesCustomMinutes {
                Stepper("\(model.customMinutes)分", value: $model.customMinutes, in: 1...180)
            }
            HStack {
                Text("休憩時間").font(.caption).foregroundStyle(.secondary)
                Spacer()
                restPresetButton(5)
                restPresetButton(10)
            }
            Stepper("細かく調整：\(model.restMinutes)分", value: $model.restMinutes, in: 1...60)
            HStack {
                Text("アラーム").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("アラーム", selection: $model.alarmDuration) {
                    Text("5秒").tag(5)
                    Text("10秒").tag(10)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 130)
            }
        }
    }

    private func presetButton(_ minutes: Int) -> some View {
        Button("\(minutes)分") { model.select(minutes: minutes) }
            .buttonStyle(.bordered)
            .tint(!model.usesCustomMinutes && model.selectedMinutes == minutes ? model.phase.color : .secondary)
    }

    private func restPresetButton(_ minutes: Int) -> some View {
        Button("\(minutes)分") { model.restMinutes = minutes }
            .buttonStyle(.bordered)
            .tint(model.restMinutes == minutes ? model.phase.color : .secondary)
    }
}

@main
private struct FocusLoopApp: App {
    @StateObject private var model = FocusTimer()

    var body: some Scene {
        MenuBarExtra {
            TimerView(model: model)
        } label: {
            Label(model.menuTitle, systemImage: model.phase.symbol)
        }
        .menuBarExtraStyle(.window)
    }
}
