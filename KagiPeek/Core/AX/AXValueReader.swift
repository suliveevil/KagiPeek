import ApplicationServices

/// Typed reads over `AXUIElementCopyAttributeValue`.
///
/// The Accessibility API answers every question with the same untyped `CFTypeRef?`, so
/// every read is really three steps: copy the attribute, check the CoreFoundation type ID,
/// cast to the concrete type. `MenuScanner` and `WindowGeometry` had each written that
/// ladder by hand, and the two copies had already drifted — one guarded against `CFNull`,
/// the other did not. This is the one copy; the callers name the type they want.
///
/// `nonisolated`: these are stateless CF calls, and `MenuScanner` walks menus on a
/// background queue. Marking this main-actor would drag the whole walk onto the main
/// thread, which is exactly what the background queue exists to avoid.
nonisolated enum AXValueReader {
    static func element(_ name: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = value(name, of: element), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    static func string(_ name: String, of element: AXUIElement) -> String? {
        guard let value = value(name, of: element), CFGetTypeID(value) == CFStringGetTypeID() else {
            return nil
        }
        return value as? String
    }

    static func int(_ name: String, of element: AXUIElement) -> Int? {
        guard let value = value(name, of: element), CFGetTypeID(value) == CFNumberGetTypeID() else {
            return nil
        }
        return (value as? NSNumber)?.intValue
    }

    static func bool(_ name: String, of element: AXUIElement, fallback: Bool) -> Bool {
        guard let value = value(name, of: element), CFGetTypeID(value) == CFBooleanGetTypeID() else {
            return fallback
        }
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }

    static func point(_ name: String, of element: AXUIElement) -> CGPoint? {
        guard let value = value(name, of: element), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgPoint, &point) else { return nil }
        return point
    }

    static func size(_ name: String, of element: AXUIElement) -> CGSize? {
        guard let value = value(name, of: element), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgSize, &size) else { return nil }
        return size
    }

    /// The children of a menu element.
    ///
    /// Heterogeneous arrays are normal — a menu holds separators next to items — so
    /// non-elements are skipped rather than failing the whole read.
    static func children(of element: AXUIElement) -> [AXUIElement] {
        guard let value = value(kAXChildrenAttribute, of: element), CFGetTypeID(value) == CFArrayGetTypeID() else {
            return []
        }
        let array = unsafeDowncast(value, to: CFArray.self)
        let count = CFArrayGetCount(array)
        guard count > 0 else { return [] }
        var result: [AXUIElement] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            guard let slot = CFArrayGetValueAtIndex(array, index) else { continue }
            // The array stores the object pointer itself, not the address of a slot holding
            // it — so this is `Unmanaged`, not a load through the pointer.
            let child = Unmanaged<AnyObject>.fromOpaque(slot).takeUnretainedValue()
            guard CFGetTypeID(child) == AXUIElementGetTypeID() else { continue }
            result.append(unsafeDowncast(child, to: AXUIElement.self))
        }
        return result
    }

    // MARK: -

    /// Copies one attribute and hands back whatever CoreFoundation type the element used.
    ///
    /// `nil` covers two cases: the attribute is absent, and the element answered with
    /// `CFNull`. A null value fails the type check at the step above either way, so folding
    /// it in here keeps every reader a two-line guard.
    private static func value(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        guard let value else { return nil }
        if CFGetTypeID(value) == CFNullGetTypeID() { return nil }
        return value
    }
}
