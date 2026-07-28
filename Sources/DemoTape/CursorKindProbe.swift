import AppKit
import ApplicationServices
import os

/// Works out which pointer shape belongs at a screen position — arrow, hand, text bar, resize.
///
/// Why bother: in a real recording the pointer changes shape constantly, and viewers read it without
/// thinking — a hand means "this is clickable", a text bar means "you can type here". Drawing one
/// arrow for an entire demo quietly removes that signal, and makes an enlarged cursor look pasted on.
///
/// **Why not just ask the system.** `NSCursor.currentSystem` reports the cursor of the *calling*
/// application. DemoTape records from the background while another app is frontmost, so it always
/// answered "arrow" no matter what the browser was showing. Verified: a take over a text field
/// recorded 1208 samples, every one of them `arrow`.
///
/// So the shape is derived from what is actually **under** the pointer, via the Accessibility API —
/// the same grant that lets DemoTape click. That turns out to be better than matching cursor images:
/// it's semantic (a link is a link, whatever a site styles its cursor as) and it works across native
/// apps and web content alike.
enum CursorKindProbe {

    /// Roles that mean "you can click this" → a pointing hand.
    ///
    /// Spelled as literals rather than the `kAX…` constants: several of these (notably `AXLink`, the
    /// one web content uses most) aren't exposed as symbols in the Swift overlay, and mixing sources
    /// would make the set harder to read than the strings it actually compares against.
    private static let clickableRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXDisclosureTriangle", "AXIncrementor",
    ]

    /// Roles (and subroles) that mean "you can type here" → a text bar.
    private static let textRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
    ]

    /// Roles that mean "you can drag this edge" → a resize pointer.
    private static let resizeRoles: Set<String> = ["AXSplitter"]

    private static let systemWide = AXUIElementCreateSystemWide()

    /// Guards `menuTrackingDepth`. The gate is written on the main thread (menu open/close) and read
    /// on the sampling queue, so it needs to be cheap and lock-safe from both.
    private static var gateLock = os_unfair_lock()
    /// How many menus are currently being tracked. AX hit-testing an open Carbon menu can segfault
    /// deep inside HIToolbox (`HIStandardMenuView::FetchItemCache` → `CFRetain` on a freed pointer)
    /// on macOS 12; while a menu is up we skip the probe entirely rather than risk taking down a
    /// recording mid-take. See `beginMenuTracking()`.
    private static var menuTrackingDepth = 0

    /// Call from `NSMenuDelegate.menuWillOpen`: suspends AX probing while a menu is on screen.
    ///
    /// Why this exists: the background sampler queries the Accessibility element under the pointer a
    /// few times a second to pick the cursor shape. When DemoTape's own status-bar menu is open and
    /// the pointer is over it, that query hit-tests a Carbon menu and crashes inside the system
    /// frameworks — a SIGSEGV we cannot catch in-process. Every crash captured in the field had the
    /// main thread tracking the status menu while this probe fired. Skipping the probe while any
    /// menu is up removes the trigger; the cursor shape over a menu doesn't matter anyway.
    static func beginMenuTracking() {
        os_unfair_lock_lock(&gateLock)
        menuTrackingDepth += 1
        os_unfair_lock_unlock(&gateLock)
    }

    /// Call from `NSMenuDelegate.menuDidClose`. Clamped at zero so an unbalanced close can't leave
    /// the probe permanently disabled.
    static func endMenuTracking() {
        os_unfair_lock_lock(&gateLock)
        if menuTrackingDepth > 0 { menuTrackingDepth -= 1 }
        os_unfair_lock_unlock(&gateLock)
    }

    private static var isMenuTracking: Bool {
        os_unfair_lock_lock(&gateLock)
        defer { os_unfair_lock_unlock(&gateLock) }
        return menuTrackingDepth > 0
    }

    /// The shape that belongs at `point` (global, top-left screen coordinates).
    ///
    /// Falls back to `.arrow`, which is both the common case and the safe default: a wrongly drawn
    /// hand is more distracting than a plain arrow. Cheap enough to call a few times a second, but
    /// not per frame — the caller caches it.
    static func kind(at point: CGPoint) -> CursorKind {
        guard AXIsProcessTrusted() else { return .arrow }
        // Never hit-test while a menu is open — AX-probing a Carbon menu segfaults on macOS 12.
        guard !isMenuTracking else { return .arrow }
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y),
                                              &element) == .success,
              let element = element else { return .arrow }

        // Walk a few ancestors: web content often reports the deepest node (a span inside a link),
        // and the meaningful role sits just above it.
        var current: AXUIElement? = element
        for _ in 0..<4 {
            guard let node = current else { break }
            if let role = copyString(node, kAXRoleAttribute as String) {
                if textRoles.contains(role) { return .ibeam }
                if clickableRoles.contains(role) { return .hand }
                if resizeRoles.contains(role) { return .resize }
                // A subrole can be more specific than the role (a search field is an AXTextField
                // subrole; a link inside web content can be marked this way too).
                if let subrole = copyString(node, kAXSubroleAttribute as String) {
                    if textRoles.contains(subrole) { return .ibeam }
                    if clickableRoles.contains(subrole) { return .hand }
                }
                // Anything that reports itself as editable takes a text bar.
                if role == kAXStaticTextRole as String,
                   let editable = copyBool(node, "AXEditable"), editable { return .ibeam }
            }
            current = copyElement(node, kAXParentAttribute as String)
        }
        return .arrow
    }

    // MARK: - Attribute helpers

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func copyBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? Bool
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as! AXUIElement?
    }
}
