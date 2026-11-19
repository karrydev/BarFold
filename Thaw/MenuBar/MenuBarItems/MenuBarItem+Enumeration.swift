//
//  MenuBarItem+Enumeration.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa
import os.lock

// The part of MenuBarItem that needs a live window server, kept apart so it
// can be excluded from coverage. The pure value type stays in MenuBarItem.swift.

private nonisolated extension MenuBarItem {
    /// Only call with a window known to be a valid menu bar item.
    @MainActor
    private init(uncheckedItemWindow itemWindow: WindowInfo, instanceIndex: Int = 0) {
        self.tag = MenuBarItemTag(uncheckedItemWindow: itemWindow, instanceIndex: instanceIndex)
        self.windowID = itemWindow.windowID
        self.ownerPID = itemWindow.ownerPID
        self.sourcePID = itemWindow.ownerPID
        self.bounds = itemWindow.bounds
        self.title = itemWindow.title
        self.isOnScreen = itemWindow.isOnScreen
    }

    /// Only call with a valid menu bar item window and the pid of the app
    /// that created it.
    @MainActor
    private init(uncheckedItemWindow itemWindow: WindowInfo, sourcePID: pid_t?, instanceIndex: Int = 0) {
        self.tag = MenuBarItemTag(uncheckedItemWindow: itemWindow, sourcePID: sourcePID, instanceIndex: instanceIndex)
        self.windowID = itemWindow.windowID
        self.ownerPID = itemWindow.ownerPID
        self.sourcePID = sourcePID
        self.bounds = itemWindow.bounds
        self.title = itemWindow.title
        self.isOnScreen = itemWindow.isOnScreen
    }
}

// MARK: - Own Control Items

@MainActor
extension MenuBarItem {
    /// Builds a menu bar item for one of Thaw's own control item windows
    /// from the window ID Thaw itself holds.
    ///
    /// The enumerated list loses control items when PID resolution degrades
    /// or they're parked offscreen. We already know their window IDs, so ask
    /// the window server directly and stamp our own PID.
    ///
    /// Returns nil when the ID is no longer known.
    static func ownControlItem(windowID: CGWindowID) -> MenuBarItem? {
        guard let window = WindowInfo(windowID: windowID) else {
            return nil
        }
        return MenuBarItem(
            uncheckedItemWindow: window,
            sourcePID: ProcessInfo.processInfo.processIdentifier
        )
    }
}

// MARK: - MenuBarItem List

