import CoreGraphics
import Foundation

/// A resolution added to a display's mode table through the `scale-resolutions`
/// key of a display override.
///
/// The plist stores *backing-store* sizes as 8-byte big-endian `UInt32` pairs.
/// One entry produces both the HiDPI point size (half the backing store) and a
/// 1× mode at the backing size. RDM-ARM only writes the HiDPI form: a 1× mode
/// larger than the panel has no output timing the display ever declared, and is
/// exactly the kind of row that blacks a screen.
struct ScaledResolution: Hashable {
    let pointWidth: Int
    let pointHeight: Int
    /// Backing scale. Always 2 for entries this app writes.
    let scale: Int

    init(pointWidth: Int, pointHeight: Int, scale: Int = 2) {
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.scale = scale
    }

    var backingWidth: Int { pointWidth * scale }
    var backingHeight: Int { pointHeight * scale }

    /// The 8-byte big-endian `(backingWidth, backingHeight)` entry.
    var entry: Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(8)
        for value in [UInt32(backingWidth), UInt32(backingHeight)] {
            bytes.append(UInt8((value >> 24) & 0xFF))
            bytes.append(UInt8((value >> 16) & 0xFF))
            bytes.append(UInt8((value >> 8) & 0xFF))
            bytes.append(UInt8(value & 0xFF))
        }
        return Data(bytes)
    }

    /// Decodes an 8- or 16-byte plist entry. The trailing fields of the 16-byte
    /// form carry flags that this app does not need; the geometry is in the
    /// first eight bytes either way.
    static func decode(_ data: Data) -> ScaledResolution? {
        guard data.count >= 8 else { return nil }
        let bytes = [UInt8](data.prefix(8))
        let width = Self.bigEndian(bytes, at: 0)
        let height = Self.bigEndian(bytes, at: 4)
        guard width > 0, height > 0 else { return nil }
        if width % 2 == 0 && height % 2 == 0 {
            return ScaledResolution(pointWidth: Int(width / 2), pointHeight: Int(height / 2), scale: 2)
        }
        return ScaledResolution(pointWidth: Int(width), pointHeight: Int(height), scale: 1)
    }

    private static func bigEndian(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    var label: String {
        let mark = scale >= 2 ? " ⚡️" : ""
        return "\(pointWidth) × \(pointHeight)\(mark) (\(backingWidth) × \(backingHeight))"
    }
}

/// Reads and edits the `scale-resolutions` array of a display override.
///
/// Everything here is a pure function on dictionaries so the self test can pin
/// the wire format without writing `/Library` or attaching a display.
enum ScaleResolutionStore {

    enum ValidationFailure: Error, CustomStringConvertible {
        case geometryOutOfRange
        case alreadyOffered(DisplayMode)
        case alreadyInstalled(ScaledResolution)

        var description: String {
            switch self {
            case .geometryOutOfRange:
                return L10n.t("error.resolutionRange")
            case .alreadyOffered(let mode):
                return L10n.t("error.resolutionAlreadyOffered",
                              mode.width, mode.height, Int32(mode.refreshRate.rounded()))
            case .alreadyInstalled(let resolution):
                return L10n.t("error.resolutionAlreadyInstalled", resolution.label)
            }
        }
    }

    /// Raw entries, keeping the original bytes so nothing is re-encoded by
    /// accident when a payload is written back.
    static func rawEntries(in payload: [String: Any]?) -> [Data] {
        guard let array = payload?["scale-resolutions"] as? [Any] else { return [] }
        return array.compactMap { $0 as? Data }
    }

    static func entries(in payload: [String: Any]?) -> [ScaledResolution] {
        rawEntries(in: payload).compactMap(ScaledResolution.decode)
    }

    /// Entries present in `installed` but not in Apple's own baseline.
    ///
    /// Count-aware: if the same entry appears twice, only the extra copy counts
    /// as custom. This is what the UI offers to remove.
    static func customEntries(installed: [Data], baseline: [Data]) -> [Data] {
        var remaining: [Data: Int] = [:]
        for entry in baseline { remaining[entry, default: 0] += 1 }

        var result: [Data] = []
        for entry in installed {
            if let count = remaining[entry], count > 0 {
                remaining[entry] = count - 1
            } else {
                result.append(entry)
            }
        }
        return result
    }

    static func merged(payload: [String: Any], adding resolution: ScaledResolution) -> [String: Any] {
        var copy = payload
        var array = rawEntries(in: payload)
        if !array.contains(resolution.entry) {
            array.append(resolution.entry)
        }
        copy["scale-resolutions"] = array
        return copy
    }

    static func merged(payload: [String: Any], removing resolution: ScaledResolution) -> [String: Any] {
        var copy = payload
        let array = rawEntries(in: payload).filter { $0 != resolution.entry }
        if array.isEmpty {
            copy.removeValue(forKey: "scale-resolutions")
        } else {
            copy["scale-resolutions"] = array
        }
        return copy
    }

    /// A mode with the same point geometry and HiDPI scale already on offer.
    static func isOffered(pointWidth: Int, pointHeight: Int,
                          on displayID: CGDirectDisplayID) -> DisplayMode? {
        DisplayManager.allModes(for: displayID, includeUnusable: true)
            .filter { $0.width == pointWidth && $0.height == pointHeight && $0.isHiDPI }
            .max { $0.refreshRate < $1.refreshRate }
    }

    static func validate(pointWidth: Int, pointHeight: Int,
                         on display: DisplayInfo, edid: EDID,
                         checkOffered: Bool = true) -> Result<ScaledResolution, ValidationFailure> {
        let lower = 320, upper = 8192
        guard (lower...upper).contains(pointWidth), (lower...upper).contains(pointHeight),
              pointWidth * 2 <= 16_384, pointHeight * 2 <= 16_384
        else { return .failure(.geometryOutOfRange) }

        let resolution = ScaledResolution(pointWidth: pointWidth, pointHeight: pointHeight)
        let existing = DisplayOverrideInstaller.scaledResolutions(for: edid)
        if existing.contains(where: { $0.backingWidth == resolution.backingWidth
            && $0.backingHeight == resolution.backingHeight }) {
            return .failure(.alreadyInstalled(resolution))
        }
        // Enumerating every mode is the expensive half; the text field calls this
        // on each keystroke, so it can skip it and let the add action pay once.
        if checkOffered,
           let offered = isOffered(pointWidth: pointWidth, pointHeight: pointHeight, on: display.id) {
            return .failure(.alreadyOffered(offered))
        }
        return .success(resolution)
    }
}
