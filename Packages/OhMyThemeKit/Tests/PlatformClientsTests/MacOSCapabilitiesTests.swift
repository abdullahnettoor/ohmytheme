import AppKit
import Foundation
import XCTest

@testable import PlatformClients

final class MacOSCapabilitiesTests: XCTestCase {
    func testWallpaperApplyChangesOnlyExplicitlySelectedDisplaysAndCapturesPlacement() throws {
        let first = WallpaperDisplay(id: 1)
        let second = WallpaperDisplay(id: 2)
        let platform = RecordingWallpaperPlatform(
            displays: [first, second],
            snapshots: [
                first: WallpaperSnapshot(
                    display: first,
                    imageURL: URL(fileURLWithPath: "/tmp/first.png"),
                    placement: WallpaperPlacement(scaling: 1, allowsClipping: true)
                ),
                second: WallpaperSnapshot(
                    display: second,
                    imageURL: URL(fileURLWithPath: "/tmp/second.png"),
                    placement: WallpaperPlacement(scaling: 2, allowsClipping: false)
                ),
            ]
        )
        let proof = WallpaperCapabilityProof(platform: platform)

        let receipt = try proof.apply(
            imageURL: URL(fileURLWithPath: "/tmp/new.png"),
            placement: WallpaperPlacement(scaling: 3, allowsClipping: true),
            to: [first.id]
        )

        XCTAssertEqual(receipt.priorSnapshots.map(\.display.id), [first.id])
        XCTAssertEqual(platform.setCalls.map(\.display.id), [first.id])
        XCTAssertEqual(platform.setCalls.first?.imageURL.path, "/tmp/new.png")
    }

    func testWallpaperRestoreUsesTheCapturedImageAndPlacement() throws {
        let display = WallpaperDisplay(id: 1)
        let original = WallpaperSnapshot(
            display: display,
            imageURL: URL(fileURLWithPath: "/tmp/original.png"),
            placement: WallpaperPlacement(scaling: 2, allowsClipping: false)
        )
        let platform = RecordingWallpaperPlatform(displays: [display], snapshots: [display: original])
        let proof = WallpaperCapabilityProof(platform: platform)

        let receipt = try proof.apply(
            imageURL: URL(fileURLWithPath: "/tmp/new.png"),
            placement: WallpaperPlacement(scaling: 3, allowsClipping: true),
            to: [display.id]
        )
        try proof.restore(receipt)

        XCTAssertEqual(platform.setCalls.map(\.imageURL.path), ["/tmp/new.png", "/tmp/original.png"])
        XCTAssertEqual(platform.setCalls.last?.placement, original.placement)
    }

    func testWallpaperRestoreRefusesAnExternalChange() throws {
        let display = WallpaperDisplay(id: 1)
        let original = WallpaperSnapshot(
            display: display,
            imageURL: URL(fileURLWithPath: "/tmp/original.png"),
            placement: WallpaperPlacement(scaling: 2, allowsClipping: false)
        )
        let platform = RecordingWallpaperPlatform(displays: [display], snapshots: [display: original])
        let proof = WallpaperCapabilityProof(platform: platform)

        let receipt = try proof.apply(
            imageURL: URL(fileURLWithPath: "/tmp/new.png"),
            placement: WallpaperPlacement(scaling: 3, allowsClipping: true),
            to: [display.id]
        )
        platform.currentSnapshots[display] = WallpaperSnapshot(
            display: display,
            imageURL: URL(fileURLWithPath: "/tmp/external.png"),
            placement: WallpaperPlacement()
        )

        XCTAssertThrowsError(try proof.restore(receipt)) { error in
            XCTAssertEqual(error as? WallpaperCapabilityError, .restoreConflict(display.id))
        }
        XCTAssertEqual(platform.setCalls.map(\.imageURL.path), ["/tmp/new.png"])
    }

    func testWallpaperRejectsAnUnselectedOrUnknownDisplayBeforeWriting() {
        let display = WallpaperDisplay(id: 1)
        let platform = RecordingWallpaperPlatform(displays: [display], snapshots: [:])
        let proof = WallpaperCapabilityProof(platform: platform)

        XCTAssertThrowsError(
            try proof.apply(
                imageURL: URL(fileURLWithPath: "/tmp/new.png"),
                to: [99]
            )
        ) { error in
            XCTAssertEqual(error as? WallpaperCapabilityError, .unknownDisplays([99]))
        }
        XCTAssertTrue(platform.setCalls.isEmpty)
    }

    func testAppearanceReportsUnchangedWithoutSendingASetter() throws {
        let runner = RecordingAppleScriptRunner(values: [.boolean(true)])
        let client = MacOSAppearanceClient(runner: runner)

        let result = try client.apply(darkMode: true)

        XCTAssertEqual(result, .unchanged(current: AppearanceSnapshot(darkMode: true)))
        XCTAssertEqual(runner.scripts, [MacOSAppearanceClient.readScript])
    }

