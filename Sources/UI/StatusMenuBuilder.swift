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

        let displays = DisplayManager.allDisplays()

        if displays.isEmpty {
            menu.addItem(disabled(L10n.t("menu.noDisplays")))
        } else {
            for display in displays {
                menu.addItem(displayItem(display, router: router))
            }
            menu.addItem(.separator())
        }

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

    // MARK: - Per-display submenu

    private static func displayItem(_ display: DisplayInfo, router: MenuActionRouter) -> NSMenuItem {
        let parent = NSMenuItem(title: display.menuTitle, action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        // Header: what the display is doing right now.
        submenu.addItem(disabled("   " + display.currentDescription))
        if let native = display.nativePixelSize {
            submenu.addItem(disabled("   native \(native.description)"))
        }
        submenu.addItem(.separator())

        submenu.addItem(resolutionsItem(for: display, router: router))
        if let refreshItem = refreshRateItem(for: display, router: router) {
            submenu.addItem(refreshItem)
        }
        submenu.addItem(capabilitiesItem(for: display))
        submenu.addItem(.separator())

        let box = DisplayBox(displayID: display.id)
        let reset = action(L10n.t("menu.resetToDefault"),
                           #selector(MenuActionRouter.resetToDefault(_:)), router)
        reset.representedObject = box
        submenu.addItem(reset)

        if let rotationItem = rotationItem(for: display, router: router) {
            submenu.addItem(rotationItem)
        }
        if let brightnessItem = brightnessItem(for: display, router: router) {
            submenu.addItem(brightnessItem)
        }

        parent.submenu = submenu
        return parent
    }

    // MARK: - Resolution and refresh rate
    //
    // These are two sibling menus, not one nested one. Nesting the refresh rates
    // under each resolution made the list hard to scan — a geometry with four
    // rates took four lines — and changing only the rate meant a submenu hop.
    // Now the geometry lives here and the rate lives next door.

    /// The modes the menu is allowed to show, after both view filters.
    private static func visibleModes(for display: DisplayInfo) -> [DisplayMode] {
        var modes = DisplayManager.allModes(for: display.id,
                                            includeUnusable: Preferences.shared.showUnusableModes)
        if Preferences.shared.hiDPIOnly { modes = modes.filter(\.isHiDPI) }
        return modes
    }

    private static func resolutionsItem(for display: DisplayInfo,
                                        router: MenuActionRouter) -> NSMenuItem {
        let parent = NSMenuItem(title: L10n.t("menu.resolution"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let current = display.currentMode
        // macOS returns many modes that are indistinguishable in the menu; collapse
        // them before grouping so each geometry appears exactly once.
        let groups = visibleModes(for: display)
            .sortedForMenu()
            .deduplicated(preferring: current)
            .groupedByResolution()

        if groups.isEmpty {
            submenu.addItem(disabled(L10n.t("menu.noModes")))
        }

        for group in groups {
            // Keep the rate the user is already on whenever the new geometry
            // supports it, so picking a resolution does not quietly change the
            // refresh rate as well.
            let target = group.refreshRates.first { rate in
                guard let current, current.refreshRate > 0 else { return false }
                return abs(rate.refreshRate - current.refreshRate) < 0.5
            } ?? group.mode

            let item = action(group.mode.menuTitle,
                              #selector(MenuActionRouter.selectMode(_:)), router)
            item.representedObject = ModeBox(target)
            item.state = group.mode.resolutionKey == current?.resolutionKey ? .on : .off
            submenu.addItem(item)
        }

        parent.submenu = submenu
        return parent
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
    private static func refreshRateItem(for display: DisplayInfo,
                                        router: MenuActionRouter) -> NSMenuItem? {
        guard let current = display.currentMode else { return nil }

        let rates = visibleModes(for: display)
            .deduplicated(preferring: current)
            .filter { $0.resolutionKey == current.resolutionKey }
            .sorted { $0.refreshRate > $1.refreshRate }

        let parent = NSMenuItem(title: L10n.t("menu.refreshRate"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()

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

        parent.submenu = submenu
        return parent
    }

    // MARK: - Hardware limits

    /// What the panel declares and what the link allows, in one read-only place.
    ///
    /// This is deliberately informational. Writing an override asks for an
    /// administrator password and can black the screen, so it stays behind the
    /// CLI where a timeout and an automatic rollback already exist — a menu click
    /// is not the right place to start that chain.
    ///
    /// The contents are built when the submenu is opened, not here. Filling them
    /// reads the EDID through IOKit, enumerates every mode and queries a private
    /// class — 40–60 ms measured per display. Paying that on every `menuWillOpen`,
    /// for a submenu most openings never touch, is what makes the menu sticky.
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
        if DisplayOverrideInstaller.hasOverride(for: edid) {
            submenu.addItem(disabled(L10n.t("menu.capabilities.override")))
        }

        submenu.addItem(.separator())
        // Same reasoning as the CLI gate: a hint that leads to a no-op is worse
        // than no hint at all, so the menu says which of the two situations the
        // machine is in before the user goes looking for the command.
        submenu.addItem(disabled(L10n.t(DisplayOverrideInstaller.support.isAvailable
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

        for step in stride(from: 100, through: 0, by: -10) {
            let value = Float(step) / 100.0
            let item = action("\(step)%",
                              #selector(MenuActionRouter.selectBrightness(_:)), router)
            item.representedObject = BrightnessBox(displayID: display.id, value: value)
            if let current, abs(current - value) < 0.05 { item.state = .on }
            submenu.addItem(item)
        }

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
