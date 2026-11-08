import AppKit
import SwiftUI

/// A small floating card in the top-right corner ("Call started in WhatsApp — Record?").
/// Doesn't steal focus from the call app.
final class PromptPanel {
    private var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?

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
        panel?.orderOut(nil)
        panel = nil
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
        if let screen = NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.maxX - panel.frame.width - 16, y: area.maxY - panel.frame.height - 12))
        }
        panel.orderFrontRegardless()
        self.panel = panel

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
