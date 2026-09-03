import AppKit
import Foundation

public struct WallpaperDisplay: Codable, Equatable, Hashable, Sendable {
    public let id: UInt32

    public init(id: UInt32) {
        self.id = id
    }
}

public struct WallpaperPlacement: Codable, Equatable, Sendable {
    public let scaling: Int?
    public let allowsClipping: Bool?
    public let fillColorArchive: Data?

    public init(scaling: Int? = nil, allowsClipping: Bool? = nil, fillColorArchive: Data? = nil) {
        self.scaling = scaling
        self.allowsClipping = allowsClipping
        self.fillColorArchive = fillColorArchive
    }
}

public struct WallpaperSnapshot: Codable, Equatable, Sendable {
    public let display: WallpaperDisplay
    public let imageURL: URL
    public let placement: WallpaperPlacement

    public init(display: WallpaperDisplay, imageURL: URL, placement: WallpaperPlacement) {
        self.display = display
        self.imageURL = imageURL
        self.placement = placement
    }
}

public enum WallpaperCapabilityError: Error, Equatable, Sendable {
    case noConnectedDisplays
    case noSelectedDisplays
    case unknownDisplays([UInt32])
    case displayUnavailable(UInt32)
    case missingCurrentImage(UInt32)
    case invalidPlacement(UInt32, String)
    case applyFailed(UInt32, String, rollbackErrors: [String])
    case restoreConflict(UInt32)
    case restoreFailed(UInt32, String)
}

public protocol WallpaperPlatform {
    func connectedDisplays() -> [WallpaperDisplay]
    func snapshot(for display: WallpaperDisplay) throws -> WallpaperSnapshot
    func setImage(
        _ imageURL: URL,
        placement: WallpaperPlacement,
        for display: WallpaperDisplay
    ) throws
}

public struct WallpaperApplyReceipt: Equatable {
    public let priorSnapshots: [WallpaperSnapshot]
    public let appliedSnapshots: [WallpaperSnapshot]

    public init(priorSnapshots: [WallpaperSnapshot], appliedSnapshots: [WallpaperSnapshot]) {
        self.priorSnapshots = priorSnapshots
        self.appliedSnapshots = appliedSnapshots
    }
}

struct WallpaperCapabilityProof {
    private let platform: any WallpaperPlatform

    init(platform: any WallpaperPlatform) {
        self.platform = platform
    }

    func connectedDisplays() throws -> [WallpaperDisplay] {
        let displays = platform.connectedDisplays()
        guard !displays.isEmpty else {
            throw WallpaperCapabilityError.noConnectedDisplays
        }
        return displays
    }

    func apply(
        imageURL: URL,
        placement: WallpaperPlacement = WallpaperPlacement(),
        to selectedDisplayIDs: Set<UInt32>
    ) throws -> WallpaperApplyReceipt {
        let displays = try connectedDisplays()
        guard !selectedDisplayIDs.isEmpty else {
            throw WallpaperCapabilityError.noSelectedDisplays
        }

        let availableIDs = Set(displays.map(\.id))
        let unknownIDs = selectedDisplayIDs.subtracting(availableIDs).sorted()
        guard unknownIDs.isEmpty else {
            throw WallpaperCapabilityError.unknownDisplays(unknownIDs)
        }

        let selectedDisplays = displays.filter { selectedDisplayIDs.contains($0.id) }
        let snapshots = try selectedDisplays.map { try platform.snapshot(for: $0) }
        var appliedDisplays: [WallpaperDisplay] = []
        var appliedSnapshots: [WallpaperSnapshot] = []

        do {
            for display in selectedDisplays {
                try platform.setImage(imageURL, placement: placement, for: display)
                appliedDisplays.append(display)
                appliedSnapshots.append(try platform.snapshot(for: display))
            }
        } catch {
            var rollbackErrors: [String] = []
            for snapshot in snapshots where appliedDisplays.contains(snapshot.display) {
                do {
                    guard
                        let appliedSnapshot = appliedSnapshots.first(where: {
                            $0.display == snapshot.display
                        })
                    else {
                        rollbackErrors.append("Display \(snapshot.display.id) could not be revalidated.")
                        continue
                    }
                    let current = try platform.snapshot(for: snapshot.display)
                    guard current == appliedSnapshot else {
                        rollbackErrors.append("Display \(snapshot.display.id) changed during apply.")
                        continue
                    }
                    try platform.setImage(
                        snapshot.imageURL,
                        placement: snapshot.placement,
                        for: snapshot.display
                    )
                } catch {
                    rollbackErrors.append(String(describing: error))
                }
            }

            let displayID = appliedDisplays.last?.id ?? selectedDisplays.first?.id ?? 0
            throw WallpaperCapabilityError.applyFailed(
                displayID,
                String(describing: error),
                rollbackErrors: rollbackErrors
            )
        }

        return WallpaperApplyReceipt(
            priorSnapshots: snapshots,
            appliedSnapshots: appliedSnapshots
        )
    }

