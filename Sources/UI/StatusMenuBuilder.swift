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

        if !Preferences.shared.rememberedModes.isEmpty {
            menu.addItem(action(L10n.t("menu.restoreRemembered"),
                                #selector(MenuActionRouter.restoreRememberedModes(_:)),
                                router))
        }

        menu.addItem(.separator())
        menu.addItem(profilesItem(router: router))
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
        submenu.addItem(.separator())

        let box = DisplayBox(displayID: display.id, identityKey: display.identity.key)
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
        if let memoryItem = memoryItem(for: display, router: router) {
            submenu.addItem(.separator())
            submenu.addItem(memoryItem)
        }

        parent.submenu = submenu
        return parent
    }

    // MARK: - Resolutions

    private static func resolutionsItem(for display: DisplayInfo,
                                        router: MenuActionRouter) -> NSMenuItem {
        let title = L10n.t("menu.resolution")
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        var modes = DisplayManager.allModes(for: display.id,
                                            includeUnusable: Preferences.shared.showUnusableModes)
        if Preferences.shared.hiDPIOnly { modes = modes.filter(\.isHiDPI) }

        let currentMode = display.currentMode
        // macOS returns many modes that are indistinguishable in the menu; collapse
        // them before grouping so each geometry + refresh rate appears exactly once.
        let groups = modes
            .sortedForMenu()
            .deduplicated(preferring: currentMode)
            .groupedByResolution()

        if groups.isEmpty {
            submenu.addItem(disabled(L10n.t("menu.noDisplays")))
        }

        for group in groups {
            let representative = group.mode
            let isCurrentResolution = representative.resolutionKey == currentMode?.resolutionKey

            if group.refreshRates.count <= 1 {
                // A single refresh rate needs no nested menu.
                guard let only = group.refreshRates.first else { continue }
                let item = action(representative.menuTitle,
                                  #selector(MenuActionRouter.selectMode(_:)), router)
                item.representedObject = ModeBox(only)
                item.state = isExactMatch(only, currentMode) ? .on : .off
                submenu.addItem(item)
            } else {
                let parentItem = NSMenuItem(title: representative.menuTitle,
                                            action: nil, keyEquivalent: "")
                parentItem.state = isCurrentResolution ? .on : .off

                let rateMenu = NSMenu()
                for rate in group.refreshRates {
                    let item = action(rate.refreshDescription,
                                      #selector(MenuActionRouter.selectMode(_:)), router)
                    item.representedObject = ModeBox(rate)
                    item.state = isExactMatch(rate, currentMode) ? .on : .off
                    rateMenu.addItem(item)
                }
                parentItem.submenu = rateMenu
                submenu.addItem(parentItem)
            }
        }

        parent.submenu = submenu
        return parent
    }

    private static func isExactMatch(_ mode: DisplayMode, _ current: DisplayMode?) -> Bool {
        mode.isSame(as: current)
    }

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

    // MARK: - Mode memory

    private static func memoryItem(for display: DisplayInfo,
                                   router: MenuActionRouter) -> NSMenuItem? {
        guard Preferences.shared.rememberPerDisplay else { return nil }
        let box = DisplayBox(displayID: display.id, identityKey: display.identity.key)

        if let remembered = Preferences.shared.rememberedModes[display.identity.key] {
            let item = action(L10n.t("menu.forgetMode"),
                              #selector(MenuActionRouter.forgetRememberedMode(_:)), router)
            item.representedObject = box
            item.toolTip = remembered.displayName
            return item
        }

        let item = action(L10n.t("menu.rememberMode"),
                          #selector(MenuActionRouter.rememberCurrentMode(_:)), router)
        item.representedObject = box
        return item
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

    // MARK: - Profiles

    private static func profilesItem(router: MenuActionRouter) -> NSMenuItem {
        let parent = NSMenuItem(title: L10n.t("menu.profiles"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let profiles = ProfileStore.shared.profiles
        if profiles.isEmpty {
            submenu.addItem(disabled(L10n.t("menu.noProfiles")))
        } else {
            for profile in profiles {
                let item = action(profile.name,
                                  #selector(MenuActionRouter.applyProfile(_:)), router)
                item.representedObject = ProfileBox(profileID: profile.id)
                item.toolTip = profile.summary
                submenu.addItem(item)
            }
        }

        submenu.addItem(.separator())
        submenu.addItem(action(L10n.t("menu.saveProfile"),
                               #selector(MenuActionRouter.saveProfile(_:)), router))
        submenu.addItem(.separator())
        submenu.addItem(action(L10n.t("menu.exportProfiles"),
                               #selector(MenuActionRouter.exportProfiles(_:)), router))
        submenu.addItem(action(L10n.t("menu.importProfiles"),
                               #selector(MenuActionRouter.importProfiles(_:)), router))

        parent.submenu = submenu
        return parent
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
