import AppKit
import ApplicationServices
import CoreGraphics
import PennantCore
import Foundation

/// Reads the accessibility tree of an application and keeps an index → element cache so the
/// model can act on nodes by index. Used only from `DesktopController`.
final class AccessibilityReader: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [Int: AXUIElement] = [:]

    /// Structural roles that add nothing when they carry no text of their own.
    private static let structuralRoles: Set<String> = ["AXGroup", "AXSplitGroup", "AXScrollArea", "AXLayoutArea", "AXLayoutItem", "AXUnknown", "AXGenericElement", "AXList", "AXOutline", "AXTable", "AXToolbar", "AXWebArea"]

    /// Chromium-based apps build their web accessibility tree only when an assistive client asks for it.
    /// Setting `AXManualAccessibility` on the application element is the documented way to ask.
    static let chromiumBundlePrefixes = ["com.google.Chrome", "org.chromium", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser", "com.vivaldi", "com.operasoftware", "com.electron", "com.microsoft.VSCode", "com.todesktop"]

    static func enableWebAccessibilityIfNeeded(app: AXUIElement, pid: pid_t) {
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        guard chromiumBundlePrefixes.contains(where: { bundleID.hasPrefix($0) }) || hasEmptyWebArea(app) else { return }
        var current: CFTypeRef?
        let already = AXUIElementCopyAttributeValue(app, "AXManualAccessibility" as CFString, &current) == .success && (current as? Bool) == true
        guard !already else { return }
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        // Chromium builds the tree asynchronously; give it a moment before the first read.
        Thread.sleep(forTimeInterval: 0.6)
    }

    /// True when the front window holds an AXWebArea with no children (the Chromium "not enabled" shape).
    private static func hasEmptyWebArea(_ app: AXUIElement) -> Bool {
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success, let windows = windowsRef as? [AXUIElement], let window = windows.first else { return false }
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            var childrenRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
            let children = childrenRef as? [AXUIElement] ?? []
            if (roleRef as? String) == "AXWebArea" { return children.isEmpty }
            if depth < 12 { queue.append(contentsOf: children.map { ($0, depth + 1) }) }
        }
        return false
    }

    func tree(pid: pid_t, maxDepth: Int, maxNodes: Int) throws -> [AXNode] {
        guard AXIsProcessTrusted() else { throw DesktopError.permissionMissing("Accessibility") }
        let app = AXUIElementCreateApplication(pid)
        Self.enableWebAccessibilityIfNeeded(app: app, pid: pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        let depthLimit = max(1, maxDepth)
        let nodeLimit = max(1, maxNodes)
        let visitLimit = nodeLimit * 6

        var nodes: [AXNode] = []
        var newCache: [Int: AXUIElement] = [:]
        var queue: [(element: AXUIElement, depth: Int)] = [(app, 0)]
        var head = 0
        var visited = 0

        while head < queue.count, nodes.count < nodeLimit, visited < visitLimit {
            let (element, depth) = queue[head]
            head += 1
            visited += 1

            let role = Self.string(element, kAXRoleAttribute)
            let title = Self.string(element, kAXTitleAttribute)
            let value = String(Self.string(element, kAXValueAttribute).prefix(200))
            let description = Self.string(element, kAXDescriptionAttribute)
            let position = Self.point(element, kAXPositionAttribute)
            let size = Self.size(element, kAXSizeAttribute)
            let hasText = !title.isEmpty || !value.isEmpty || !description.isEmpty
            let hasFrame = position != nil && (size.map { $0.width > 0 && $0.height > 0 } ?? false)

            var include = depth > 0 && hasFrame && !role.isEmpty
            if include, Self.structuralRoles.contains(role), !hasText { include = false }

            if include, let position, let size {
                let enabled = Self.bool(element, kAXEnabledAttribute) ?? true
                let focused = Self.bool(element, kAXFocusedAttribute) ?? false
                let actions = Self.actions(element)
                let index = nodes.count
                nodes.append(AXNode(index: index, role: role, title: title, value: value, description: description,
                                    x: Double(position.x), y: Double(position.y), width: Double(size.width), height: Double(size.height),
                                    enabled: enabled, focused: focused, depth: depth, actions: actions))
                newCache[index] = element
            }

            if depth < depthLimit {
                for child in Self.children(element) {
                    queue.append((child, depth + 1))
                }
            }
        }

        lock.lock()
        cache = newCache
        lock.unlock()
        return nodes
    }

    func perform(index: Int, action: String) throws {
        let element = try cachedElement(index)
        let error = AXUIElementPerformAction(element, action as CFString)
        guard error == .success else { throw DesktopError.inputFailed("AX action \(action) on node \(index) failed (\(error.rawValue))") }
    }

    func setValue(index: Int, value: String) throws {
        let element = try cachedElement(index)
        let error = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
        guard error == .success else { throw DesktopError.inputFailed("Setting value on node \(index) failed (\(error.rawValue))") }
    }

    private func cachedElement(_ index: Int) throws -> AXUIElement {
        lock.lock(); defer { lock.unlock() }
        guard let element = cache[index] else {
            throw DesktopError.inputFailed("No UI node with index \(index); call ui_tree first")
        }
        return element
    }

    // MARK: Static helpers

    static func windowTitles(pid: pid_t, timeout: Float = 0.25) -> [String] {
        guard AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return windows.prefix(12).map { string($0, kAXTitleAttribute) }.filter { !$0.isEmpty }
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let list = names as? [String] else { return [] }
        return list
    }

    static func string(_ element: AXUIElement, _ name: String) -> String {
        guard let value = attribute(element, name) else { return "" }
        return stringify(value)
    }

    static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        guard let value = attribute(element, name) else { return nil }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    static func point(_ element: AXUIElement, _ name: String) -> CGPoint? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var point = CGPoint.zero
        guard AXValueGetType(axValue) == .cgPoint, AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    static func size(_ element: AXUIElement, _ name: String) -> CGSize? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var size = CGSize.zero
        guard AXValueGetType(axValue) == .cgSize, AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    static func stringify(_ value: AnyObject) -> String {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        if let url = value as? URL { return url.absoluteString }
        if let attributed = value as? NSAttributedString { return attributed.string }
        let typeID = CFGetTypeID(value)
        if typeID == AXValueGetTypeID() {
            let axValue = unsafeDowncast(value, to: AXValue.self)
            switch AXValueGetType(axValue) {
            case .cgPoint:
                var p = CGPoint.zero
                AXValueGetValue(axValue, .cgPoint, &p)
                return "(\(Int(p.x)), \(Int(p.y)))"
            case .cgSize:
                var s = CGSize.zero
                AXValueGetValue(axValue, .cgSize, &s)
                return "\(Int(s.width))x\(Int(s.height))"
            case .cfRange:
                var r = CFRange()
                AXValueGetValue(axValue, .cfRange, &r)
                return "range(\(r.location), \(r.length))"
            default:
                return ""
            }
        }
        if typeID == AXUIElementGetTypeID() {
            let element = unsafeDowncast(value, to: AXUIElement.self)
            let title = string(element, kAXTitleAttribute)
            return title.isEmpty ? "<element>" : "<\(title)>"
        }
        if let array = value as? [AnyObject] {
            return "[" + array.prefix(5).map { stringify($0) }.joined(separator: ", ") + (array.count > 5 ? ", …" : "") + "]"
        }
        return ""
    }
}
