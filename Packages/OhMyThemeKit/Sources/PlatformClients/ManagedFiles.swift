import CryptoKit
import Foundation

#if canImport(Darwin)
import Darwin
#endif

public enum ManagedFileLineEnding: String, Codable, Equatable, Sendable {
    case none
    case lf
    case crlf
    case cr
    case mixed
}

public enum ManagedFileOwnership: Codable, Equatable, Sendable {
    case userOwned
    case linkedUserOwned(sourcePath: String)
    case managedByNix
}

public struct ManagedFileIdentity: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

public struct ManagedFileMetadata: Codable, Equatable, Sendable {
    public let permissions: UInt16
    public let ownerID: UInt32
    public let groupID: UInt32
    public let flags: UInt32
    public let extendedAttributes: [String: Data]
    public let accessControlList: String?
    public let lineEnding: ManagedFileLineEnding

    public init(
        permissions: UInt16,
        ownerID: UInt32,
        groupID: UInt32,
        flags: UInt32 = 0,
        extendedAttributes: [String: Data] = [:],
        accessControlList: String? = nil,
        lineEnding: ManagedFileLineEnding
    ) {
        self.permissions = permissions
        self.ownerID = ownerID
        self.groupID = groupID
        self.flags = flags
        self.extendedAttributes = extendedAttributes
        self.accessControlList = accessControlList
        self.lineEnding = lineEnding
    }
}

public struct ManagedFileSnapshot: Codable, Equatable, Sendable {
    public let url: URL
    public let exists: Bool
    public let identity: ManagedFileIdentity?
    public let digest: String?
    public let bytes: Data?
    public let metadata: ManagedFileMetadata?
    public let staleStateToken: String

    public var lineEnding: ManagedFileLineEnding {
        metadata?.lineEnding ?? .none
    }

    public init(
        url: URL,
        exists: Bool,
        identity: ManagedFileIdentity?,
        digest: String?,
        bytes: Data?,
        metadata: ManagedFileMetadata?,
        staleStateToken: String
    ) {
        self.url = url
        self.exists = exists
        self.identity = identity
        self.digest = digest
        self.bytes = bytes
        self.metadata = metadata
        self.staleStateToken = staleStateToken
    }
}

public struct ManagedFileInspection: Codable, Equatable, Sendable {
    public let requestedURL: URL
    public let resolvedURL: URL
    public let ownership: ManagedFileOwnership
    public let snapshot: ManagedFileSnapshot

    public init(
        requestedURL: URL,
        resolvedURL: URL,
        ownership: ManagedFileOwnership,
        snapshot: ManagedFileSnapshot
    ) {
        self.requestedURL = requestedURL
        self.resolvedURL = resolvedURL
        self.ownership = ownership
        self.snapshot = snapshot
    }
}

public struct ManagedFilePlan: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let inspection: ManagedFileInspection
    public let intendedBytes: Data
    public let intendedDigest: String
    public let staleStateToken: String
    public let linkedSourceApproved: Bool

    public var requestedURL: URL { inspection.requestedURL }
    public var resolvedURL: URL { inspection.resolvedURL }

    public init(
        id: UUID,
        inspection: ManagedFileInspection,
        intendedBytes: Data,
        intendedDigest: String,
        staleStateToken: String,
        linkedSourceApproved: Bool
    ) {
        self.id = id
        self.inspection = inspection
        self.intendedBytes = intendedBytes
        self.intendedDigest = intendedDigest
        self.staleStateToken = staleStateToken
        self.linkedSourceApproved = linkedSourceApproved
    }
}

public struct ManagedFileReceipt: Codable, Equatable, Sendable {
    public let planID: UUID
    public let before: ManagedFileInspection
    public let after: ManagedFileInspection
    public let changed: Bool

    public init(
        planID: UUID,
        before: ManagedFileInspection,
        after: ManagedFileInspection,
        changed: Bool
    ) {
        self.planID = planID
        self.before = before
        self.after = after
        self.changed = changed
    }
}