    func restore(_ receipt: WallpaperApplyReceipt) throws {
        for (prior, applied) in zip(receipt.priorSnapshots, receipt.appliedSnapshots) {
            do {
                let current = try platform.snapshot(for: prior.display)
                guard current == applied else {
                    throw WallpaperCapabilityError.restoreConflict(prior.display.id)
                }
                try platform.setImage(
                    prior.imageURL,
                    placement: prior.placement,
                    for: prior.display
                )
            } catch {
                if let conflict = error as? WallpaperCapabilityError,
                    case .restoreConflict = conflict
                {
                    throw conflict
                }
                throw WallpaperCapabilityError.restoreFailed(prior.display.id, String(describing: error))
            }
        }
    }
}

public struct SystemWallpaperPlatform: WallpaperPlatform {
    private let workspace: NSWorkspace

    public init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    public func connectedDisplays() -> [WallpaperDisplay] {
        NSScreen.screens.compactMap { screen in
            displayID(for: screen).map(WallpaperDisplay.init(id:))
        }
    }

    public func snapshot(for display: WallpaperDisplay) throws -> WallpaperSnapshot {
        guard let screen = screen(for: display) else {
            throw WallpaperCapabilityError.displayUnavailable(display.id)
        }
        guard let imageURL = workspace.desktopImageURL(for: screen) else {
            throw WallpaperCapabilityError.missingCurrentImage(display.id)
        }

        let options = workspace.desktopImageOptions(for: screen) ?? [:]
        return WallpaperSnapshot(
            display: display,
            imageURL: imageURL,
            placement: try placement(from: options, displayID: display.id)
        )
    }

    public func setImage(
        _ imageURL: URL,
        placement: WallpaperPlacement,
        for display: WallpaperDisplay
    ) throws {
        guard let screen = screen(for: display) else {
            throw WallpaperCapabilityError.displayUnavailable(display.id)
        }
        try workspace.setDesktopImageURL(
            imageURL,
            for: screen,
            options: options(from: placement, displayID: display.id)
        )
    }

    private func screen(for display: WallpaperDisplay) -> NSScreen? {
        NSScreen.screens.first { screen in
            displayID(for: screen) == display.id
        }
    }

    private func displayID(for screen: NSScreen) -> UInt32? {
        let numberKey = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[numberKey] as? NSNumber)?.uint32Value
    }

    private func placement(
        from options: [NSWorkspace.DesktopImageOptionKey: Any],
        displayID: UInt32
    ) throws -> WallpaperPlacement {
        let scaling: Int?
        if let value = options[.imageScaling] {
            guard let number = value as? NSNumber else {
                throw WallpaperCapabilityError.invalidPlacement(displayID, "scaling")
            }
            scaling = number.intValue
        } else {
            scaling = nil
        }

        let allowsClipping: Bool?
        if let value = options[.allowClipping] {
            guard let number = value as? NSNumber else {
                throw WallpaperCapabilityError.invalidPlacement(displayID, "allowClipping")
            }
            allowsClipping = number.boolValue
        } else {
            allowsClipping = nil
        }

        let fillColorArchive: Data?
        if let value = options[.fillColor] {
            guard let color = value as? NSColor else {
                throw WallpaperCapabilityError.invalidPlacement(displayID, "fillColor")
            }
            do {
                fillColorArchive = try NSKeyedArchiver.archivedData(
                    withRootObject: color,
                    requiringSecureCoding: true
                )
            } catch {
                throw WallpaperCapabilityError.invalidPlacement(displayID, "fillColor archive")
            }
        } else {
            fillColorArchive = nil
        }

        return WallpaperPlacement(
            scaling: scaling,
            allowsClipping: allowsClipping,
            fillColorArchive: fillColorArchive
        )
    }

    private func options(
        from placement: WallpaperPlacement,
        displayID: UInt32
    ) throws -> [NSWorkspace.DesktopImageOptionKey: Any] {
        var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
        if let scaling = placement.scaling {
            options[.imageScaling] = NSNumber(value: scaling)
        }
        if let allowsClipping = placement.allowsClipping {
            options[.allowClipping] = NSNumber(value: allowsClipping)
        }
        if let fillColorArchive = placement.fillColorArchive {
            do {
                options[.fillColor] = try NSKeyedUnarchiver.unarchivedObject(
                    ofClass: NSColor.self,
                    from: fillColorArchive
                )
            } catch {
                throw WallpaperCapabilityError.invalidPlacement(displayID, "fillColor archive")
            }
        }
        return options
    }
}

