//
//  MoveEndpointIdentityTests.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import CoreGraphics
import Testing
@testable import Thaw

@Suite("Move endpoint identity")
struct MoveEndpointIdentityTests {
    private func item(
        windowID: CGWindowID,
        x: CGFloat,
        ownerPID: pid_t = 80,
        sourcePID: pid_t? = 81,
        title: String
    ) -> MenuBarItem {
        .fixture(
            tag: .appItem(bundleID: "com.example.MoveEndpoint", title: title),
            windowID: windowID,
            bounds: CGRect(x: x, y: 0, width: 24, height: 33),
            sourcePID: sourcePID,
            ownerPID: ownerPID,
            title: title
        )
    }

    @Test("A same-tag replacement is not the planned endpoint")
    func replacementWindowIsRejected() {
        let expected = item(windowID: 40, x: 100, title: "Item")
        let replacement = item(windowID: 41, x: 100, title: "Item")

        #expect(!MenuBarItemManager.moveEndpointIsCurrent(replacement, expected: expected))
    }

    @Test("A recycled window owned by another process is rejected")
    func recycledWindowIsRejected() {
        let expected = item(windowID: 40, x: 100, ownerPID: 80, title: "Item")
        let recycled = item(windowID: 40, x: 100, ownerPID: 90, title: "Item")

        #expect(!MenuBarItemManager.moveEndpointIsCurrent(recycled, expected: expected))
    }

    @Test("A resolved source must still match after the gate")
    func changedSourceIsRejected() {
        let expected = item(windowID: 40, x: 100, sourcePID: 81, title: "Item")
        let changed = item(windowID: 40, x: 100, sourcePID: 82, title: "Item")

        #expect(!MenuBarItemManager.moveEndpointIsCurrent(changed, expected: expected))
    }

    @Test("The exact resolver returns fresh endpoint geometry")
    func exactResolverReturnsFreshRecords() throws {
        let source = item(windowID: 40, x: 100, title: "Source")
        let target = item(windowID: 42, x: 300, title: "Target")
        let movedSource = item(windowID: 40, x: 180, title: "Source")
        let movedTarget = item(windowID: 42, x: 360, title: "Target")

        let endpoints = try MenuBarItemManager.currentMoveEndpoints(
            in: [movedTarget, movedSource],
            expectedSource: source,
            expectedDestination: target
        ).get()

        #expect(endpoints.source.bounds.minX == 180)
        #expect(endpoints.target.bounds.minX == 360)
    }