    func testAppearanceVerifiesAChangeAndCanRestoreThePriorState() throws {
        let runner = RecordingAppleScriptRunner(values: [
            .boolean(false),
            .none,
            .boolean(true),
            .boolean(true),
            .none,
            .boolean(false),
        ])
        let client = MacOSAppearanceClient(runner: runner)

        let applied = try client.apply(darkMode: true)
        guard case .applied(let previous, let current) = applied else {
            return XCTFail("Expected a verified appearance change.")
        }
        XCTAssertEqual(previous, AppearanceSnapshot(darkMode: false))
        XCTAssertEqual(current, AppearanceSnapshot(darkMode: true))

        let restored = try client.restore(previous)
        XCTAssertEqual(
            restored,
            .applied(
                previous: AppearanceSnapshot(darkMode: true),
                current: AppearanceSnapshot(darkMode: false)
            )
        )
        XCTAssertEqual(
            runner.scripts,
            [
                MacOSAppearanceClient.readScript,
                MacOSAppearanceClient.setDarkScript,
                MacOSAppearanceClient.readScript,
                MacOSAppearanceClient.readScript,
                MacOSAppearanceClient.setLightScript,
                MacOSAppearanceClient.readScript,
            ]
        )
    }

    func testAppearancePermissionFailureLeavesOtherCapabilitiesUsable() throws {
        let runner = RecordingAppleScriptRunner(failure: .notAuthorized)
        let client = MacOSAppearanceClient(runner: runner)

        XCTAssertThrowsError(try client.read()) { error in
            XCTAssertEqual(error as? AppleScriptFailure, .notAuthorized)
        }

        let display = WallpaperDisplay(id: 1)
        let platform = RecordingWallpaperPlatform(
            displays: [display],
            snapshots: [
                display: WallpaperSnapshot(
                    display: display,
                    imageURL: URL(fileURLWithPath: "/tmp/original.png"),
                    placement: WallpaperPlacement()
                )
            ]
        )
        let proof = WallpaperCapabilityProof(platform: platform)
        XCTAssertNoThrow(
            try proof.apply(
                imageURL: URL(fileURLWithPath: "/tmp/new.png"),
                to: [display.id]
            )
        )
    }

    func testAppearanceReportsVerificationFailureSeparatelyFromUnchanged() throws {
        let runner = RecordingAppleScriptRunner(values: [
            .boolean(false),
            .none,
            .boolean(false),
        ])
        let client = MacOSAppearanceClient(runner: runner)

        let result = try client.apply(darkMode: true)

        XCTAssertEqual(
            result,
            .verificationFailed(
                previous: AppearanceSnapshot(darkMode: false),
                expected: AppearanceSnapshot(darkMode: true),
                observed: AppearanceSnapshot(darkMode: false)
            )
        )
    }
}

private final class RecordingWallpaperPlatform: WallpaperPlatform {
    struct SetCall {
        let imageURL: URL
        let placement: WallpaperPlacement
        let display: WallpaperDisplay
    }

    let displays: [WallpaperDisplay]
    var currentSnapshots: [WallpaperDisplay: WallpaperSnapshot]
    private(set) var setCalls: [SetCall] = []

    init(displays: [WallpaperDisplay], snapshots: [WallpaperDisplay: WallpaperSnapshot]) {
        self.displays = displays
        currentSnapshots = snapshots
    }

    func connectedDisplays() -> [WallpaperDisplay] {
        displays
    }

    func snapshot(for display: WallpaperDisplay) throws -> WallpaperSnapshot {
        guard let snapshot = currentSnapshots[display] else {
            throw WallpaperCapabilityError.missingCurrentImage(display.id)
        }
        return snapshot
    }

    func setImage(
        _ imageURL: URL,
        placement: WallpaperPlacement,
        for display: WallpaperDisplay
    ) throws {
        setCalls.append(SetCall(imageURL: imageURL, placement: placement, display: display))
        currentSnapshots[display] = WallpaperSnapshot(
            display: display,
            imageURL: imageURL,
            placement: placement
        )
    }
}

private final class RecordingAppleScriptRunner: AppleScriptRunner {
    private var values: [AppleScriptValue]
    private let failure: AppleScriptFailure?
    private(set) var scripts: [String] = []

    init(values: [AppleScriptValue] = [], failure: AppleScriptFailure? = nil) {
        self.values = values
        self.failure = failure
    }

    func run(_ source: String) throws -> AppleScriptValue {
        scripts.append(source)
        if let failure {
            throw failure
        }
        return values.removeFirst()
    }
}
