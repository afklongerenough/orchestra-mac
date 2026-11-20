//
//  BrowserControl.swift
//  leanring-buddy
//
//  Works inside web pages directly instead of clicking pixels: reads the
//  page, lists the buttons/links/fields with short ids, and clicks or types
//  into them by id. Runs JavaScript in the front browser tab through Apple
//  Events, so no extension is needed — the user turns on, once:
//    Chrome / Brave / Edge / Arc: View › Developer › Allow JavaScript from Apple Events
//    Safari: Develop menu › Allow JavaScript from Apple Events
//
//  Same safety rules as screen clicks: never presses Send/Buy/Delete-style
//  buttons, never types into password fields, never submits forms itself.
//

import AppKit
import Foundation

@MainActor
enum BrowserControl {
    private enum BrowserFamily {
        /// Chrome-style AppleScript: `execute active tab of front window javascript`.
        case chromium
        case safari
    }

    private static let supportedBrowsers: [String: (applicationName: String, family: BrowserFamily)] = [
        "com.google.Chrome": ("Google Chrome", .chromium),
        "com.google.Chrome.beta": ("Google Chrome Beta", .chromium),
        "com.brave.Browser": ("Brave Browser", .chromium),
        "com.microsoft.edgemac": ("Microsoft Edge", .chromium),
        "company.thebrowser.Browser": ("Arc", .chromium),
        "com.apple.Safari": ("Safari", .safari)
    ]

