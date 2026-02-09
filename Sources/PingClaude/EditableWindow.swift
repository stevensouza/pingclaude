import Cocoa

/// NSWindow subclass that routes Cmd+C/V/X/A to the first responder.
/// Required for LSUIElement apps where there's no visible menu bar
/// to provide standard Edit menu keyboard shortcuts.
class EditableWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "c":
                if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) { return true }
            case "v":
                if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) { return true }
            case "x":
                if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) { return true }
            case "a":
                if NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self) { return true }
            case "z":
                if event.modifierFlags.contains(.shift) {
                    if NSApp.sendAction(NSSelectorFromString("redo:"), to: nil, from: self) { return true }
                } else {
                    if NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: self) { return true }
                }
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
