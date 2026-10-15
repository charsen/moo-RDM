import CoreGraphics
import Foundation

/// One display's desired state inside a profile.
///
/// Deliberately stores the *display identity* rather than a `CGDirectDisplayID`,
/// because display IDs are reassigned by the system on every reconnect.
public struct DisplayTarget: Codable, Hashable, Sendable {
    public var identityKey: String
    public var displayName: String
    public var width: Int
    public var height: Int
    public var scale: Double
    public var refreshRate: Double
    public var rotation: Double

    public init(identityKey: String, displayName: String,
                width: Int, height: Int, scale: Double,
                refreshRate: Double, rotation: Double) {
        self.identityKey = identityKey
        self.displayName = displayName
        self.width = width
        self.height = height
        self.scale = scale
        self.refreshRate = refreshRate
        self.rotation = rotation
    }

    public var resolutionDescription: String {
        let marker = scale >= 2 ? " ⚡️" : ""
        var text = "\(width) × \(height)\(marker)"
        if refreshRate > 0 { text += String(format: " @ %.0f Hz", refreshRate) }
        return text
    }
}

/// A named set of per-display targets.
public struct DisplayProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var targets: [DisplayTarget]

    public init(id: UUID = UUID(), name: String,
                createdAt: Date = Date(), updatedAt: Date = Date(),
                targets: [DisplayTarget]) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.targets = targets
    }

    public var summary: String {
        guard !targets.isEmpty else { return "—" }
        return targets.map(\.resolutionDescription).joined(separator: ", ")
    }
}

/// Reads and writes saved profiles from
/// `~/Library/Application Support/RDM-ARM/profiles.json`.
public final class ProfileStore {

    public static let shared = ProfileStore()

    public private(set) var profiles: [DisplayProfile] = []

    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            Preferences.ensureSupportDirectory()
            self.fileURL = Preferences.supportDirectory.appendingPathComponent("profiles.json")
        }
        reload()
    }

    // MARK: - Persistence

    public func reload() {
        guard let data = try? Data(contentsOf: fileURL) else {
            profiles = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        profiles = (try? decoder.decode([DisplayProfile].self, from: data)) ?? []
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(profiles) else { return }
        Preferences.ensureSupportDirectory()
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Mutation

    /// Captures the current state of every connected display as a new profile.
    public func captureCurrentLayout(named name: String) -> DisplayProfile {
        let targets: [DisplayTarget] = DisplayManager.allDisplays().compactMap { display in
            guard let mode = display.currentMode else { return nil }
            return DisplayTarget(identityKey: display.identity.key,
                                 displayName: display.name,
                                 width: mode.width,
                                 height: mode.height,
                                 scale: mode.scale,
                                 refreshRate: mode.refreshRate,
                                 rotation: display.rotation)
        }
        return DisplayProfile(name: name, targets: targets)
    }

    /// Inserts or replaces a profile with the same name, then persists.
    public func upsert(_ profile: DisplayProfile) {
        if let index = profiles.firstIndex(where: { $0.name == profile.name }) {
            var updated = profile
            updated.id = profiles[index].id
            updated.createdAt = profiles[index].createdAt
            updated.updatedAt = Date()
            profiles[index] = updated
        } else {
            profiles.append(profile)
        }
        profiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persist()
    }

    public func delete(id: UUID) {
        profiles.removeAll { $0.id == id }
        persist()
    }

    public func delete(named name: String) {
        profiles.removeAll { $0.name == name }
        persist()
    }

    public func profile(named name: String) -> DisplayProfile? {
        profiles.first { $0.name == name }
    }

    // MARK: - Applying

    public struct ApplyReport: Sendable {
        public var applied: [String] = []
        public var warnings: [String] = []
        public var isClean: Bool { warnings.isEmpty }
    }

    /// Applies every target in `profile` to the matching connected display.
    ///
    /// A target whose display is not currently connected produces a warning rather
    /// than a failure, so multi-display profiles still apply partially.
    @discardableResult
    public func apply(_ profile: DisplayProfile, permanently: Bool? = nil) -> ApplyReport {
        let usePermanent = permanently ?? Preferences.shared.permanentChanges
        let displays = DisplayManager.allDisplays()
        var report = ApplyReport()

        for target in profile.targets {
            guard let display = displays.first(where: { $0.identity.key == target.identityKey }) else {
                report.warnings.append("\(target.displayName): not connected")
                continue
            }

            switch ModeController.applyResolution(on: display.id,
                                                  width: target.width,
                                                  height: target.height,
                                                  scale: target.scale,
                                                  refreshRate: target.refreshRate > 0 ? target.refreshRate : nil,
                                                  permanently: usePermanent,
                                                  includeUnusable: true) {
            case .success(let mode):
                report.applied.append("\(display.name): \(mode.menuTitle)")
            case .failure(let error):
                report.warnings.append("\(display.name): \(error.description)")
            }

            // Only touch rotation when the profile actually recorded one.
            if target.rotation != 0, DisplayRotationController.isAvailable,
               abs(DisplayRotationController.currentRotation(of: display.id) - target.rotation) > 0.5 {
                if case .failure(let error) = DisplayRotationController.setRotation(target.rotation, on: display.id) {
                    report.warnings.append("\(display.name): \(error.description)")
                }
            }
        }
        return report
    }

    // MARK: - Import / export

    public func export(ids: [UUID]? = nil, to url: URL) throws {
        let selection = ids.map { wanted in profiles.filter { wanted.contains($0.id) } } ?? profiles
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(selection)
        try data.write(to: url, options: .atomic)
    }

    /// Imports profiles, replacing same-named entries. Returns how many were read.
    @discardableResult
    public func importProfiles(from url: URL, replacing: Bool = true) throws -> Int {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Accept both a bare array and a single profile object.
        let incoming: [DisplayProfile]
        if let list = try? decoder.decode([DisplayProfile].self, from: data) {
            incoming = list
        } else {
            incoming = [try decoder.decode(DisplayProfile.self, from: data)]
        }

        for var profile in incoming {
            if replacing, let index = profiles.firstIndex(where: { $0.name == profile.name }) {
                profile.id = profiles[index].id
                profiles[index] = profile
            } else {
                profile.id = UUID()
                profiles.append(profile)
            }
        }
        profiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persist()
        return incoming.count
    }
}