    struct BrowserError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The browser in front, if it's one we can drive.
    static var frontmostBrowserName: String? {
        guard let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return nil }
        return supportedBrowsers[bundleIdentifier]?.applicationName
    }

    // MARK: - Page reading

    /// One JavaScript label function, used both for the list the model sees and
    /// for the safety gate, so they always agree. Never reads what's typed in
    /// text/password/card fields — only what a button says.
    private static let elementLabelJavaScriptFunction = """
    function orchestraLabel(node, maximumLength) {
      var isButtonLikeInput = node.tagName === 'INPUT' && /^(button|submit|reset)$/i.test(node.type || '');
      var imageAlt = '';
      var innerImage = node.querySelector ? node.querySelector('img[alt], svg[aria-label]') : null;
      if (innerImage) imageAlt = innerImage.getAttribute('alt') || innerImage.getAttribute('aria-label') || '';
      var parts = [node.getAttribute('aria-label'), (node.tagName === 'INPUT' || node.tagName === 'TEXTAREA' || node.tagName === 'SELECT') ? '' : node.innerText,
                   isButtonLikeInput ? node.value : '', node.getAttribute('placeholder'), node.getAttribute('title'),
                   node.getAttribute('name'), imageAlt];
      return parts.filter(function (part) { return part; }).join(' ').replace(/\\s+/g, ' ').trim().slice(0, maximumLength || 100);
    }
    """

    /// Title, address, the visible buttons/links/fields (with ids for click/type),
    /// and the start of the page text. Ids are fresh on every read.
    private static func readPageUsingAppleEvents(maximumTextCharacters: Int) throws -> String {
        let javaScript = """
        (function () {
          document.querySelectorAll('[data-orch-id]').forEach(function (node) { node.removeAttribute('data-orch-id'); });
          \(elementLabelJavaScriptFunction)
          var selector = 'a[href], button, input, textarea, [role=button], [role=link], [role=tab], [role=menuitem], [role=checkbox], [role=option], [contenteditable=true], summary';
          var lines = [];
          var nextId = 1;
          var nodes = document.querySelectorAll(selector);
          for (var index = 0; index < nodes.length && nextId <= 150; index++) {
            var node = nodes[index];
            var box = node.getBoundingClientRect();
            if (box.width < 2 || box.height < 2) continue;
            if (box.bottom < 0 || box.top > window.innerHeight * 2) continue;
            var style = window.getComputedStyle(node);
            if (style.visibility === 'hidden' || style.display === 'none') continue;
            var label = orchestraLabel(node);
            if ((node.tagName === 'INPUT' || node.tagName === 'TEXTAREA') && node.value) label += ' (has text)';
            var kind = (node.getAttribute('role') || node.tagName).toLowerCase();
            if (node.tagName === 'INPUT') kind = 'input:' + (node.type || 'text');
            node.setAttribute('data-orch-id', String(nextId));
            var onScreen = box.top >= 0 && box.bottom <= window.innerHeight ? '' : ' (below, scroll to see)';
            lines.push('[' + nextId + '] ' + kind + ' "' + label + '"' + onScreen);
            nextId++;
          }
          var pageText = (document.body ? document.body.innerText : '').replace(/\\n{3,}/g, '\\n\\n').slice(0, \(maximumTextCharacters));
          return 'page: ' + document.title + '\\naddress: ' + location.href + '\\n\\nelements:\\n' + lines.join('\\n') + '\\n\\npage text:\\n' + pageText;
        })()
        """
        return try runJavaScriptInFrontTab(javaScript)
    }

    // MARK: - Public actions (the Chrome extension when it's connected, else Apple Events)

    /// The extension works in Chrome-family browsers; use it when one is in front.
    private static var usableExtensionBridge: BrowserExtensionBridge? {
        let extensionBridge = BrowserExtensionBridge.shared
        guard extensionBridge.isExtensionConnected,
              let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              supportedBrowsers[bundleIdentifier]?.family == .chromium else { return nil }
        return extensionBridge
    }

    static func readPage(maximumTextCharacters: Int = 3500) async throws -> String {
        if let extensionBridge = usableExtensionBridge {
            return try await extensionBridge.send(["action": "read", "maxText": maximumTextCharacters])
        }
        return try readPageUsingAppleEvents(maximumTextCharacters: maximumTextCharacters)
    }

    /// Clicks an element by id. Refuses Send/Buy/Delete-style and unlabelled controls.
    static func clickElement(id elementIdentifier: Int) async throws -> String {
        guard let extensionBridge = usableExtensionBridge else {
            return try clickElementUsingAppleEvents(id: elementIdentifier)
        }
        let elementLabel = try await extensionBridge.send(["action": "describe", "elementId": elementIdentifier])
        guard !elementLabel.isEmpty else { throw BrowserError(message: "element \(elementIdentifier) is gone; read the page again") }
        try checkClickIsAllowed(elementLabel: elementLabel, elementIdentifier: elementIdentifier)
        // The page re-checks the label right before clicking, so a re-render
        // between the two messages can't swap in a different button.
        let clickResult = try await extensionBridge.send(["action": "click", "elementId": elementIdentifier, "expectedLabel": elementLabel])
        if clickResult == "changed" { throw BrowserError(message: "element \(elementIdentifier) changed since the read; read the page again") }
        guard clickResult == "clicked" else { throw BrowserError(message: "element \(elementIdentifier) is gone; read the page again") }
        return "clicked \"\(elementLabel.prefix(100))\""
    }

    static func typeIntoElement(id elementIdentifier: Int, text textToType: String) async throws -> String {
        guard let extensionBridge = usableExtensionBridge else {
            return try typeIntoElementUsingAppleEvents(id: elementIdentifier, text: textToType)
        }
        guard !textToType.isEmpty else { throw BrowserError(message: "nothing to type") }
        let typeResult = try await extensionBridge.send(["action": "type", "elementId": elementIdentifier, "text": textToType])
        switch typeResult {
        case "typed": return "typed into element \(elementIdentifier)"
        case "password": throw BrowserError(message: "that's a password field; the user types passwords themselves")
        case "unsupported": throw BrowserError(message: "element \(elementIdentifier) isn't a text field (a dropdown, checkbox or button?); click it instead")
        default: throw BrowserError(message: "element \(elementIdentifier) is gone; read the page again")
        }
    }

    static func scrollPage(screens screenCount: Double) async throws -> String {
        if let extensionBridge = usableExtensionBridge {
            return try await extensionBridge.send(["action": "scroll", "screens": screenCount])
        }
        return try scrollPageUsingAppleEvents(screens: screenCount)
    }

    static func goBack() async throws -> String {
        if let extensionBridge = usableExtensionBridge {
            return try await extensionBridge.send(["action": "back"])
        }
        return try goBackUsingAppleEvents()
    }

    static func openAddress(_ addressText: String) async throws -> String {
        if let extensionBridge = usableExtensionBridge {
            let address = try validatedWebAddress(addressText)
            return try await extensionBridge.send(["action": "open", "url": address.absoluteString])
        }
        return try openAddressUsingAppleEvents(addressText)
    }

    /// Lists the open tabs (extension only).
    static func listTabs() async throws -> String {
        guard let extensionBridge = usableExtensionBridge else {
            throw BrowserError(message: "listing tabs needs the Orchestra Chrome extension (set it up in the menu)")
        }
        return try await extensionBridge.send(["action": "tabs"])
    }

    static func switchToTab(tabIdentifier: Int) async throws -> String {
        guard let extensionBridge = usableExtensionBridge else {
            throw BrowserError(message: "switching tabs needs the Orchestra Chrome extension (set it up in the menu)")
        }
        return try await extensionBridge.send(["action": "switch_tab", "tabId": tabIdentifier])
    }

    /// Attaches a file from the user's own folders to an upload field (extension only).
    static func uploadFile(toElement elementIdentifier: Int, filePath: String) async throws -> String {
        guard let extensionBridge = usableExtensionBridge else {
            throw BrowserError(message: "uploading files needs the Orchestra Chrome extension (set it up in the menu)")
        }
        let expandedPath = (filePath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        let resolvedPath = URL(fileURLWithPath: expandedPath).standardizedFileURL.resolvingSymlinksInPath().path
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let allowedFolderPaths = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"]
            .map { homePath + "/" + $0 + "/" }
        // Inside ~/Orchestra only an agent's files/ folder: never the extension's
        // token, job briefs, notes, chat history or the log.
        let isAgentDeliverable = resolvedPath.range(of: "^" + NSRegularExpression.escapedPattern(for: homePath) + "/Orchestra/Agents/[^/]+/files/",
                                                    options: .regularExpression) != nil
        guard allowedFolderPaths.contains(where: { resolvedPath.hasPrefix($0) }) || isAgentDeliverable else {
            throw BrowserError(message: "only files in Desktop, Documents, Downloads, Pictures, Movies or Music (or an agent's files folder) can be uploaded")
        }
        let fileValues = try? URL(fileURLWithPath: resolvedPath).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard fileValues?.isRegularFile == true else { throw BrowserError(message: "there's no file at \(resolvedPath)") }
        let maximumUploadBytes = 200 * 1024 * 1024
        guard let fileSize = fileValues?.fileSize, fileSize <= maximumUploadBytes else { throw BrowserError(message: "couldn't check that file's size, or it's over 200 MB; the user should attach it themselves") }
        return try await extensionBridge.send(["action": "upload", "elementId": elementIdentifier, "path": resolvedPath])
    }

    // MARK: - Safety gate (shared)

    private static func checkClickIsAllowed(elementLabel: String, elementIdentifier: Int) throws {
        // An unlabelled control could be an icon-only Send or Delete: don't guess.
        // Fewer than three letters (an icon like "➤") says nothing about what it does.
        let letterCount = elementLabel.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard elementLabel != "(no label)", letterCount >= 3 else {
            throw BrowserError(message: "element \(elementIdentifier) has no label, so i can't tell what it does; that click is the user's")
        }
        if elementLabel.range(of: ScreenControl.irreversibleWordsPatternForSharing, options: [.regularExpression, .caseInsensitive]) != nil {
            throw BrowserError(message: "not clicking \"\(elementLabel.prefix(100))\": that can't be undone, so it's the user's click")
        }
    }

    private static func validatedWebAddress(_ addressText: String) throws -> URL {
        guard let address = URL(string: addressText.trimmingCharacters(in: .whitespacesAndNewlines)),
              address.scheme == "https" || address.scheme == "http" else {
            throw BrowserError(message: "that isn't a web address")
        }
        return address
    }

    // MARK: - Apple Events versions (no extension)

    /// Clicks the element with this id (from the last readPage). Refuses Send/Buy/Delete-style controls.
    private static func clickElementUsingAppleEvents(id elementIdentifier: Int) throws -> String {
        let elementLabel = try describeElement(id: elementIdentifier)
        try checkClickIsAllowed(elementLabel: elementLabel, elementIdentifier: elementIdentifier)
        let javaScript = """
        (function () {
          var node = document.querySelector('[data-orch-id="\(elementIdentifier)"]');
          if (!node) return 'missing';
          node.scrollIntoView({block: 'center'});
          node.focus();
          node.click();
          return 'clicked';
        })()
        """
        let result = try runJavaScriptInFrontTab(javaScript)
        guard result == "clicked" else { throw BrowserError(message: "element \(elementIdentifier) is gone; read the page again") }
        return "clicked \"\(elementLabel.prefix(100))\""
    }

    /// Types text into a field by id (replaces what's there). Never into password fields.
    private static func typeIntoElementUsingAppleEvents(id elementIdentifier: Int, text textToType: String) throws -> String {
        guard !textToType.isEmpty else { throw BrowserError(message: "nothing to type") }
        let textAsJavaScriptLiteral = javaScriptStringLiteral(textToType)
        let javaScript = """
        (function () {
          var node = document.querySelector('[data-orch-id="\(elementIdentifier)"]');
          if (!node) return 'missing';
          if (node.tagName === 'INPUT' && node.type === 'password') return 'password';
          if (node.tagName === 'SELECT') return 'unsupported';
          if (node.tagName === 'INPUT' && /^(file|checkbox|radio|submit|button|image|reset|hidden|range|color)$/i.test(node.type || '')) return 'unsupported';
          if (node.tagName !== 'INPUT' && node.tagName !== 'TEXTAREA' && !node.isContentEditable) return 'unsupported';
          node.scrollIntoView({block: 'center'});
          node.focus();
          var text = \(textAsJavaScriptLiteral);
          if (node.isContentEditable) {
            document.execCommand('selectAll', false, null);
            document.execCommand('insertText', false, text);
          } else {
            // The native setter, so React/Vue-style pages notice the change.
            var prototype = node.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            var descriptor = Object.getOwnPropertyDescriptor(prototype, 'value');
            if (descriptor && descriptor.set) { descriptor.set.call(node, text); } else { node.value = text; }
            node.dispatchEvent(new Event('input', {bubbles: true}));
            node.dispatchEvent(new Event('change', {bubbles: true}));
          }
          return 'typed';
        })()
        """
        let result = try runJavaScriptInFrontTab(javaScript)
        switch result {
        case "typed": return "typed into element \(elementIdentifier)"
        case "password": throw BrowserError(message: "that's a password field; the user types passwords themselves")
        case "unsupported": throw BrowserError(message: "element \(elementIdentifier) isn't a text field (a dropdown, checkbox or button?); click it instead")
        default: throw BrowserError(message: "element \(elementIdentifier) is gone; read the page again")
        }
    }

    private static func scrollPageUsingAppleEvents(screens screenCount: Double) throws -> String {
        _ = try runJavaScriptInFrontTab("window.scrollBy(0, window.innerHeight * 0.8 * \(screenCount)); 'ok'")
        return "scrolled"
    }

    private static func goBackUsingAppleEvents() throws -> String {
        _ = try runJavaScriptInFrontTab("history.back(); 'ok'")
        return "went back"
    }

    /// Opens a link in the front tab (https only).
    private static func openAddressUsingAppleEvents(_ addressText: String) throws -> String {
        let address = try validatedWebAddress(addressText)
        _ = try runJavaScriptInFrontTab("location.href = \(javaScriptStringLiteral(address.absoluteString)); 'ok'")
        return "opening \(address.absoluteString)"
    }

    // MARK: - Plumbing

    private static func describeElement(id elementIdentifier: Int) throws -> String {
        let javaScript = """
        (function () {
          \(elementLabelJavaScriptFunction)
          var node = document.querySelector('[data-orch-id="\(elementIdentifier)"]');
          if (!node) return '';
          // Full length (no cut-off) plus the visible text on its own, for the safety check.
          var fullLabel = orchestraLabel(node, 2000);
          var visibleText = (node.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 2000);
          return (fullLabel + (visibleText && fullLabel.indexOf(visibleText) < 0 ? ' ' + visibleText : '')) || '(no label)';
        })()
        """
        let label = try runJavaScriptInFrontTab(javaScript)
        guard !label.isEmpty else { throw BrowserError(message: "element \(elementIdentifier) is gone; read the page again") }
        return label
    }

    private static func javaScriptStringLiteral(_ text: String) -> String {
        // JSON string encoding is a valid JavaScript string literal.
        guard let encodedData = try? JSONSerialization.data(withJSONObject: [text]),
              let encodedArray = String(data: encodedData, encoding: .utf8) else { return "\"\"" }
        return String(encodedArray.dropFirst().dropLast())
    }

    private static func runJavaScriptInFrontTab(_ javaScript: String) throws -> String {
        guard let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              let browser = supportedBrowsers[bundleIdentifier] else {
            throw BrowserError(message: "no supported browser is in front (Chrome, Brave, Edge, Arc or Safari)")
        }
        let javaScriptForAppleScript = javaScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let appleScriptSource: String
        switch browser.family {
        case .chromium:
            appleScriptSource = "tell application \"\(browser.applicationName)\" to execute active tab of front window javascript \"\(javaScriptForAppleScript)\""
        case .safari:
            appleScriptSource = "tell application \"Safari\" to do JavaScript \"\(javaScriptForAppleScript)\" in current tab of front window"
        }
        guard let appleScript = NSAppleScript(source: appleScriptSource) else {
            throw BrowserError(message: "couldn't build the browser script")
        }
        var errorInfo: NSDictionary?
        let resultDescriptor = appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let errorMessage = errorInfo[NSAppleScript.errorMessage] as? String ?? "browser script error"
            if errorMessage.localizedCaseInsensitiveContains("javascript") || errorMessage.localizedCaseInsensitiveContains("apple events") {
                let settingPath = browser.family == .safari
                    ? "Safari's Develop menu › Allow JavaScript from Apple Events"
                    : "\(browser.applicationName)'s View menu › Developer › Allow JavaScript from Apple Events"
                throw BrowserError(message: "browser control is off. turn on \(settingPath), then ask again")
            }
            throw BrowserError(message: errorMessage)
        }
        return resultDescriptor.stringValue ?? ""
    }
}
