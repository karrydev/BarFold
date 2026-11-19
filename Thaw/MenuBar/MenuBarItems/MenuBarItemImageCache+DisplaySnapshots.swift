//
//  MenuBarItemImageCache+DisplaySnapshots.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa

extension MenuBarItemImageCache {
    // MARK: Stationary BarFold previews

    @MainActor
    func stationaryPreviewKey(displayID: CGDirectDisplayID) -> StationaryPreviewKey {
        let appearance = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? ""
        return StationaryPreviewKey(displayID: displayID, appearance: appearance)
    }

    @MainActor
    func stationaryPreview(for item: MenuBarItem, on displayID: CGDirectDisplayID?) -> CapturedImage? {
        guard let displayID else { return nil }
        let key = stationaryPreviewKey(displayID: displayID)
        if let snapshot = stationaryPreviews[key],
           let preview = snapshot[item.windowID], Self.sameStationaryWindow(preview.item, item) {
            return preview.image
        }
        // A parked item can belong to the active manager cache on both displays.
        // Use another screen only when WindowServer identifies the same window.
        for (donor, snapshot) in stationaryPreviews where donor != key && donor.appearance == key.appearance {
            if let preview = snapshot[item.windowID], Self.sameStationaryWindow(preview.item, item) {
                return preview.image
            }
        }
        return nil
    }

    private nonisolated static func sameStationaryWindow(_ lhs: MenuBarItem, _ rhs: MenuBarItem) -> Bool {
        lhs.windowID == rhs.windowID && lhs.ownerPID == rhs.ownerPID
            && (lhs.sourcePID == nil || rhs.sourcePID == nil || lhs.sourcePID == rhs.sourcePID)
    }

