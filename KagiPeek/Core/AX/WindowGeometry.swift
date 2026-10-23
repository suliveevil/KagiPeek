import AppKit
import ApplicationServices

/// Reads window/element frames from the Accessibility API and converts them to Cocoa
/// screen coordinates so the panel can sit next to the front window without covering it.
enum WindowGeometry {
    static func focusedWindowFrame(pid: pid_t) -> CGRect? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        guard let window = elementAttribute(kAXFocusedWindowAttribute, of: application) else { return nil }
        return frame(of: window)
    }

    static func focusedElementFrame(pid: pid_t) -> CGRect? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        guard let element = elementAttribute(kAXFocusedUIElementAttribute, of: application) else { return nil }
        return frame(of: element)
    }

    /// Converts an AX (top-left origin) rect into Cocoa (bottom-left origin) coordinates.
    static func cocoaRect(fromAX rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
        return CGRect(x: rect.origin.x, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The same flip the other way round: Cocoa (bottom-left origin) into the top-left
    /// origin that `CGEvent.location` and `CGWarpMouseCursorPosition` use. Spelled from the
    /// direction it is needed in — the arithmetic is its own inverse, because CG and AX
    /// share an origin.
    static func cgRect(fromCocoa rect: CGRect) -> CGRect {
        cocoaRect(fromAX: rect)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(kAXPositionAttribute, of: element),
              let size = sizeAttribute(kAXSizeAttribute, of: element) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func pointAttribute(_ name: String, of element: AXUIElement) -> CGPoint? {
        guard let value = attribute(name, of: element), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeAttribute(_ name: String, of element: AXUIElement) -> CGSize? {
        guard let value = attribute(name, of: element), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgSize, &size) else { return nil }
        return size
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func elementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, of: element), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
}
