// Licensed under the GNU GPLv3.

import CoreGraphics
import Testing
@testable import Thaw

@Suite("BarFold pointer and tray policies")
struct BarFoldInteractionPolicyTests {
    @Test("A synthetic snap is restored without overriding movement elsewhere")
    func pointerRestoration() {
        let synthetic = CGPoint(x: 600, y: 15)
        #expect(MouseHelpers.shouldRestoreSavedCursorPosition(physicalPointerInputOccurred: false))
        #expect(!MouseHelpers.shouldRestoreSavedCursorPosition(physicalPointerInputOccurred: true))
        #expect(MouseHelpers.shouldRestoreSavedCursorPosition(
            physicalPointerInputOccurred: true,
            currentPosition: synthetic,
            syntheticPositions: [synthetic]
        ))
        #expect(!MouseHelpers.shouldRestoreSavedCursorPosition(
            physicalPointerInputOccurred: true,
            currentPosition: CGPoint(x: 420, y: 250),
            syntheticPositions: [synthetic]
        ))
    }

    @Test("A newly opened tray awaits permitted captures but uses a warm icon immediately")
    func trayIconPolicy() {
        #expect(MenuBarItemIconFallback.waitsForFirstTrayCapture(
            hasCapture: false, prefersAppIcon: false, canCapture: true, timedOut: false
        ))
        #expect(!MenuBarItemIconFallback.waitsForFirstTrayCapture(
            hasCapture: true, prefersAppIcon: false, canCapture: true, timedOut: false
        ))
        #expect(!MenuBarItemIconFallback.waitsForFirstTrayCapture(
            hasCapture: false, prefersAppIcon: false, canCapture: false, timedOut: false
        ))
        #expect(!MenuBarItemIconFallback.waitsForFirstTrayCapture(
            hasCapture: false, prefersAppIcon: true, canCapture: true, timedOut: false
        ))
        #expect(!MenuBarItemIconFallback.waitsForFirstTrayCapture(
            hasCapture: false, prefersAppIcon: false, canCapture: true, timedOut: true
        ))
    }

    @Test("Dragging near an edge scrolls in the correct direction")
    func dragEdgeScroll() {
        let row = CGRect(x: 100, y: 0, width: 320, height: 48)
        #expect(LayoutBarScrollView.dragScrollStep(pointerX: 103, visibleBounds: row) < 0)
        #expect(LayoutBarScrollView.dragScrollStep(pointerX: 418, visibleBounds: row) > 0)
        #expect(LayoutBarScrollView.dragScrollStep(pointerX: 280, visibleBounds: row) == 0)
        #expect(LayoutBarScrollView.dragScrollStep(pointerX: 450, visibleBounds: row) == 0)
    }

    @Test("Only discrete vertical scrolling is redirected")
    func scrollAxes() {
        #expect(LayoutBarScrollView.horizontalDelta(deltaX: 0, deltaY: 2, isPrecise: false) == 20)
        #expect(LayoutBarScrollView.horizontalDelta(deltaX: -5, deltaY: 1, isPrecise: true) == -5)
        #expect(LayoutBarScrollView.horizontalDelta(deltaX: 0.5, deltaY: 3, isPrecise: true) == nil)
        #expect(LayoutBarScrollView.horizontalDelta(deltaX: 0, deltaY: 0, isPrecise: false) == nil)
    }
}
