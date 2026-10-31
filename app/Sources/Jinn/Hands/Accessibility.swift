import AppKit
import ApplicationServices

enum AX {
    static let clickable: Set<String> = ["AXButton", "AXMenuItem", "AXCheckBox", "AXRadioButton", "AXLink", "AXPopUpButton", "AXTab", "AXMenuBarItem", "AXDisclosureTriangle"]
    static let textual: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    static func describe(_ e: AXError) -> String {
        switch e {
        case .success: return "ok"
        case .illegalArgument: return "invalid argument"
        case .invalidUIElement: return "the element no longer exists (call app_state again)"
        case .cannotComplete: return "the app did not respond (busy or hung)"
        case .notImplemented: return "the app does not implement this"
        case .attributeUnsupported: return "this element does not have that property"
        case .actionUnsupported: return "this element does not support that action"
        case .apiDisabled: return "Accessibility permission is off for Jinn"
        case .parameterizedAttributeUnsupported, .noValue: return "no value"
        default: return "accessibility error \(e.rawValue)"
        }
    }

    static func configure() { AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.5) }

    static func attr(_ e: AXUIElement, _ k: String) -> AnyObject? {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(e, k as CFString, &v)
        return v
    }
    static func str(_ e: AXUIElement, _ k: String) -> String { (attr(e, k) as? String) ?? "" }
    static func pid(_ e: AXUIElement) -> pid_t { var p: pid_t = 0; AXUIElementGetPid(e, &p); return p }
    static func alive(_ e: AXUIElement) -> Bool { attr(e, kAXRoleAttribute) != nil }
    static func actions(_ e: AXUIElement) -> [String] {
        var names: CFArray?
        AXUIElementCopyActionNames(e, &names)
        return (names as? [String]) ?? []
    }

    private static let batchKeys: [String] = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
                                              kAXPlaceholderValueAttribute, kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute,
                                              kAXSubroleAttribute]

    static func batch(_ e: AXUIElement) -> [String: Any] {
        var out: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(e, batchKeys as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &out) == .success,
              let arr = out as? [Any] else { return [:] }
        var d: [String: Any] = [:]
        for (k, v) in zip(batchKeys, arr) {
            let cf = v as AnyObject
            if CFGetTypeID(cf) == AXValueGetTypeID() {
                if AXValueGetType(unsafeBitCast(cf, to: AXValue.self)) == .axError { continue }
            } else if v is NSNull { continue }
            d[k] = v
        }
        return d
    }

    static func point(_ v: Any?) -> CGPoint? {
        guard let v, CFGetTypeID(v as AnyObject) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(unsafeBitCast(v as AnyObject, to: AXValue.self), .cgPoint, &p) ? p : nil
    }
    static func size(_ v: Any?) -> CGSize? {
        guard let v, CFGetTypeID(v as AnyObject) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(unsafeBitCast(v as AnyObject, to: AXValue.self), .cgSize, &s) ? s : nil
    }

    static func window(_ app: AXUIElement) -> AXUIElement {
        for k in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] { if let w = attr(app, k) { return w as! AXUIElement } }
        if let ws = attr(app, kAXWindowsAttribute) as? [AXUIElement], let f = ws.first { return f }
        return app
    }
}
