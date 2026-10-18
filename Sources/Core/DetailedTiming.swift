import Foundation

/// One 18-byte EDID detailed timing descriptor (DTD).
///
/// This is the only place macOS, the panel and the GPU agree on what a video
/// mode *is*: a pixel clock plus four sets of blanking numbers. Everything the
/// app can do about refresh rates beyond the ones macOS lists ultimately reduces
/// to editing these 18 bytes.
///
/// The struct keeps the original bytes and only re-encodes the pixel clock, so
/// sync polarity, stereo bits and image size survive a round trip untouched. A
/// rebuilt descriptor that differs in one unrelated bit is a descriptor a panel
/// may refuse to lock onto.
///
/// Layout reference: VESA E-EDID 1.4, section 3.10.2. Field offsets were
/// verified against the BenQ PD2705U's own descriptor
/// (`4d d0 00 a0 f0 70 3e 80 30 20 35 00 55 50 21 00 00 1a` → 533.25 MHz,
/// 3840 × 2160, 4000 × 2222 totals, 59.997 Hz).
public struct DetailedTiming: Hashable, Sendable {

    /// The descriptor exactly as it appears in the EDID.
    public let raw: [UInt8]

    public static let byteCount = 18

    // MARK: - Decoded fields

    /// Pixel clock in kHz. Stored in 10 kHz units inside the descriptor.
    public let pixelClockKHz: Int
    public let hActive: Int
    public let hBlank: Int
    public let hFrontPorch: Int
    public let hSyncWidth: Int
    public let vActive: Int
    public let vBlank: Int
    public let vFrontPorch: Int
    public let vSyncWidth: Int
    public let isInterlaced: Bool

    public var hTotal: Int { hActive + hBlank }
    public var vTotal: Int { vActive + vBlank }

    /// Width in pixels.
    public var width: Int { hActive }
    /// Height in pixels.
    public var height: Int { vActive }

    /// Exact refresh rate implied by the timing, e.g. 59.997 for a "60 Hz" mode.
    ///
    /// This is the number that matters when comparing against macOS: CoreGraphics
    /// reports nominal rates (60.000), the descriptor carries the real one.
    public var refreshRate: Double {
        let total = Double(hTotal) * Double(vTotal)
        guard total > 0 else { return 0 }
        return Double(pixelClockKHz) * 1000.0 / total
    }

    /// Roughly the bandwidth this timing needs, in pixels per second.
    public var pixelRate: Int { pixelClockKHz * 1000 }

    // MARK: - Decoding

    /// Decodes 18 bytes, returning `nil` for monitor descriptors and for values
    /// that cannot be a real timing.
    ///
    /// The validation is deliberately strict: a garbage row decoded as a "mode"
    /// would be offered to the user and then black the screen when applied.
    public init?(raw: [UInt8]) {
        guard raw.count == Self.byteCount else { return nil }
        // A monitor descriptor has a zero pixel clock and a tag in byte 3; those
        // are name/serial/range blocks, not timings.
        guard raw[0] != 0 || raw[1] != 0 else { return nil }

        let clock = Int(raw[0]) | (Int(raw[1]) << 8)
        let hActive = Int(raw[2]) | ((Int(raw[4]) & 0xF0) << 4)
        let hBlank  = Int(raw[3]) | ((Int(raw[4]) & 0x0F) << 8)
        let vActive = Int(raw[5]) | ((Int(raw[7]) & 0xF0) << 4)
        let vBlank  = Int(raw[6]) | ((Int(raw[7]) & 0x0F) << 8)
        let hFront  = Int(raw[8]) | ((Int(raw[11]) & 0xC0) << 2)
        let hSync   = Int(raw[9]) | ((Int(raw[11]) & 0x30) << 4)
        let vFront  = ((Int(raw[10]) & 0xF0) >> 4) | ((Int(raw[11]) & 0x0C) << 2)
        let vSync   = (Int(raw[10]) & 0x0F) | ((Int(raw[11]) & 0x03) << 4)

        // 10 kHz units → kHz. A zero or absurd clock is a decode failure.
        guard clock > 0, clock <= 65_535 else { return nil }
        guard hActive >= 320, hActive <= 16_384,
              vActive >= 200, vActive <= 16_384,
              hBlank >= 8, vBlank >= 2 else { return nil }

        let total = hActive + hBlank
        let lines = vActive + vBlank
        let hz = Double(clock * 10) * 1000.0 / Double(total * lines)
        guard hz >= 1, hz <= 1000 else { return nil }

        self.raw = raw
        self.pixelClockKHz = clock * 10
        self.hActive = hActive
        self.hBlank = hBlank
        self.hFrontPorch = hFront
        self.hSyncWidth = hSync
        self.vActive = vActive
        self.vBlank = vBlank
        self.vFrontPorch = vFront
        self.vSyncWidth = vSync
        self.isInterlaced = (raw[17] & 0x80) != 0
    }

    // MARK: - Re-timing

    /// The same geometry and blanking, re-clocked to `hz`.
    ///
    /// Blanking is kept from the source descriptor on purpose. A panel that locks
    /// onto the original timing has already proven it accepts these porch and
    /// sync numbers; only the pixel clock is genuinely new information. Inventing
    /// a fresh CVT timing would change two variables at once and make a failure
    /// impossible to attribute.
    public func retimed(toRefresh hz: Double) -> DetailedTiming? {
        guard hz > 0, hTotal > 0, vTotal > 0 else { return nil }
        // Descriptors store the clock in 10 kHz units, so the achievable refresh
        // rate is quantised. Round to the nearest encodable clock instead of
        // pretending we hit the exact number.
        let exactKHz = Double(hTotal * vTotal) * hz / 1000.0
        let units = Int((exactKHz / 10.0).rounded())
        guard units > 0, units <= 65_535 else { return nil }

        var bytes = raw
        bytes[0] = UInt8(units & 0xFF)
        bytes[1] = UInt8((units >> 8) & 0xFF)
        return DetailedTiming(raw: bytes)
    }

