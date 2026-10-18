import Foundation

/// A parsed EDID blob — the panel's own description of what it can display.
///
/// macOS builds its mode list mostly *from* this data, then filters it. Reading
/// the EDID back is therefore the only way to answer two questions CoreGraphics
/// will not answer: which timings the panel declares but the system did not
/// offer, and what the hardware's bandwidth ceiling actually is.
///
/// Only parsing and re-encoding live here; nothing in this type touches the
/// system. Reading the blob is `DisplayEDID`'s job, writing an override is
/// `DisplayOverrideInstaller`'s.
public struct EDID: Hashable, Sendable {

    public static let blockSize = 128

    /// The whole blob, 128-byte blocks back to back.
    public let bytes: [UInt8]

    public var blockCount: Int { bytes.count / Self.blockSize }
    public var data: Data { Data(bytes) }

    // MARK: - Identity

    /// EDID manufacturer ID as stored (big endian), e.g. 0x09D1 for BenQ.
    /// Matches `CGDisplayVendorNumber`.
    public var vendor: UInt32 {
        UInt32(bytes[8]) << 8 | UInt32(bytes[9])
    }

    /// Product code, little endian. Matches `CGDisplayModelNumber`.
    public var product: UInt32 {
        UInt32(bytes[10]) | UInt32(bytes[11]) << 8
    }

    /// Serial number, little endian. Matches `CGDisplaySerialNumber` for most
    /// panels; a fair number of them put 0 here and use the string descriptor.
    public var serial: UInt32 {
        UInt32(bytes[12]) | UInt32(bytes[13]) << 8
            | UInt32(bytes[14]) << 16 | UInt32(bytes[15]) << 24
    }

    /// Three-letter PNP ID, e.g. "BNQ".
    public var manufacturerCode: String {
        let value = vendor
        let letters = [
            UInt8((value >> 10) & 0x1F),
            UInt8((value >> 5) & 0x1F),
            UInt8(value & 0x1F),
        ]
        return String(letters.map { Character(UnicodeScalar(0x40 + $0)) })
    }

