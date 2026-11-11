//
//  ScreenControl.swift
//  leanring-buddy
//
//  Low-level mouse and keyboard control used by screen takeover and the
//  click/key/scroll actions. Everything goes through CGEvent, which needs
//  the Accessibility permission Orchestra already asks for.
//
//  Coordinates: the AI answers in screenshot pixels (top-left origin, per
//  screen). CGEvent wants global Quartz points (top-left origin of the main
//  display). AppKit frames use a bottom-left origin, so we convert twice.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
enum ScreenControl {

    // MARK: - Coordinate mapping

    /// Converts a point in a screenshot's pixel space into global AppKit
    /// coordinates (bottom-left origin) — the same math the pointing cursor uses.
    static func appKitGlobalPoint(fromScreenshotPoint screenshotPoint: CGPoint,
                                  in screenCapture: CompanionScreenCapture) -> CGPoint {
        let screenshotWidth = CGFloat(screenCapture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(screenCapture.screenshotHeightInPixels)
        let displayWidth = CGFloat(screenCapture.displayWidthInPoints)
        let displayHeight = CGFloat(screenCapture.displayHeightInPoints)

        let clampedX = max(0, min(screenshotPoint.x, screenshotWidth))
        let clampedY = max(0, min(screenshotPoint.y, screenshotHeight))
        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)

        return CGPoint(
            x: screenCapture.displayFrame.origin.x + displayLocalX,
            y: screenCapture.displayFrame.origin.y + (displayHeight - displayLocalY)
        )
    }

    /// A point on a 0–1000 grid over the screenshot (0,0 top-left, 1000,1000
    /// bottom-right) → AppKit global point. Vision models place things much
    /// more accurately on this grid than in raw pixels of a resized image.
    static func appKitGlobalPoint(fromNormalizedPoint normalizedPoint: CGPoint,
                                  in screenCapture: CompanionScreenCapture) -> CGPoint {
        let clampedNormalizedX = max(0, min(normalizedPoint.x, 1000))
        let clampedNormalizedY = max(0, min(normalizedPoint.y, 1000))
        let screenshotPoint = CGPoint(
            x: clampedNormalizedX / 1000 * CGFloat(screenCapture.screenshotWidthInPixels),
            y: clampedNormalizedY / 1000 * CGFloat(screenCapture.screenshotHeightInPixels)
        )
        return appKitGlobalPoint(fromScreenshotPoint: screenshotPoint, in: screenCapture)
    }

    /// AppKit global (bottom-left origin) → Quartz global (top-left origin of
    /// the primary display), which is what CGEvent expects.
    static func quartzGlobalPoint(fromAppKitGlobalPoint appKitPoint: CGPoint) -> CGPoint {
        // The primary display is the one whose AppKit frame starts at (0, 0).
        let primaryScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first
        let primaryScreenHeight = primaryScreen?.frame.height ?? 0
        return CGPoint(x: appKitPoint.x, y: primaryScreenHeight - appKitPoint.y)
    }

    // MARK: - Mouse

    enum MouseClickKind {
        case left
        case double
        /// Selects a whole line/paragraph of text.
        case triple
        case right
    }

    static func click(atAppKitGlobalPoint appKitPoint: CGPoint, kind: MouseClickKind) {
        let quartzPoint = quartzGlobalPoint(fromAppKitGlobalPoint: appKitPoint)
        let eventSource = CGEventSource(stateID: .combinedSessionState)

        // Move first so hover states and tooltips behave like a real click.
        CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved,
                mouseCursorPosition: quartzPoint, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(60_000)

        switch kind {
        case .left:
            postMouseButtonPair(at: quartzPoint, downType: .leftMouseDown, upType: .leftMouseUp,
                                button: .left, clickCount: 1, eventSource: eventSource)
        case .double:
            postMouseButtonPair(at: quartzPoint, downType: .leftMouseDown, upType: .leftMouseUp,
                                button: .left, clickCount: 1, eventSource: eventSource)
            usleep(80_000)
            postMouseButtonPair(at: quartzPoint, downType: .leftMouseDown, upType: .leftMouseUp,
                                button: .left, clickCount: 2, eventSource: eventSource)
        case .triple:
            for clickNumber in 1...3 {
                postMouseButtonPair(at: quartzPoint, downType: .leftMouseDown, upType: .leftMouseUp,
                                    button: .left, clickCount: Int64(clickNumber), eventSource: eventSource)
                usleep(80_000)
            }
        case .right:
            postMouseButtonPair(at: quartzPoint, downType: .rightMouseDown, upType: .rightMouseUp,
                                button: .right, clickCount: 1, eventSource: eventSource)
        }
    }