    /// A new timing for a different geometry, keeping this one's blanking ratios.
    ///
    /// Used only when the panel declares no descriptor at the requested geometry —
    /// a 4K panel that describes 1080p with a one-byte CEA code has no 1080p
    /// descriptor to borrow. Scaling the blanking is an approximation; the caller
    /// has to treat the result as synthetic and say so.
    public func scaled(toWidth width: Int, toHeight height: Int,
                       refresh: Double) -> DetailedTiming? {
        guard hActive > 0, vActive > 0,
              width > 0, height > 0,
              width <= hActive * 2, height <= vActive * 2 else { return nil }
        let newHTotal = Int((Double(width) * Double(hTotal) / Double(hActive)).rounded())
        let newVTotal = Int((Double(height) * Double(vTotal) / Double(vActive)).rounded())
        return .synthesized(width: width, height: height,
                            hTotal: newHTotal, vTotal: newVTotal,
                            refresh: refresh, template: self)
    }

    /// Builds a descriptor from fields, borrowing sync widths, image size and
    /// flags from `template`.
    ///
    /// The template supply of sync values matters: whatever the panel does at its
    /// native timing is, by definition, a shape it locks onto.
    public static func synthesized(width: Int, height: Int,
                                   hTotal: Int, vTotal: Int,
                                   refresh: Double,
                                   template: DetailedTiming) -> DetailedTiming? {
        guard width > 0, height > 0,
              hTotal > width + 16, vTotal > height + 4,
              refresh > 0 else { return nil }

        let hBlank = hTotal - width
        let vBlank = vTotal - height

        var hSync = min(max(template.hSyncWidth, 8), max(8, hBlank / 4))
        var hFront = min(max(template.hFrontPorch, 4), max(4, hBlank - hSync - 4))
        if hFront + hSync >= hBlank { hSync = 8; hFront = 4 }
        guard hBlank - hFront - hSync > 0 else { return nil }

        var vSync = min(max(template.vSyncWidth, 2), max(2, vBlank / 4))
        var vFront = min(max(template.vFrontPorch, 1), max(1, vBlank - vSync - 1))
        if vFront + vSync >= vBlank { vSync = 2; vFront = 1 }
        guard vBlank - vFront - vSync > 0 else { return nil }

        // The descriptor stores the pixel clock in 10 kHz units.
        let units = Int((Double(hTotal * vTotal) * refresh / 10_000.0).rounded())
        guard units > 0, units <= 65_535 else { return nil }

        var raw = [UInt8](repeating: 0, count: byteCount)
        raw[0] = UInt8(units & 0xFF)
        raw[1] = UInt8((units >> 8) & 0xFF)
        raw[2] = UInt8(width & 0xFF)
        raw[3] = UInt8(hBlank & 0xFF)
        // Bytes 4 and 7 pack a 4-bit high half each; keep the halves as typed
        // locals rather than one nested expression (see byte 11 below).
        let widthHigh = UInt8((width >> 8) & 0x0F) << 4
        let hBlankHigh = UInt8((hBlank >> 8) & 0x0F)
        raw[4] = widthHigh | hBlankHigh
        raw[5] = UInt8(height & 0xFF)
        raw[6] = UInt8(vBlank & 0xFF)
        let heightHigh = UInt8((height >> 8) & 0x0F) << 4
        let vBlankHigh = UInt8((vBlank >> 8) & 0x0F)
        raw[7] = heightHigh | vBlankHigh
        raw[8] = UInt8(hFront & 0xFF)
        raw[9] = UInt8(hSync & 0xFF)
        raw[10] = UInt8(vFront & 0x0F) << 4 | UInt8(vSync & 0x0F)
        // Byte 11 packs the high bits of all four values: 7–6 horizontal front
        // porch, 5–4 horizontal sync, 3–2 vertical front porch, 1–0 vertical
        // sync. Kept as separate terms because a single chained expression this
        // dense times out the type checker on older toolchains (Swift 5.10).
        let hFrontHigh = UInt8((hFront >> 8) & 0x03) << 6
        let hSyncHigh = UInt8((hSync >> 8) & 0x03) << 4
        let vFrontHigh = UInt8((vFront >> 4) & 0x03) << 2
        let vSyncHigh = UInt8((vSync >> 4) & 0x03)
        raw[11] = hFrontHigh | hSyncHigh | vFrontHigh | vSyncHigh
        // Image size and borders describe the physical panel; keep them.
        raw[12] = template.raw[12]
        raw[13] = template.raw[13]
        raw[14] = template.raw[14]
        raw[15] = template.raw[15]
        raw[16] = template.raw[16]
        // Sync flags are reused, but the interlace bit must be clear: every mode
        // this app synthesises is progressive.
        raw[17] = template.raw[17] & ~0x80

        return DetailedTiming(raw: raw)
    }

    /// How far the requested rate and the encoded rate can differ, in Hz. Used to
    /// report honestly when the 10 kHz grid forces an approximation.
    public var description: String {
        String(format: "%d × %d @ %.3f Hz (%.2f MHz, totals %d × %d)",
               width, height, refreshRate, Double(pixelClockKHz) / 1000.0, hTotal, vTotal)
    }
}
