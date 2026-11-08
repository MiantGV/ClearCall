import AppKit
import CoreAudio
import Foundation

/// Notices when a calling app starts or stops using the microphone.
/// Uses Core Audio's per-process "is running input" flag (macOS 14+). No extra permission needed.
final class CallDetector {
    struct Call: Equatable {
        let appName: String
        let bundleID: String
    }

    var onCallStarted: ((Call) -> Void)?
    var onCallEnded: ((Call) -> Void)?
    private(set) var activeCall: Call?

    private var timer: Timer?
    private var firstSeen: [String: Date] = [:]   // app name -> when it started using the mic
    private var goneSince: Date?

    /// A call app must use the mic this long before it counts as a call (filters out quick mic checks).
    private let startDelay: TimeInterval = 1
    /// …and stop using it this long before the call counts as ended.
    private let endDelay: TimeInterval = 4

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        firstSeen = [:]
        goneSince = nil
        activeCall = nil
    }

    private func poll() {
        let calls = Self.callAppsUsingMic()
        let now = Date()

        if let active = activeCall {
            if calls.contains(where: { $0.appName == active.appName }) {
                goneSince = nil
            } else if let since = goneSince {
                if now.timeIntervalSince(since) >= endDelay {
                    activeCall = nil
                    goneSince = nil
                    firstSeen = [:]
                    onCallEnded?(active)
                }
            } else {
                goneSince = now
            }
            return
        }

        let names = Set(calls.map(\.appName))
        firstSeen = firstSeen.filter { names.contains($0.key) }
        for call in calls {
            if let seen = firstSeen[call.appName] {
                if now.timeIntervalSince(seen) >= startDelay {
                    activeCall = call
                    firstSeen = [:]
                    goneSince = nil
                    onCallStarted?(call)
                    return
                }
            } else {
                firstSeen[call.appName] = now
            }
        }
    }

    // MARK: - Which apps count as calls

    /// Bundle ID prefixes of apps used for calls. Browsers are included for web calls (Meet, Teams, Zoom web).
    static let knownApps: [(prefix: String, name: String)] = [
        ("net.whatsapp.WhatsApp", "WhatsApp"),
        ("desktop.WhatsApp", "WhatsApp"),
        ("us.zoom", "Zoom"),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.apple.avconferenced", "FaceTime"),
        ("com.apple.mobilephone", "Phone"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.hnc.Discord", "Discord"),
        ("com.skype", "Skype"),
        ("Cisco-Systems.Spark", "Webex"),
        ("com.cisco.webexmeetings", "Webex"),
        ("com.webex", "Webex"),
        ("ru.keepcoder.Telegram", "Telegram"),
        ("org.telegram", "Telegram"),
        ("com.tdesktop.Telegram", "Telegram"),
        ("com.viber.osx", "Viber"),
        ("org.whispersystems.signal-desktop", "Signal"),
        ("com.ringcentral", "RingCentral"),
        ("com.google.Chrome", "Google Chrome"),
        ("com.microsoft.edgemac", "Microsoft Edge"),
        ("company.thebrowser", "Arc"),
        ("com.brave.Browser", "Brave"),
        ("org.mozilla.firefox", "Firefox"),
        ("com.apple.Safari", "Safari"),
        ("com.apple.WebKit", "Safari"),
        ("com.operasoftware", "Opera"),
        ("com.vivaldi", "Vivaldi"),
    ]

    static func callAppsUsingMic() -> [Call] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var result: [Call] = []
        for (pid, bundleID) in processesUsingMic() where pid != ownPID {
            guard let match = knownApps.first(where: { bundleID.hasPrefix($0.prefix) }) else { continue }
            if !result.contains(where: { $0.appName == match.name }) {
                result.append(Call(appName: match.name, bundleID: bundleID))
            }
        }
        return result
    }

    /// Every process currently capturing from an input device, with its bundle ID.
    static func processesUsingMic() -> [(pid: pid_t, bundleID: String)] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }

        var result: [(pid_t, String)] = []
        for object in objects {
            guard readUInt32(object, kAudioProcessPropertyIsRunningInput) == 1 else { continue }
            let pid = readPID(object)
            var bundleID = readString(object, kAudioProcessPropertyBundleID) ?? ""
            if bundleID.isEmpty, pid > 0 {
                bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            }
            result.append((pid, bundleID))
        }
        return result
    }

    private static func propertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func readUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = propertyAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : 0
    }

    private static func readPID(_ object: AudioObjectID) -> pid_t {
        var address = propertyAddress(kAudioProcessPropertyPID)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : -1
    }

    private static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = propertyAddress(selector)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let err = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        return err == noErr ? value as String : nil
    }
}