enum AppleScriptValue: Equatable {
    case boolean(Bool)
    case none
}

public enum AppleScriptFailure: Error, Equatable, Sendable {
    case notAuthorized
    case targetUnavailable
    case executionFailed(code: Int, message: String)
}

protocol AppleScriptRunner {
    func run(_ source: String) throws -> AppleScriptValue
}

struct SystemEventsAppleScriptRunner: AppleScriptRunner {
    func run(_ source: String) throws -> AppleScriptValue {
        guard let script = NSAppleScript(source: source) else {
            throw AppleScriptFailure.executionFailed(code: 0, message: "Unable to compile AppleScript.")
        }

        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue ?? 0
            let message = error["NSAppleScriptErrorMessage"] as? String ?? "AppleScript execution failed."
            switch code {
            case -1743:
                throw AppleScriptFailure.notAuthorized
            case -600, -609:
                throw AppleScriptFailure.targetUnavailable
            default:
                throw AppleScriptFailure.executionFailed(code: code, message: message)
            }
        }

        return Self.decode(result)
    }

    static func decode(_ result: NSAppleEventDescriptor) -> AppleScriptValue {
        switch result.descriptorType {
        case typeBoolean, typeTrue, typeFalse:
            return .boolean(result.booleanValue)
        default:
            return .none
        }
    }
}

public struct AppearanceSnapshot: Codable, Equatable, Sendable {
    public let darkMode: Bool

    public init(darkMode: Bool) {
        self.darkMode = darkMode
    }
}

public enum AppearanceApplyResult: Codable, Equatable, Sendable {
    case applied(previous: AppearanceSnapshot, current: AppearanceSnapshot)
    case unchanged(current: AppearanceSnapshot)
    case verificationFailed(
        previous: AppearanceSnapshot,
        expected: AppearanceSnapshot,
        observed: AppearanceSnapshot
    )
}

public protocol MacOSAppearancePlatform {
    func read() throws -> AppearanceSnapshot
    func apply(darkMode desired: Bool) throws -> AppearanceApplyResult
    func restore(_ snapshot: AppearanceSnapshot) throws -> AppearanceApplyResult
}

public struct MacOSAppearanceClient: MacOSAppearancePlatform {
    static let readScript = """
        tell application "System Events"
            return dark mode of appearance preferences
        end tell
        """

    static let setLightScript = """
        tell application "System Events"
            set dark mode of appearance preferences to false
        end tell
        """

    static let setDarkScript = """
        tell application "System Events"
            set dark mode of appearance preferences to true
        end tell
        """

    private let runner: any AppleScriptRunner

    public init() {
        runner = SystemEventsAppleScriptRunner()
    }

    init(runner: any AppleScriptRunner) {
        self.runner = runner
    }

    public func read() throws -> AppearanceSnapshot {
        guard case .boolean(let darkMode) = try runner.run(Self.readScript) else {
            throw AppleScriptFailure.executionFailed(code: 0, message: "System Events returned no appearance value.")
        }
        return AppearanceSnapshot(darkMode: darkMode)
    }

    public func apply(darkMode desired: Bool) throws -> AppearanceApplyResult {
        let previous = try read()
        guard previous.darkMode != desired else {
            return .unchanged(current: previous)
        }

        let script = desired ? Self.setDarkScript : Self.setLightScript
        _ = try runner.run(script)
        let current = try read()
        guard current.darkMode == desired else {
            return .verificationFailed(
                previous: previous,
                expected: AppearanceSnapshot(darkMode: desired),
                observed: current
            )
        }
        return .applied(previous: previous, current: current)
    }

    public func restore(_ snapshot: AppearanceSnapshot) throws -> AppearanceApplyResult {
        try apply(darkMode: snapshot.darkMode)
    }
}
