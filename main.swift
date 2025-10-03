import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

// MARK: - Configuration

struct HotKeyConfiguration {
    let keyCode: UInt16
    let modifiers: CGEventFlags

    var usesKeyCode: Bool { keyCode != 0 }

    func matchesKeyEvent(_ event: CGEvent) -> Bool {
        guard usesKeyCode else { return false }
        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        return eventKeyCode == keyCode && modifiers.isSubset(of: event.flags)
    }

    func matchesModifiers(_ flags: CGEventFlags) -> Bool {
        modifiers.isSubset(of: flags)
    }
}

struct WindowDraggerConfiguration {
    let dragHotKey: HotKeyConfiguration
    let resizeHotKey: HotKeyConfiguration
    let emergencyStopKeyCode: UInt16
    let minimumWindowSize: CGSize
    let updateInterval: CFTimeInterval

    static let `default` = WindowDraggerConfiguration(
        dragHotKey: HotKeyConfiguration(
            keyCode: 0,
            modifiers: [.maskCommand, .maskControl]
        ),
        resizeHotKey: HotKeyConfiguration(
            keyCode: 0,
            modifiers: [.maskShift, .maskCommand, .maskControl]
        ),
        emergencyStopKeyCode: 53,
        minimumWindowSize: CGSize(width: 100, height: 100),
        updateInterval: 1.0 / 240.0
    )
}

// MARK: - State Management
enum DraggerState {
    case idle
    case armed
    case dragging
    case resizeArmed
    case resizing
}

// MARK: - Main Window Dragger
class WindowDragger {
    private let configuration: WindowDraggerConfiguration
    private let dragHotKey: HotKeyConfiguration
    private let resizeHotKey: HotKeyConfiguration
    private let emergencyStopKeyCode: UInt16
    private let minimumWindowSize: CGSize
    private let updateInterval: CFTimeInterval

    private var state: DraggerState = .idle
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    // Drag state
    private var initialMousePosition: CGPoint = .zero
    private var initialWindowOrigin: CGPoint = .zero
    private var capturedWindow: AXUIElement?
    private var capturedPID: pid_t = 0
    
    // Resize state
    private var initialWindowSize: CGSize = .zero
    
    // Rate limiting
    private var lastUpdateTime: CFTimeInterval = 0

    init(configuration: WindowDraggerConfiguration = .default) {
        self.configuration = configuration
        self.dragHotKey = configuration.dragHotKey
        self.resizeHotKey = configuration.resizeHotKey
        self.emergencyStopKeyCode = configuration.emergencyStopKeyCode
        self.minimumWindowSize = configuration.minimumWindowSize
        self.updateInterval = configuration.updateInterval
    }
    
    func start() {
        // Check accessibility permissions
        guard checkAccessibilityPermissions() else {
            exit(1)
        }
        
        // Create event tap
        setupEventTap()
        
        // Start run loop
        let triggerDescription = hotKeyDescription(for: dragHotKey, action: "Move windows")
        let resizeDescription = hotKeyDescription(for: resizeHotKey, action: "Resize windows")
        fputs("Window Dragger started.\n", stderr)
        fputs("\(triggerDescription)\n", stderr)
        fputs("\(resizeDescription)\n", stderr)
        fputs("Press \(emergencyStopDescription()) to stop the current operation, Ctrl+C to quit.\n", stderr)
        
        CFRunLoopRun()
    }
    
