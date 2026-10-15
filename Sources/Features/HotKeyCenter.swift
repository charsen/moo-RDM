import AppKit
import Carbon.HIToolbox
import Foundation

/// A single global keyboard shortcut.
///
/// Stored as a Carbon key code plus Carbon modifier flags so it can be handed
/// straight to `RegisterEventHotKey`, and cached as a display string so the UI
/// does not have to rebuild it.
public struct HotKeySpec: Codable, Hashable, Sendable {

    public var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
    public var modifiers: UInt32
    /// Pre-rendered form such as "⌃⌥⌘→".
    public var display: String

    public init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    public static let none = HotKeySpec(keyCode: 0, modifiers: 0, display: "")

    public var isEmpty: Bool { display.isEmpty }

    /// A shortcut with no modifier is not allowed — it would swallow ordinary typing.
    public var isValid: Bool { !isEmpty && modifiers != 0 }

    // MARK: - Conversion

    /// Builds a spec from an AppKit key event.
    public static func from(event: NSEvent) -> HotKeySpec? {
        let keyCode = UInt32(event.keyCode)
        guard let name = Self.keyName(for: event.keyCode) else { return nil }

        var carbon: UInt32 = 0
        var symbols = ""
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.control) { carbon |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option)  { carbon |= UInt32(optionKey);  symbols += "⌥" }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey);   symbols += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey);     symbols += "⌘" }

        guard carbon != 0 else { return nil }
        return HotKeySpec(keyCode: keyCode, modifiers: carbon, display: symbols + name)
    }

    /// Human-readable name for a virtual key code.
    public static func keyName(for keyCode: UInt16) -> String? {
        if let special = specialKeys[Int(keyCode)] { return special }
        // Fall back to the unmodified character produced by this key code.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawLayout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(rawLayout).takeUnretainedValue() as Data

        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(layout,
                                  keyCode,
                                  UInt16(kUCKeyActionDisplay),
                                  0,
                                  UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState,
                                  characters.count,
                                  &length,
                                  &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length).uppercased()
        return text.isEmpty ? nil : text
    }

    private static let specialKeys: [Int: String] = [
        0x24: "↩", 0x30: "⇥", 0x31: "Space", 0x33: "⌫", 0x35: "⎋", 0x75: "⌦",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        0x73: "↖", 0x77: "↘", 0x74: "⇞", 0x79: "⇟", 0x72: "Help", 0x6E: "Menu",
    ]
}

/// Registers global hotkeys through Carbon's `RegisterEventHotKey`.
///
/// Deliberately **not** `CGEventTap`: Carbon hotkeys need no Accessibility
/// permission, so RDM-ARM never asks for one.
public final class HotKeyCenter {

    public static let shared = HotKeyCenter()

    /// The four-character signature identifying our hotkeys to Carbon ('RDMA').
    private static let signature: OSType = 0x5244_4D41

    private var handlerRef: EventHandlerRef?
    private var registeredRefs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var nextIdentifier: UInt32 = 1

    private init() {}

    // MARK: - Registration

    /// Registers `spec`. Returns false when the system refuses (usually a conflict
    /// with another app that already owns the combination).
    @discardableResult
    public func register(_ spec: HotKeySpec, handler: @escaping () -> Void) -> Bool {
        guard spec.isValid else { return false }
        installEventHandlerIfNeeded()

        let identifier = nextIdentifier
        nextIdentifier += 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        let status = RegisterEventHotKey(spec.keyCode,
                                         spec.modifiers,
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        guard status == noErr, let ref else { return false }

        registeredRefs[identifier] = ref
        actions[identifier] = handler
        return true
    }

    /// Releases every registered shortcut.
    public func unregisterAll() {
        for ref in registeredRefs.values { UnregisterEventHotKey(ref) }
        registeredRefs.removeAll()
        actions.removeAll()
    }

    // MARK: - Dispatch

    fileprivate func fire(identifier: UInt32) {
        actions[identifier]?()
    }

    private func installEventHandlerIfNeeded() {
        guard handlerRef == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        // The closure captures nothing, so it is a valid C function pointer.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKeyID)
            guard status == noErr else { return noErr }
            Unmanaged<HotKeyCenter>.fromOpaque(userData)
                .takeUnretainedValue()
                .fire(identifier: hotKeyID.id)
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }
}
