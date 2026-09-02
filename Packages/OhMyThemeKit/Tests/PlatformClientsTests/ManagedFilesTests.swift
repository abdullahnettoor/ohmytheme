import Foundation
import Testing

@testable import PlatformClients

@Suite("Managed files")
struct ManagedFilesTests {
    @Test("Inspection resolves an ordinary symbolic link and exposes its source")
    func inspectionResolvesSymbolicLink() throws {
        let fixture = try Fixture()
        let source = fixture.directory.appendingPathComponent("dotfiles/config")
        let link = fixture.directory.appendingPathComponent("config")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("source".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)

        let inspection = try fixture.client.inspect(at: link)

        #expect(inspection.resolvedURL.standardizedFileURL == source.standardizedFileURL)
        #expect(inspection.ownership == .linkedUserOwned(sourcePath: source.standardizedFileURL.path))
        #expect(inspection.snapshot.bytes == Data("source".utf8))
    }

    @Test("A linked source requires explicit approval before it can be planned")
    func linkedSourceRequiresApproval() throws {
        let fixture = try Fixture()
        let source = fixture.directory.appendingPathComponent("dotfiles/config")
        let link = fixture.directory.appendingPathComponent("config")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("source".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)

        #expect(throws: ManagedFileError.self) {
            try fixture.client.prepare(at: link, replacingWith: Data("theme".utf8))
        }
        let plan = try fixture.client.prepare(
            at: link,
            replacingWith: Data("theme".utf8),
            approveLinkedSource: true
        )
        let receipt = try fixture.client.apply(plan)

