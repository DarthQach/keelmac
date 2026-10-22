import Foundation
import HelperCore
import HelperShared

// KeelMacHelper: launchd starts this as root on demand when KeelMac connects to its Mach service.
// It accepts only KeelMac signed by the same team and runs only HelperOperation cases (see Packages/MaintenanceKit).
let delegate = HelperListenerDelegate.production()
let listener = NSXPCListener(machServiceName: helperMachServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
