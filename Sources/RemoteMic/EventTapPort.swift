import CoreGraphics
import Foundation

// Adapted from upstream 4c43641: disabling a tap does not unregister its port.
enum EventTapPort {
    static func release(port: CFMachPort?, source: CFRunLoopSource?) {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
    }
}
