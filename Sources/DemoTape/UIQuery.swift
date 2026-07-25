import AppKit
import ApplicationServices

/// Reads what is *actually* on screen, so a demo can be scripted semantically — "click the button
/// labelled Export" — instead of with baked-in coordinates.
///
/// Why this exists: coordinates are the brittle way to automate a GUI. They break when a window
/// moves, when a layout changes, when the display resolution differs, and they give an orchestrator
/// no way to know whether the thing it wants is even present. This type resolves a target from the
/// live UI hierarchy and hands back its real screen rect, which the cursor commands then glide to.
///
/// Two backends, picked automatically:
///
/// - **Our own windows** are inspected through AppKit directly (`NSView` walk). Exact, synchronous,
///   and it needs no permission because it's our own process.
/// - **Any other app** is inspected through the **Accessibility API** (`AXUIElement`), which is the
///   same foundation Appium/XCUITest and macOS computer-use agents build on. DemoTape already holds
///   the Accessibility grant it requires (that grant is also what makes its synthetic clicks land),
///   so demoing a *user's* app works without granting anything to a driver process.
enum UIQuery {

    /// One addressable thing on screen.
    struct Element: Equatable {
        var role: String          // AXButton, AXStaticText, AXMenuItem, … (AppKit views are mapped)
        var label: String         // title / value / accessibility description, whichever exists
        var frame: CGRect         // screen points, TOP-LEFT origin (matches the cursor commands)
        var enabled: Bool = true

        var centre: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
    }

    /// A semantic request for something on screen.
    struct Query: Equatable {
        var label: String            // matched case-insensitively, ignoring trailing "…"
        var role: String? = nil      // optional filter, e.g. "AXButton"
        var app: String? = nil       // nil / "DemoTape" = our own UI; otherwise a running app name
        var index: Int = 0           // which match to take when several share a label
    }

    // MARK: - Matching (pure, testable)