    /// Press at one point, move to another, release: selects text (or drags a thing).
    static func drag(fromAppKitGlobalPoint startAppKitPoint: CGPoint, toAppKitGlobalPoint endAppKitPoint: CGPoint) {
        let startQuartzPoint = quartzGlobalPoint(fromAppKitGlobalPoint: startAppKitPoint)
        let endQuartzPoint = quartzGlobalPoint(fromAppKitGlobalPoint: endAppKitPoint)
        let eventSource = CGEventSource(stateID: .combinedSessionState)

        CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved,
                mouseCursorPosition: startQuartzPoint, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(60_000)
        CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown,
                mouseCursorPosition: startQuartzPoint, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(80_000)
        // Several small moves so apps see a real drag, not a jump.
        let dragStepCount = 12
        for dragStepNumber in 1...dragStepCount {
            let progress = CGFloat(dragStepNumber) / CGFloat(dragStepCount)
            let intermediatePoint = CGPoint(
                x: startQuartzPoint.x + (endQuartzPoint.x - startQuartzPoint.x) * progress,
                y: startQuartzPoint.y + (endQuartzPoint.y - startQuartzPoint.y) * progress
            )
            CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged,
                    mouseCursorPosition: intermediatePoint, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(16_000)
        }
        usleep(60_000)
        CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp,
                mouseCursorPosition: endQuartzPoint, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private static func postMouseButtonPair(at quartzPoint: CGPoint,
                                            downType: CGEventType,
                                            upType: CGEventType,
                                            button: CGMouseButton,
                                            clickCount: Int64,
                                            eventSource: CGEventSource?) {
        let mouseDownEvent = CGEvent(mouseEventSource: eventSource, mouseType: downType,
                                     mouseCursorPosition: quartzPoint, mouseButton: button)
        let mouseUpEvent = CGEvent(mouseEventSource: eventSource, mouseType: upType,
                                   mouseCursorPosition: quartzPoint, mouseButton: button)
        mouseDownEvent?.setIntegerValueField(.mouseEventClickState, value: clickCount)
        mouseUpEvent?.setIntegerValueField(.mouseEventClickState, value: clickCount)
        mouseDownEvent?.post(tap: .cghidEventTap)
        usleep(40_000)
        mouseUpEvent?.post(tap: .cghidEventTap)
    }

    /// Scrolls the content under the mouse. Positive = down (content moves up),
    /// whatever the "natural scrolling" setting is.
    static func scroll(lines scrollLineCount: Int) {
        // Synthetic wheel events aren't flipped by "natural scrolling" (that
        // happens for the physical device), so a negative wheel delta scrolls
        // down. If the user's Mac proves otherwise, flip "orchestraInvertScroll".
        let shouldInvertScroll = UserDefaults.standard.bool(forKey: "orchestraInvertScroll")
        let wheelDelta = shouldInvertScroll ? scrollLineCount : -scrollLineCount
        let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                  wheelCount: 1, wheel1: Int32(wheelDelta), wheel2: 0, wheel3: 0)
        scrollEvent?.post(tap: .cghidEventTap)
    }

    // MARK: - Safety gate (enforced in code, not just in the prompt)

    /// Words on a button/link that mean "this step can't be undone".
    /// The same "can't be undone" words, for the browser gate.
    static var irreversibleWordsPatternForSharing: String { irreversibleWordsPattern }

    private static let irreversibleWordsPattern = #"\b(send|buy|purchase|pay|place order|checkout|check out|delete|remove|trash|erase|post|publish|submit|confirm|transfer|tweet|reply all|unsubscribe)\b"#