nonisolated extension MenuBarItem {
    struct ListOption: OptionSet {
        let rawValue: Int

        /// Specifies menu bar items that are currently on screen.
        static let onScreen = ListOption(rawValue: 1 << 0)

        /// Specifies menu bar items on the currently active space.
        static let activeSpace = ListOption(rawValue: 1 << 1)
    }

    /// One enumeration together with the source-PID values that came from
    /// persisted seeds instead of the live Accessibility resolver.
    struct EnumerationSnapshot {
        let items: [MenuBarItem]
        let appliedSourcePIDSeeds: [CGWindowID: SourcePIDSeed]
        let windowsByID: [CGWindowID: WindowInfo]
        let controlCenterGeneration: ProcessGeneration?
    }

    private static let diagLog = DiagLog(category: "MenuBarItem")

    /// - Parameters:
    ///   - display: Pass nil for all displays.
    ///   - option: Pass an empty set for all windows.
    static func getMenuBarItemWindows(on display: CGDirectDisplayID? = nil, option: ListOption) -> [WindowInfo] {
        var bridgingOption: Bridging.MenuBarWindowListOption = .itemsOnly

        if option.contains(.onScreen) {
            bridgingOption.insert(.onScreen)
        }
        if option.contains(.activeSpace) {
            bridgingOption.insert(.activeSpace)
        }

        let rawWindowIDs = Bridging.getMenuBarWindowList(option: bridgingOption)
        diagLog.debug("getMenuBarItemWindows: Bridging returned \(rawWindowIDs.count) window IDs (display=\(display.map { "\($0)" } ?? "nil"))")

        let displayBounds = display.map { CGDisplayBounds($0) }

        let windows = WindowInfo.createWindows(from: rawWindowIDs.reversed()).compactMap { window -> WindowInfo? in
            if let displayBounds {
                // Hidden items are pushed off-screen horizontally but keep
                // their Y, so filter by the display's Y range.
                let midY = window.bounds.midY
                guard midY >= displayBounds.minY, midY <= displayBounds.maxY else {
                    return nil
                }
            }

            return window
        }

        diagLog.debug("getMenuBarItemWindows: returning \(windows.count) windows from \(rawWindowIDs.count) raw IDs")
        return windows
    }

    @MainActor
    static func assignStableInstanceIndices(
        to items: inout [MenuBarItem],
        using windowsByID: [CGWindowID: WindowInfo]
    ) {
        // Instance indices tell apart items with the same namespace and title.
        // Sorted by windowID so they don't swap when items move, which would
        // collide in the image cache.
        var groups = [String: [Int]]()
        for i in 0 ..< items.count {
            let key = "\(items[i].tag.namespace):\(items[i].tag.title)"
            groups[key, default: []].append(i)
        }
        for (_, indices) in groups where indices.count > 1 {
            let sorted = indices.sorted { items[$0].windowID < items[$1].windowID }
            for (instanceIndex, itemIndex) in sorted.enumerated() where instanceIndex > 0 {
                guard let window = windowsByID[items[itemIndex].windowID] else { continue }
                if let sourcePID = items[itemIndex].sourcePID {
                    items[itemIndex] = MenuBarItem(
                        uncheckedItemWindow: window,
                        sourcePID: sourcePID,
                        instanceIndex: instanceIndex
                    )
                } else {
                    items[itemIndex] = MenuBarItem(
                        uncheckedItemWindow: window,
                        sourcePID: nil,
                        instanceIndex: instanceIndex
                    )
                }
            }
        }
    }

    @available(macOS 26.0, *)
    @MainActor
    private static func makeItemsWithoutResolvingSourcePID(
        from windows: [WindowInfo]
    ) -> EnumerationSnapshot {
        var items = windows.map { window in
            if let title = window.title, title.hasPrefix("Thaw.ControlItem.") {
                let ccBundleID = "com.apple.controlcenter"
                if window.owningApplication?.bundleIdentifier == ccBundleID ||
                    window.ownerPID == ProcessInfo.processInfo.processIdentifier
                {
                    return MenuBarItem(
                        uncheckedItemWindow: window,
                        sourcePID: ProcessInfo.processInfo.processIdentifier
                    )
                }
            }

            return MenuBarItem(uncheckedItemWindow: window, sourcePID: nil)
        }

        assignStableInstanceIndices(
            to: &items,
            using: Dictionary(windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        )
        let nilPIDCount = items.count(where: { $0.sourcePID == nil })
        diagLog.debug(
            "getMenuBarItemsExperimental: created \(items.count) items without sourcePID resolution, \(nilPIDCount) unresolved"
        )
        return EnumerationSnapshot(
            items: items,
            appliedSourcePIDSeeds: [:],
            windowsByID: Dictionary(
                windows.map { ($0.windowID, $0) },
                uniquingKeysWith: { first, _ in first }
            ),
            controlCenterGeneration: nil
        )
    }

    @available(macOS 26.0, *)
    @MainActor
    private static func getMenuBarItemsExperimental(
        on display: CGDirectDisplayID?,
        option: ListOption,
        resolveSourcePID: Bool
    ) async -> EnumerationSnapshot {
        let windows = getMenuBarItemWindows(on: display, option: option)
        diagLog.debug("getMenuBarItems: processing \(windows.count) windows for source PID resolution")

        guard resolveSourcePID else {
            return makeItemsWithoutResolvingSourcePID(from: windows)
        }

        // One batch call avoids a thread explosion in the XPC service.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ccBundleID = "com.apple.controlcenter"

        let controlItemIndices = Set(windows.indices.filter { i in
            guard let title = windows[i].title, title.hasPrefix("Thaw.ControlItem.") else {
                return false
            }
            return windows[i].owningApplication?.bundleIdentifier == ccBundleID ||
                windows[i].ownerPID == ownPID
        })

        // Control items' PID is known locally. Resolving them always misses
        // and can scan every app's extras menu bar.
        let indicesToResolve = windows.indices.filter { !controlItemIndices.contains($0) }
        let resolvedPIDs: [pid_t?] = if indicesToResolve.isEmpty {
            []
        } else {
            await MenuBarItemService.Connection.shared.sourcePIDs(
                for: indicesToResolve.map { windows[$0] }
            )
        }

        var pids = [pid_t?](repeating: nil, count: windows.count)
        if resolvedPIDs.count == indicesToResolve.count {
            for (resolvedIndex, windowIndex) in indicesToResolve.enumerated() {
                pids[windowIndex] = resolvedPIDs[resolvedIndex]
            }
        } else if !indicesToResolve.isEmpty {
            diagLog.error(
                "getMenuBarItems: sourcePIDs returned \(resolvedPIDs.count) entries for \(indicesToResolve.count) windows; treating all as unresolved"
            )
        }

        // A status item window can outlive an app relaunch. Keep its last
        // owner while the resolver is cold, never over a fresh result.
        let controlCenterGeneration = SourcePIDSeedStore.currentControlCenterGeneration()
        let appliedSeeds: [CGWindowID: SourcePIDSeed] = if let controlCenterGeneration {
            SourcePIDSeedStore.apply(
                seeds: SourcePIDSeedStore.load(from: Defaults.store),
                to: &pids,
                windows: windows,
                currentControlCenterGeneration: controlCenterGeneration,
                liveIdentity: SourcePIDSeedStore.liveIdentity(of:)
            )
        } else {
            [:]
        }
        let seededWindowIDs = Set(appliedSeeds.keys)
        if !appliedSeeds.isEmpty {
            diagLog.info(
                "getMenuBarItems: restored source PIDs for \(appliedSeeds.count) surviving window(s): \(seededWindowIDs.sorted())"
            )
        }

        var items = windows.enumerated().map { index, window in
            let pid: pid_t? = controlItemIndices.contains(index) ? ownPID : pids[index]
            return MenuBarItem(uncheckedItemWindow: window, sourcePID: pid)
        }

        // Spatial matching can miss one of an app's several status items
        // (OneDrive) due to CG/AX timing skew. Propagate a PID to same-title
        // items only if it already owns 2+ items, or two apps sharing
        // "Item-0" get merged.
        let unresolvedIndices = items.indices.filter { items[$0].sourcePID == nil && !items[$0].isControlItem }
        if !unresolvedIndices.isEmpty {
            var resolvedCountByPID = [pid_t: Int]()
            for item in items where item.sourcePID != nil && !seededWindowIDs.contains(item.windowID) {
                if let pid = item.sourcePID {
                    resolvedCountByPID[pid, default: 0] += 1
                }
            }

            var titleToPID = [String: ResolvedPID]()
            for item in items where item.sourcePID != nil && !seededWindowIDs.contains(item.windowID) {
                if let title = item.title, let pid = item.sourcePID {
                    if let existing = titleToPID[title] {
                        if case let .resolved(existingPID) = existing, existingPID != pid {
                            titleToPID[title] = .ambiguous
                        }
                    } else {
                        titleToPID[title] = .resolved(pid)
                    }
                }
            }

            for idx in unresolvedIndices {
                let item = items[idx]
                if let title = item.title,
                   case let .resolved(siblingPID) = titleToPID[title]
                {
                    let resolvedCount = resolvedCountByPID[siblingPID, default: 0]
                    guard resolvedCount >= 2 else {
                        diagLog.debug("getMenuBarItems: skipping propagation of sourcePID \(siblingPID) to windowID \(item.windowID) (title=\(title)) — PID has only \(resolvedCount) resolved item(s)")
                        continue
                    }
                    diagLog.debug("getMenuBarItems: propagating sourcePID \(siblingPID) to unresolved windowID \(item.windowID) (title=\(title))")
                    items[idx] = MenuBarItem(uncheckedItemWindow: windows[idx], sourcePID: siblingPID)
                }
            }
        }

        assignStableInstanceIndices(
            to: &items,
            using: Dictionary(windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        )

        let nilPIDItems = items.filter { $0.sourcePID == nil }
        if !nilPIDItems.isEmpty {
            let itemsDesc = nilPIDItems.prefix(3).map(\.logString).joined(separator: ", ")
            let moreDesc = nilPIDItems.count > 3 ? " and \(nilPIDItems.count - 3) more" : ""
            diagLog.debug("getMenuBarItems: created \(items.count) items, \(nilPIDItems.count) with nil sourcePID: \(itemsDesc)\(moreDesc)")
        } else {
            diagLog.debug("getMenuBarItems: created \(items.count) items, all with resolved sourcePID")
        }
        return EnumerationSnapshot(
            items: items,
            appliedSourcePIDSeeds: appliedSeeds,
            windowsByID: Dictionary(
                windows.map { ($0.windowID, $0) },
                uniquingKeysWith: { first, _ in first }
            ),
            controlCenterGeneration: controlCenterGeneration
        )
    }

    /// Creates a menu-bar enumeration while preserving whether each restored
    /// source PID was confirmed live or supplied by the persisted seed store.
    @MainActor
    static func getMenuBarItemsSnapshot(
        on display: CGDirectDisplayID? = nil,
        option: ListOption,
        resolveSourcePID: Bool = true
    ) async -> EnumerationSnapshot {
        diagLog.debug(
            "getMenuBarItems: starting (resolveSourcePID=\(resolveSourcePID))"
        )
        let snapshot = await getMenuBarItemsExperimental(
            on: display,
            option: option,
            resolveSourcePID: resolveSourcePID
        )
        diagLog.debug("getMenuBarItems: returned \(snapshot.items.count) items")
        return snapshot
    }

    /// Refreshes only the windows a move uses. A Settings user move may
    /// independently corroborate an unresolved parked Control Center slot.
    @MainActor
    static func refreshMoveEndpoints(
        _ expectedEndpoints: [MenuBarItem],
        mirroredDisplayID: CGDirectDisplayID? = nil
    ) async -> [MenuBarItem] {
        let expectedByWindowID = Dictionary(
            expectedEndpoints.map { ($0.windowID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let windows = expectedEndpoints.compactMap { expected in
            WindowInfo(windowID: expected.windowID)
        }
        guard !windows.isEmpty else { return [] }

        let sourcePIDs: [pid_t?]
        if #available(macOS 26.0, *) {
            let resolved = await MenuBarItemService.Connection.shared.sourcePIDs(for: windows)
            sourcePIDs = resolved.count == windows.count
                ? resolved
                : [pid_t?](repeating: nil, count: windows.count)
        } else {
            sourcePIDs = windows.map(\.ownerPID)
        }

        let mirroredWindows: [WindowInfo] = if mirroredDisplayID != nil && sourcePIDs.contains(nil) {
            getMenuBarItemWindows(option: [])
        } else {
            []
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let controlCenterBundleID = "com.apple.controlcenter"
        return windows.enumerated().compactMap { index, window in
            guard let expected = expectedByWindowID[window.windowID] else { return nil }
            let isOwnControlItem = window.title?.hasPrefix("Thaw.ControlItem.") == true
                && (window.owningApplication?.bundleIdentifier == controlCenterBundleID
                    || window.ownerPID == ownPID)
            let sourcePID: pid_t? = if isOwnControlItem {
                ownPID
            } else if let fresh = sourcePIDs[index] {
                fresh
            } else if let displayID = mirroredDisplayID {
                mirroredParkedSourcePID(for: window, expected: expected, on: displayID, in: mirroredWindows)
            } else {
                nil
            }
            return MenuBarItem(
                uncheckedItemWindow: window,
                sourcePID: sourcePID,
                instanceIndex: expected.tag.instanceIndex
            )
        }
    }

    struct ParkedMirrorSlot {
        let id: CGWindowID
        let owner: pid_t
        let layer: Int
        let title: String?
        let frame: CGRect
    }

    /// Both menu bars must publish an unambiguous slot at the same exact
    /// offset from their right edges. Reject width-only matches and duplicate
    /// slot claims; the parked/current window must itself still be present.
    nonisolated static func parkedMirrorTitle(
        for source: ParkedMirrorSlot, on active: CGRect, other: CGRect, slots: [ParkedMirrorSlot]
    ) -> String? {
        guard active.minY != other.minY, source.frame.minY == active.minY,
              source.frame.maxX <= active.minX, !source.frame.isEmpty,
              MarkerPairResolver.isGenericControlCenterTitle(source.title)
        else { return nil }
        let offset = source.frame.minX - active.maxX
        let activeMatches = slots.filter {
            $0.owner == source.owner && $0.layer == source.layer && $0.frame == source.frame
        }
        guard activeMatches.count == 1, activeMatches.first?.id == source.id else { return nil }
        let target = CGRect(
            x: other.maxX + offset, y: other.minY,
            width: source.frame.width, height: source.frame.height
        )
        guard target.maxX <= other.minX else { return nil }
        let mirrored = slots.filter {
            $0.id != source.id && $0.owner == source.owner && $0.layer == source.layer && $0.frame == target
        }
        guard mirrored.count == 1, let title = mirrored.first?.title,
              title.split(separator: ".").count >= 3
        else { return nil }
        return title
    }

    @MainActor
    private static func mirroredParkedSourcePID(
        for window: WindowInfo, expected: MenuBarItem, on displayID: CGDirectDisplayID, in liveWindows: [WindowInfo]
    ) -> pid_t? {
        guard expected.windowID == window.windowID, expected.ownerPID == window.ownerPID,
              expected.title == window.title, expected.bounds.size == window.bounds.size,
              expected.bounds.minY == window.bounds.minY,
              let host = SourcePIDSeedStore.currentControlCenterGeneration(), host.pid == window.ownerPID,
              let pid = expected.sourcePID, pid != host.pid,
              let source = SourcePIDSeedStore.liveIdentity(of: pid), let bundleID = source.bundleIdentifier,
              bundleID == expected.tag.namespace.description
        else { return nil }
        let active = CGDisplayBounds(displayID)
        let displays = NSScreen.screens.map(\.displayID)
        guard displays.count == 2, let other = displays.first(where: { $0 != displayID }) else { return nil }
        let slot = ParkedMirrorSlot(id: window.windowID, owner: window.ownerPID, layer: window.layer,
                                    title: window.title, frame: window.bounds)
        let slots = liveWindows.map {
            ParkedMirrorSlot(id: $0.windowID, owner: $0.ownerPID, layer: $0.layer, title: $0.title, frame: $0.bounds)
        }
        guard parkedMirrorTitle(for: slot, on: active, other: CGDisplayBounds(other), slots: slots) == bundleID,
              NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter({ !$0.isTerminated }).map(\.processIdentifier) == [pid]
        else { return nil }
        diagLog.debug("BarFold independently matched a parked move endpoint: window=\(window.windowID)")
        return pid
    }

    /// - Parameters:
    ///   - display: Pass nil for all displays.
    ///   - option: Pass an empty set for all items.
    @MainActor
    static func getMenuBarItems(
        on display: CGDirectDisplayID? = nil,
        option: ListOption,
        resolveSourcePID: Bool = true
    ) async -> [MenuBarItem] {
        let snapshot = await getMenuBarItemsSnapshot(
            on: display,
            option: option,
            resolveSourcePID: resolveSourcePID
        )
        return snapshot.items
    }
}

// MARK: - MenuBarItemTag Helper

private nonisolated extension MenuBarItemTag {
    /// Only call with a window known to be a valid menu bar item.
    @MainActor
    init(uncheckedItemWindow itemWindow: WindowInfo, instanceIndex: Int = 0) {
        self.namespace = Namespace(uncheckedItemWindow: itemWindow)
        self.title = itemWindow.title ?? ""
        self.windowID = itemWindow.windowID
        self.instanceIndex = instanceIndex
    }

    /// Only call with a valid menu bar item window and the pid of the app
    /// that created it.
    @MainActor
    init(uncheckedItemWindow itemWindow: WindowInfo, sourcePID: pid_t?, instanceIndex: Int = 0) {
        self.namespace = Namespace(uncheckedItemWindow: itemWindow, sourcePID: sourcePID)
        self.title = itemWindow.title ?? ""
        self.windowID = itemWindow.windowID
        self.instanceIndex = instanceIndex
    }
}

// MARK: - MenuBarItemTag.Namespace Helper

nonisolated extension MenuBarItemTag.Namespace {
    private static let uuidCache = OSAllocatedUnfairLock<[CGWindowID: UUID]>(initialState: [:])

    @MainActor
    static func pruneUUIDCache(keeping validWindowIDs: Set<CGWindowID>) {
        uuidCache.withLock { $0 = $0.filter { validWindowIDs.contains($0.key) } }
    }

    /// The canonicalized bundle identifier for the app, recovering a
    /// transiently nil bundleIdentifier through the bundle URL.
    ///
    /// bundleIdentifier can read nil during launch races, and the name
    /// fallback persists localized names like Control Centre:WiFi (#949).
    private static func canonicalBundleIdentifier(of app: NSRunningApplication) -> String? {
        let bundleID = app.bundleIdentifier
            ?? app.bundleURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
        return bundleID.map(Self.canonicalBundleID)
    }

    /// Only call with a window known to be a valid menu bar item.
    @MainActor
    init(uncheckedItemWindow itemWindow: WindowInfo) {
        // Daemons and helpers often have no bundle ID.
        if let app = itemWindow.owningApplication {
            self = .optional(
                Self.canonicalBundleIdentifier(of: app) ?? itemWindow.ownerName ?? app.localizedName
            )
        } else {
            self = .optional(itemWindow.ownerName)
        }
    }

    /// Only call with a valid menu bar item window and the pid of the app
    /// that created it.
    @MainActor
    init(uncheckedItemWindow itemWindow: WindowInfo, sourcePID: pid_t?) {
        // On macOS 26 our control items are owned by Control Center.
        if let title = itemWindow.title, title.hasPrefix("Thaw.ControlItem.") {
            let ccBundleID = "com.apple.controlcenter"
            if itemWindow.owningApplication?.bundleIdentifier == ccBundleID ||
                itemWindow.ownerPID == ProcessInfo.processInfo.processIdentifier
            {
                self = .thaw
                return
            }
        }

        // Bundle IDs are canonicalised so nested helpers are named after
        // their app (see helperBundleIDAliases). Process names are not.
        if let sourcePID, let app = NSRunningApplication(processIdentifier: sourcePID) {
            self = .optional(Self.canonicalBundleIdentifier(of: app) ?? app.localizedName)
        } else if let app = itemWindow.owningApplication {
            // The source PID didn't resolve but the owner is known.
            self = .optional(
                Self.canonicalBundleIdentifier(of: app) ?? itemWindow.ownerName ?? app.localizedName
            )
        } else if let ownerName = itemWindow.ownerName {
            self = .string(ownerName)
        } else if let uuid = Self.uuidCache.withLock({ $0[itemWindow.windowID] }) {
            self = .uuid(uuid)
        } else {
            let uuid = UUID()
            Self.uuidCache.withLock { $0[itemWindow.windowID] = uuid }
            self = .uuid(uuid)
        }
    }
}

/// For the PID-propagation pass.
private enum ResolvedPID {
    case resolved(pid_t)
    /// Several PIDs share this title, so propagation is unsafe.
    case ambiguous
}
