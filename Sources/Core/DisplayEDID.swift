import CoreGraphics
import Foundation
import IOKit

/// Reads a display's EDID blob out of IOKit.
///
/// `CGDisplayIOServicePort` — the documented way to find a display's I/O service —
/// returns 0 on Apple silicon (verified on M4 Max / macOS 27.0.1), so it cannot be
/// used. The blob itself is reachable through plain class matching on the display
/// port transport, which is public IOKit and needs no special rights.
///
/// Only the EDID lives here. The link budget and vendor refresh range sit on
/// undocumented Apple DCP classes and are therefore isolated in
/// `Sources/Optional/DisplayLinkInfo.swift`.
public enum DisplayEDIDReader {

    /// The panel's EDID, or `nil` when the display exposes none (virtual screens,
    /// some KVMs) or the blob does not parse.
    public static func read(for displayID: CGDirectDisplayID) -> EDID? {
        let candidate = Candidate(vendor: CGDisplayVendorNumber(displayID),
                                  product: CGDisplayModelNumber(displayID),
                                  serial: CGDisplaySerialNumber(displayID))

        var blobs: [EDID] = []
        for className in transportClassNames {
            for service in services(named: className) {
                defer { IOObjectRelease(service) }
                if let data = property(of: service, key: "EDID") as? Data,
                   let edid = EDID(data: data) {
                    blobs.append(edid)
                }
            }
        }
        guard !blobs.isEmpty else { return nil }
        return blobs.first { candidate.matches($0) } ?? (blobs.count == 1 ? blobs[0] : nil)
    }

    /// Whether anything in the registry publishes a display transport at all.
    ///
    /// A missing EDID has two very different causes, and `read(for:)` returning
    /// `nil` collapses them: a *virtual* screen (VM, headless runner, screen
    /// sharing) has no port transport in the registry and therefore no EDID to
    /// read — an environment, not a fault; a real panel whose port exists but
    /// whose descriptors did not come back is a genuine failure. Callers that
    /// report results need to tell those apart, so this exposes the registry
    /// question separately.
    public static func hasTransportService() -> Bool {
        for className in transportClassNames {
            let found = services(named: className)
            found.forEach { IOObjectRelease($0) }
            if !found.isEmpty { return true }
        }
        return false
    }

    /// Asks the display driver to re-read its descriptors, then reports whether
    /// the mode list actually changed.
    ///
    /// This is the open question in the override path: writing the plist is easy,
    /// but the system only reads it at enumeration time. `IOServiceRequestProbe`
    /// is the documented rescan request; on some machines it is not enough and the
    /// cable has to be re-plugged. The return value is therefore a verified
    /// answer, not a "probably worked".
    public static func requestReprobe(for displayID: CGDirectDisplayID,
                                      timeout: TimeInterval = 3.0) -> Bool {
        let before = modeSignature(for: displayID)
        for className in transportClassNames {
            for service in services(named: className) {
                _ = IOServiceRequestProbe(service, 0)
                IOObjectRelease(service)
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if modeSignature(for: displayID) != before { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    // MARK: - IOKit plumbing

    /// The generic class is tried first because it also covers embedded
    /// (built-in) panels; the concrete one covers the rest.
    static let transportClassNames = [
        "IOPortTransportState",
        "IOPortTransportStateDisplayPort",
    ]

    private struct Candidate {
        let vendor: UInt32
        let product: UInt32
        let serial: UInt32

        func matches(_ edid: EDID) -> Bool {
            guard edid.vendor == vendor, edid.product == product else { return false }
            // Some panels put 0 in the binary serial while CoreGraphics
            // synthesises one from the string descriptor.
            return edid.serial == 0 || serial == 0 || edid.serial == serial
        }
    }

    /// Caller owns the returned services and must release each one.
    static func services(named className: String) -> [io_service_t] {
        guard let matching = IOServiceMatching(className) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [io_service_t] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            result.append(service)
            service = IOIteratorNext(iterator)
        }
        return result
    }

    static func property(of service: io_service_t, key: String) -> AnyObject? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    static func dictionary(of service: io_service_t, key: String) -> [String: Any]? {
        property(of: service, key: key) as? [String: Any]
    }

    /// Cheap fingerprint of a display's mode list, used to tell whether a reprobe
    /// actually did anything.
    private static func modeSignature(for displayID: CGDirectDisplayID) -> Int {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) else { return 0 }
        var hash = CFArrayGetCount(modes)
        for index in 0..<CFArrayGetCount(modes) {
            guard let pointer = CFArrayGetValueAtIndex(modes, index) else { continue }
            let mode = Unmanaged<CGDisplayMode>.fromOpaque(pointer).takeUnretainedValue()
            hash = hash &* 31 &+ Int(mode.ioDisplayModeID)
            hash = hash &* 31 &+ Int(mode.width)
            hash = hash &* 31 &+ Int(mode.refreshRate.rounded())
        }
        return hash
    }
}