    /// Runs once after startup. Enumerating and capturing window IDs never
    /// repositions a menu bar item or opens the tray.
    @MainActor
    func prewarmStationaryPreviews() async {
        guard let appState, appState.hasPermission(.screenRecording) else { return }
        let screens = Array(NSScreen.screens.prefix(8))
        let activeDisplay = NSScreen.screenWithActiveMenuBar?.displayID
        var views = [(key: StationaryPreviewKey, items: [MenuBarItem], direct: [CGWindowID: CapturedImage])]()
        for screen in screens {
            guard !Task.isCancelled, appState.hasPermission(.screenRecording) else { return }
            let displayID = screen.displayID
            let key = stationaryPreviewKey(displayID: displayID)
            let displayBounds = CGDisplayBounds(displayID)
            let menuLine = displayBounds.minY
            let maxRowDepth = max(30, screen.getMenuBarHeightEstimate()) + 8
            let sharesMenuLine = screens.contains {
                $0.displayID != displayID && abs(CGDisplayBounds($0.displayID).minY - menuLine) <= 2
            }
            let windows = await MenuBarItem.getMenuBarItemsSnapshot(on: displayID, option: []).items
            let screenBounds = screens.map { CGDisplayBounds($0.displayID) }
            let candidates: [(item: MenuBarItem, visible: Bool)] = windows.compactMap { item in
                guard (!item.isControlItem || item.tag == .visibleControlItem),
                      item.bounds.midY >= menuLine, item.bounds.midY <= menuLine + maxRowDepth
                else { return nil }
                let center = CGPoint(x: item.bounds.midX, y: item.bounds.midY)
                if displayBounds.contains(center) {
                    return (item, item.isOnScreen)
                }
                guard !screenBounds.contains(where: { $0.contains(center) }) else { return nil }
                // WindowServer sometimes keeps its "on screen" bit on an
                // offscreen parked window. Geometry, not that bit, decides.
                // Two aligned displays cannot both claim the same parked slot.
                guard !sharesMenuLine || displayID == activeDisplay else { return nil }
                return (item, false)
            }
            let onScreen = candidates.filter(\.visible).map(\.item)
            let hidden = candidates.filter { !$0.visible }.map(\.item)
            await withCapturePermit {
                let captured = await captureStationaryPreviewIcons(
                    onScreen: Array(onScreen.prefix(64)),
                    hidden: Array(hidden.prefix(64)),
                    scale: screen.backingScaleFactor
                )
                guard !Task.isCancelled, key == stationaryPreviewKey(displayID: displayID) else { return }
                views.append((key, Array(onScreen.prefix(64)) + Array(hidden.prefix(64)), captured))
            }
        }

        guard !Task.isCancelled, appState.hasPermission(.screenRecording) else { return }
        for target in views where target.key == stationaryPreviewKey(displayID: target.key.displayID) {
            var resolved = [CGWindowID: StationaryPreview]()
            for item in target.items {
                if let image = target.direct[item.windowID] {
                    resolved[item.windowID] = StationaryPreview(item: item, image: image)
                    continue
                }
                if let image = views.lazy
                    .filter({ $0.key != target.key && $0.key.appearance == target.key.appearance })
                    .compactMap({ donor -> CapturedImage? in
                        guard donor.items.contains(where: { Self.sameStationaryWindow($0, item) }) else { return nil }
                        return donor.direct[item.windowID]
                    }).first {
                    resolved[item.windowID] = StationaryPreview(item: item, image: image)
                    continue
                }
                guard !item.tag.isControlCenterGenericItem,
                      !item.tag.isMisattributedControlCenterModule,
                      item.sourcePID != nil || item.tag.isSystemItem,
                      target.items.lazy.filter({ Self.sameStationaryPreviewItem($0, item) }).count == 1
                else { continue }
                for donor in views where donor.key != target.key && donor.key.appearance == target.key.appearance {
                    let matches = donor.items.filter { Self.sameStationaryPreviewItem($0, item) }
                    guard matches.count == 1, let match = matches.first, let image = donor.direct[match.windowID] else { continue }
                    // Keep the image's captured scale; renderers resample its real pixels.
                    resolved[item.windowID] = StationaryPreview(item: item, image: image)
                    break
                }
            }
            stationaryPreviews[target.key] = resolved
            Self.diagLog.notice(
                "BarFold startup previews: display=\(target.key.displayID) genuine=\(resolved.count) direct=\(target.direct.count) requested=\(target.items.count)"
            )
        }
        let managed = appState.itemManager.itemCache
        for screen in screens {
            let hidden = managed.managedItems(for: .hidden)
            let genuine = hidden.filter { stationaryPreview(for: $0, on: screen.displayID) != nil }.count
            Self.diagLog.notice("BarFold managed hidden preview coverage: display=\(screen.displayID) genuine=\(genuine) requested=\(hidden.count)")
        }
    }

    private nonisolated static func sameStationaryPreviewItem(_ lhs: MenuBarItem, _ rhs: MenuBarItem) -> Bool {
        lhs.ownerPID == rhs.ownerPID && lhs.sourcePID == rhs.sourcePID
            && lhs.tag.matchesIgnoringWindowID(rhs.tag)
    }

    // MARK: Visible Layout refresh

