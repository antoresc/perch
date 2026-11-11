import AppKit

/// Keeps a window in its own layer above every desktop, so it stays put at the notch
/// instead of sliding sideways when you swipe between desktops.
///
/// macOS has no public way to do this: a window that joins all desktops is still carried along
/// with each one during the swipe. This uses the window server's own calls, looked up at run
/// time. If a future macOS removes them, `pin` returns false and the panel simply behaves as before.
enum FixedSpace {
    private typealias DefaultConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SetLevel = @convention(c) (Int32, UInt64, Int32) -> Void
    private typealias AddWindows = @convention(c) (Int32, CFArray, CFArray) -> Void
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Void

    private static var space: UInt64 = 0

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        // -2 is RTLD_DEFAULT: search everything already loaded.
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    @discardableResult
    static func pin(_ window: NSWindow) -> Bool {
        if ProcessInfo.processInfo.environment["PERCH_NO_FIXED_SPACE"] != nil { return false }
        guard window.windowNumber > 0,
              let connection = symbol("_CGSDefaultConnection", as: DefaultConnection.self),
              let create = symbol("CGSSpaceCreate", as: SpaceCreate.self),
              let setLevel = symbol("CGSSpaceSetAbsoluteLevel", as: SetLevel.self),
              let add = symbol("CGSAddWindowsToSpaces", as: AddWindows.self),
              let show = symbol("CGSShowSpaces", as: ShowSpaces.self)
        else { return false }

        let cid = connection()
        if space == 0 {
            // The flag must be 1, otherwise Finder draws desktop icons in the new layer.
            space = create(cid, 1, nil)
            guard space != 0 else { return false }
            setLevel(cid, space, Int32.max)
            show(cid, [NSNumber(value: space)] as CFArray)
        }
        add(cid, [NSNumber(value: window.windowNumber)] as CFArray, [NSNumber(value: space)] as CFArray)
        return true
    }
}