    /// Normalises a label for comparison: case-folded, trimmed, and stripped of the trailing
    /// ellipsis macOS puts on actions that open something ("Export…" should match "export").
    static func normalise(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while t.hasSuffix("…") || t.hasSuffix("...") {
            t = t.hasSuffix("…") ? String(t.dropLast()) : String(t.dropLast(3))
            t = t.trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    /// True when an element satisfies a query. Exact (normalised) match wins; otherwise a contains
    /// match, so "Star on GitHub" is reachable as "star".
    static func matches(_ element: Element, _ query: Query) -> Bool {
        if let role = query.role, !role.isEmpty,
           element.role.caseInsensitiveCompare(role) != .orderedSame { return false }
        let want = normalise(query.label)
        guard !want.isEmpty else { return false }
        let have = normalise(element.label)
        return have == want || have.contains(want)
    }

    /// Picks the query's chosen match, preferring exact label equality over partial matches so a
    /// query for "Export" doesn't land on "Export CSV" when a plain "Export" button exists.
    static func resolve(_ elements: [Element], _ query: Query) -> Element? {
        let candidates = elements.filter { matches($0, query) }
        guard !candidates.isEmpty else { return nil }
        let want = normalise(query.label)
        let exact = candidates.filter { normalise($0.label) == want }
        let pool = exact.isEmpty ? candidates : exact
        guard query.index >= 0, query.index < pool.count else { return nil }
        return pool[query.index]
    }

    // MARK: - Reading the screen

    /// Every addressable element for a query's target app.
    static func snapshot(app: String?) -> [Element] {
        let name = app?.trimmingCharacters(in: .whitespaces) ?? ""
        if name.isEmpty || name.caseInsensitiveCompare("DemoTape") == .orderedSame {
            return ownElements()
        }
        return axElements(appNamed: name)
    }

    /// Finds one element, or nil when it isn't on screen (which is useful information: the caller
    /// should fail loudly rather than click an arbitrary spot).
    static func find(_ query: Query) -> Element? {
        resolve(snapshot(app: query.app), query)
    }

    // MARK: - Our own UI, via AppKit

    /// Walks our visible windows collecting controls and labels. Exact by construction — these are
    /// the very objects being drawn.
    static func ownElements() -> [Element] {
        // Front-to-back order matters: matches are taken in order, so the window the user is
        // actually looking at must be searched first. Without this, a query for "Star" (About's
        // "★ Star on GitHub") could land on the recorder bar's "Start" button in another window.
        let visible = NSApp.windows.filter { $0.isVisible }
        let ordered = visible.sorted { a, b in
            if a === NSApp.keyWindow { return true }
            if b === NSApp.keyWindow { return false }
            return a.orderedIndex < b.orderedIndex
        }
        var out: [Element] = []
        for window in ordered {
            guard let root = window.contentView else { continue }
            collect(view: root, in: window, into: &out)
            // Menu-bar items and menus aren't in the view tree; the status item is reachable via
            // control.json's menuBarButton, and its menu via `ui/open?window=menu`.
        }
        return out
    }

    private static func collect(view: NSView, in window: NSWindow, into out: inout [Element]) {
        if !view.isHidden {
            if let control = view as? NSButton {
                out.append(Element(role: "AXButton", label: control.title,
                                   frame: screenRect(of: view, in: window),
                                   enabled: control.isEnabled))
            } else if let field = view as? NSTextField {
                let role = field.isEditable ? "AXTextField" : "AXStaticText"
                let text = field.stringValue.isEmpty ? (field.placeholderString ?? "") : field.stringValue
                out.append(Element(role: role, label: text,
                                   frame: screenRect(of: view, in: window),
                                   enabled: field.isEnabled))
            } else if let seg = view as? NSSegmentedControl {
                for i in 0..<seg.segmentCount {
                    out.append(Element(role: "AXRadioButton", label: seg.label(forSegment: i) ?? "",
                                       frame: screenRect(of: view, in: window), enabled: seg.isEnabled))
                }
            }
        }
        for sub in view.subviews { collect(view: sub, in: window, into: &out) }
    }

    /// View bounds converted to screen points with a top-left origin, matching `demotape://cursor`.
    private static func screenRect(of view: NSView, in window: NSWindow) -> CGRect {
        let inWindow = view.convert(view.bounds, to: nil)
        let onScreen = window.convertToScreen(inWindow)      // bottom-left origin
        let displayHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(x: onScreen.minX, y: displayHeight - onScreen.maxY,
                      width: onScreen.width, height: onScreen.height)
    }

    // MARK: - Any other app, via the Accessibility API

    /// Walks another application's accessibility tree. This is the general case that makes demoing
    /// a *user's* app possible — the same mechanism Appium's mac driver and desktop agents use.
    static func axElements(appNamed name: String, maxDepth: Int = 14) -> [Element] {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
                || $0.bundleIdentifier?.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            Log.write("UIQuery: no running app named \(name)")
            return []
        }
        guard AXIsProcessTrusted() else {
            Log.write("UIQuery: Accessibility not granted — cannot inspect \(name)")
            return []
        }
        var out: [Element] = []
        let root = AXUIElementCreateApplication(app.processIdentifier)
        walk(root, depth: 0, maxDepth: maxDepth, into: &out)
        return out
    }

    private static func walk(_ element: AXUIElement, depth: Int, maxDepth: Int,
                             into out: inout [Element]) {
        guard depth <= maxDepth else { return }
        if let e = readElement(element) { out.append(e) }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString,
                                            &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children { walk(child, depth: depth + 1, maxDepth: maxDepth, into: &out) }
    }

    /// Reads one AX element into our shape, skipping anything without a usable label or frame.
    private static func readElement(_ element: AXUIElement) -> Element? {
        func string(_ attr: String) -> String? {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success
            else { return nil }
            if let s = ref as? String { return s }
            if let n = ref as? NSNumber { return n.stringValue }
            return nil
        }
        let role = string(kAXRoleAttribute) ?? ""
        // Prefer the visible title, then description, then value.
        let label = [string(kAXTitleAttribute), string(kAXDescriptionAttribute),
                     string(kAXValueAttribute)]
            .compactMap { $0 }.first { !$0.isEmpty } ?? ""
        guard !label.isEmpty, !role.isEmpty else { return nil }

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let p = posRef, let s = sizeRef,
              AXValueGetValue(p as! AXValue, .cgPoint, &origin),
              AXValueGetValue(s as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0
        else { return nil }

        var enabledRef: CFTypeRef?
        let enabled = AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString,
                                                    &enabledRef) == .success
            ? ((enabledRef as? Bool) ?? true) : true

        // AX already reports top-left origin screen coordinates.
        return Element(role: role, label: label,
                       frame: CGRect(origin: origin, size: size), enabled: enabled)
    }

    // MARK: - Serialising a snapshot

    /// Where a dump of the current UI tree is written, so an agent can read what's on screen and
    /// decide what to do instead of being told coordinates up front.
    static var dumpURL: URL { Paths.supportDirectory.appendingPathComponent("ui-tree.json") }

    @discardableResult
    static func writeDump(app: String?) -> Int {
        let elements = snapshot(app: app)
        let payload: [String: Any] = [
            "app": app ?? "DemoTape",
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "elements": elements.map {
                ["role": $0.role, "label": $0.label, "enabled": $0.enabled,
                 "x": $0.frame.minX, "y": $0.frame.minY,
                 "w": $0.frame.width, "h": $0.frame.height,
                 "centerX": $0.frame.midX, "centerY": $0.frame.midY]
            }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: dumpURL, options: .atomic)
        }
        Log.write("UIQuery: dumped \(elements.count) elements for \(app ?? "DemoTape")")
        return elements.count
    }
}
