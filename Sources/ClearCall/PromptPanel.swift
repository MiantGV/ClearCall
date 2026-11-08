import AppKit
import SwiftUI

/// A small floating card in the top-right corner ("Call started in WhatsApp — Record?").
/// Doesn't steal focus from the call app.
final class PromptPanel {
    private var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?
    private var moveObserver: NSObjectProtocol?

    func showCallStarted(_ call: CallDetector.Call, record: @escaping () -> Void) {
        show(PromptCard(icon: "phone.fill",
                        title: "Call started in \(call.appName)",
                        subtitle: "Record it with ClearCall?",
                        primary: ("Record", { [weak self] in self?.hide(); record() }),
                        secondary: ("Not now", { [weak self] in self?.hide() })),
             autoHideAfter: 45)
    }

    func showSaved(_ file: URL, source: String?, reveal: @escaping () -> Void) {
        let title = source.map { "\($0) call ended" } ?? "Recording saved"
        show(PromptCard(icon: "checkmark.circle.fill",
                        title: title,
                        subtitle: "Saved \(file.deletingPathExtension().lastPathComponent)",
                        primary: ("Show", { [weak self] in self?.hide(); reveal() }),
                        secondary: ("Close", { [weak self] in self?.hide() })),
             autoHideAfter: 12)
    }

    func hide() {
        dismissWork?.cancel()
        dismissWork = nil
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: Position

    /// The screen you're working on (where the mouse is).
    private static var currentScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// Default: bottom of the screen, just right of centre (beside Wispr Flow's card), above the Dock.
    /// After you drag the card, its spot is kept relative to the bottom centre of whichever screen is in use.
    private static func position(for size: NSSize) -> NSPoint {
        guard let area = currentScreen?.visibleFrame else { return .zero }
        let defaults = UserDefaults.standard
        let dx = defaults.object(forKey: "promptOffsetX") as? Double ?? 200
        let dy = defaults.object(forKey: "promptOffsetY") as? Double ?? 24
        var x = area.midX + dx
        var y = area.minY + dy
        x = min(max(x, area.minX + 8), area.maxX - size.width - 8)
        y = min(max(y, area.minY + 8), area.maxY - size.height - 8)
        return NSPoint(x: x, y: y)
    }

    private static func remember(_ frame: NSRect) {
        guard let area = (NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main)?.visibleFrame else { return }
        UserDefaults.standard.set(Double(frame.minX - area.midX), forKey: "promptOffsetX")
        UserDefaults.standard.set(Double(frame.minY - area.minY), forKey: "promptOffsetY")
    }

    static func resetPosition() {
        UserDefaults.standard.removeObject(forKey: "promptOffsetX")
        UserDefaults.standard.removeObject(forKey: "promptOffsetY")
    }

    private func show(_ card: PromptCard, autoHideAfter seconds: TimeInterval) {
        hide()
        let hosting = NSHostingView(rootView: card)
        hosting.frame.size = hosting.fittingSize
        let panel = ClickablePanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        panel.isMovableByWindowBackground = true     // drag it anywhere; the spot is remembered
        panel.setFrameOrigin(Self.position(for: panel.frame.size))
        panel.orderFrontRegardless()
        self.panel = panel
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { _ in
            Self.remember(panel.frame)
        }

        let work = DispatchWorkItem { [weak self] in self?.hide() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// A borderless panel that still takes clicks on the first try.
private final class ClickablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct PromptCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let primary: (String, () -> Void)
    let secondary: (String, () -> Void)

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Brand.gradient).frame(width: 38, height: 38)
                Image(systemName: icon).foregroundStyle(.white).font(.system(size: 16, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(spacing: 6) {
                Button(primary.0, action: primary.1)
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.violet)
                    .controlSize(.regular)
                Button(secondary.0, action: secondary.1)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(14)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08)))
        .padding(1)
    }
}
