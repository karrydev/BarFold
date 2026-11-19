//
//  LayoutBarScrollView.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa

final class LayoutBarScrollView: NSScrollView {
    private let paddingView: LayoutBarPaddingView

    var arrangedViews: [LayoutBarArrangedView] {
        get { paddingView.arrangedViews }
        set { paddingView.arrangedViews = newValue }
    }

    init(appState: AppState, section: MenuBarSection.Name) {
        self.paddingView = LayoutBarPaddingView(appState: appState, section: section)

        super.init(frame: .zero)

        self.documentView = paddingView
        // A hidden or transparent legacy scroller still reserves a gutter.
        // With no scrollers, the clip view fills the row in either macOS style.
        self.hasHorizontalScroller = false
        self.hasVerticalScroller = false
        self.automaticallyAdjustsContentInsets = false
        self.contentInsets = NSEdgeInsets()
        self.verticalScrollElasticity = .none
        self.drawsBackground = false
        self.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            paddingView.heightAnchor.constraint(equalTo: contentView.heightAnchor),
            paddingView.widthAnchor.constraint(greaterThanOrEqualTo: contentView.widthAnchor),
            paddingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    /// Retains horizontal trackpad/momentum input and maps a discrete mouse wheel
    /// to the row. Vertical trackpad gestures still scroll the surrounding settings.
    override func scrollWheel(with event: NSEvent) {
        guard let delta = Self.horizontalDelta(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            isPrecise: event.hasPreciseScrollingDeltas
        ), canScrollHorizontally else {
            nextResponder?.scrollWheel(with: event)
            return
        }
        // AppKit already supplies trackpad momentum as successive deltas.
        scrollHorizontally(by: -delta)
    }

    /// Keeps drag destinations reachable without a scroller control.
    func autoscrollForDrag(at locationInWindow: NSPoint) {
        guard canScrollHorizontally else { return }
        let point = contentView.convert(locationInWindow, from: nil)
        let bounds = contentView.bounds
        guard bounds.contains(point) else { return }
        let step = Self.dragScrollStep(pointerX: point.x, visibleBounds: bounds)
        if step != 0 {
            scrollHorizontally(by: step)
        }
    }

    private var canScrollHorizontally: Bool {
        (documentView?.frame.width ?? 0) > contentView.bounds.width
    }

    private func scrollHorizontally(by delta: CGFloat) {
        let bounds = contentView.bounds
        let proposed = CGRect(
            origin: CGPoint(x: bounds.minX + delta, y: bounds.minY),
            size: bounds.size
        )
        let limited = contentView.constrainBoundsRect(proposed)
        guard limited.origin != bounds.origin else { return }
        contentView.scroll(to: limited.origin)
        reflectScrolledClipView(contentView)
    }

    nonisolated static func dragScrollStep(pointerX: CGFloat, visibleBounds: CGRect) -> CGFloat {
        let edge = min(22, visibleBounds.width / 2)
        guard edge > 0 else { return 0 }
        let left = pointerX - visibleBounds.minX
        let right = visibleBounds.maxX - pointerX
        if left >= 0, left < edge {
            return -(2 + 12 * (1 - left / edge))
        }
        if right >= 0, right < edge {
            return 2 + 12 * (1 - right / edge)
        }
        return 0
    }

    nonisolated static func horizontalDelta(deltaX: CGFloat, deltaY: CGFloat, isPrecise: Bool) -> CGFloat? {
        if deltaX != 0, !isPrecise || abs(deltaX) >= abs(deltaY) {
            return deltaX
        }
        if !isPrecise, deltaY != 0 {
            return deltaY * 10
        }
        return nil
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension LayoutBarScrollView {
    override func accessibilityChildren() -> [Any]? {
        return arrangedViews
    }
}
