import Foundation

/// Generates zero-patch macOS `.app` launcher bundles in `~/Applications` for each Claude Desktop account.
/// Launchers route through `claudedock open` so Egress Guard runs even when clicked directly from Dock/Spotlight.
public final class LauncherBuilder: Sendable {
    public let homeDirectory: URL
    public let appsDirectory: URL
    private var fm: FileManager { .default }

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        appsDirectory: URL? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.appsDirectory = appsDirectory ?? homeDirectory.appendingPathComponent("Applications", isDirectory: true)
    }

    public static func locateClaudeApp(customPath: String? = nil, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        var candidates: [String] = []
        if let c = customPath, !c.isEmpty { candidates.append(c) }
        if let envPath = ProcessInfo.processInfo.environment["CLAUDE_APP"], !envPath.isEmpty {
            candidates.append(envPath)
        }
        candidates.append("/Applications/Claude.app")
        candidates.append(homeDirectory.appendingPathComponent("Applications/Claude.app").path)

        let fm = FileManager.default
        for path in candidates {
            let exe = URL(fileURLWithPath: path).appendingPathComponent("Contents/MacOS/Claude").path
            if fm.isExecutableFile(atPath: exe) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    public func createOrUpdateLauncher(for account: AccountProfile, claudeAppURL: URL) throws -> URL {
        try Validation.validateAccountName(account.name)
        try fm.createDirectory(at: appsDirectory, withIntermediateDirectories: true)

        let appURL = account.launcherAppURL(appsDirectory: appsDirectory)
        // Never overwrite an existing unmanaged .app bundle or follow symlinks.
        if fm.fileExists(atPath: appURL.path) {
            let attrs = try fm.attributesOfItem(atPath: appURL.path)
            if (attrs[.type] as? FileAttributeType) == .typeSymbolicLink || !isManagedLauncher(appURL) {
                throw DockError.launcherOperationFailed("Refusing to overwrite existing unmanaged app at '\(appURL.path)'")
            }
        }

        // Stage the entire bundle in a private sibling directory, then atomically swap into place
        let stageDir = appsDirectory.appendingPathComponent(".claudedock-stage-\(UUID().uuidString).app", isDirectory: true)
        defer { try? fm.removeItem(at: stageDir) }

        let macOSDir = stageDir.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let resourcesDir = stageDir.appendingPathComponent("Contents/Resources", isDirectory: true)
        try fm.createDirectory(at: macOSDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])

        let plist = buildInfoPlist(for: account)
        try plist.write(to: stageDir.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)

        let script = buildLauncherScript(for: account, claudeAppURL: claudeAppURL)
        let launcherURL = macOSDir.appendingPathComponent("launcher")
        try script.write(to: launcherURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherURL.path)

        let icnsURL = resourcesDir.appendingPathComponent("icon.icns")
        try? IconRenderer.renderICNS(
            style: account.iconStyle,
            label: account.name,
            colorHex: account.colorHex,
            claudeAppURL: claudeAppURL,
            outputICNSURL: icnsURL
        )

        if fm.fileExists(atPath: appURL.path) {
            _ = try fm.replaceItemAt(appURL, withItemAt: stageDir)
        } else {
            try fm.moveItem(at: stageDir, to: appURL)
        }

        refreshLaunchServices(appURL: appURL)
        return appURL
    }

    public func isManagedLauncher(_ appURL: URL) -> Bool {
        let launcherURL = appURL.appendingPathComponent("Contents/MacOS/launcher")
        guard let text = try? String(contentsOf: launcherURL, encoding: .utf8) else { return false }
        return text.contains(DockConstants.launcherMarker)
    }

    public func removeLauncher(for account: AccountProfile) throws {
        let appURL = account.launcherAppURL(appsDirectory: appsDirectory)
        guard fm.fileExists(atPath: appURL.path) else { return }
        guard isManagedLauncher(appURL) else {
            throw DockError.launcherOperationFailed("Refusing to remove '\(appURL.path)': not created by ClaudeDock")
        }
        unregisterLaunchServices(appURL: appURL)
        try fm.removeItem(at: appURL)
    }

    public func renameLauncher(from oldAccount: AccountProfile, to newAccount: AccountProfile, claudeAppURL: URL) throws -> URL {
        let oldURL = oldAccount.launcherAppURL(appsDirectory: appsDirectory)
        if fm.fileExists(atPath: oldURL.path) && isManagedLauncher(oldURL) {
            unregisterLaunchServices(appURL: oldURL)
            try fm.removeItem(at: oldURL)
        }
        return try createOrUpdateLauncher(for: newAccount, claudeAppURL: claudeAppURL)
    }

    /// Launches Claude Desktop directly with proper Electron flags (`--user-data-dir`, `--proxy-server`, `--lang`) and `TZ`.
    public func launchClaudeDesktopDirect(account: AccountProfile, claudeAppURL: URL) throws {
        let dataDir = account.userDataDirectory(homeDirectory: homeDirectory)
        try fm.createDirectory(at: dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        var openArgs: [String] = ["-n", "-a", claudeAppURL.path]

        // Pass isolated environment variables cleanly via macOS `open --env`
        if account.proxy.enabled {
            if let tz = account.proxy.timezone, !tz.isEmpty {
                try Validation.validateTimezone(tz)
                openArgs.append(contentsOf: ["--env", "TZ=\(tz)"])
            }
            openArgs.append(contentsOf: ["--env", "HTTP_PROXY=\(account.proxy.proxyURLString)"])
            openArgs.append(contentsOf: ["--env", "HTTPS_PROXY=\(account.proxy.proxyURLString)"])
            openArgs.append(contentsOf: ["--env", "ALL_PROXY=\(account.proxy.proxyURLString)"])
        }

        // Electron launch flags with leak-hardening (disable QUIC UDP bypass, WebRTC non-proxied UDP, SOCKS5 local DNS)
        var electronArgs: [String] = ["--user-data-dir=\(dataDir.path)"]
        if account.proxy.enabled {
            try Validation.validateProxy(account.proxy)
            electronArgs.append("--proxy-server=\(account.proxy.electronProxyArg)")
            if !account.proxy.bypassList.isEmpty {
                electronArgs.append("--proxy-bypass-list=\(account.proxy.bypassList)")
            }
            // Prevent QUIC/UDP and WebRTC from bypassing the configured TCP proxy
            electronArgs.append("--disable-quic")
            electronArgs.append("--force-webrtc-ip-handling-policy=disable_non_proxied_udp")
            if account.proxy.scheme == .socks5 {
                // Force remote DNS resolution via SOCKS5 proxy
                electronArgs.append("--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE localhost, EXCLUDE 127.0.0.1, EXCLUDE \(account.proxy.host)")
            }
            if let lang = account.proxy.language, !lang.isEmpty {
                try Validation.validateLanguage(lang)
                electronArgs.append("--lang=\(lang)")
            }
        }

        openArgs.append("--args")
        openArgs.append(contentsOf: electronArgs)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = openArgs
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice
        try proc.run()
        // Drain stderr BEFORE waitUntilExit to avoid pipe buffer deadlocks
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let errText = String(data: errData, encoding: .utf8) ?? ""
            throw DockError.launcherOperationFailed("Failed launching Claude Desktop: \(errText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    public func buildInfoPlist(for account: AccountProfile) -> String {
        let escapedName = xmlEscape("Claude \(account.name)")
        let bundleID = xmlEscape("\(DockConstants.bundleIDPrefix)\(account.slug)")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleName</key><string>\(escapedName)</string>
          <key>CFBundleDisplayName</key><string>\(escapedName)</string>
          <key>CFBundleIdentifier</key><string>\(bundleID)</string>
          <key>CFBundleExecutable</key><string>launcher</string>
          <key>CFBundleIconFile</key><string>icon</string>
          <key>CFBundlePackageType</key><string>APPL</string>
          <key>CFBundleShortVersionString</key><string>\(DockConstants.version)</string>
          <key>CFBundleVersion</key><string>\(DockConstants.version)</string>
          <key>LSUIElement</key><true/>
          <key>ClaudeDockAccountID</key><string>\(xmlEscape(account.id))</string>
          <key>ClaudeDockColorHex</key><string>\(xmlEscape(account.colorHex))</string>
        </dict>
        </plist>
        """
    }

    public func buildLauncherScript(for account: AccountProfile, claudeAppURL: URL) -> String {
        let quotedName = Self.shellQuote(account.name)
        let quotedApp = Self.shellQuote(claudeAppURL.path)
        let dataDir = account.userDataDirectory(homeDirectory: homeDirectory).path
        let quotedDataDir = Self.shellQuote(dataDir)
        let strictGuard = (account.egressPolicy.mode == .failClosed)

        let fallbackBlock: String
        if strictGuard {
            fallbackBlock = """
            /usr/bin/osascript -e 'display alert "ClaudeDock Egress Guard" message "claudedock CLI not found; refusing unguarded direct launch because Fail-Closed Egress Guard is enabled." as critical' >/dev/null 2>&1 || true
            exit 1
            """
        } else {
            var directFlags = "--user-data-dir=\(quotedDataDir)"
            if account.proxy.enabled {
                directFlags += " --proxy-server=\(Self.shellQuote(account.proxy.electronProxyArg))"
            }
            fallbackBlock = "exec /usr/bin/open -n -a \(quotedApp) --args \(directFlags)"
        }

        return """
        #!/bin/bash
        \(DockConstants.launcherMarker) (https://github.com/claudedock/claudedock)
        set -euo pipefail

        # Always route through claudedock so Fail-Closed Clash Egress Guard runs even from Dock/Spotlight
        for BIN in "/Applications/ClaudeDock.app/Contents/MacOS/claudedock" "$HOME/Applications/ClaudeDock.app/Contents/MacOS/claudedock" "/usr/local/bin/claudedock" "/opt/homebrew/bin/claudedock" "$HOME/.local/bin/claudedock"; do
          if [ -x "$BIN" ]; then
            if ! ERR=$("$BIN" open \(quotedName) 2>&1); then
              /usr/bin/osascript -e 'on run argv' -e 'display alert "ClaudeDock Egress Guard" message (item 1 of argv) as critical' -e 'end run' -- "$ERR" >/dev/null 2>&1 || true
              exit 1
            fi
            exit 0
          fi
        done

        \(fallbackBlock)
        """
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func refreshLaunchServices(appURL: URL) {
        let lsreg = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: appURL.path)
        guard fm.isExecutableFile(atPath: lsreg) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: lsreg)
        p.arguments = ["-f", appURL.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            p.waitUntilExit()
        }
    }

    private func unregisterLaunchServices(appURL: URL) {
        let lsreg = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        guard fm.isExecutableFile(atPath: lsreg) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: lsreg)
        p.arguments = ["-u", appURL.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            p.waitUntilExit()
        }
    }
}
