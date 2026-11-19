//
//  LayoutBarItemView.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa
import Combine

// MARK: - LayoutBarItemView

/// A view that displays an image in a menu bar layout view.
final class LayoutBarItemView: LayoutBarArrangedView {
    private static let diagLog = DiagLog(category: "LayoutBarItemView")

    private enum Metrics {
        static let minWidth: CGFloat = 14
        static let maxWidth: CGFloat = 240
        static let minHeight: CGFloat = 18
        static let placeholderCornerRadius: CGFloat = 6
        static let placeholderHorizontalInset: CGFloat = 2
        static let placeholderVerticalInset: CGFloat = 2
        static let iconInset: CGFloat = 2
        static let unresponsiveBadgeWidth: CGFloat = 15
        static let triggerBadgeWidth: CGFloat = 11
        static let triggerControlledFraction: CGFloat = 0.45
    }

    private weak var appState: AppState?

    private var cancellables = Set<AnyCancellable>()

    /// Observes `appState.imageCache.images`.
    private var imageObservationTask: Task<Void, Never>?

    /// Observes trigger ownership. Views rebuild only on cache changes, so a
    /// trigger toggled while the editor is open would otherwise go stale.
    private var triggerObservationTask: Task<Void, Never>?

    @MainActor
    deinit {
        imageObservationTask?.cancel()
        triggerObservationTask?.cancel()
    }

    let item: MenuBarItem

    /// The app-owned identity AX correlation resolved for an
    /// `unresolvedControlCenterPlaceholder`. Once set, it stays.
    private var aliasedItem: MenuBarItem?

    /// The alias when one was resolved, otherwise `item`.
    private var effectiveItem: MenuBarItem {
        aliasedItem ?? item
    }

    private lazy var tooltipController = CustomTooltipController(text: item.displayName, view: self)
    private var tooltipTrackingArea: NSTrackingArea?
    private static let placeholderSymbol = NSImage(
        systemSymbolName: "menubar.rectangle", accessibilityDescription: nil
    )

    private var cachedImage: MenuBarItemImageCache.CapturedImage? {
        didSet {
            // Real animated previews update pixels in place. Give an item a
            // new slot size only when it first gains (or loses) native pixels.
            if oldValue == nil || cachedImage == nil {
                let newSize = preferredSize(for: cachedImage)
                if frame.size != newSize {
                    setFrameSize(newSize)
                    (superview as? LayoutBarContainer)?.itemPreferredSizeDidChange(self)
                }
            }
            needsDisplay = true
        }
    }

    /// While frozen, a system move can publish a transient thumbnail from
    /// under the notch or between sections, so keep the last stable one.
    static nonisolated func shouldUpdateCachedImage(
        hasContainer: Bool,
        containerAllowsUpdates: Bool
    ) -> Bool {
        !hasContainer || containerAllowsUpdates
    }

    /// The dragged view stays as the drop placeholder, dimmed rather than
    /// blank.
    static nonisolated func iconFraction(
        isDraggingPlaceholder: Bool,
        isEnabled: Bool
    ) -> CGFloat {
        if isDraggingPlaceholder {
            return 0.45
        }
        return isEnabled ? 1.0 : 0.67
    }

    override var kind: Kind {
        .item(effectiveItem)
    }

    /// The enabled trigger that owns this item's placement, or `nil`.
    ///
    /// The trigger decides where the item sits. Dragging is still allowed as
    /// a manual fix before a trigger applies; the badge explains the
    /// snap-back.
    private var isTriggerControlled: Bool {
        appState?.settings.triggers.isControlledByTrigger(
            identifier: effectiveItem.tag.tagIdentifier
        ) ?? false
    }

    /// For the hover tooltip only; `draw` uses ``isTriggerControlled``.
    private var controllingTrigger: MenuBarItemTrigger? {
        appState?.settings.triggers.controllingTrigger(
            forIdentifier: effectiveItem.tag.tagIdentifier
        )
    }