    private func checkAccessibilityPermissions() -> Bool {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            fputs("❌ Accessibility permission required!\n", stderr)
            fputs("\n", stderr)
            fputs("Please add this binary to System Settings → Privacy & Security → Accessibility:\n", stderr)
            fputs("1. Run this binary once\n", stderr)
            fputs("2. Open System Settings → Privacy & Security → Accessibility\n", stderr)
            fputs("3. Add this binary to the list\n", stderr)
            fputs("4. Restart this binary\n", stderr)
        }
        return trusted
    }
    
    private func hotKeyDescription(for hotKey: HotKeyConfiguration, action: String) -> String {
        let modifierNames = modifierDescription(for: hotKey.modifiers)

        if hotKey.usesKeyCode {
            let keyName = keyName(for: hotKey.keyCode)
            if modifierNames.isEmpty {
                return "\(action): Press \(keyName) and drag the mouse."
            } else {
                return "\(action): Press \(modifierNames)+\(keyName) and drag the mouse."
            }
        }

        if !modifierNames.isEmpty {
            return "\(action): Press \(modifierNames) and drag the mouse."
        }

        return "\(action): Drag the mouse."
    }

    private func emergencyStopDescription() -> String {
        keyName(for: emergencyStopKeyCode)
    }

    private func keyName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 49: return "Space"
        case 53: return "Esc"
        case 48: return "Tab"
        case 96: return "F20"
        case 105: return "F13"
        case 106: return "F14"
        case 107: return "F15"
        case 109: return "F16"
        case 103: return "F17"
        case 111: return "F18"
        case 113: return "F19"
        default: return "Key(\(keyCode))"
        }
    }
    
    private func modifierDescription(for modifiers: CGEventFlags) -> String {
        var parts: [String] = []
        
        if modifiers.contains(.maskCommand) {
            parts.append("Cmd")
        }
        if modifiers.contains(.maskControl) {
            parts.append("Ctrl")
        }
        if modifiers.contains(.maskAlternate) {
            parts.append("Opt")
        }
        if modifiers.contains(.maskShift) {
            parts.append("Shift")
        }
        
        return parts.joined(separator: "+")
    }
    
    private func setupEventTap() {
        let eventMask = (1 << CGEventType.mouseMoved.rawValue) | 
                       (1 << CGEventType.flagsChanged.rawValue) |
                       (1 << CGEventType.leftMouseDragged.rawValue) |
                       (1 << CGEventType.keyDown.rawValue)
        
        eventTap = CGEvent.tapCreate(
            tap: CGEventTapLocation(rawValue: 0)!, // kCGHIDEventTap
            place: CGEventTapPlacement(rawValue: 0)!, // kCGHeadInsertEventTap
            options: CGEventTapOptions(rawValue: 0)!, // kCGEventTapOptionDefault
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                let dragger = Unmanaged<WindowDragger>.fromOpaque(refcon!).takeUnretainedValue()
                return dragger.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        
        guard let eventTap = eventTap else {
            fputs("❌ Failed to create event tap\n", stderr)
            exit(1)
        }
        
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)
    }
    
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .keyDown {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

            if keyCode == emergencyStopKeyCode {
                if state == .dragging || state == .resizing {
                    stopCurrentOperation()
                }
                return nil
            }

            if dragHotKey.matchesKeyEvent(event) {
                handleTriggerKeyPressed()
                return nil
            }

            if resizeHotKey.matchesKeyEvent(event) {
                handleResizeKeyPressed()
                return nil
            }
        }

        if type == .flagsChanged && (!dragHotKey.usesKeyCode || !resizeHotKey.usesKeyCode) {
            handleFlagsChanged(event: event)
            return Unmanaged.passUnretained(event)
        }

        if type == .mouseMoved || type == .leftMouseDragged {
            handleMouseMoved(event: event)
            return Unmanaged.passUnretained(event)
        }
        
        return Unmanaged.passUnretained(event)
    }
    
    private func handleTriggerKeyPressed() {
        switch state {
        case .idle:
            state = .armed
            fputs("🔧 Armed via trigger key\n", stderr)
            
        case .armed, .dragging:
            stopDragging()
            
        case .resizeArmed, .resizing:
            stopResizing()
        }
    }
    
    private func handleResizeKeyPressed() {
        switch state {
        case .idle:
            state = .resizeArmed
            fputs("📏 Resize armed via trigger key\n", stderr)
            
        case .resizeArmed, .resizing:
            stopResizing()
            
        case .armed, .dragging:
            stopDragging()
        }
    }
    
    private func handleFlagsChanged(event: CGEvent) {
        let flags = event.flags
        let resizeShortcutActive = !resizeHotKey.usesKeyCode && resizeModifiersActive(flags: flags)
        let dragShortcutActive = !dragHotKey.usesKeyCode && dragModifiersActive(flags: flags)
        let dragOnlyActive = dragShortcutActive && !resizeShortcutActive

        if resizeShortcutActive {
            switch state {
            case .idle, .armed:
                state = .resizeArmed
                fputs("📏 Resize armed - move mouse over a window\n", stderr)
            case .dragging:
                // Let mouse movement handler take care of switching to resize
                break
            case .resizeArmed, .resizing:
                break
            }
        } else if dragOnlyActive {
            switch state {
            case .idle, .resizeArmed:
                state = .armed
                fputs("🔧 Armed - move mouse over a window\n", stderr)
            case .resizing:
                stopResizing()
                state = .armed
                fputs("🔧 Armed - move mouse over a window\n", stderr)
            case .armed, .dragging:
                break
            }
        } else {
            // No modifiers are active anymore - stop any ongoing work
            switch state {
            case .armed, .dragging:
                stopDragging()
            case .resizeArmed, .resizing:
                stopResizing()
            case .idle:
                break
            }
        }
    }
    
    private func handleMouseMoved(event: CGEvent) {
        let flags = event.flags
        let resizeStateActive = state == .resizeArmed || state == .resizing
        let dragStateActive = state == .armed || state == .dragging

        let resizeActive = resizeHotKey.usesKeyCode
            ? (resizeStateActive && resizeModifiersActive(flags: flags))
            : resizeModifiersActive(flags: flags)

        let dragActive = dragHotKey.usesKeyCode
            ? (dragStateActive && dragModifiersActive(flags: flags))
            : dragModifiersActive(flags: flags)
        let dragOnlyActive = dragActive && !resizeActive
        
        // Rate limiting
        let currentTime = CFAbsoluteTimeGetCurrent()
        if currentTime - lastUpdateTime < updateInterval {
            return
        }
        lastUpdateTime = currentTime
        
        // Dynamic switch with priority for dragging
        if dragOnlyActive && (state == .resizing || state == .resizeArmed) {
            // Switch from resizing to dragging
            stopResizing()
            if let window = hitTestWindow(at: event.location) {
                startDragging(window: window, initialMouse: event.location)
            } else {
                state = .armed
                fputs("🔧 Armed - move mouse over a window\n", stderr)
            }
            return
        }

        switch state {
        case .armed:
            if resizeActive {
                state = .resizeArmed
                fputs("📏 Resize armed - move mouse over a window\n", stderr)
            } else if dragOnlyActive {
                if let window = hitTestWindow(at: event.location) {
                    startDragging(window: window, initialMouse: event.location)
                }
            } else {
                state = .idle
                fputs("💤 Idle\n", stderr)
            }

        case .dragging:
            if resizeActive {
                if let window = capturedWindow {
                    let windowRef = window
                    let location = event.location
                    stopDragging()
                    startResizing(window: windowRef, initialMouse: location)
                } else {
                    stopDragging()
                }
            } else if dragOnlyActive && capturedWindow != nil {
                updateWindowPosition(currentMouse: event.location)
            } else {
                stopDragging()
            }

        case .resizeArmed:
            if resizeActive {
                if let window = hitTestWindow(at: event.location) {
                    startResizing(window: window, initialMouse: event.location)
                }
            } else if dragOnlyActive {
                state = .armed
                fputs("🔧 Armed - move mouse over a window\n", stderr)
            } else {
                state = .idle
                fputs("💤 Idle\n", stderr)
            }

        case .resizing:
            if resizeActive && capturedWindow != nil {
                updateWindowSize(currentMouse: event.location)
            } else {
                stopResizing()
            }
            
        case .idle:
            break
        }
    }
    
    private func dragModifiersActive(flags: CGEventFlags) -> Bool {
        return dragHotKey.matchesModifiers(flags)
    }

    private func resizeModifiersActive(flags: CGEventFlags) -> Bool {
        return resizeHotKey.matchesModifiers(flags)
    }
    
    private func hitTestWindow(at location: CGPoint) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(systemWide, Float(location.x), Float(location.y), &element)
        
        guard result == .success, let uiElement = element else {
            return nil
        }
        
        // Walk up to find window
        var currentElement = uiElement
        
        while true {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(currentElement, kAXRoleAttribute as CFString, &role)
            
            if let roleString = role as? String, roleString == kAXWindowRole {
                // Check if window is movable
                if isWindowMovable(currentElement) {
                    return currentElement
                }
                break
            }
            
            var parent: CFTypeRef?
            if AXUIElementCopyAttributeValue(currentElement, kAXParentAttribute as CFString, &parent) == .success,
               let parentElement = parent {
                currentElement = parentElement as! AXUIElement
            } else {
                break
            }
        }
        
        return nil
    }
    
    private func isWindowMovable(_ window: AXUIElement) -> Bool {
        // Check if window has position attribute (movable)
        var position: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position)
        
        guard result == .success else {
            return false
        }
        
        // Check if window is not minimized
        var minimized: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
           let isMinimized = minimized as? Bool, isMinimized {
            return false
        }
        
        // Note: kAXFullscreenAttribute may not be available in all macOS versions
        // Skip fullscreen check for compatibility
        
        return true
    }
    
    private func startDragging(window: AXUIElement, initialMouse: CGPoint) {
        // Get window position and PID
        guard let windowOrigin = getWindowOrigin(window),
              let pid = getWindowPID(window) else {
            fputs("❌ Failed to get window info\n", stderr)
            return
        }
        
        // Activate the application
        activateApp(pid: pid)
        
        // Store drag state
        capturedWindow = window
        capturedPID = pid
        initialMousePosition = initialMouse
        initialWindowOrigin = windowOrigin
        state = .dragging
        
        fputs("🎯 Dragging window (PID: \(pid))\n", stderr)
    }
    
    private func updateWindowPosition(currentMouse: CGPoint) {
        guard let window = capturedWindow else {
            stopDragging()
            return
        }
        
        // Calculate delta and new position
        let deltaX = currentMouse.x - initialMousePosition.x
        let deltaY = currentMouse.y - initialMousePosition.y
        
        let newOrigin = CGPoint(
            x: initialWindowOrigin.x + deltaX,
            y: initialWindowOrigin.y + deltaY
        )
        
        // Update window position
        if !setWindowOrigin(window: window, origin: newOrigin) {
            fputs("⚠️ Failed to move window, stopping drag\n", stderr)
            stopDragging()
        }
    }
    
    private func stopDragging() {
        capturedWindow = nil
        capturedPID = 0
        initialMousePosition = .zero
        initialWindowOrigin = .zero
        state = .idle
        fputs("💤 Idle\n", stderr)
    }
    
    // MARK: - Resize Functions
    
    private func startResizing(window: AXUIElement, initialMouse: CGPoint) {
        // Get window size and PID
        guard let windowSize = getWindowSize(window),
              let pid = getWindowPID(window) else {
            fputs("❌ Failed to get window info for resize\n", stderr)
            return
        }
        
        // Activate the application
        activateApp(pid: pid)
        
        // Store resize state
        capturedWindow = window
        capturedPID = pid
        initialMousePosition = initialMouse
        initialWindowSize = windowSize
        state = .resizing
        
        fputs("📏 Resizing window (PID: \(pid))\n", stderr)
    }
    
    private func updateWindowSize(currentMouse: CGPoint) {
        guard let window = capturedWindow else {
            stopResizing()
            return
        }
        
        // Calculate delta and new size
        let deltaX = currentMouse.x - initialMousePosition.x
        let deltaY = currentMouse.y - initialMousePosition.y
        
        let newSize = CGSize(
            width: max(minimumWindowSize.width, initialWindowSize.width + deltaX),
            height: max(minimumWindowSize.height, initialWindowSize.height + deltaY)
        )
        
        // Update window size
        if !setWindowSize(window: window, size: newSize) {
            fputs("⚠️ Failed to resize window, stopping resize\n", stderr)
            stopResizing()
        }
    }
    
    private func stopResizing() {
        capturedWindow = nil
        capturedPID = 0
        initialMousePosition = .zero
        initialWindowSize = .zero
        state = .idle
        fputs("💤 Idle\n", stderr)
    }
    
    private func stopCurrentOperation() {
        switch state {
        case .dragging:
            stopDragging()
        case .resizing:
            stopResizing()
        default:
            state = .idle
            fputs("💤 Idle\n", stderr)
        }
    }
    
    // MARK: - Helper Functions
    
    private func getWindowOrigin(_ window: AXUIElement) -> CGPoint? {
        var position: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              let pointValue = position else {
            return nil
        }
        
        var point = CGPoint.zero
        AXValueGetValue(pointValue as! AXValue, AXValueType.cgPoint, &point)
        return point
    }
    
    private func getWindowPID(_ window: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        let result = AXUIElementGetPid(window, &pid)
        return result == .success ? pid : nil
    }
    
    private func activateApp(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return
        }
        
        app.activate(options: [])
    }
    
    private func setWindowOrigin(window: AXUIElement, origin: CGPoint) -> Bool {
        var point = origin
        guard let positionValue = AXValueCreate(AXValueType.cgPoint, &point) else {
            return false
        }
        
        let result = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        return result == .success
    }
    
    private func getWindowSize(_ window: AXUIElement) -> CGSize? {
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let sizeValue = size else {
            return nil
        }
        
        var cgSize = CGSize.zero
        AXValueGetValue(sizeValue as! AXValue, AXValueType.cgSize, &cgSize)
        return cgSize
    }
    
    private func setWindowSize(window: AXUIElement, size: CGSize) -> Bool {
        var cgSize = size
        guard let sizeValue = AXValueCreate(AXValueType.cgSize, &cgSize) else {
            return false
        }
        
        let result = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        return result == .success
    }
}

// MARK: - Main
@main
struct Main {
    static func main() {
        let dragger = WindowDragger()
        
        // Handle Ctrl+C
        signal(SIGINT) { _ in
            fputs("\n👋 Goodbye!\n", stderr)
            exit(0)
        }
        
        dragger.start()
    }
}
