import AppKit
import SwiftUI

enum Brand {
    static let blue = Color(red: 0x5B / 255, green: 0x86 / 255, blue: 0xFF / 255)
    static let violet = Color(red: 0x7A / 255, green: 0x3C / 255, blue: 0xF0 / 255)
    static let gradient = LinearGradient(colors: [blue, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let red = Color(red: 0.93, green: 0.26, blue: 0.27)
}

struct MainView: View {
    @ObservedObject var controller = AppController.shared
    @ObservedObject var settings = AppSettings.shared
    var openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 34)   // room for the window buttons
                .padding(.horizontal, 22)

            RecordButton(isRecording: controller.isRecording) { controller.toggle() }
                .padding(.top, 22)

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(elapsed)
                    .font(.system(size: 30, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(controller.isRecording ? .primary : .tertiary)
            }
            .padding(.top, 14)

            Text(statusLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
                .frame(height: 20)

            VStack(spacing: 10) {
                LevelRow(label: "You", icon: "mic.fill", level: controller.micLevel, active: controller.isRecording)
                LevelRow(label: "Call", icon: "speaker.wave.2.fill", level: controller.callLevel, active: controller.isRecording)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
            .padding(.horizontal, 22)
            .padding(.top, 18)

            recentList
                .padding(.horizontal, 22)
                .padding(.top, 18)

            Spacer(minLength: 12)
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(width: 380, height: 600)
        .onAppear { controller.refreshRecent() }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
            Text("ClearCall")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
            Spacer()
            StatusPill(isRecording: controller.isRecording, call: controller.activeCall?.appName)
        }
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent recordings")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Show all") { settings.revealFolder() }
                    .buttonStyle(.link)
                    .font(.subheadline)
            }
            if controller.recent.isEmpty {
                Text("Your recordings will appear here.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                VStack(spacing: 2) {
                    ForEach(controller.recent) { item in
                        RecordingRow(item: item,
                                     isNew: item.url == controller.lastSaved,
                                     open: { controller.open(item.url) },
                                     reveal: { controller.reveal(item.url) })
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                settings.revealFolder()
            } label: {
                Label(folderName, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.borderless)
            .help("Recordings are saved in \(settings.saveFolder.path)")
            Spacer()
            Button(action: openSettings) {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    // MARK: Text

    private var elapsed: String {
        guard let start = controller.startedAt else { return "00:00" }
        let s = Int(Date().timeIntervalSince(start))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }

    private var statusLine: String {
        if controller.isRecording {
            if let source = controller.recordingSource { return "Recording your \(source) call" }
            return "Recording"
        }
        if let call = controller.activeCall?.appName { return "Call in progress in \(call) — click to record" }
        return "Click to start recording"
    }

    private var folderName: String {
        settings.saveFolder.lastPathComponent
    }
}

// MARK: - Components

struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void
    @State private var pulse = false
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRecording {
                    Circle()
                        .stroke(Brand.red.opacity(0.35), lineWidth: 6)
                        .frame(width: 136, height: 136)
                        .scaleEffect(pulse ? 1.12 : 0.96)
                        .opacity(pulse ? 0 : 1)
                        .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: pulse)
                }
                Circle()
                    .fill(isRecording ? AnyShapeStyle(Brand.red) : AnyShapeStyle(Brand.gradient))
                    .frame(width: 120, height: 120)
                    .shadow(color: (isRecording ? Brand.red : Brand.violet).opacity(0.35), radius: hover ? 16 : 10, y: 6)
                if isRecording {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.white)
                        .frame(width: 38, height: 38)
                } else {
                    Circle()
                        .fill(.white)
                        .frame(width: 44, height: 44)
                }
            }
            .frame(width: 150, height: 150)
            .contentShape(Circle())
            .scaleEffect(hover ? 1.03 : 1)
            .animation(.easeOut(duration: 0.15), value: hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .onAppear { pulse = isRecording }
        .onChange(of: isRecording) { _, recording in pulse = recording }
        .keyboardShortcut("r", modifiers: .command)
        .help(isRecording ? "Stop recording (⌘R)" : "Start recording (⌘R)")
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

struct LevelRow: View {
    let label: String
    let icon: String
    let level: Float
    let active: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.callout)
                .frame(width: 34, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(Brand.gradient)
                        .frame(width: max(0, geo.size.width * CGFloat(active ? level : 0)))
                        .animation(.linear(duration: 0.08), value: level)
                }
            }
            .frame(height: 8)
        }
    }
}

struct StatusPill: View {
    let isRecording: Bool
    let call: String?

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.14)))
    }

    private var text: String {
        if isRecording { return "Recording" }
        if let call { return "Call: \(call)" }
        return "Ready"
    }

    private var color: Color {
        if isRecording { return Brand.red }
        if call != nil { return .orange }
        return .green
    }
}

struct RecordingRow: View {
    let item: RecordingItem
    let isNew: Bool
    let open: () -> Void
    let reveal: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .foregroundStyle(Brand.violet)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.dateText(item.date))
                    .font(.callout)
                    .lineLimit(1)
                Text(Self.durationText(item.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isNew {
                Text("New")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Brand.blue.opacity(0.15)))
            }
            Spacer()
            if hover {
                Button(action: open) { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless)
                    .help("Play")
                Button(action: reveal) { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2, perform: open)
        .help(item.title)
    }

    static func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    static func durationText(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        if s >= 3600 { return String(format: "%d h %02d min", s / 3600, (s / 60) % 60) }
        if s >= 60 { return String(format: "%d min %02d s", s / 60, s % 60) }
        return "\(s) s"
    }
}
