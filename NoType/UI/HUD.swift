import AppKit
import Observation
import SwiftUI

enum HUDState: Equatable {
    case hidden
    case recording(handsFree: Bool)
    case processing
    case success
    case message(String, symbol: String)
}

@MainActor
@Observable
final class HUDModel {
    var state: HUDState = .hidden
}

/// The small Liquid Glass capsule at the bottom of the screen. It never takes focus or clicks.
@MainActor
final class HUDController {
    let model = HUDModel()
    private let meter: LevelMeter
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    private static let size = CGSize(width: 420, height: 120)
    private static let motion = Animation.spring(duration: 0.42, bounce: 0.22)

    init(meter: LevelMeter) {
        self.meter = meter
    }

    func show(_ state: HUDState) {
        hideTask?.cancel()
        let panel = self.panel ?? makePanel()
        if !panel.isVisible || model.state == .hidden {
            place(panel)
            panel.orderFrontRegardless()
        }
        withAnimation(Self.motion) { model.state = state }
    }

    /// Shows a state briefly, then fades out.
    func flash(_ state: HUDState, for duration: Duration? = nil) {
        show(state)
        let duration = duration ?? (state == .success ? .milliseconds(650) : .milliseconds(1_900))
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        guard model.state != .hidden else { return }
        withAnimation(.smooth(duration: 0.28)) { model.state = .hidden }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self, self.model.state == .hidden else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let host = NSHostingView(rootView: HUDView(model: model, meter: meter))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        return panel
    }

    /// Bottom centre of the screen the pointer is on, just above the Dock.
    private func place(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrameOrigin(CGPoint(x: visible.midX - Self.size.width / 2, y: visible.minY + 6))
    }
}

struct HUDView: View {
    let model: HUDModel
    let meter: LevelMeter

    @Namespace private var glass

    var body: some View {
        GlassEffectContainer {
            if model.state != .hidden {
                content
                    .padding(.horizontal, horizontalPadding)
                    .frame(height: 40)
                    .glassEffect(.regular, in: .capsule)
                    .glassEffectID("hud", in: glass)
                    .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 14)
    }

    private var horizontalPadding: CGFloat {
        if case .success = model.state { return 12 }
        return 16
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .recording(let handsFree):
            HStack(spacing: 10) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, options: .repeating)
                Waveform(meter: meter, listening: true)
                if handsFree {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        case .processing:
            Waveform(meter: meter, listening: false)
        case .success:
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .transition(.scale.combined(with: .opacity))
        case .message(let text, let symbol):
            Label(text, systemImage: symbol)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .fixedSize()
        case .hidden:
            EmptyView()
        }
    }
}

/// Level bars that follow the voice while listening and turn into a soft travelling wave while
/// the text is being recognized. Updated every display frame from the lock-free meter; plain
/// shapes in the primary style, so the glass can adapt their colour to what is behind it.
private struct Waveform: View {
    let meter: LevelMeter
    let listening: Bool

    @State private var motion = WaveMotion()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let bars = 13
    private static let barWidth: CGFloat = 3.5
    private static let gap: CGFloat = 3
    private static let height: CGFloat = 22

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let (level, thinking) = motion.advance(
                to: time, level: listening ? meter.level : 0, thinking: listening ? 0 : 1)
            HStack(spacing: Self.gap) {
                ForEach(0 ..< Self.bars, id: \.self) { index in
                    Capsule()
                        .frame(width: Self.barWidth, height: barHeight(index, time: time, level: level, thinking: thinking))
                }
            }
            .frame(height: Self.height)
        }
        .foregroundStyle(.primary)
    }

    private func barHeight(_ index: Int, time: TimeInterval, level: Float, thinking: Double) -> CGFloat {
        let position = Double(index) / Double(Self.bars - 1)
        let envelope = 0.35 + 0.65 * sin(.pi * (Double(index) + 0.5) / Double(Self.bars))
        let wobble = reduceMotion ? 1 : 0.62 + 0.38 * sin(time * 8.5 + Double(index) * 1.9)
        let voice = min(1, Double(level) * 1.35) * envelope * wobble
        let wave = reduceMotion ? 0.3 : 0.18 + 0.22 * (0.5 + 0.5 * sin(time * 5.5 - position * 5.2))
        let amount = voice * (1 - thinking) + wave * thinking
        return max(Self.barWidth, CGFloat(amount) * Self.height)
    }
}

/// Smooths the bursty meter (fast attack, slow release) and blends between listening and thinking.
private final class WaveMotion {
    private var level: Float = 0
    private var thinking: Double = 0
    private var lastTime: TimeInterval = 0

    func advance(to time: TimeInterval, level target: Float, thinking thinkingTarget: Double) -> (Float, Double) {
        let step = lastTime == 0 ? 1.0 / 60 : min(max(time - lastTime, 0), 0.1)
        lastTime = time
        let response: Float = target > level ? 0.045 : 0.16
        level += (target - level) * (1 - exp(-Float(step) / response))
        thinking += (thinkingTarget - thinking) * (1 - exp(-step / 0.22))
        return (level, thinking)
    }
}