        #expect(receipt.changed)
        #expect(try Data(contentsOf: source) == Data("theme".utf8))
        #expect(FileManager.default.fileExists(atPath: link.path))
    }

    @Test("Nix-owned paths are classified and cannot produce a write plan")
    func nixOwnershipIsReadOnly() throws {
        let fixture = try Fixture()
        let nixPath = fixture.directory.appendingPathComponent("nix/store/abc/config")
        try FileManager.default.createDirectory(
            at: nixPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("managed".utf8).write(to: nixPath)

        let client = ManagedFiles(nixRoots: [fixture.directory.appendingPathComponent("nix/store")])
        let inspection = try client.inspect(at: nixPath)

        #expect(inspection.ownership == .managedByNix)
        #expect(throws: ManagedFileError.self) {
            try client.prepare(at: nixPath, replacingWith: Data("new".utf8))
        }
    }

    @Test("Home Manager generations are classified as Nix-owned")
    func homeManagerGenerationIsReadOnly() throws {
        let fixture = try Fixture()
        let generation = fixture.directory.appendingPathComponent(
            ".local/state/home-manager/profiles/home-manager/config"
        )
        try FileManager.default.createDirectory(
            at: generation.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("managed".utf8).write(to: generation)

        #expect(try fixture.client.inspect(at: generation).ownership == .managedByNix)
    }

    @Test("A missing artifact can be created and safely removed by rollback")
    func missingArtifactApplyAndRollback() throws {
        let fixture = try Fixture()
        let path = fixture.directory.appendingPathComponent("missing/config")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)

        let plan = try fixture.client.prepare(at: path, replacingWith: Data("created\r\n".utf8))
        #expect(!FileManager.default.fileExists(atPath: path.path))
        let receipt = try fixture.client.apply(plan)
        #expect(receipt.changed)
        #expect(try Data(contentsOf: path) == Data("created\r\n".utf8))

        try fixture.client.rollback(receipt)

        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test("Apply preserves mode and exact bytes, including line endings")
    func applyPreservesMetadataAndBytes() throws {
        let fixture = try Fixture()
        let path = fixture.directory.appendingPathComponent("config")
        let original = Data("old\r\nvalue\r\n".utf8)
        let replacement = Data("new\r\nvalue\r\n".utf8)
        try original.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path.path)

        let plan = try fixture.client.prepare(at: path, replacingWith: replacement)
        let receipt = try fixture.client.apply(plan)

        #expect(try Data(contentsOf: path) == replacement)
        #expect(try fixture.permissions(of: path) == 0o640)
        #expect(receipt.before.snapshot.lineEnding == .crlf)
        #expect(receipt.after.snapshot.lineEnding == .crlf)
    }

    @Test("Preparation rejects a replacement that would change line-ending style")
    func lineEndingChangesAreRejected() throws {
        let fixture = try Fixture()
        let path = fixture.directory.appendingPathComponent("config")
        try Data("original\r\n".utf8).write(to: path)

        #expect(throws: ManagedFileError.self) {
            try fixture.client.prepare(at: path, replacingWith: Data("theme\n".utf8))
        }
        #expect(try Data(contentsOf: path) == Data("original\r\n".utf8))
    }

    @Test("Opaque malformed bytes are replaced and restored without parsing")
    func malformedBytesRemainOpaque() throws {
        let fixture = try Fixture()
        let path = fixture.directory.appendingPathComponent("config")
        let original = Data([0xFF, 0x00, 0xFE])
        let replacement = Data([0x80, 0x81, 0x82])
        try original.write(to: path)

        let receipt = try fixture.client.apply(
            try fixture.client.prepare(at: path, replacingWith: replacement)
        )
        #expect(try Data(contentsOf: path) == replacement)

        try fixture.client.rollback(receipt)

        #expect(try Data(contentsOf: path) == original)
    }

    @Test("An interrupted replacement leaves the original destination unchanged")
    func interruptedReplacementIsSafe() throws {
        let fixture = try Fixture(
            client: ManagedFiles(nixRoots: [], interruptionPoint: .beforeRename)
        )
        let path = fixture.directory.appendingPathComponent("config")
        let original = Data("original".utf8)
        try original.write(to: path)
        let plan = try fixture.client.prepare(at: path, replacingWith: Data("theme".utf8))

        #expect(throws: ManagedFileError.self) {
            try fixture.client.apply(plan)
        }
        #expect(try Data(contentsOf: path) == original)
    }

    @Test("Apply revalidates the plan before replacing an externally changed file")
    func stalePlanDoesNotWrite() throws {
        let fixture = try Fixture()
        let path = fixture.directory.appendingPathComponent("config")
        try Data("original\r\n".utf8).write(to: path)
        let plan = try fixture.client.prepare(at: path, replacingWith: Data("theme\r\n".utf8))
        try Data("external\r\n".utf8).write(to: path)

        #expect(throws: ManagedFileError.self) {
            try fixture.client.apply(plan)
        }
        #expect(try Data(contentsOf: path) == Data("external\r\n".utf8))
    }

    @Test("Repeated application is reported as unchanged")
    func repeatedApplyIsIdempotent() throws {
        let fixture = try Fixture()
        let path = fixture.directory.appendingPathComponent("config")
        try Data("original".utf8).write(to: path)
        let plan = try fixture.client.prepare(at: path, replacingWith: Data("theme".utf8))
        _ = try fixture.client.apply(plan)

        let repeatedPlan = try fixture.client.prepare(at: path, replacingWith: Data("theme".utf8))
        let receipt = try fixture.client.apply(repeatedPlan)

        #expect(!receipt.changed)
    }

    @Test("A plan round trips with its exact intended bytes and stale-state evidence")
    func planIsSerializable() throws {
        let fixture = try Fixture()
        let path = fixture.directory.appendingPathComponent("config")
        try Data("original\r\n".utf8).write(to: path)
        let intendedBytes = Data([0, 1, 2, 255, 13, 10])
        let plan = try fixture.client.prepare(at: path, replacingWith: intendedBytes)

        let restored = try JSONDecoder().decode(
            ManagedFilePlan.self,
            from: JSONEncoder().encode(plan)
        )

        #expect(restored == plan)
        #expect(restored.intendedBytes == intendedBytes)
        #expect(!restored.staleStateToken.isEmpty)
    }

    @Test("Rollback refuses to overwrite an external edit")
    func rollbackProtectsExternalEdit() throws {
        let fixture = try Fixture()
        let path = fixture.directory.appendingPathComponent("config")
        try Data("original".utf8).write(to: path)
        let plan = try fixture.client.prepare(at: path, replacingWith: Data("theme".utf8))
        let receipt = try fixture.client.apply(plan)
        try Data("external".utf8).write(to: path)

        #expect(throws: ManagedFileError.self) {
            try fixture.client.rollback(receipt)
        }
        #expect(try Data(contentsOf: path) == Data("external".utf8))
    }

    private struct Fixture {
        let directory: URL
        let client: ManagedFiles

        init(client: ManagedFiles = ManagedFiles()) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("oh-my-theme-managed-files-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.client = client
        }

        func permissions(of url: URL) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.posixPermissions] as! NSNumber).intValue & 0o777
        }
    }
}
