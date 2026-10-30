import AppKit
import CoreGraphics
import Foundation

/// Builds the status-bar menu from the current display state.
///
/// The menu is rebuilt every time it opens, so it always reflects reality — a
/// display unplugged a second ago is gone, a mode changed elsewhere is ticked.
enum StatusMenuBuilder {

    static func build(into menu: NSMenu, router: MenuActionRouter) {
        menu.removeAllItems()

        let displays = DisplayManager.allInfos()

        if displays.isEmpty {
            menu.addItem(disabled(L10n.t("menu.noDisplays")))
        } else {
            if displays.count >= 2 {
                menu.addItem(allDisplaysItem(router: router))
                menu.addItem(.separator())
            }
            for display in displays {
                menu.addItem(displayItem(display, among: displays, router: router))
            }
        }

        menu.addItem(.separator())
        menu.addItem(presetsItem(router: router))

        menu.addItem(showHiddenModesItem(router: router))
        menu.addItem(hiDPIOnlyItem(router: router))

        menu.addItem(.separator())

        menu.addItem(action(L10n.t("menu.preferences"),
                            #selector(MenuActionRouter.openPreferences(_:)),
                            router, key: ","))
        menu.addItem(action(L10n.t("menu.about"),
                            #selector(MenuActionRouter.showAbout(_:)),
                            router))
        menu.addItem(.separator())
        menu.addItem(action(L10n.t("menu.quit"),
                            #selector(MenuActionRouter.quit(_:)),
                            router, key: "q"))
    }

    // MARK: - Titles

    /// A display name that stays distinguishable when two identical panels are
    /// attached. Two rows reading "BenQ PD2705U" are one row too many.
    private static func displayTitle(_ display: DisplayInfo, among displays: [DisplayInfo]) -> String {
        var title = display.name
        if displays.filter({ $0.name == display.name }).count > 1 {
            title += " #\(display.ordinal + 1)"
        }
        if displays.count > 1 && display.isMain {
            title += " · " + L10n.t("menu.mainShort")
        }
        if display.isBuiltin {
            title += " · " + L10n.t("menu.builtinShort")
        }
        return title
    }

    // MARK: - Per-display submenu