    /// `0xFC` descriptor, e.g. "BenQ PD2705U".
    public var productName: String? {
        monitorDescriptor(tag: 0xFC).map { descriptor in
            String(decoding: descriptor[5..<18].prefix { $0 != 0x0A && $0 != 0x00 }, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: - Timings

    /// Detailed timings in the base block, preferred timing first.
    public var detailedTimings: [DetailedTiming] {
        Self.dtdOffsets.compactMap { offset in
            DetailedTiming(raw: Array(bytes[offset..<(offset + DetailedTiming.byteCount)]))
        }
    }

    /// The panel's preferred timing: the one the GPU must use to bring it up.
    public var preferredTiming: DetailedTiming? {
        DetailedTiming(raw: Array(bytes[54..<72]))
    }

    /// Every refresh rate the panel declares, from both detailed timings and the
    /// CEA short video descriptors.
    ///
    /// The short formats ("VICs") matter: a 4K panel usually puts only 4K in a
    /// detailed timing and describes 1080p and 720p with one byte each. Without
    /// them the list would claim the panel knows a single mode.
    public var declaredRates: [DeclaredRate] {
        var result: [DeclaredRate] = detailedTimings.map {
            DeclaredRate(width: $0.width, height: $0.height,
                         refreshRate: $0.refreshRate, source: .detailedTiming)
        }
        for block in extensionBlocks where block[0] == 0x02 {
            result.append(contentsOf: Self.ceaRates(in: block))
        }
        return result
    }

    /// One entry the panel says it can display.
    public struct DeclaredRate: Hashable, Sendable {
        public enum Source: String, Hashable, Sendable {
            case detailedTiming
            case ceaShortFormat
        }
        public let width: Int
        public let height: Int
        public let refreshRate: Double
        public let source: Source

        public var description: String {
            String(format: "%d × %d @ %.3f Hz", width, height, refreshRate)
        }
    }

    // MARK: - Re-encoding

    /// Returns a copy with `timing` written into a spare descriptor slot.
    ///
    /// Slot preference, in order: an empty slot, an explicit dummy descriptor
    /// (`0x10`), then an existing *non-preferred* timing, then any descriptor
    /// that is not the name/serial/range-limit blocks. The preferred timing at
    /// offset 54 is never touched — it is what the GPU uses to bring the panel up.
    ///
    /// - Returns: `nil` when no slot can be freed, which is the honest answer for
    ///   a packed EDID rather than silently dropping something important.
    public func adding(_ timing: DetailedTiming) -> EDID? {
        guard let offset = spareSlotOffset() else { return nil }
        var out = bytes
        out.replaceSubrange(offset..<(offset + DetailedTiming.byteCount), with: timing.raw)
        out[127] = Self.checksum(of: out, block: 0)
        return EDID(bytes: out)
    }

    private static let dtdOffsets = [54, 72, 90, 108]

    private func spareSlotOffset() -> Int? {
        // Offset 54 stays first-in, first-served.
        let candidates = [108, 90, 72]

        // 1. Nothing there at all.
        if let offset = candidates.first(where: { isBlank($0) }) { return offset }
        // 2. Explicit dummy descriptor (tag 0x10) — its whole purpose is padding.
        if let offset = candidates.first(where: { isMonitorDescriptor($0) && bytes[$0 + 3] == 0x10 }) {
            return offset
        }
        // 3. A timing we would be replacing anyway: the panel's extra timings are
        //    exactly what macOS already enumerated, so losing one costs nothing.
        if let offset = candidates.first(where: { !isMonitorDescriptor($0) }) { return offset }
        // 4. Last resort: a text descriptor. Sacrifice the serial first (the
        //    binary serial field usually carries the same number and macOS keeps
        //    its own copy), then free-form text, and only then the product name —
        //    losing the name makes the display show up unnamed everywhere.
        for tag: UInt8 in [0xFF, 0xFE, 0xFC] {
            if let offset = candidates.first(where: { isMonitorDescriptor($0) && bytes[$0 + 3] == tag }) {
                return offset
            }
        }
        return nil
    }

    private func isBlank(_ offset: Int) -> Bool {
        bytes[offset..<(offset + DetailedTiming.byteCount)].allSatisfy { $0 == 0 }
    }

    private func isMonitorDescriptor(_ offset: Int) -> Bool {
        bytes[offset] == 0 && bytes[offset + 1] == 0
    }

    private func monitorDescriptor(tag: UInt8) -> [UInt8]? {
        for offset in Self.dtdOffsets {
            guard isMonitorDescriptor(offset), bytes[offset + 3] == tag else { continue }
            return Array(bytes[offset..<(offset + DetailedTiming.byteCount)])
        }
        return nil
    }

    // MARK: - Extension blocks

    /// 128-byte blocks after the first one, unparsed.
    public var extensionBlocks: [[UInt8]] {
        guard blockCount > 1 else { return [] }
        return (1..<blockCount).map { index in
            Array(bytes[(index * Self.blockSize)..<((index + 1) * Self.blockSize)])
        }
    }

    /// Video data block → refresh rates, via the CEA-861 short format table.
    ///
    /// The table is a subset: progressive broadcast and desktop formats, which is
    /// what a computer monitor declares and what a user could actually pick.
    /// Interlaced VICs are skipped on purpose — they are not desktop modes, and
    /// offering them here would only produce list noise.
    private static func ceaRates(in block: [UInt8]) -> [DeclaredRate] {
        guard block.count >= 128, block[0] == 0x02 else { return [] }
        let dtdOffset = Int(block[2])
        guard dtdOffset >= 4 else { return [] }
        let end = min(dtdOffset == 0 ? 127 : dtdOffset, 127)

        var rates: [DeclaredRate] = []
        var index = 4
        while index < end {
            let header = block[index]
            let tag = header >> 5
            let length = Int(header & 0x1F)
            guard length > 0, index + length < 128 else { break }
            if tag == 0x02 {
                for vic in block[(index + 1)...(index + length)] {
                    // Bit 7 marks the display's preferred short format; the
                    // format itself is the low seven bits.
                    if let format = videoFormats[Int(vic & 0x7F)] {
                        rates.append(DeclaredRate(width: format.width,
                                                  height: format.height,
                                                  refreshRate: format.refreshRate,
                                                  source: .ceaShortFormat))
                    }
                }
            }
            index += length + 1
        }
        return rates
    }

    /// CEA-861 VIC → progressive format. Values are the standard's, including the
    /// 1000/1001 ("NTSC") rates that macOS normally rounds to whole numbers.
    static let videoFormats: [Int: (width: Int, height: Int, refreshRate: Double)] = [
        1:  (640, 480, 59.94),
        2:  (720, 480, 59.94),
        3:  (720, 480, 59.94),
        4:  (1280, 720, 59.94),
        16: (1920, 1080, 59.94),
        17: (720, 576, 50.0),
        18: (720, 576, 50.0),
        19: (1280, 720, 50.0),
        31: (1920, 1080, 50.0),
        32: (1920, 1080, 23.976),
        33: (1920, 1080, 25.0),
        34: (1920, 1080, 29.97),
        60: (1280, 720, 24.0),
        61: (1280, 720, 25.0),
        62: (1280, 720, 30.0),
        63: (1920, 1080, 119.88),
        64: (1920, 1080, 100.0),
        93: (3840, 2160, 23.976),
        94: (3840, 2160, 25.0),
        95: (3840, 2160, 29.97),
        96: (3840, 2160, 50.0),
        97: (3840, 2160, 59.94),
        98: (3840, 2160, 100.0),
        99: (3840, 2160, 119.88),
    ]

    // MARK: - Checksums

    static func checksum(of bytes: [UInt8], block: Int) -> UInt8 {
        let start = block * blockSize
        let end = start + blockSize - 1
        guard end < bytes.count else { return 0 }
        var sum: UInt32 = 0
        for index in start..<end { sum = (sum &+ UInt32(bytes[index])) & 0xFF }
        return UInt8((256 &- Int(sum & 0xFF)) & 0xFF)
    }

    /// True when every block's last byte makes the block sum to zero.
    public var hasValidChecksums: Bool {
        (0..<blockCount).allSatisfy { block in
            let end = block * Self.blockSize + Self.blockSize - 1
            guard end < bytes.count else { return false }
            var sum: UInt32 = 0
            for index in (block * Self.blockSize)...end { sum = (sum &+ UInt32(bytes[index])) & 0xFF }
            return sum & 0xFF == 0
        }
    }

    // MARK: - Init

    public init?(bytes: [UInt8]) {
        guard bytes.count >= Self.blockSize,
              bytes.count % Self.blockSize == 0,
              bytes.count <= Self.blockSize * 8 else { return nil }
        // Header, including the seven-byte magic that starts every EDID.
        guard bytes[0] == 0x00, Array(bytes[1..<8]) == [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
        else { return nil }
        guard bytes[18] == 1 else { return nil }   // EDID version 1
        self.bytes = bytes
        // A panel that declares no timing at all cannot produce a usable mode.
        guard !detailedTimings.isEmpty || !declaredRates.isEmpty else { return nil }
    }

    public init?(data: Data) {
        self.init(bytes: [UInt8](data))
    }
}
