import UIKit
import XCTest

/// Drives SwiftUI controls in a hosted unit test by their accessibility label. The accessibility
/// tree is empty under an XCTest host until automation is switched on; this does that through the
/// simulator's `libAccessibility` and walks the tree for an element to activate.
@MainActor
enum AccessibilityTestSupport {
    private static var enabled = false

    static func enableAutomation() {
        guard !enabled else { return }
        enabled = true
        let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW)
            ?? dlopen("libAccessibility.dylib", RTLD_NOW)
        guard let handle, let sym = dlsym(handle, "_AXSSetAutomationEnabled") else { return }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(sym, to: SetEnabled.self)(1)
    }

    /// Every accessibility element reachable from `root`, depth first.
    static func elements(in root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        var out: [NSObject] = []
        func walk(_ node: NSObject) {
            guard seen.insert(ObjectIdentifier(node)).inserted else { return }
            out.append(node)
            if let view = node as? UIView { view.subviews.forEach(walk) }
            if let elements = node.accessibilityElements as? [NSObject] { elements.forEach(walk) }
            let count = node.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for i in 0..<count { if let e = node.accessibilityElement(at: i) as? NSObject { walk(e) } }
            }
        }
        walk(root)
        return out
    }

    /// Labels of everything reachable, for failure messages.
    static func labels(in root: NSObject) -> [String] {
        elements(in: root).compactMap { $0.accessibilityLabel }.filter { !$0.isEmpty }
    }

    /// Activates the first element whose label contains `text`. Returns false when none was found
    /// or the activation was refused.
    @discardableResult
    static func activate(label text: String, in root: NSObject) -> Bool {
        guard let element = elements(in: root).first(where: {
            ($0.accessibilityLabel ?? "").localizedCaseInsensitiveContains(text)
        }) else { return false }
        return element.accessibilityActivate()
    }
}