    @Test("A recycled source or anchor stops the transaction")
    func recycledEndpointStopsTransaction() {
        let source = item(windowID: 40, x: 100, title: "Source")
        let target = item(windowID: 42, x: 300, title: "Target")
        let recycledSource = item(windowID: 40, x: 180, ownerPID: 999, title: "Source")
        let recycledTarget = item(windowID: 42, x: 120, sourcePID: 999, title: "Target")

        #expect(MenuBarItemManager.currentMoveEndpoints(
            in: [recycledSource, target],
            expectedSource: source,
            expectedDestination: target
        ) == .failure(.recycledSource))
        #expect(MenuBarItemManager.currentMoveEndpoints(
            in: [source, recycledTarget],
            expectedSource: source,
            expectedDestination: target
        ) == .failure(.recycledDestination))
    }

    @Test("Fresh endpoints overlay an unresolved geometry snapshot")
    func freshEndpointsOverlayGeometrySnapshot() {
        let source = item(windowID: 40, x: 100, sourcePID: nil, title: "Source")
        let middle = item(windowID: 41, x: 200, sourcePID: nil, title: "Middle")
        let target = item(windowID: 42, x: 300, sourcePID: nil, title: "Target")
        let freshSource = item(windowID: 40, x: 140, sourcePID: 81, title: "Source")
        let freshTarget = item(windowID: 42, x: 340, sourcePID: 81, title: "Target")

        let merged = MenuBarItemManager.replacingMoveEndpoints(
            in: [source, middle, target],
            with: [freshSource, freshTarget]
        )

        #expect(merged.map(\.windowID) == [40, 41, 42])
        #expect(merged[0].sourcePID == 81)
        #expect(merged[0].bounds.minX == 140)
        #expect(merged[1] == middle)
        #expect(merged[2].sourcePID == 81)
        #expect(merged[2].bounds.minX == 340)
    }

    @Test("Exact endpoints produce deterministic ordinal positions")
    func exactEndpointsProduceIndices() {
        let source = item(windowID: 40, x: 100, title: "Source")
        let middle = item(windowID: 41, x: 200, title: "Middle")
        let destination = item(windowID: 42, x: 300, title: "Destination")

        #expect(
            MenuBarItemManager.moveEndpointIndices(
                in: [destination, source, middle],
                sourceWindowID: source.windowID,
                destinationWindowID: destination.windowID
            ) == .init(source: 0, destination: 2)
        )
    }

    @Test("Equal-X endpoint geometry stays unverified")
    func equalXIsAmbiguous() {
        let source = item(windowID: 40, x: 100, title: "Source")
        let destination = item(windowID: 42, x: 100, title: "Destination")

        #expect(MenuBarItemManager.moveEndpointIndices(
            in: [source, destination],
            sourceWindowID: source.windowID,
            destinationWindowID: destination.windowID
        ) == nil)
    }

    @Test("An anchor absent from the selected display cannot verify")
    func missingDisplayEndpointIsRejected() {
        let source = item(windowID: 40, x: 100, title: "Source")
        let destination = item(windowID: 42, x: 300, title: "Destination")

        #expect(MenuBarItemManager.moveEndpointIndices(
            in: [source],
            sourceWindowID: source.windowID,
            destinationWindowID: destination.windowID
        ) == nil)
    }

    @Test("An off-display Tahoe window is parked despite its onscreen bit")
    func onscreenBitDoesNotOverrideParkedGeometry() {
        let selected: CGDirectDisplayID = 1
        let displays = [
            MenuBarItemManager.MoveDisplayGeometry(
                id: selected,
                bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117)
            ),
        ]
        let parked = CGRect(x: -7775, y: 0, width: 24, height: 24)

        #expect(MenuBarItemManager.moveEndpointDisposition(
            bounds: parked,
            isOnScreen: true,
            selectedDisplayID: selected,
            displays: displays,
            parkedLaneYRange: 0 ... 24,
            controlDividerX: 1400
        ) == .parked)
    }

    @Test("Parked lane geometry is not mistaken for a left display")
    func parkedLaneIsExplicit() {
        let selected: CGDirectDisplayID = 1
        let left: CGDirectDisplayID = 2
        let displays = [
            MenuBarItemManager.MoveDisplayGeometry(
                id: selected,
                bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117)
            ),
            MenuBarItemManager.MoveDisplayGeometry(
                id: left,
                bounds: CGRect(x: -2560, y: 0, width: 2560, height: 1440)
            ),
        ]
        let parked = CGRect(x: -2450, y: 0, width: 24, height: 24)

        #expect(MenuBarItemManager.moveEndpointDisposition(
            bounds: parked,
            isOnScreen: false,
            selectedDisplayID: selected,
            displays: displays,
            parkedLaneYRange: 0 ... 24,
            controlDividerX: 1400
        ) == .parked)
        #expect(MenuBarItemManager.moveEndpointDisposition(
            bounds: parked,
            isOnScreen: true,
            selectedDisplayID: selected,
            displays: displays,
            parkedLaneYRange: 0 ... 24,
            controlDividerX: 1400
        ) == .otherDisplay(left))
    }
}

@Suite("Independent parked menu-bar ownership proof")
struct ParkedMoveMirrorTests {
    private let active = CGRect(x: 1600, y: -300, width: 2400, height: 1400)
    private let other = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    private func slot(
        _ id: CGWindowID, _ x: CGFloat, _ y: CGFloat, title: String = "Item-0", owner: pid_t = 9
    ) -> MenuBarItem.ParkedMirrorSlot {
        .init(id: id, owner: owner, layer: 25, title: title, frame: CGRect(x: x, y: y, width: 32, height: 30))
    }

    @Test("A current, unambiguous same-offset mirror names the parked slot")
    func provesExactMirroredWindow() {
        let activeSlot = slot(10, -1400, -300)
        let sameWidthWrongLocation = slot(12, -3804, 0, title: "com.example.wrong")
        let mirror = slot(11, -3800, 0, title: "com.example.right")
        #expect(MenuBarItem.parkedMirrorTitle(
            for: activeSlot, on: active, other: other, slots: [activeSlot, mirror, sameWidthWrongLocation]
        ) == "com.example.right")
    }

    @Test("Rejects missing current window, ambiguous mirror, different host, and shifted coordinates")
    func rejectsInvalidCorroboration() {
        let activeSlot = slot(10, -1400, -300)
        let mirror = slot(11, -3800, 0, title: "com.example.right")
        let duplicate = slot(12, -3800, 0, title: "com.example.conflict")
        let wrongOwner = slot(13, -3800, 0, title: "com.example.right", owner: 33)
        let shifted = slot(14, -3799, 0, title: "com.example.right")
        for invalid in [[mirror], [activeSlot, mirror, duplicate], [activeSlot, wrongOwner], [activeSlot, shifted]] {
            #expect(MenuBarItem.parkedMirrorTitle(for: activeSlot, on: active, other: other, slots: invalid) == nil)
        }
    }
}
