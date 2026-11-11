//
//  OrchestraUpdater.swift
//  leanring-buddy
//
//  "Check for updates" without leaving the app:
//    1. asks GitHub for the latest release of the public repo (build-N)
//    2. downloads Orchestra.dmg, mounts it, and checks the app inside is
//       signed by the SAME certificate as the running app (so a tampered
//       download can never be installed, and macOS keeps its permissions)
//    3. swaps it into place and relaunches.
//
//  Only works when the running app is signed with Orchestra's own
//  certificate; an ad-hoc signed copy can't prove anything, so it refuses
//  (fails closed) and says to update by hand.
//

import AppKit
import Combine
import Foundation
import Security

@MainActor
final class OrchestraUpdater: ObservableObject {
    static let shared = OrchestraUpdater()

    enum UpdateState: Equatable {
        case idle
        case checking
        case upToDate
        case available(buildNumber: Int)
        case installing(step: String)
        case failed(String)
    }

    @Published private(set) var updateState: UpdateState = .idle

    private static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/afklongerenough/orchestra-mac/releases/latest")!
    private static let periodicCheckIntervalSeconds: TimeInterval = 6 * 60 * 60

    private var latestDMGDownloadURL: URL?
    private var periodicCheckTimer: Timer?

    /// CFBundleVersion is stamped with the CI run number (build-N).
    var currentBuildNumber: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    func startPeriodicChecks() {
        guard periodicCheckTimer == nil else { return }
        Task { await checkForUpdates() }
        periodicCheckTimer = Timer.scheduledTimer(withTimeInterval: Self.periodicCheckIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Don't interrupt an install or hide an update that's already waiting.
                switch self.updateState {
                case .installing, .available, .checking: return
                default: break
                }
                await self.checkForUpdates()
            }
        }
    }

    // MARK: - Check

    func checkForUpdates() async {
        guard currentBuildNumber > 0 else {
            updateState = .failed("can't tell this copy's build number; update by hand once")
            return
        }
        updateState = .checking
        var request = URLRequest(url: Self.latestReleaseAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("orchestra-mac-updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let releaseJSON = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let tagName = releaseJSON["tag_name"] as? String,
                  let latestBuildNumber = Int(tagName.replacingOccurrences(of: "build-", with: "")),
                  let assets = releaseJSON["assets"] as? [[String: Any]],
                  let dmgAsset = assets.first(where: { ($0["name"] as? String) == "Orchestra.dmg" }),
                  let downloadURLText = dmgAsset["browser_download_url"] as? String,
                  let downloadURL = URL(string: downloadURLText) else {
                updateState = .failed("couldn't read the latest release")
                return
            }
            latestDMGDownloadURL = downloadURL
            updateState = latestBuildNumber > currentBuildNumber ? .available(buildNumber: latestBuildNumber) : .upToDate
        } catch {
            updateState = .failed("couldn't reach GitHub (\(error.localizedDescription))")
        }
    }

    // MARK: - Install

    func installAvailableUpdate() async {
        guard case .available = updateState, let latestDMGDownloadURL else { return }
        do {
            try await downloadVerifyAndInstall(from: latestDMGDownloadURL)
        } catch {
            OrchestraLog.write("⬆️ Update failed: \(error.localizedDescription)")
            updateState = .failed(error.localizedDescription)
        }
    }

    private struct UpdateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func downloadVerifyAndInstall(from dmgDownloadURL: URL) async throws {
        // The running app must have a real signature to compare against.
        guard let runningAppRequirement = Self.designatedRequirementOfRunningApp() else {
            throw UpdateError(message: "this copy of Orchestra isn't signed with Orchestra's certificate, so it can't check updates. download the newest DMG by hand once.")
        }

        updateState = .installing(step: "downloading")
        let (downloadedTemporaryURL, response) = try await URLSession.shared.download(from: dmgDownloadURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError(message: "the download failed")
        }
        let workingFolderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("orchestra-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingFolderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingFolderURL) }
        let dmgFileURL = workingFolderURL.appendingPathComponent("Orchestra.dmg")
        try FileManager.default.moveItem(at: downloadedTemporaryURL, to: dmgFileURL)

        updateState = .installing(step: "checking the signature")
        let mountPointURL = workingFolderURL.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPointURL, withIntermediateDirectories: true)
        try await Self.runTool("/usr/bin/hdiutil", arguments: ["attach", dmgFileURL.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPointURL.path])
        defer {
            let detachProcess = Process()
            detachProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detachProcess.arguments = ["detach", mountPointURL.path, "-force"]
            try? detachProcess.run()
            detachProcess.waitUntilExit()
        }

        // Copy out of the read-only image first, then check that copy (what we install is what we checked).
        let mountedAppURL = mountPointURL.appendingPathComponent("Orchestra.app", isDirectory: true)
        let stagedAppURL = workingFolderURL.appendingPathComponent("Orchestra.app", isDirectory: true)
        try await Self.runTool("/usr/bin/ditto", arguments: [mountedAppURL.path, stagedAppURL.path])
        // A quarantine flag (if the download got one) would make Gatekeeper block the relaunch.
        try? await Self.runTool("/usr/bin/xattr", arguments: ["-dr", "com.apple.quarantine", stagedAppURL.path])
        try Self.verifySignature(ofAppAt: stagedAppURL, satisfies: runningAppRequirement)

        let stagedBuildNumber = Int(Bundle(url: stagedAppURL)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        guard stagedBuildNumber > currentBuildNumber else {
            throw UpdateError(message: "the download isn't newer than this build")
        }

        updateState = .installing(step: "installing")
        let installedAppURL = Bundle.main.bundleURL
        // Put the new copy next to the old one (same volume), then swap atomically.
        let besideInstalledAppURL = installedAppURL.deletingLastPathComponent()
            .appendingPathComponent(".Orchestra-update-\(stagedBuildNumber).app", isDirectory: true)
        try? FileManager.default.removeItem(at: besideInstalledAppURL)
        try await Self.runTool("/usr/bin/ditto", arguments: [stagedAppURL.path, besideInstalledAppURL.path])
        do {
            _ = try FileManager.default.replaceItemAt(installedAppURL, withItemAt: besideInstalledAppURL)
        } catch {
            try? FileManager.default.removeItem(at: besideInstalledAppURL)
            throw UpdateError(message: "couldn't replace Orchestra in \(installedAppURL.deletingLastPathComponent().path) (\(error.localizedDescription))")
        }
        OrchestraLog.write("⬆️ Updated to build \(stagedBuildNumber); relaunching")

        updateState = .installing(step: "restarting")
        // Reopen once this process has really exited (waits on our pid, up to ~30 s).
        let relaunchProcess = Process()
        relaunchProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunchProcess.arguments = [
            "-c",
            "for attempt in $(seq 1 150); do /bin/kill -0 \"$1\" 2>/dev/null || break; sleep 0.2; done; /usr/bin/open -n \"$0\"",
            installedAppURL.path,
            String(ProcessInfo.processInfo.processIdentifier)
        ]
        try relaunchProcess.run()
        NSApp.terminate(nil)
    }

    // MARK: - Signature checks

    /// The running app's designated requirement, or nil if it's ad-hoc signed
    /// (an ad-hoc requirement is just this build's hash, which no update can match).
    private static func designatedRequirementOfRunningApp() -> SecRequirement? {
        var runningCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &runningCode) == errSecSuccess, let runningCode else { return nil }
        var runningStaticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(runningCode, SecCSFlags(), &runningStaticCode) == errSecSuccess,
              let runningStaticCode else { return nil }

        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(runningStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInformation) == errSecSuccess,
              let signingInformationDictionary = signingInformation as? [String: Any],
              let certificates = signingInformationDictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
              !certificates.isEmpty else {
            return nil
        }

        var designatedRequirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(runningStaticCode, SecCSFlags(), &designatedRequirement) == errSecSuccess else { return nil }
        return designatedRequirement
    }

    private static func verifySignature(ofAppAt appURL: URL, satisfies requirement: SecRequirement) throws {
        var downloadedStaticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, SecCSFlags(), &downloadedStaticCode) == errSecSuccess,
              let downloadedStaticCode else {
            throw UpdateError(message: "couldn't read the downloaded app")
        }
        let validityFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let validityStatus = SecStaticCodeCheckValidity(downloadedStaticCode, validityFlags, requirement)
        guard validityStatus == errSecSuccess else {
            throw UpdateError(message: "the download isn't signed by Orchestra's certificate (code \(validityStatus)), so it wasn't installed")
        }
    }

    // MARK: - Helpers

    private static func runTool(_ toolPath: String, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: toolPath)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finishedProcess in
                if finishedProcess.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let toolName = URL(fileURLWithPath: toolPath).lastPathComponent
                    continuation.resume(throwing: UpdateError(message: "\(toolName) failed (exit \(finishedProcess.terminationStatus))"))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