    /// The Settings Layout view owns and cancels this task. Cold previews are
    /// still shared; opening Layout only keeps already-visible real glyphs fresh.
    @MainActor
    func refreshOpenLayoutPreviews() async {
        Self.diagLog.debug("BarFold Layout native preview refresh started")
        defer { Self.diagLog.debug("BarFold Layout native preview refresh stopped") }
        while !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(950)) } catch { return }
            guard let appState, appState.hasPermission(.screenRecording),
                  appState.navigationState.isSettingsPresented, NSEvent.pressedMouseButtons == 0,
                  let displayID = appState.itemManager.itemCache.displayID,
                  let screen = NSScreen.screens.first(where: { $0.displayID == displayID })
            else { continue }
            let key = stationaryPreviewKey(displayID: displayID)
            // Do not compete with the initial all-item warmup.
            guard stationaryPreviews[key] != nil else { continue }
            let visible = appState.itemManager.itemCache.managedItems(for: .visible)
                .filter { !$0.isControlItem }
            let items = Array(visible.prefix(32))
            guard !items.isEmpty else { continue }

            await withCapturePermit {
                guard !Task.isCancelled else { return }
                let images = await captureActiveLayoutPreviews(
                    items: items, displayBounds: CGDisplayBounds(displayID), scale: screen.backingScaleFactor
                )
                guard !Task.isCancelled, appState.navigationState.isSettingsPresented,
                      appState.itemManager.itemCache.displayID == displayID,
                      key == stationaryPreviewKey(displayID: displayID),
                      NSEvent.pressedMouseButtons == 0 else { return }
                guard var snapshot = stationaryPreviews[key] else { return }
                var changed = [CGWindowID]()
                for item in items {
                    guard let image = images[item.windowID],
                          !CapturedImage.isVisuallyEqual(stationaryPreview(for: item, on: displayID), image)
                    else { continue }
                    snapshot[item.windowID] = StationaryPreview(item: item, image: image)
                    changed.append(item.windowID)
                }
                if !changed.isEmpty {
                    stationaryPreviews[key] = snapshot
                    Self.diagLog.debug("BarFold Layout native previews changed: display=\(displayID) windows=\(changed)")
                }
            }
        }
    }

    // MARK: Per-Display Snapshots

    /// Force-recaptures a section for a specific display, including off-screen
    /// (hidden / always-hidden) items via SkyLight.
    ///
    /// For the Thaw Bar opening on another screen: ``updateCacheWithoutChecks``
    /// skips off-screen items, and waiting for live refresh flashes the wrong tint.
    @MainActor
    func recaptureSection(
        _ section: MenuBarSection.Name,
        preferredDisplayID: CGDirectDisplayID
    ) async {
        guard let appState else { return }
        guard let resolvedScreen = Self.resolveScreen(preferredDisplayID: preferredDisplayID) else {
            return
        }
        let screen = resolvedScreen.screen
        let scale = screen.backingScaleFactor
        let items = appState.itemManager.itemCache.managedItems(for: section)
            .filter { !$0.isControlItem }
        guard !items.isEmpty else { return }

        MenuBarItemImageCache.diagLog.notice(
            "recaptureSection: section=\(section.logString) displayID=\(screen.displayID) items=\(items.count)"
        )

        await withCapturePermit {
            if section == .visible {
                await refreshImages(of: items, scale: scale, viaSCK: true)
                lastSCKRefreshAt = ContinuousClock.now
            } else {
                // Shares the live-refresh cadence so opens can't bypass the SkyLight throttle (#759).
                await awaitOffscreenRefreshSlot(for: section)
                await refreshImages(of: items, scale: scale, viaSCK: false)
            }
        }
        guard !Task.isCancelled else { return }
        storeImages(for: screen.displayID, capturedTags: items.map(\.tag))
    }

    /// Waits for, then claims, the live-refresh offscreen slot for `section`.
    @MainActor
    private func awaitOffscreenRefreshSlot(for section: MenuBarSection.Name) async {
        let interval = Duration.seconds(
            MenuBarLiveRefreshPolicy.refreshInterval(
                for: section,
                target: Self.minIconRefreshInterval
            ) ?? MenuBarCaptureService.minAlwaysHiddenInterval
        )
        let now = ContinuousClock.now
        let lastCaptureAt: ContinuousClock.Instant? = switch section {
        case .hidden: lastHiddenRefreshAt
        case .alwaysHidden: lastAlwaysHiddenRefreshAt
        case .visible: nil
        }
        if let lastCaptureAt, now - lastCaptureAt < interval {
            try? await Task.sleep(for: interval - (now - lastCaptureAt))
        }
        let claimedAt = ContinuousClock.now
        switch section {
        case .hidden:
            lastHiddenRefreshAt = claimedAt
        case .alwaysHidden:
            lastAlwaysHiddenRefreshAt = claimedAt
        case .visible:
            break
        }
    }

    /// Restores a warm per-display snapshot for the Thaw Bar, or clears the
    /// section when only another screen's bitmaps are available.
    ///
    /// Call before ordering the panel front so it never paints another screen's icons.
    ///
    /// - Returns: `true` when a background recapture is still needed (cold or
    ///   incomplete warm restore).
    @MainActor
    @discardableResult
    func prepareImagesForDisplay(_ displayID: CGDirectDisplayID, section: MenuBarSection.Name) -> Bool {
        guard let appState else { return true }
        let sectionItems = appState.itemManager.itemCache[section]
        guard !sectionItems.isEmpty else { return false }

        if let stored = imagesByDisplay[displayID], !stored.isEmpty {
            var applied = 0
            var missingTags = [MenuBarItemTag]()
            for item in sectionItems {
                if let image = Self.image(for: item.tag, in: stored) {
                    images[item.tag] = image
                    updateAccessOrder(for: item.tag)
                    applied += 1
                } else {
                    missingTags.append(item.tag)
                }
            }
            // Drop unrestored tags so previous-display bitmaps cannot linger
            // beside a partial warm restore.
            for tag in missingTags {
                images.removeValue(forKey: tag)
                accessOrder.remove(tag)
            }
            if applied > 0 {
                lastCaptureDisplayID = displayID
                MenuBarItemImageCache.diagLog.notice(
                    "prepareImagesForDisplay: restored \(applied)/\(sectionItems.count) icons for display \(displayID)"
                )
                return !missingTags.isEmpty
            }
        }

        if lastCaptureDisplayID != displayID {
            MenuBarItemImageCache.diagLog.notice(
                "prepareImagesForDisplay: no warm cache for display \(displayID); clearing section \(section.logString) to avoid wrong tint"
            )
            clearImages(for: section)
            return true
        }
        return !sectionHasCachedImages(section)
    }

    /// Snapshots the tags a capture just produced for `displayID`.
    ///
    /// Only the captured tags: `images` holds other sections' bitmaps, possibly
    /// from another display. Entries gone from `images` are dropped.
    @MainActor
    func storeImages(
        for displayID: CGDirectDisplayID,
        capturedTags: some Sequence<MenuBarItemTag>
    ) {
        // A display's snapshot outlives the active-display render cache.
        var snapshot = imagesByDisplay[displayID] ?? [:]
        for tag in capturedTags {
            if let image = Self.image(for: tag, in: images) {
                snapshot[tag] = image
            }
        }
        guard !snapshot.isEmpty else { return }
        imagesByDisplay[displayID] = snapshot
        lastCaptureDisplayID = displayID
        pruneDisconnectedDisplayCaches()
        enforcePerDisplayCacheLimit()
    }

    @MainActor
    private func pruneDisconnectedDisplayCaches() {
        let connected = Set(NSScreen.screens.map(\.displayID))
        imagesByDisplay = imagesByDisplay.filter { connected.contains($0.key) }
    }

    /// Caps total icons retained across per-display snapshots.
    @MainActor
    private func enforcePerDisplayCacheLimit() {
        let total = imagesByDisplay.values.reduce(0) { $0 + $1.count }
        let limit = Self.maxCacheSize * max(imagesByDisplay.count, 1)
        guard total > limit else { return }

        let standing = lastCaptureDisplayID
        let victims = imagesByDisplay.keys.filter { $0 != standing }
        for displayID in victims {
            imagesByDisplay.removeValue(forKey: displayID)
            let remaining = imagesByDisplay.values.reduce(0) { $0 + $1.count }
            if remaining <= limit {
                return
            }
        }

        if var standingImages = standing.flatMap({ imagesByDisplay[$0] }),
           standingImages.count > Self.maxCacheSize
        {
            let keys = Array(standingImages.keys.prefix(standingImages.count - Self.maxCacheSize))
            for key in keys {
                standingImages.removeValue(forKey: key)
            }
            if let standing {
                imagesByDisplay[standing] = standingImages
            }
        }
    }

    /// Prepares icons for `displayID` and reports whether a fresh capture is needed.
    @MainActor
    func prepareImagesForThawBar(
        displayID: CGDirectDisplayID,
        section: MenuBarSection.Name
    ) -> Bool {
        prepareImagesForDisplay(displayID, section: section)
    }

    @MainActor
    private func sectionHasCachedImages(_ section: MenuBarSection.Name) -> Bool {
        guard let appState else { return false }
        let items = appState.itemManager.itemCache[section]
        guard !items.isEmpty else { return true }
        let keys = Set(images.keys)
        return items.contains { keys.contains($0.tag) }
    }
}