    /// If the thing under this point is an irreversible button (Send, Buy,
    /// Delete…), returns its label so the caller can stop and ask the user.
    /// Fails closed: if we can't inspect the screen at all, it says so.
    static func irreversibleControlLabel(atAppKitGlobalPoint appKitPoint: CGPoint) -> String? {
        guard AXIsProcessTrusted() else {
            return "unknown (accessibility is off, so i can't check what's there)"
        }
        let quartzPoint = quartzGlobalPoint(fromAppKitGlobalPoint: appKitPoint)
        let systemWideElement = AXUIElementCreateSystemWide()
        var elementUnderPoint: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWideElement, Float(quartzPoint.x), Float(quartzPoint.y), &elementUnderPoint) == .success,
              let elementUnderPoint else {
            // Can't read what's under the point. In a messaging app that's
            // too risky (it could be an icon-only Send); elsewhere allow it.
            if frontmostAppIsMessagingApp() {
                return "unlabelled button in a messaging app"
            }
            return nil
        }
        // Icon-only buttons in messaging apps (paper-plane Send) have no words to match.
        if frontmostAppIsMessagingApp(),
           accessibilityRole(of: elementUnderPoint) == (kAXButtonRole as String),
           accessibilityLabelText(of: elementUnderPoint).trimmingCharacters(in: .whitespaces).isEmpty {
            return "unlabelled button in a messaging app"
        }
        // Check the element and a couple of parents (labels often sit on the button, not the text inside it).
        var currentElement: AXUIElement? = elementUnderPoint
        for _ in 0..<3 {
            guard let element = currentElement else { break }
            let labelText = accessibilityLabelText(of: element)
            if labelText.range(of: irreversibleWordsPattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return labelText
            }
            currentElement = accessibilityParent(of: element)
        }
        return nil
    }

    /// Apps where pressing return in a text box sends a message.
    private static let messagingAppBundleIdentifiers: Set<String> = [
        "com.apple.MobileSMS", "com.apple.mail", "com.tinyspeck.slackmacgap", "com.hnc.Discord",
        "ru.keepcoder.Telegram", "org.telegram.desktop", "net.whatsapp.WhatsApp", "desktop.WhatsApp",
        "com.facebook.archon", "com.microsoft.teams2", "com.microsoft.teams", "com.microsoft.Outlook",
        "us.zoom.xos", "com.readdle.smartemail-Mac", "com.superhuman.electron"
    ]

    /// True when pressing return (or typing a newline) right now would likely
    /// send a message: a messaging app is in front, or the focused text box is
    /// labelled like a message/reply/comment box (e.g. Messenger or Gmail chat in a browser).
    static func returnKeyWouldLikelySend() -> Bool {
        if frontmostAppIsMessagingApp() {
            return true
        }
        // Fail closed: if we can't see what's focused, assume return could send.
        guard AXIsProcessTrusted() else { return true }
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElementValue) == .success,
              let focusedElementValue,
              CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID() else {
            return true
        }
        let focusedElement = focusedElementValue as! AXUIElement
        let labelText = accessibilityLabelText(of: focusedElement)
        return labelText.range(of: #"message|reply|chat|comment|write a|send"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Key combos that send/submit almost everywhere (Gmail, Slack, etc.).
    static func isSendShortcut(_ keyCombinationText: String) -> Bool {
        let normalizedKeys = keyCombinationText.lowercased().replacingOccurrences(of: " ", with: "")
        return ["cmd+return", "cmd+enter", "command+return", "command+enter", "ctrl+return", "ctrl+enter",
                "control+return", "control+enter", "cmd+shift+d"].contains(normalizedKeys)
    }

    static func isPlainReturn(_ keyCombinationText: String) -> Bool {
        let normalizedKeys = keyCombinationText.lowercased().replacingOccurrences(of: " ", with: "")
        return normalizedKeys == "return" || normalizedKeys == "enter"
    }

    static func frontmostAppIsMessagingApp() -> Bool {
        guard let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return messagingAppBundleIdentifiers.contains(frontmostBundleIdentifier)
    }

    private static func accessibilityRole(of element: AXUIElement) -> String? {
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success else { return nil }
        return roleValue as? String
    }

    /// Words that describe an element. The value attribute is only used for
    /// buttons/links/menu items — for text fields it's the typed content, and
    /// a search box containing "send" must not block clicks.
    private static func accessibilityLabelText(of element: AXUIElement) -> String {
        let role = accessibilityRole(of: element) ?? ""
        let valueIsALabel = [kAXButtonRole as String, "AXLink", kAXMenuItemRole as String,
                             kAXCheckBoxRole as String, kAXPopUpButtonRole as String].contains(role)
        var labelAttributeNames = [kAXTitleAttribute as String, kAXDescriptionAttribute as String,
                                   kAXHelpAttribute as String, kAXPlaceholderValueAttribute as String]
        if valueIsALabel {
            labelAttributeNames.append(kAXValueAttribute as String)
        }
        var labelPieces: [String] = []
        for attributeName in labelAttributeNames {
            var attributeValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attributeName as CFString, &attributeValue) == .success,
               let stringValue = attributeValue as? String, !stringValue.isEmpty, stringValue.count < 80 {
                labelPieces.append(stringValue)
            }
        }
        return labelPieces.joined(separator: " ")
    }

    private static func accessibilityParent(of element: AXUIElement) -> AXUIElement? {
        var parentValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentValue) == .success,
              let parentValue,
              CFGetTypeID(parentValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return (parentValue as! AXUIElement)
    }

    // MARK: - Keyboard

    /// Types arbitrary text (any language/emoji) into the frontmost app.
    static func typeText(_ textToType: String) {
        let eventSource = CGEventSource(stateID: .combinedSessionState)
        for character in textToType {
            let utf16Characters = Array(String(character).utf16)
            guard let keyDownEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true),
                  let keyUpEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) else {
                continue
            }
            keyDownEvent.keyboardSetUnicodeString(stringLength: utf16Characters.count, unicodeString: utf16Characters)
            keyUpEvent.keyboardSetUnicodeString(stringLength: utf16Characters.count, unicodeString: utf16Characters)
            keyDownEvent.post(tap: .cghidEventTap)
            keyUpEvent.post(tap: .cghidEventTap)
            usleep(2_000)
        }
    }

    /// Presses a key combination like "cmd+shift+t", "return", "esc", "cmd+space".
    /// Returns false if a key name isn't recognized.
    @discardableResult
    static func pressKeyCombination(_ keyCombinationText: String) -> Bool {
        let keyNames = keyCombinationText
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .split(separator: "+")
            .map(String.init)
        guard let mainKeyName = keyNames.last,
              let mainVirtualKeyCode = virtualKeyCodeByName[mainKeyName] else {
            return false
        }

        var modifierFlags: CGEventFlags = []
        for modifierName in keyNames.dropLast() {
            switch modifierName {
            case "cmd", "command": modifierFlags.insert(.maskCommand)
            case "shift": modifierFlags.insert(.maskShift)
            case "opt", "option", "alt": modifierFlags.insert(.maskAlternate)
            case "ctrl", "control": modifierFlags.insert(.maskControl)
            case "fn": modifierFlags.insert(.maskSecondaryFn)
            default: return false
            }
        }

        let eventSource = CGEventSource(stateID: .combinedSessionState)
        let keyDownEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: mainVirtualKeyCode, keyDown: true)
        let keyUpEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: mainVirtualKeyCode, keyDown: false)
        keyDownEvent?.flags = modifierFlags
        keyUpEvent?.flags = modifierFlags
        keyDownEvent?.post(tap: .cghidEventTap)
        usleep(30_000)
        keyUpEvent?.post(tap: .cghidEventTap)
        return true
    }

    /// US-layout virtual key codes (Carbon kVK_* values).
    private static let virtualKeyCodeByName: [String: CGKeyCode] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
        "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
        "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
        "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32,
        "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31, "delete": 0x33, "backspace": 0x33,
        "esc": 0x35, "escape": 0x35, "forwarddelete": 0x75, "home": 0x73, "end": 0x77,
        "pageup": 0x74, "pagedown": 0x79, "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62,
        "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F
    ]
}