    private static func displayItem(_ display: DisplayInfo,
                                    among displays: [DisplayInfo],
                                    router: MenuActionRouter) -> NSMenuItem {
        let parent = NSMenuItem(title: displayTitle(display, among: displays),
                                action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let lazy = LazyDisplayMenu(display: display, router: router)
        submenu.delegate = lazy
        objc_setAssociatedObject(submenu, &lazyDisplayDelegateKey, lazy,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        parent.submenu = submenu
        return parent
    }

    fileprivate static func populateDisplay(into submenu: NSMenu,
                                            for info: DisplayInfo,
                                            router: MenuActionRouter) {
        let ids = DisplayManager.onlineDisplayIDs()
        guard let ordinal = ids.firstIndex(of: info.id) else { return }
        let snapshot = DisplayManager.snapshot(info.id, ordinal: ordinal,
                                                includeUnusable: Preferences.shared.showUnusableModes)
        let display = snapshot.display
        let hiddenTwins = hiddenStandardSizes(for: [snapshot])[display.id] ?? []
        let rememberedModes = Preferences.shared.rememberedModes

        // Header: what the display is doing right now.
        submenu.addItem(disabled("   " + display.currentDescription))
        if let native = display.nativePixelSize {
            submenu.addItem(disabled("   " + L10n.t("menu.native", native.description)))
        }
        if let note = router.memory.restoreNote(for: display.id) {
            submenu.addItem(disabled("   " + note))
        }
        submenu.addItem(.separator())

        submenu.addItem(lazyModesItem(.resolutions, snapshot: snapshot,
                                      hiddenTwins: hiddenTwins, router: router))
        if snapshot.display.currentMode != nil {
            submenu.addItem(lazyModesItem(.refreshRates, snapshot: snapshot,
                                          hiddenTwins: hiddenTwins, router: router))
        }
        submenu.addItem(capabilitiesItem(for: display))
        submenu.addItem(.separator())

        let box = DisplayBox(displayID: display.id)
        let reset = action(L10n.t("menu.resetToDefault"),
                           #selector(MenuActionRouter.resetToDefault(_:)), router)
        reset.representedObject = box
        submenu.addItem(reset)

        if rememberedModes[display.identity.key] != nil
            || rememberedModes[display.identity.legacyKey] != nil {
            let forget = action(L10n.t("menu.forgetRemembered"),
                                #selector(MenuActionRouter.forgetRememberedMode(_:)), router)
            forget.representedObject = DisplayBox(displayID: display.id)
            submenu.addItem(forget)
        }

        if let rotationItem = rotationItem(for: display, router: router) {
            submenu.addItem(rotationItem)
        }
        if let brightnessItem = brightnessItem(for: display, router: router) {
            submenu.addItem(brightnessItem)
        }
    }

    // MARK: - Resolution and refresh rate
    //
    // These are two sibling menus, not one nested one. Nesting the refresh rates
    // under each resolution made the list hard to scan — a geometry with four
    // rates took four lines — and changing only the rate meant a submenu hop.
    // Now the geometry lives here and the rate lives next door.

    /// Modes that belong in the menu for this display.
    ///
    /// The snapshot already applied the "show unusable" filter. On top of that,
    /// 1× rows whose output geometry is larger than the panel are hidden: a
    /// `scale-resolutions` entry adds one of those next to the HiDPI size it was
    /// meant to create, and selecting it asks the display for a timing it never
    /// declared. The CLI still reports them; the menu should not offer a way to
    /// black the screen.
    private static func menuModes(_ snapshot: DisplaySnapshot,
                                  hiddenTwins: Set<PixelSize> = []) -> [DisplayMode] {
        let native = snapshot.display.nativePixelSize
        return snapshot.modes.filter { mode in
            if mode.isStandardOutputBeyondPanel(native) { return false }
            if mode.isHiDPI { return true }
            let backing = PixelSize(width: mode.pixelWidth, height: mode.pixelHeight)
            return !hiddenTwins.contains(backing)
        }
    }

    /// 1× twins of `scale-resolutions` entries this app added for each display.
    ///
    /// Read once per menu build. Each entry `4608 × 2592` creates both
    /// `2304 × 1296 ⚡️` and a plain `4608 × 2592`; the second one has no timing
    /// the panel ever declared and is hidden from the menu.
    private static func hiddenStandardSizes(for snapshots: [DisplaySnapshot]) -> [CGDirectDisplayID: Set<PixelSize>] {
        var result: [CGDirectDisplayID: Set<PixelSize>] = [:]
        for snapshot in snapshots {
            let id = snapshot.display.id
            let sizes = DisplayOverrideInstaller.scaledResolutions(
                vendor: CGDisplayVendorNumber(id),
                product: CGDisplayModelNumber(id)
            ).map {
                PixelSize(width: $0.backingWidth, height: $0.backingHeight)
            }
            if !sizes.isEmpty { result[id] = Set(sizes) }
        }
        return result
    }

    /// A submenu whose contents are built only when it is opened.
    ///
    /// Building every mode row for every display on every top-level open was the
    /// bulk of the menu cost (hundreds of `NSMenuItem`s for a 4K panel), even
    /// when the user only wanted Preferences or another display.
    private static func lazyModesItem(_ kind: LazyModesMenu.Kind,
                                      snapshot: DisplaySnapshot,
                                      hiddenTwins: Set<PixelSize>,
                                      router: MenuActionRouter) -> NSMenuItem {
        let parent = NSMenuItem(title: kind.title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let lazy = LazyModesMenu(kind: kind, snapshot: snapshot,
                                 hiddenTwins: hiddenTwins, router: router)
        submenu.delegate = lazy
        objc_setAssociatedObject(submenu, &lazyModesDelegateKey, lazy,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        parent.submenu = submenu
        return parent
    }

    private static var lazyModesDelegateKey: UInt8 = 0
    private static var lazyDisplayDelegateKey: UInt8 = 0
    private static var lazyAllDisplaysDelegateKey: UInt8 = 0

    fileprivate static func populateResolutions(into submenu: NSMenu,
                                                for snapshot: DisplaySnapshot,
                                                hiddenTwins: Set<PixelSize>,
                                                router: MenuActionRouter) {
        let display = snapshot.display
        let current = display.currentMode
        let isFiltering = Preferences.shared.hiDPIOnly
        let all = menuModes(snapshot, hiddenTwins: hiddenTwins)
        // macOS returns many modes that are indistinguishable in the menu; collapse
        // them before grouping so each geometry appears exactly once.
        let rows = isFiltering ? all.filter(\.isHiDPI) : all
        let groups = rows
            .sortedForMenu()
            .deduplicated(preferring: current)
            .groupedByResolution()

        // The 1× list is unconditional. It used to be built from whatever
        // survived the HiDPI filter on speed, which made the whole submenu
        // appear and vanish as the mode table changed — pick a 60 Hz timing and
        // the 1× rows start tying with their HiDPI twins, so the group the user
        // had just found was gone. Whether these rows are "faster" is a property
        // of the current timing, not of the display; membership should not
        // depend on it.
        let standardGroups = (isFiltering ? all.filter { !$0.isHiDPI } : [])
            .sortedForMenu()
            .deduplicated(preferring: current)
            .groupedByResolution()

        if groups.isEmpty {
            submenu.addItem(disabled(L10n.t("menu.noModes")))
        }

        for group in groups {
            submenu.addItem(modeItem(for: group, current: current, router: router))
        }

        if !standardGroups.isEmpty {
            submenu.addItem(.separator())
            let header = NSMenuItem(title: L10n.t("menu.standardResolutions"),
                                    action: nil, keyEquivalent: "")
            let child = NSMenu()
            for group in standardGroups {
                child.addItem(modeItem(for: group, current: current, router: router))
            }
            header.submenu = child
            // The tick belongs on the submenu itself: while the display sits in a
            // 1× mode no row above is current, and a list with no tick reads as
            // if it had lost track of the display.
            header.state = (current?.isHiDPI == false) ? .on : .off
            submenu.addItem(header)
        }

        // Custom scaled-resolution entry points are hidden for now; the window,
        // router actions and override store stay in the target. See TODOS.md.
    }

    /// One resolution row, including where a click should land.
    private static func modeItem(for group: (mode: DisplayMode, refreshRates: [DisplayMode]),
                                 current: DisplayMode?,
                                 router: MenuActionRouter) -> NSMenuItem {
        // The row prints the group's fastest rate, so the click has to deliver
        // it. Keeping the current rate instead would have the label promise
        // `· 60 Hz` and land on 30 whenever the current rate also exists at the
        // new size — technically gentle, but it makes the number on the row a
        // lie. The geometry and its best timing are one choice.
        let fastest = group.refreshRates.max { $0.refreshRate < $1.refreshRate } ?? group.mode

        // See the comment on `menuTitle(withFastestRate:)`: two sibling menus
        // mean a resolution can be picked without the rate ever being in view,
        // and that is how a user ends up on a 30 Hz HiDPI size while believing
        // the panel cannot do 60.
        var title = group.mode.menuTitle(withFastestRate: fastest.refreshRate)
        if !fastest.isUsable {
            title += " · " + L10n.t("menu.unsupported")
        }
        let item = action(title, #selector(MenuActionRouter.selectMode(_:)), router)
        item.representedObject = ModeBox(fastest)
        item.state = group.mode.resolutionKey == current?.resolutionKey ? .on : .off
        return item
    }

    /// Refresh rates available *at the resolution currently in use*.
    ///
    /// Listing rates from every geometry would make this a second resolution
    /// picker. Rates that would drag the geometry along are simply not offered.
    ///
    /// The menu appears even when the display offers a single rate. Hiding it
    /// makes a working display look like a broken feature — a lone ticked entry
    /// says "this panel only does 60 Hz", which is the honest answer, rather than
    /// saying nothing at all.
    fileprivate static func populateRefreshRates(into submenu: NSMenu,
                                                 for snapshot: DisplaySnapshot,
                                                 hiddenTwins: Set<PixelSize>,
                                                 router: MenuActionRouter) {
        guard let current = snapshot.display.currentMode else { return }

        // The unfiltered table: the HiDPI filter only decides which list a row
        // goes into, and the user sitting in a 1× mode still needs the rates of
        // the geometry they are actually on.
        let modes = menuModes(snapshot, hiddenTwins: hiddenTwins).deduplicated(preferring: current)
        let rates = modes
            .filter { $0.resolutionKey == current.resolutionKey }
            .sorted { $0.refreshRate > $1.refreshRate }

        // Nothing to offer because the current geometry was filtered out: show the
        // rate in use rather than an empty menu.
        if rates.isEmpty {
            submenu.addItem(disabled(current.refreshDescription))
        }

        for rate in rates {
            let item = action(rate.refreshDescription,
                              #selector(MenuActionRouter.selectMode(_:)), router)
            item.representedObject = ModeBox(rate)
            item.state = rate.isSame(as: current) ? .on : .off
            submenu.addItem(item)
        }

        // A higher rate can be one geometry away and still be invisible here.
        // On this TV the link carries 60 Hz only in the 1× 1080p timing while
        // every HiDPI size stops at 30, so a user sitting at 1600 × 900 sees a
        // three-row menu and concludes the panel cannot do 60.
        //
        // This is a clickable row, not a note: "60 Hz is not offered" is the
        // exact complaint that led here, and an entry the user cannot press
        // would answer it with an explanation instead of a fix. It carries the
        // geometry because choosing it changes the resolution too — the rate and
        // the timing travel together, and hiding that would be a surprise.
        //
        // Only geometries at least as large qualify. Trading 2304 × 1296 for a
        // 75 Hz 1024 × 768 is not "the same screen, faster"; that rate stays in
        // the standard-resolution submenu without shouting from here.
        let fastestHere = rates.map(\.refreshRate).max() ?? 0
        let faster = modes
            .filter { mode in
                mode.resolutionKey != current.resolutionKey
                    && mode.refreshRate > fastestHere + 0.5
                    && mode.width * mode.height >= current.width * current.height
            }
            .sorted { a, b in
                if abs(a.refreshRate - b.refreshRate) > 0.5 {
                    return a.refreshRate > b.refreshRate
                }
                return a.width * a.height > b.width * b.height
            }
            .first

        if let faster {
            submenu.addItem(.separator())
            let item = action(L10n.t("menu.refreshAtGeometry",
                                     faster.refreshDescription, faster.menuTitle),
                              #selector(MenuActionRouter.selectMode(_:)), router)
            item.representedObject = ModeBox(faster)
            item.state = .off
            submenu.addItem(item)
        }
    }

    // MARK: - All displays

    private static func allDisplaysItem(router: MenuActionRouter) -> NSMenuItem {
        let parent = NSMenuItem(title: L10n.t("menu.allDisplays"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let lazy = LazyAllDisplaysMenu(router: router)
        submenu.delegate = lazy
        objc_setAssociatedObject(submenu, &lazyAllDisplaysDelegateKey, lazy,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        parent.submenu = submenu
        return parent
    }

    fileprivate static func populateAllDisplays(into submenu: NSMenu,
                                                router: MenuActionRouter) {
        let snapshots = DisplayManager.snapshots(includeUnusable: Preferences.shared.showUnusableModes)
        let hiddenTwins = hiddenStandardSizes(for: snapshots)
        let active = snapshots.filter { !$0.modes.isEmpty }
        guard active.count >= 2 else { return }

        let isFiltering = Preferences.shared.hiDPIOnly
        func publicModes(_ snapshot: DisplaySnapshot) -> [DisplayMode] {
            let hidden = hiddenTwins[snapshot.display.id] ?? []
            return menuModes(snapshot, hiddenTwins: hidden).filter {
                $0.cgMode != nil && !$0.isPrivate
            }
        }

        let eligible = active.map(publicModes)
        let common = DisplayMode.commonResolutions(among: eligible, hiDPIOnly: isFiltering)

        let same = NSMenuItem(title: L10n.t("menu.sameResolution"), action: nil, keyEquivalent: "")
        let sameMenu = NSMenu()
        if common.isEmpty {
            sameMenu.addItem(disabled(L10n.t("menu.noCommonResolution")))
        }

        for entry in common {
            let assignments = assignments(for: entry.choice,
                                          rate: entry.refreshRate,
                                          in: active,
                                          hiddenTwins: hiddenTwins)
            guard assignments.count == active.count else { continue }
            guard let representative = eligible.flatMap({ $0 }).first(where: {
                $0.width == entry.choice.width
                    && $0.height == entry.choice.height
                    && $0.isHiDPI == entry.choice.isHiDPI
                    && abs($0.refreshRate - Double(entry.refreshRate)) < 0.5
            }) else { continue }

            let item = action(representative.menuTitle(withFastestRate: Double(entry.refreshRate)),
                              #selector(MenuActionRouter.matchDisplays(_:)), router)
            item.representedObject = MatchBox(assignments: assignments)
            item.state = active.allSatisfy {
                $0.display.currentMode?.resolutionKey == representative.resolutionKey
            } ? .on : .off
            sameMenu.addItem(item)
        }
        same.submenu = sameMenu
        submenu.addItem(same)

        // Match the main display: one click for "make everything look like this".
        if let main = active.first(where: { $0.display.isMain }) ?? active.first,
           let current = main.display.currentMode {
            let choice = ResolutionChoice(width: current.width,
                                          height: current.height,
                                          isHiDPI: current.isHiDPI)
            let rate = Int(current.refreshRate.rounded())
            let currentAssignments = assignments(for: choice, rate: rate, in: active,
                                                 hiddenTwins: hiddenTwins)
            let missing = active.filter { snapshot in
                !currentAssignments.contains { $0.displayID == snapshot.display.id }
            }.map(\.display.name)

            let item = action(L10n.t("menu.matchMain"),
                              #selector(MenuActionRouter.matchDisplays(_:)), router)
            if missing.isEmpty {
                item.representedObject = MatchBox(assignments: currentAssignments)
                item.toolTip = L10n.t("menu.matchMain.hint")
            } else {
                item.isEnabled = false
                item.toolTip = L10n.t("menu.missingOn", missing.joined(separator: ", "))
            }
            submenu.addItem(item)

            submenu.addItem(.separator())

            // Mirror everything onto the main display. The master's timing has to
            // be valid on every slave, so this is checked up front and the reason
            // is printed in the tooltip rather than failing after the click.
            let mirrorItem = action(L10n.t("menu.mirrorAll"),
                                    #selector(MenuActionRouter.mirrorDisplays(_:)), router)
            if missing.isEmpty {
                let mirror = Dictionary(uniqueKeysWithValues: active
                    .filter { $0.display.id != main.display.id }
                    .map { ($0.display.id, main.display.id) })
                mirrorItem.representedObject = MatchBox(assignments: currentAssignments,
                                                        mirroring: mirror)
            } else {
                mirrorItem.isEnabled = false
                mirrorItem.toolTip = L10n.t("menu.missingOn", missing.joined(separator: ", "))
            }
            submenu.addItem(mirrorItem)
        }

        if active.contains(where: { $0.display.isMirrored }) {
            submenu.addItem(action(L10n.t("menu.stopMirroring"),
                                   #selector(MenuActionRouter.stopMirroring(_:)), router))
        }
    }

    private static func assignments(for choice: ResolutionChoice,
                                    rate: Int,
                                    in snapshots: [DisplaySnapshot],
                                    hiddenTwins: [CGDirectDisplayID: Set<PixelSize>]) -> [ModeController.Assignment] {
        snapshots.compactMap { snapshot in
            let hidden = hiddenTwins[snapshot.display.id] ?? []
            let matches = menuModes(snapshot, hiddenTwins: hidden)
                .filter {
                    $0.cgMode != nil && !$0.isPrivate
                        && $0.width == choice.width && $0.height == choice.height
                        && $0.isHiDPI == choice.isHiDPI
                        && abs($0.refreshRate - Double(rate)) < 0.5
                }
            let candidate = matches.sorted { a, b in
                if a.isUsable != b.isUsable { return a.isUsable }
                return a.modeID < b.modeID
            }.first
            guard let candidate else { return nil }
            return ModeController.Assignment(displayID: snapshot.display.id, mode: candidate)
        }
    }

    // MARK: - Presets

    /// Saved whole-setup presets: resolution, rotation, mirror links, brightness.
    private static func presetsItem(router: MenuActionRouter) -> NSMenuItem {
        let parent = NSMenuItem(title: L10n.t("menu.presets"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        submenu.addItem(action(L10n.t("menu.preset.save"),
                               #selector(MenuActionRouter.savePreset(_:)), router))
        submenu.addItem(.separator())

        let presets = Preferences.shared.displayPresets
        if presets.isEmpty {
            submenu.addItem(disabled(L10n.t("menu.preset.none")))
        } else {
            for preset in presets {
                let item = action(preset.name,
                                  #selector(MenuActionRouter.applyPreset(_:)), router)
                item.representedObject = PresetBox(preset)
                item.toolTip = presetSummary(preset)
                submenu.addItem(item)
            }

            submenu.addItem(.separator())
            let deleteHeader = NSMenuItem(title: L10n.t("menu.preset.delete"),
                                          action: nil, keyEquivalent: "")
            let deleteMenu = NSMenu()
            for preset in presets {
                let item = action(preset.name,
                                  #selector(MenuActionRouter.deletePreset(_:)), router)
                item.representedObject = PresetBox(preset)
                deleteMenu.addItem(item)
            }
            deleteHeader.submenu = deleteMenu
            submenu.addItem(deleteHeader)
        }

        parent.submenu = submenu
        return parent
    }

    private static func presetSummary(_ preset: DisplayPreset) -> String {
        var parts = preset.displays.values.map(\.name).sorted()
        if !preset.mirrors.isEmpty {
            parts.append(L10n.t("menu.preset.summary.mirrors", Int32(preset.mirrors.count)))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Hardware limits

    /// What the panel declares and what the link allows, in one read-only place.
    ///
    /// The contents are built when the submenu is opened, not here. Filling them
    /// reads the EDID through IOKit, enumerates every mode and queries a private
    /// class — 40–60 ms measured per display. Paying that on every `menuWillOpen`,
    /// for a submenu most openings never touch, is what makes the menu sticky.
    ///
    /// Writing a custom *timing* still lives behind the CLI, because that path can
    /// black the screen the moment it is installed. Adding a scaled *resolution*
    /// does not: it only adds a selectable row, and lives in the Resolution
    /// submenu instead.
    private static func capabilitiesItem(for display: DisplayInfo) -> NSMenuItem {
        let parent = NSMenuItem(title: L10n.t("menu.capabilities"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let lazy = LazyCapabilitiesMenu(display: display)
        submenu.delegate = lazy
        // `NSMenu.delegate` is weak, so the delegate needs an owner. Tying it to
        // the menu means it is released with the menu instead of accumulating one
        // more entry per rebuild.
        objc_setAssociatedObject(submenu, &capabilityDelegateKey, lazy,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        parent.submenu = submenu
        return parent
    }

    /// Fills the submenu that `capabilitiesItem` handed out empty.
    fileprivate static func populateCapabilities(into submenu: NSMenu, for display: DisplayInfo) {
        let report = DisplayCapabilities.report(for: display.id)
        guard let edid = report.edid else {
            submenu.addItem(disabled(L10n.t("menu.capabilities.noEDID")))
            return
        }

        if let timing = report.nativeTiming {
            submenu.addItem(disabled(L10n.t("menu.capabilities.native", timing.description)))
        }
        let budget = report.budgetDescription()
        if !budget.isEmpty {
            submenu.addItem(disabled(L10n.t("menu.capabilities.link", budget)))
        }

        if report.hiddenRates.isEmpty {
            submenu.addItem(disabled(L10n.t("menu.capabilities.nothingHidden")))
        } else {
            for rate in report.hiddenRates.prefix(8) {
                submenu.addItem(disabled(L10n.t("menu.capabilities.hidden", rate.description)))
            }
        }
        let scaled = DisplayOverrideInstaller.scaledResolutions(for: edid)
        if DisplayOverrideInstaller.hasEDIDOverride(for: edid) {
            submenu.addItem(disabled(L10n.t("menu.capabilities.override")))
        }
        if !scaled.isEmpty {
            submenu.addItem(disabled(L10n.t("menu.capabilities.scaled",
                                            scaled.map(\.label).joined(separator: ", "))))
        }

        submenu.addItem(.separator())
        // Same reasoning as the CLI gate: a hint that leads to a no-op is worse
        // than no hint at all, so the menu says which of the two situations the
        // machine is in before the user goes looking for the command.
        submenu.addItem(disabled(L10n.t(DisplayOverrideInstaller.support(for: .edidBlob).isAvailable
                                        ? "menu.capabilities.cliHint"
                                        : "menu.capabilities.inert")))
    }

    /// Associated-object key for the lazily built capability submenu.
    private static var capabilityDelegateKey: UInt8 = 0

    // MARK: - Rotation
    private static func rotationItem(for display: DisplayInfo,
                                     router: MenuActionRouter) -> NSMenuItem? {
        guard DisplayRotationController.isAvailable else { return nil }

        let parent = NSMenuItem(title: L10n.t("menu.rotation"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = DisplayRotationController.currentRotation(of: display.id)

        for angle in DisplayRotationController.supportedAngles {
            let item = action(DisplayRotationController.label(for: angle),
                              #selector(MenuActionRouter.selectRotation(_:)), router)
            item.representedObject = RotationBox(displayID: display.id, degrees: angle)
            item.state = abs(current - angle) < 0.5 ? .on : .off
            submenu.addItem(item)
        }

        parent.submenu = submenu
        return parent
    }

    // MARK: - Brightness

    private static func brightnessItem(for display: DisplayInfo,
                                       router: MenuActionRouter) -> NSMenuItem? {
        // Hidden entirely on displays that cannot do software brightness —
        // which is the honest behaviour rather than showing a dead control.
        guard DisplayBrightnessController.canChangeBrightness(of: display.id) else { return nil }

        let parent = NSMenuItem(title: L10n.t("menu.brightness"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let current = DisplayBrightnessController.brightness(of: display.id)
        submenu.addItem(disabled(L10n.t("menu.brightness.current",
                                        Int32((current ?? 0) * 100))))

        // A continuous slider instead of eleven fixed rows: the menu closes when
        // the user lets go, so the change is still immediate and there is no
        // confirmation step.
        let slider = NSSlider(value: Double(current ?? 0.5),
                              minValue: 0, maxValue: 1,
                              target: router,
                              action: #selector(MenuActionRouter.brightnessSliderChanged(_:)))
        slider.isContinuous = true
        slider.tag = Int(display.id)
        slider.frame = NSRect(x: 0, y: 0, width: 200, height: 24)

        let control = NSMenuItem()
        control.view = slider
        submenu.addItem(control)

        parent.submenu = submenu
        return parent
    }

    // MARK: - View toggles

    private static func showHiddenModesItem(router: MenuActionRouter) -> NSMenuItem {
        let item = action(L10n.t("menu.showAllModes"),
                          #selector(MenuActionRouter.toggleShowAllModes(_:)), router)
        item.state = Preferences.shared.showUnusableModes ? .on : .off
        item.toolTip = L10n.t("menu.showAllModes.hint")
        return item
    }

    private static func hiDPIOnlyItem(router: MenuActionRouter) -> NSMenuItem {
        let item = action(L10n.t("menu.hiDPIOnly"),
                          #selector(MenuActionRouter.toggleHiDPIOnly(_:)), router)
        item.state = Preferences.shared.hiDPIOnly ? .on : .off
        item.toolTip = L10n.t("menu.hiDPIOnly.hint")
        return item
    }

    // MARK: - Item helpers

    private static func action(_ title: String,
                               _ selector: Selector,
                               _ router: MenuActionRouter,
                               key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = router
        return item
    }

    private static func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

/// Builds the capability submenu the first time it is opened, and again on every
/// later opening, so it never shows a stale EDID after a cable swap.
///
/// Held alive by an associated object on the menu it serves — see
/// `StatusMenuBuilder.capabilitiesItem`.
private final class LazyCapabilitiesMenu: NSObject, NSMenuDelegate {

    private let display: DisplayInfo

    init(display: DisplayInfo) {
        self.display = display
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        StatusMenuBuilder.populateCapabilities(into: menu, for: display)
    }
}

/// Builds the resolution or refresh-rate submenu only when it is opened.
///
/// The top-level menu is shown dozens of times for every time the mode list is
/// actually needed; keeping these empty until then removes the bulk of the menu
/// build from the common path.
private final class LazyModesMenu: NSObject, NSMenuDelegate {

    enum Kind {
        case resolutions
        case refreshRates

        var title: String {
            switch self {
            case .resolutions: return L10n.t("menu.resolution")
            case .refreshRates: return L10n.t("menu.refreshRate")
            }
        }
    }

    private let kind: Kind
    private let snapshot: DisplaySnapshot
    private let hiddenTwins: Set<PixelSize>
    private let router: MenuActionRouter

    init(kind: Kind, snapshot: DisplaySnapshot,
         hiddenTwins: Set<PixelSize>, router: MenuActionRouter) {
        self.kind = kind
        self.snapshot = snapshot
        self.hiddenTwins = hiddenTwins
        self.router = router
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        switch kind {
        case .resolutions:
            StatusMenuBuilder.populateResolutions(into: menu,
                                                  for: snapshot,
                                                  hiddenTwins: hiddenTwins,
                                                  router: router)
        case .refreshRates:
            StatusMenuBuilder.populateRefreshRates(into: menu,
                                                   for: snapshot,
                                                   hiddenTwins: hiddenTwins,
                                                   router: router)
        }
    }
}

/// Builds a display's own submenu when it is opened. The top-level menu only
/// needs the display's name; the mode table, native size and status entries are
/// paid for on hover.
private final class LazyDisplayMenu: NSObject, NSMenuDelegate {

    private let display: DisplayInfo
    private let router: MenuActionRouter

    init(display: DisplayInfo, router: MenuActionRouter) {
        self.display = display
        self.router = router
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        StatusMenuBuilder.populateDisplay(into: menu, for: display, router: router)
    }
}

/// Builds the "All displays" submenu when it is opened; it needs every mode table.
private final class LazyAllDisplaysMenu: NSObject, NSMenuDelegate {

    private let router: MenuActionRouter

    init(router: MenuActionRouter) {
        self.router = router
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        StatusMenuBuilder.populateAllDisplays(into: menu, router: router)
    }
}