    init(appState: AppState, item: MenuBarItem) {
        self.item = item
        self.appState = appState
        let initialImage = appState.hasPermission(.screenRecording)
            ? appState.imageCache.stationaryPreview(for: item, on: appState.itemManager.itemCache.displayID)
            : nil
        self.cachedImage = initialImage

        super.init(frame: CGRect(origin: .zero, size: Self.preferredSize(for: item, image: initialImage)))
        unregisterDraggedTypes()
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(item.displayName)

        isEnabled = item.isDraggableInLayoutEditor(
            displayBounds: NSScreen.screens.map { CGDisplayBounds($0.displayID) }
        )

        configureCancellables()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var tooltipDelay: TimeInterval {
        appState?.settings.advanced.tooltipDelay ?? 0.5
    }

    override func draggingImage() -> NSImage? {
        return cachedImage?.nsImage ?? placeholderBitmapImage()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tooltipTrackingArea {
            removeTrackingArea(tooltipTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tooltipTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        // A trigger can change while the editor is open.
        tooltipController.text = if let trigger = controllingTrigger {
            String(localized: "\(effectiveItem.displayName) \u{2014} placed by trigger \u{201C}\(trigger.displayName)\u{201D}")
        } else {
            effectiveItem.displayName
        }
        tooltipController.scheduleShow(delay: tooltipDelay)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        tooltipController.cancel()
    }

    private func configureCancellables() {
        let c = Set<AnyCancellable>()

        if let appState {
            let item = self.item
            imageObservationTask = Task { @MainActor [weak self, weak appState] in
                var previous: MenuBarItemImageCache.CapturedImage?
                let changes = Observations { [weak appState] in
                    guard let appState, appState.hasPermission(.screenRecording) else { return nil as MenuBarItemImageCache.CapturedImage? }
                    return appState.imageCache.stationaryPreview(for: item, on: appState.itemManager.itemCache.displayID)
                }
                for await image in changes {
                    guard let self else { return }
                    guard !MenuBarItemImageCache.CapturedImage.isVisuallyEqual(previous, image) else { continue }
                    // Only when applied, or a republished copy dedupes and
                    // strands the stale thumbnail.
                    guard self.updateCachedImageIfAllowed(image) else { continue }
                    previous = image
                }
            }

            // `controlledIdentifiers` is stored so every read registers a
            // dependency. Read through `effectiveItem` to match `draw`.
            triggerObservationTask = Task { @MainActor [weak self, weak appState] in
                let changes = Observations { [weak self, weak appState] in
                    guard let self, let appState else { return false }
                    return appState.settings.triggers.isControlledByTrigger(
                        identifier: self.effectiveItem.tag.tagIdentifier
                    )
                }
                var previous: Bool?
                for await controlled in changes {
                    guard let self else { return }
                    guard controlled != previous else { continue }
                    previous = controlled
                    self.needsDisplay = true
                }
            }
        }

        cancellables = c
    }

    /// Only blame macOS for static system items; an unresolved Control
    /// Center slot is Thaw's own gate. Names the AX-resolved owner if known.
    func provideAlertForDisabledItem(axResolvedName: String? = nil) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "Menu bar item is not movable.")
        switch item.immovabilityReason {
        case .unresolvedControlCenterPlaceholder:
            let name = axResolvedName ?? item.displayName
            alert.informativeText = String(localized: "\(Constants.displayName) can't currently tell which app owns \"\(name)\", so moving it is disabled. This usually resolves on its own; relaunching the app that owns the item can help.")
        case .prohibitedSystemItem, nil:
            alert.informativeText = String(localized: "macOS prohibits \"\(item.displayName)\" from being moved.")
        }
        return alert
    }

    /// Logs the resolved identifier and the refusal condition. Returns the
    /// AX-resolved app name for the alert.
    ///
    /// Reuses the alias attempt's identity; a second AX snapshot is a
    /// visible hitch mid-drag.
    private func logMoveRefusal(
        correlatedIdentity: AXIdentityCatalog.AXItemIdentity?
    ) -> String? {
        let reason = item.immovabilityReason?.logDescription ?? "isMovable false with no named gate"
        Self.diagLog.warning(
            "Move refused for \(item.logString): \(reason); uniqueIdentifier=\(item.uniqueIdentifier), windowID=\(item.windowID), sourcePID=\(item.sourcePID.map(String.init) ?? "nil"), ownerPID=\(item.ownerPID)"
        )
        guard item.immovabilityReason == .unresolvedControlCenterPlaceholder else {
            return nil
        }
        guard let identity = correlatedIdentity else {
            Self.diagLog.warning(
                "Move refusal: AX correlation found no confident identity for windowID \(item.windowID)"
            )
            return nil
        }
        Self.diagLog.warning(
            "Move refusal: AX names windowID \(item.windowID) as identifier=\(identity.identifier ?? "nil"), title=\(identity.title ?? "nil"), help=\(identity.help ?? "nil")"
        )
        return identity.identifier ?? identity.title ?? identity.help
    }

    /// When `item` is an `unresolvedControlCenterPlaceholder` (#905) but
    /// Control Center's AX tree names the owning app for the slot's frame,
    /// builds a movable alias tagged and PID'd as that app. AppKit still moves
    /// the slot by `windowID`.
    ///
    /// The AX snapshot (up to 500 ms) runs at most once per drag: success
    /// enables the view, and failure hands its identity to
    /// ``logMoveRefusal(correlatedIdentity:)``.
    private func aliasForUnresolvedControlCenterPlaceholder(
    ) -> (alias: MenuBarItem?, correlatedIdentity: AXIdentityCatalog.AXItemIdentity?) {
        precondition(item.immovabilityReason == .unresolvedControlCenterPlaceholder)

        let hosts = ["com.apple.controlcenter", "com.apple.systemuiserver"]
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        guard !hosts.isEmpty else { return (nil, nil) }

        let snapshot = AXIdentityCatalog.snapshot(hosts: hosts)
        let bounds = Bridging.getWindowBounds(for: item.windowID) ?? item.bounds
        guard let identity = AXIdentityCatalog.identity(for: bounds, in: snapshot) else {
            Self.diagLog.warning(
                "Move alias: AX correlation found no confident identity for \(item.logString) (windowID=\(item.windowID))"
            )
            return (nil, nil)
        }

        let hostBundleIDs: Set = ["com.apple.controlcenter", "com.apple.systemuiserver"]
        guard let bundleID = UnresolvedPlaceholderAlias.appBundleID(
            from: identity,
            excluding: hostBundleIDs,
            thawBundleID: Constants.bundleIdentifier
        ) else {
            Self.diagLog.warning(
                "Move alias: AX names \(item.logString) (windowID=\(item.windowID)) as identifier=\(identity.identifier ?? "nil"), title=\(identity.title ?? "nil"), help=\(identity.help ?? "nil"); none is a non-host bundle identifier"
            )
            return (nil, identity)
        }

        guard
            let hostApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
            hostApp.processIdentifier != 0
        else {
            Self.diagLog.warning(
                "Move alias: AX named \(item.logString) (windowID=\(item.windowID)) as \(bundleID), but no running application matches that bundle ID"
            )
            return (nil, identity)
        }

        let alias = UnresolvedPlaceholderAlias.aliasedItem(
            for: item,
            appBundleID: bundleID,
            hostPID: hostApp.processIdentifier
        )
        return (alias, identity)
    }

    /// Provides an alert to display when a menu bar item is unresponsive.
    func provideAlertForUnresponsiveItem() -> NSAlert {
        let alert = provideAlertForDisabledItem()
        alert.informativeText = String(localized: "\(item.displayName) is unresponsive. Until it is restarted, it cannot be moved. Movement of other menu bar items may also be affected until this is resolved.")
        return alert
    }

    override func draw(_: NSRect) {
        // Dimmed so the badge reads as state, not a rendering bug.
        let fraction: CGFloat = if !isDraggingPlaceholder, isTriggerControlled {
            Metrics.triggerControlledFraction
        } else {
            Self.iconFraction(
                isDraggingPlaceholder: isDraggingPlaceholder,
                isEnabled: isEnabled
            )
        }
        if let capturedImage = cachedImage?.nsImage {
            capturedImage.draw(
                in: bounds,
                from: .zero,
                operation: .sourceOver,
                fraction: fraction
            )
        } else {
            drawPlaceholder(fraction: fraction)
        }

        // Keep status badges out of the drag placeholder.
        if !isDraggingPlaceholder {
            if isTriggerControlled {
                drawTriggerBadge()
            }
            if Bridging.isProcessUnresponsive(item.ownerPID) {
                let warningImage = NSImage.warning
                let width = Metrics.unresponsiveBadgeWidth
                let scale = width / warningImage.size.width
                let size = CGSize(
                    width: width,
                    height: warningImage.size.height * scale
                )
                warningImage.draw(
                    in: CGRect(
                        x: bounds.maxX - size.width,
                        y: bounds.minY,
                        width: size.width,
                        height: size.height
                    )
                )
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        tooltipController.cancel()

        guard canBeginDraggingFromCurrentContainer else {
            return
        }

        // Try the AX alias before refusing a placeholder drag. On a hit the
        // view becomes enabled and the guard below passes.
        var correlatedIdentity: AXIdentityCatalog.AXItemIdentity?
        if !isEnabled,
           item.immovabilityReason == .unresolvedControlCenterPlaceholder
        {
            let attempt = aliasForUnresolvedControlCenterPlaceholder()
            correlatedIdentity = attempt.correlatedIdentity
            if let alias = attempt.alias {
                Self.diagLog.info(
                    "Move enabled for \(item.logString) via AX-correlated identity: re-tagged as \(alias.uniqueIdentifier) (sourcePID=\(alias.sourcePID.map(String.init) ?? "nil")); windowID=\(item.windowID)"
                )
                aliasedItem = alias
                isEnabled = true
            }
        }

        guard isEnabled else {
            let axResolvedName = logMoveRefusal(correlatedIdentity: correlatedIdentity)
            let alert = provideAlertForDisabledItem(axResolvedName: axResolvedName)
            alert.runModal()
            return
        }

        guard !Bridging.isProcessUnresponsive(item.ownerPID) else {
            Self.diagLog.warning(
                "Move refused for \(item.logString): owner process \(item.ownerPID) is unresponsive; uniqueIdentifier=\(item.uniqueIdentifier)"
            )
            let alert = provideAlertForUnresponsiveItem()
            alert.runModal()
            return
        }

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setData(Data(), forType: .layoutBarItem)

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(bounds, contents: draggingImage())

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    @discardableResult
    private func updateCachedImageIfAllowed(_ image: MenuBarItemImageCache.CapturedImage?) -> Bool {
        let container = superview as? LayoutBarContainer
        guard Self.shouldUpdateCachedImage(
            hasContainer: container != nil,
            containerAllowsUpdates: container?.canSetArrangedViews ?? true
        ) else {
            return false
        }
        cachedImage = image
        return true
    }

    private func preferredSize(for image: MenuBarItemImageCache.CapturedImage?) -> CGSize {
        Self.preferredSize(for: item, image: image)
    }

    private static func preferredSize(
        for item: MenuBarItem,
        image: MenuBarItemImageCache.CapturedImage?
    ) -> CGSize {
        if let image {
            return image.scaledSize
        }

        let width = item.bounds.width.clamped(to: Metrics.minWidth ... Metrics.maxWidth)
        let height = max(item.bounds.height, Metrics.minHeight)
        return CGSize(width: width, height: height)
    }

    /// Leading edge, since the unresponsive badge owns the trailing one.
    /// Cached because `draw(_:)` runs per frame during a drag and symbol
    /// resolution allocates.
    private static let triggerBadge: NSImage? = {
        let configuration = NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor])
        return NSImage(
            systemSymbolName: "bolt.fill",
            accessibilityDescription: String(localized: "Controlled by a trigger")
        )?.withSymbolConfiguration(configuration)
    }()

    private func drawTriggerBadge() {
        guard let badge = Self.triggerBadge else {
            return
        }
        let width = Metrics.triggerBadgeWidth
        let scale = width / badge.size.width
        let size = CGSize(width: width, height: badge.size.height * scale)
        badge.draw(
            in: CGRect(
                x: bounds.minX,
                y: bounds.minY,
                width: size.width,
                height: size.height
            )
        )
    }

    private func drawPlaceholder(fraction: CGFloat) {
        let placeholderRect = bounds.insetBy(
            dx: Metrics.placeholderHorizontalInset,
            dy: Metrics.placeholderVerticalInset
        )
        let backgroundPath = NSBezierPath(
            roundedRect: placeholderRect,
            xRadius: Metrics.placeholderCornerRadius,
            yRadius: Metrics.placeholderCornerRadius
        )
        NSColor.quaternaryLabelColor.withAlphaComponent(0.35 * fraction).setFill()
        backgroundPath.fill()

        NSColor.separatorColor.withAlphaComponent(0.6 * fraction).setStroke()
        backgroundPath.lineWidth = 1
        backgroundPath.stroke()

        guard let placeholderImage = Self.placeholderSymbol else { return }
        let iconBounds = placeholderRect.insetBy(
            dx: Metrics.iconInset,
            dy: Metrics.iconInset
        )
        let iconSide = min(iconBounds.width, iconBounds.height)
        guard iconSide > 0 else {
            return
        }

        let iconRect = CGRect(
            x: placeholderRect.midX - (iconSide / 2),
            y: placeholderRect.midY - (iconSide / 2),
            width: iconSide,
            height: iconSide
        )

        if placeholderImage.isTemplate {
            let tinted = placeholderImage.copy() as? NSImage
            tinted?.isTemplate = true
            NSColor.secondaryLabelColor.set()
            tinted?.draw(
                in: iconRect,
                from: .zero,
                operation: .sourceOver,
                fraction: (isEnabled ? 0.8 : 0.5) * fraction
            )
        } else {
            placeholderImage.draw(
                in: iconRect,
                from: .zero,
                operation: .sourceOver,
                fraction: (isEnabled ? 0.9 : 0.5) * fraction
            )
        }
    }

    private func placeholderBitmapImage() -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

// MARK: Layout Bar Item Pasteboard Type

extension NSPasteboard.PasteboardType {
    static let layoutBarItem = Self("\(Constants.bundleIdentifier).layout-bar-item")
}
