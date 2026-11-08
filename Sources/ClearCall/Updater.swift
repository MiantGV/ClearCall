import AppKit
import Foundation
import Security

/// Built-in updates from the ClearCall GitHub releases.
/// Downloads happen inside the app (not a browser), so macOS doesn't block the new version,
/// and the signature pins the bundle identifier, so permissions carry over.
final class Updater: ObservableObject {
    static let shared = Updater()

    static let repo = "MiantGV/ClearCall"
    private static let checkInterval: TimeInterval = 6 * 3600

    struct Release: Equatable {
        let version: String      // "0.1.15"
        let build: Int           // 15
        let zipURL: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?

    var availableRelease: Release? {
        if case .available(let release) = state { return release }
        return nil
    }

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    var currentBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }

    private var timer: Timer?

    func startAutomaticChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.check() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in self?.check() }
    }

    // MARK: Check

    func check() {
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        state = .checking
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClearCall/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async { self?.handleCheck(data: data, response: response, error: error) }
        }.resume()
    }

    private func handleCheck(data: Data?, response: URLResponse?, error: Error?) {
        lastChecked = Date()
        guard error == nil, let data, (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]]
        else {
            let code = (response as? HTTPURLResponse)?.statusCode
            state = .failed(code == 404 ? "Updates aren't reachable. The ClearCall repository needs to be public."
                                        : "Couldn't check for updates. Check your internet connection.")
            return
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let build = Int(version.split(separator: ".").last ?? "") ?? 0
        guard build > currentBuild,
              let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let urlString = asset["browser_download_url"] as? String,
              let url = URL(string: urlString)
        else {
            state = .upToDate
            return
        }
        state = .available(Release(version: version, build: build, zipURL: url))
    }

    // MARK: Install

    func install() {
        guard let release = availableRelease else { return }
        guard !AppController.shared.isRecording else {
            state = .failed("Stop the recording before updating.")
            return
        }
        let appURL = Bundle.main.bundleURL
        if appURL.path.contains("/AppTranslocation/") {
            state = .failed("Move ClearCall into your Applications folder first, then update.")
            return
        }
        guard FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path) else {
            state = .failed("ClearCall can't replace itself in \(appURL.deletingLastPathComponent().path).")
            return
        }
        state = .downloading
        URLSession.shared.downloadTask(with: release.zipURL) { [weak self] tempURL, response, error in
            guard let self else { return }
            guard let tempURL, error == nil, (response as? HTTPURLResponse)?.statusCode == 200 else {
                DispatchQueue.main.async { self.state = .failed("The download failed. Please try again.") }
                return
            }
            do {
                let newApp = try self.unpackAndVerify(zip: tempURL, expectedBuild: release.build)
                DispatchQueue.main.async {
                    self.state = .installing
                    self.replaceAndRelaunch(with: newApp, at: appURL)
                }
            } catch {
                DispatchQueue.main.async { self.state = .failed(error.localizedDescription) }
            }
        }.resume()
    }

    private func unpackAndVerify(zip: URL, expectedBuild: Int) throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ClearCall-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zipCopy = work.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: zip, to: zipCopy)
        guard run("/usr/bin/ditto", ["-x", "-k", zipCopy.path, work.path]) == 0 else {
            throw CaptureError.message("The update couldn't be unpacked.")
        }
        let newApp = work.appendingPathComponent("ClearCall.app")
        guard let bundle = Bundle(url: newApp),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") == expectedBuild
        else {
            throw CaptureError.message("The downloaded update isn't a valid ClearCall version.")
        }
        guard Self.satisfiesOurRequirement(newApp) else {
            throw CaptureError.message("The update's signature doesn't match ClearCall, so it wasn't installed.")
        }
        return newApp
    }

    /// The new app must be validly signed and meet the same designated requirement as this one.
    private static func satisfiesOurRequirement(_ url: URL) -> Bool {
        var selfCode: SecCode?
        var selfStatic: SecStaticCode?
        var requirement: SecRequirement?
        var newCode: SecStaticCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess, let selfStatic,
              SecCodeCopyDesignatedRequirement(selfStatic, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(url as CFURL, [], &newCode) == errSecSuccess, let newCode
        else { return false }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSStrictValidate) | UInt32(kSecCSCheckNestedCode))
        return SecStaticCodeCheckValidity(newCode, flags, requirement) == errSecSuccess
    }

    /// Swaps the app once this process has quit, then opens the new version.
    private func replaceAndRelaunch(with newApp: URL, at appURL: URL) {
        let script = """
        pid="$1"; old="$2"; new="$3"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        backup="${old%.app}.previous.app"
        rm -rf "$backup"
        if mv "$old" "$backup" && mv "$new" "$old"; then
          rm -rf "$backup"
        else
          [ -d "$backup" ] && [ ! -d "$old" ] && mv "$backup" "$old"
        fi
        xattr -dr com.apple.quarantine "$old" 2>/dev/null
        open "$old"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "clearcall-update",
                             String(ProcessInfo.processInfo.processIdentifier), appURL.path, newApp.path]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed("Couldn't start the update: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
