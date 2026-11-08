import AppKit
import SwiftUI

/// A small dark pill at the bottom of the screen while ClearCall records:
/// red dot, live waveform, timer and a stop button. Draggable; its spot is remembered.
final class RecordingPill {
    private var panel: NSPanel?
    private var moveObserver: NSObjectProtocol?

    var isVisible: Bool { panel != nil }

    func show(stop: @escaping () -> Void) {
        guard panel == nil else { return }
        let hosting = NSHostingView(rootView: PillView(stop: stop))
        hosting.frame.size = hosting.fittingSize
        let panel = PillPanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                              styleMask: [.nonactivatingPanel, .borderless],
                              backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hosting
        panel.setFrameOrigin(Self.position(for: panel.frame.size))
        panel.orderFrontRegardless()
        self.panel = panel
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { _ in
            Self.remember(panel.frame)
        }
    }

    func hide() {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: Position (bottom of the screen you're working on, just right of centre)

    private static func position(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return .zero }
        let defaults = UserDefaults.standard
        let dx = defaults.object(forKey: "pillOffsetX") as? Double ?? 90
        let dy = defaults.object(forKey: "pillOffsetY") as? Double ?? 14
        let x = min(max(area.midX + dx, area.minX + 8), area.maxX - size.width - 8)
        let y = min(max(area.minY + dy, area.minY + 4), area.maxY - size.height - 8)
        return NSPoint(x: x, y: y)
    }

    private static func remember(_ frame: NSRect) {
        guard let area = (NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main)?.visibleFrame else { return }
        UserDefaults.standard.set(Double(frame.minX - area.midX), forKey: "pillOffsetX")
        UserDefaults.standard.set(Double(frame.minY - area.minY), forKey: "pillOffsetY")
    }

    static func resetPosition() {
        UserDefaults.standard.removeObject(forKey: "pillOffsetX")
        UserDefaults.standard.removeObject(forKey: "pillOffsetY")
    }
}

private final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct PillView: View {
    @ObservedObject var controller = AppController.shared
    var stop: () -> Void
    @State private var blink = false
    @State private var hoverStop = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Brand.red)
                .frame(width: 9, height: 9)
                .opacity(blink ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: blink)
                .onAppear { blink = true }

            PillWaveform(levels: controller.levelHistory)
                .frame(width: 46, height: 18)

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(elapsed)
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
            }

            Button(action: stop) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(hoverStop ? 0.28 : 0.16))
                        .frame(width: 26, height: 26)
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(.white)
                        .frame(width: 10, height: 10)
                }
            }
            .buttonStyle(.plain)
            .onHover { hoverStop = $0 }
            .help("Stop recording")
            .accessibilityLabel("Stop recording")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.88))
                .overlay(Capsule().strokeBorder(Brand.gradient.opacity(0.9), lineWidth: 1.5))
        )
        .padding(2)
        .help(controller.recordingSource.map { "ClearCall is recording your \($0) call" } ?? "ClearCall is recording")
    }

    private var elapsed: String {
        guard let start = controller.startedAt else { return "00:00" }
        let s = Int(Date().timeIntervalSince(start))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Recent sound levels as mirrored bars, newest on the right.
struct PillWaveform: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geo in
            let count = 9
            let gap: CGFloat = 2
            let width = (geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count)
            let values = Array((Array(repeating: Float(0), count: count) + levels).suffix(count))
            HStack(alignment: .center, spacing: gap) {
                ForEach(0..<count, id: \.self) { i in
                    Capsule()
                        .fill(Color.white)
                        .frame(width: width, height: max(3, geo.size.height * CGFloat(values[i])))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.linear(duration: 0.1), value: levels)
        }
    }
}