public enum ManagedFileError: Error, Equatable, Sendable {
    case notRegularFile(URL)
    case parentDirectoryMissing(URL)
    case managedByNix(URL)
    case linkedSourceRequiresApproval(URL)
    case lineEndingMismatch(URL, expected: ManagedFileLineEnding, actual: ManagedFileLineEnding)
    case invalidPlan(URL)
    case staleState(URL)
    case rollbackConflict(URL)
    case metadataFailure(URL, String)
    case replacementFailure(URL, String)
}

enum ManagedFileInterruptionPoint: Error, Equatable {
    case beforeRename
}

public final class ManagedFiles: @unchecked Sendable {
    private let fileManager: FileManager
    private let nixRoots: [URL]
    private var interruptionPoint: ManagedFileInterruptionPoint?

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        nixRoots = Self.defaultNixRoots
        interruptionPoint = nil
    }

    public init(
        fileManager: FileManager = .default,
        nixRoots: [URL]
    ) {
        self.fileManager = fileManager
        self.nixRoots = nixRoots.map { $0.standardizedFileURL }
        interruptionPoint = nil
    }

    init(
        fileManager: FileManager = .default,
        nixRoots: [URL],
        interruptionPoint: ManagedFileInterruptionPoint? = nil
    ) {
        self.fileManager = fileManager
        self.nixRoots = nixRoots.map { $0.standardizedFileURL }
        self.interruptionPoint = interruptionPoint
    }

    public func existingURLs(in candidates: [URL]) throws -> [URL] {
        try candidates.filter { try inspect(at: $0).snapshot.exists }
    }

    public func inspect(at url: URL) throws -> ManagedFileInspection {
        let requestedURL = url.standardizedFileURL
        let resolvedURL = requestedURL.resolvingSymlinksInPath().standardizedFileURL
        let ownership = Self.ownership(
            of: resolvedURL,
            requestedURL: requestedURL,
            nixRoots: nixRoots
        )
        let snapshot = try snapshot(at: resolvedURL)
        return ManagedFileInspection(
            requestedURL: requestedURL,
            resolvedURL: resolvedURL,
            ownership: ownership,
            snapshot: snapshot
        )
    }

    public func prepare(
        at url: URL,
        replacingWith intendedBytes: Data,
        approveLinkedSource: Bool = false
    ) throws -> ManagedFilePlan {
        try prepare(
            at: url,
            replacingWith: intendedBytes,
            approveLinkedSource: approveLinkedSource,
            allowUnapprovedLinkedSource: false,
            allowMissingParent: false,
            allowLineEndingChange: false
        )
    }

    public func prepareForConnection(
        at url: URL,
        replacingWith intendedBytes: Data,
        approveLinkedSource: Bool = false
    ) throws -> ManagedFilePlan {
        try prepare(
            at: url,
            replacingWith: intendedBytes,
            approveLinkedSource: approveLinkedSource,
            allowUnapprovedLinkedSource: true,
            allowMissingParent: true,
            allowLineEndingChange: true
        )
    }

    private func prepare(
        at url: URL,
        replacingWith intendedBytes: Data,
        approveLinkedSource: Bool,
        allowUnapprovedLinkedSource: Bool,
        allowMissingParent: Bool,
        allowLineEndingChange: Bool
    ) throws -> ManagedFilePlan {
        let inspection = try inspect(at: url)
        switch inspection.ownership {
        case .managedByNix:
            throw ManagedFileError.managedByNix(inspection.resolvedURL)
        case .linkedUserOwned(let sourcePath)
        where !approveLinkedSource && !allowUnapprovedLinkedSource:
            throw ManagedFileError.linkedSourceRequiresApproval(URL(fileURLWithPath: sourcePath))
        case .userOwned, .linkedUserOwned:
            break
        }

        if let expectedLineEnding = inspection.snapshot.metadata?.lineEnding, !allowLineEndingChange {
            let actualLineEnding = Self.lineEnding(of: intendedBytes)
            guard expectedLineEnding == actualLineEnding else {
                throw ManagedFileError.lineEndingMismatch(
                    inspection.resolvedURL,
                    expected: expectedLineEnding,
                    actual: actualLineEnding
                )
            }
        }

        guard
            inspection.snapshot.exists
                || allowMissingParent
                || fileManager.fileExists(atPath: inspection.resolvedURL.deletingLastPathComponent().path)
        else {
            throw ManagedFileError.parentDirectoryMissing(inspection.resolvedURL.deletingLastPathComponent())
        }

        return ManagedFilePlan(
            id: UUID(),
            inspection: inspection,
            intendedBytes: intendedBytes,
            intendedDigest: Self.digest(of: intendedBytes),
            staleStateToken: inspection.snapshot.staleStateToken,
            linkedSourceApproved: approveLinkedSource
        )
    }

    public func apply(
        _ plan: ManagedFilePlan,
        recoveryMarker: Bool = false
    ) throws -> ManagedFileReceipt {
        guard Self.digest(of: plan.intendedBytes) == plan.intendedDigest else {
            throw ManagedFileError.invalidPlan(plan.resolvedURL)
        }
        let current = try inspect(at: plan.requestedURL)
        guard current.resolvedURL == plan.resolvedURL,
            current.snapshot.staleStateToken == plan.staleStateToken
        else {
            throw ManagedFileError.staleState(plan.resolvedURL)
        }

        switch current.ownership {
        case .managedByNix:
            throw ManagedFileError.managedByNix(current.resolvedURL)
        case .linkedUserOwned where !plan.linkedSourceApproved:
            throw ManagedFileError.linkedSourceRequiresApproval(current.resolvedURL)
        case .userOwned, .linkedUserOwned:
            break
        }

        if current.snapshot.digest == plan.intendedDigest {
            return ManagedFileReceipt(planID: plan.id, before: plan.inspection, after: current, changed: false)
        }

        let metadata = plan.inspection.snapshot.metadata ?? Self.defaultMetadata
        try replace(
            at: plan.resolvedURL,
            bytes: plan.intendedBytes,
            metadata: metadata,
            expected: current,
            applyMarker: recoveryMarker ? plan.id : nil
        )
        let after = try inspect(at: plan.requestedURL)
        return ManagedFileReceipt(planID: plan.id, before: plan.inspection, after: after, changed: true)
    }

    public func hasRecoveryMarker(
        for plan: ManagedFilePlan,
        in inspection: ManagedFileInspection
    ) -> Bool {
        guard inspection.resolvedURL == plan.resolvedURL,
            let marker = Self.validRecoveryMarker(in: inspection)
        else {
            return false
        }
        return marker.planID == plan.id && marker.digest == plan.intendedDigest
    }

    public func matchesMarkedApplication(
        _ inspection: ManagedFileInspection,
        of plan: ManagedFilePlan
    ) -> Bool {
        guard hasRecoveryMarker(for: plan, in: inspection),
            inspection.snapshot.digest == plan.intendedDigest
        else {
            return false
        }
        return Self.metadataMatchesManagedReplacement(
            inspection.snapshot.metadata,
            preserving: plan.inspection.snapshot.metadata,
            intendedLineEnding: Self.lineEnding(of: plan.intendedBytes)
        )
    }

    public func matchesMarkedManagedState(
        _ inspection: ManagedFileInspection,
        preserving baseline: ManagedFileInspection
    ) -> Bool {
        guard inspection.requestedURL == baseline.requestedURL,
            inspection.resolvedURL == baseline.resolvedURL,
            inspection.ownership == baseline.ownership,
            Self.validRecoveryMarker(in: inspection) != nil
        else {
            return false
        }
        let expectedLineEnding =
            baseline.snapshot.exists
            ? baseline.snapshot.lineEnding
            : inspection.snapshot.lineEnding
        return Self.metadataMatchesManagedReplacement(
            inspection.snapshot.metadata,
            preserving: baseline.snapshot.metadata,
            intendedLineEnding: expectedLineEnding
        )
    }

    public func rollback(_ receipt: ManagedFileReceipt) throws {
        guard receipt.changed else { return }

        let current = try inspect(at: receipt.after.requestedURL)
        guard current.resolvedURL == receipt.after.resolvedURL,
            current.snapshot.staleStateToken == receipt.after.snapshot.staleStateToken
        else {
            throw ManagedFileError.rollbackConflict(receipt.after.resolvedURL)
        }

        if receipt.before.snapshot.exists {
            guard let bytes = receipt.before.snapshot.bytes,
                let metadata = receipt.before.snapshot.metadata
            else {
                throw ManagedFileError.rollbackConflict(receipt.before.resolvedURL)
            }
            try replace(
                at: receipt.before.resolvedURL,
                bytes: bytes,
                metadata: metadata,
                expected: current
            )
        } else {
            do {
                try fileManager.removeItem(at: receipt.after.resolvedURL)
            } catch {
                throw ManagedFileError.replacementFailure(receipt.after.resolvedURL, String(describing: error))
            }
        }
    }

    private func snapshot(at url: URL) throws -> ManagedFileSnapshot {
        guard fileManager.fileExists(atPath: url.path) else {
            let token = Self.digest(of: Data("missing:\(url.path)".utf8))
            return ManagedFileSnapshot(
                url: url,
                exists: false,
                identity: nil,
                digest: nil,
                bytes: nil,
                metadata: nil,
                staleStateToken: token
            )
        }

        var attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            throw ManagedFileError.metadataFailure(url, String(describing: error))
        }
        guard
            let type = attributes[.type] as? FileAttributeType,
            type == .typeRegular
        else {
            throw ManagedFileError.notRegularFile(url)
        }

        let bytes: Data
        do {
            bytes = try Data(contentsOf: url)
        } catch {
            throw ManagedFileError.metadataFailure(url, String(describing: error))
        }
        let metadata = try metadata(at: url, attributes: attributes, bytes: bytes)
        let identity = try identity(at: url)
        let digest = Self.digest(of: bytes)
        let token = Self.stateToken(
            url: url,
            identity: identity,
            contentDigest: digest,
            metadata: metadata
        )
        return ManagedFileSnapshot(
            url: url,
            exists: true,
            identity: identity,
            digest: digest,
            bytes: bytes,
            metadata: metadata,
            staleStateToken: token
        )
    }

    private func metadata(
        at url: URL,
        attributes: [FileAttributeKey: Any],
        bytes: Data
    ) throws -> ManagedFileMetadata {
        guard let permissions = attributes[.posixPermissions] as? NSNumber else {
            throw ManagedFileError.metadataFailure(url, "Missing file permissions")
        }

        #if canImport(Darwin)
        var fileInformation = stat()
        guard lstat(url.path, &fileInformation) == 0 else {
            throw ManagedFileError.metadataFailure(url, systemErrorDescription())
        }
        let flags = UInt32(fileInformation.st_flags)
        let ownerID = UInt32(fileInformation.st_uid)
        let groupID = UInt32(fileInformation.st_gid)
        #else
        let flags = UInt32((attributes[.immutable] as? NSNumber)?.uint32Value ?? 0)
        let ownerID = UInt32((attributes[.ownerAccountID] as? NSNumber)?.uint32Value ?? 0)
        let groupID = UInt32((attributes[.groupOwnerAccountID] as? NSNumber)?.uint32Value ?? 0)
        #endif

        return ManagedFileMetadata(
            permissions: UInt16(permissions.uint16Value),
            ownerID: ownerID,
            groupID: groupID,
            flags: flags,
            extendedAttributes: try extendedAttributes(at: url),
            accessControlList: try accessControlList(at: url),
            lineEnding: Self.lineEnding(of: bytes)
        )
    }

    private func identity(at url: URL) throws -> ManagedFileIdentity {
        #if canImport(Darwin)
        var fileInformation = stat()
        guard lstat(url.path, &fileInformation) == 0 else {
            throw ManagedFileError.metadataFailure(url, systemErrorDescription())
        }
        return ManagedFileIdentity(
            device: UInt64(fileInformation.st_dev),
            inode: UInt64(fileInformation.st_ino)
        )
        #else
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard
            let device = attributes[.systemNumber] as? NSNumber,
            let inode = attributes[.systemFileNumber] as? NSNumber
        else {
            throw ManagedFileError.metadataFailure(url, "Missing file identity")
        }
        return ManagedFileIdentity(device: device.uint64Value, inode: inode.uint64Value)
        #endif
    }

    private func replace(
        at url: URL,
        bytes: Data,
        metadata: ManagedFileMetadata,
        expected: ManagedFileInspection? = nil,
        applyMarker: UUID? = nil
    ) throws {
        let directory = url.deletingLastPathComponent()
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ManagedFileError.parentDirectoryMissing(directory)
        }

        let temporaryURL = directory.appendingPathComponent(".oh-my-theme-\(UUID().uuidString).tmp")
        do {
            try bytes.write(to: temporaryURL, options: [.atomic])
            try applyMetadata(metadata, to: temporaryURL)
            if let applyMarker {
                let temporaryIdentity = try identity(at: temporaryURL)
                try setExtendedAttributes(
                    [
                        Self.recoveryMarkerAttribute: Self.recoveryMarker(
                            for: applyMarker,
                            identity: temporaryIdentity,
                            digest: Self.digest(of: bytes)
                        )
                    ],
                    at: temporaryURL
                )
            }
            try applyFlags(metadata.flags, to: temporaryURL)
            if let expected {
                let current = try inspect(at: expected.requestedURL)
                guard current == expected else {
                    throw ManagedFileError.staleState(url)
                }
            }
            try trigger(.beforeRename)
            try flushAndRename(from: temporaryURL, to: url)
        } catch let error as ManagedFileError {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw ManagedFileError.replacementFailure(url, String(describing: error))
        }
    }

    private func applyMetadata(_ metadata: ManagedFileMetadata, to url: URL) throws {
        #if canImport(Darwin)
        guard chown(url.path, uid_t(metadata.ownerID), gid_t(metadata.groupID)) == 0 else {
            throw ManagedFileError.metadataFailure(url, systemErrorDescription())
        }
        #endif

        do {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: metadata.permissions)],
                ofItemAtPath: url.path
            )
        } catch {
            throw ManagedFileError.metadataFailure(url, String(describing: error))
        }

        try setExtendedAttributes(metadata.extendedAttributes, at: url)
        try setAccessControlList(metadata.accessControlList, at: url)
    }

    private func applyFlags(_ flags: UInt32, to url: URL) throws {
        #if canImport(Darwin)
        guard chflags(url.path, flags) == 0 else {
            throw ManagedFileError.metadataFailure(url, systemErrorDescription())
        }
        #else
        _ = flags
        _ = url
        #endif
    }

    private func flushAndRename(from temporaryURL: URL, to destinationURL: URL) throws {
        #if canImport(Darwin)
        let descriptor = open(temporaryURL.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw ManagedFileError.replacementFailure(destinationURL, systemErrorDescription())
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw ManagedFileError.replacementFailure(destinationURL, systemErrorDescription())
        }
        let result = temporaryURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw ManagedFileError.replacementFailure(destinationURL, systemErrorDescription())
        }
        #else
        do {
            try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } catch {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try? fileManager.removeItem(at: destinationURL)
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            } else {
                throw ManagedFileError.replacementFailure(destinationURL, String(describing: error))
            }
        }
        #endif
    }

    private func extendedAttributes(at url: URL) throws -> [String: Data] {
        #if canImport(Darwin)
        let size = listxattr(url.path, nil, 0, 0)
        guard size >= 0 else {
            guard errno == ENOTSUP || errno == ENOENT else {
                throw ManagedFileError.metadataFailure(url, systemErrorDescription())
            }
            return [:]
        }
        guard size > 0 else { return [:] }
        var namesBuffer = [UInt8](repeating: 0, count: size)
        let namesSize = namesBuffer.withUnsafeMutableBytes { buffer in
            listxattr(
                url.path,
                buffer.baseAddress?.assumingMemoryBound(to: CChar.self),
                size,
                0
            )
        }
        guard namesSize >= 0 else {
            throw ManagedFileError.metadataFailure(url, systemErrorDescription())
        }

        var result: [String: Data] = [:]
        for nameData in Data(namesBuffer.prefix(namesSize)).split(separator: 0) {
            let name = String(decoding: nameData, as: UTF8.self)
            let valueSize = getxattr(url.path, name, nil, 0, 0, 0)
            guard valueSize >= 0 else {
                throw ManagedFileError.metadataFailure(url, systemErrorDescription())
            }
            var value = Data(count: valueSize)
            let bytesRead = value.withUnsafeMutableBytes { buffer in
                getxattr(url.path, name, buffer.baseAddress, valueSize, 0, 0)
            }
            guard bytesRead >= 0 else {
                throw ManagedFileError.metadataFailure(url, systemErrorDescription())
            }
            value.removeSubrange(bytesRead..<value.count)
            result[name] = value
        }
        return result
        #else
        _ = url
        return [:]
        #endif
    }

    private func setExtendedAttributes(_ values: [String: Data], at url: URL) throws {
        #if canImport(Darwin)
        for (name, value) in values {
            let result = value.withUnsafeBytes { buffer in
                setxattr(url.path, name, buffer.baseAddress, value.count, 0, 0)
            }
            guard result == 0 else {
                throw ManagedFileError.metadataFailure(url, systemErrorDescription())
            }
        }
        #else
        _ = values
        _ = url
        #endif
    }

    private func accessControlList(at url: URL) throws -> String? {
        #if canImport(Darwin)
        guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else {
            guard errno == ENOTSUP || errno == ENOENT || errno == EINVAL else {
                throw ManagedFileError.metadataFailure(url, systemErrorDescription())
            }
            return nil
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var length = 0
        guard let text = acl_to_text(acl, &length) else {
            throw ManagedFileError.metadataFailure(url, systemErrorDescription())
        }
        defer { acl_free(text) }
        return String(decoding: UnsafeBufferPointer(start: text, count: length).map(UInt8.init), as: UTF8.self)
        #else
        _ = url
        return nil
        #endif
    }

    private func setAccessControlList(_ text: String?, at url: URL) throws {
        #if canImport(Darwin)
        guard let text else {
            let result = acl_set_file(url.path, ACL_TYPE_EXTENDED, nil)
            guard result == 0 || errno == ENOTSUP || errno == EINVAL else {
                throw ManagedFileError.metadataFailure(url, systemErrorDescription())
            }
            return
        }
        guard let acl = acl_from_text(text) else {
            throw ManagedFileError.metadataFailure(url, "Could not decode access control list")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_file(url.path, ACL_TYPE_EXTENDED, acl) == 0 else {
            throw ManagedFileError.metadataFailure(url, systemErrorDescription())
        }
        #else
        _ = text
        _ = url
        #endif
    }

    private static var defaultMetadata: ManagedFileMetadata {
        #if canImport(Darwin)
        let ownerID = UInt32(getuid())
        let groupID = UInt32(getgid())
        #else
        let ownerID: UInt32 = 0
        let groupID: UInt32 = 0
        #endif
        return ManagedFileMetadata(
            permissions: 0o600,
            ownerID: ownerID,
            groupID: groupID,
            lineEnding: .none
        )
    }

    private static let recoveryMarkerAttribute = "com.ohmytheme.apply-id"

    private struct RecoveryMarker {
        let planID: UUID
        let identity: ManagedFileIdentity
        let digest: String
    }

    private static func recoveryMarker(
        for planID: UUID,
        identity: ManagedFileIdentity,
        digest: String
    ) -> Data {
        Data("\(planID.uuidString)|\(identity.device)|\(identity.inode)|\(digest)".utf8)
    }

    private static func validRecoveryMarker(in inspection: ManagedFileInspection) -> RecoveryMarker? {
        guard let identity = inspection.snapshot.identity,
            let digest = inspection.snapshot.digest,
            let data = inspection.snapshot.metadata?.extendedAttributes[recoveryMarkerAttribute],
            let encoded = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        let fields = encoded.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 4,
            let planID = UUID(uuidString: String(fields[0])),
            let device = UInt64(fields[1]),
            let inode = UInt64(fields[2]),
            fields[3] == Substring(digest),
            identity == ManagedFileIdentity(device: device, inode: inode)
        else {
            return nil
        }
        return RecoveryMarker(planID: planID, identity: identity, digest: digest)
    }

    private static func metadataMatchesManagedReplacement(
        _ current: ManagedFileMetadata?,
        preserving baseline: ManagedFileMetadata?,
        intendedLineEnding: ManagedFileLineEnding
    ) -> Bool {
        guard let current else { return false }
        let baseline = baseline ?? defaultMetadata
        var currentAttributes = current.extendedAttributes
        var baselineAttributes = baseline.extendedAttributes
        currentAttributes.removeValue(forKey: recoveryMarkerAttribute)
        baselineAttributes.removeValue(forKey: recoveryMarkerAttribute)
        if baselineAttributes["com.apple.provenance"] == nil {
            currentAttributes.removeValue(forKey: "com.apple.provenance")
        }
        return current.permissions == baseline.permissions
            && current.ownerID == baseline.ownerID
            && current.groupID == baseline.groupID
            && current.flags == baseline.flags
            && currentAttributes == baselineAttributes
            && current.accessControlList == baseline.accessControlList
            && current.lineEnding == intendedLineEnding
    }

    private static let defaultNixRoots = [
        URL(fileURLWithPath: "/nix/store"),
        URL(fileURLWithPath: "/nix/var/nix/profiles"),
    ]

    private static func ownership(
        of resolvedURL: URL,
        requestedURL: URL,
        nixRoots: [URL]
    ) -> ManagedFileOwnership {
        if isNixPath(resolvedURL, nixRoots: nixRoots) {
            return .managedByNix
        }
        guard resolvedURL != requestedURL else { return .userOwned }
        return .linkedUserOwned(sourcePath: resolvedURL.path)
    }

    private static func isNixPath(_ url: URL, nixRoots: [URL]) -> Bool {
        let path = url.standardizedFileURL.path
        if nixRoots.contains(where: { root in
            let rootPath = root.standardizedFileURL.path
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }) {
            return true
        }
        let components = url.standardizedFileURL.pathComponents
        let hasHomeManager = components.contains {
            $0 == "home-manager" || $0.hasPrefix("home-manager-")
        }
        let isGeneration = components.contains("generations") || components.contains("current-home")
        let isHomeManagerProfile = components.contains("profiles")
        return hasHomeManager && (isGeneration || isHomeManagerProfile)
    }

    private func trigger(_ point: ManagedFileInterruptionPoint) throws {
        guard interruptionPoint == point else { return }
        interruptionPoint = nil
        throw ManagedFileInterruptionPoint.beforeRename
    }

    private static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func stateToken(
        url: URL,
        identity: ManagedFileIdentity,
        contentDigest: String,
        metadata: ManagedFileMetadata
    ) -> String {
        var value =
            "\(url.path)|\(identity.device)|\(identity.inode)|\(contentDigest)|\(metadata.permissions)|\(metadata.ownerID)|\(metadata.groupID)|\(metadata.flags)|\(metadata.lineEnding.rawValue)|\(metadata.accessControlList ?? "")"
        for name in metadata.extendedAttributes.keys.sorted() {
            value += "|\(name):\(digest(of: metadata.extendedAttributes[name] ?? Data()))"
        }
        return digest(of: Data(value.utf8))
    }

    private static func lineEnding(of data: Data) -> ManagedFileLineEnding {
        let bytes = [UInt8](data)
        var hasLF = false
        var hasCRLF = false
        var hasCR = false
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case 0x0D:
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    hasCRLF = true
                    index += 1
                } else {
                    hasCR = true
                }
            case 0x0A:
                hasLF = true
            default:
                break
            }
            index += 1
        }
        let styles = [hasLF, hasCRLF, hasCR].filter { $0 }.count
        if styles == 0 { return .none }
        if styles > 1 { return .mixed }
        if hasCRLF { return .crlf }
        if hasCR { return .cr }
        return .lf
    }
}

#if canImport(Darwin)
private func systemErrorDescription() -> String {
    String(cString: strerror(errno))
}
#endif
