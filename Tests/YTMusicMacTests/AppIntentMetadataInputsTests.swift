import Foundation
import Testing

@Suite("App Intents compiler inputs")
struct AppIntentMetadataInputsTests {
    @Test func debugPerFileConstantsIgnoreTestableTargetsAndOtherArchitectures() throws {
        let fixture = try MetadataInputsFixture()
        defer { fixture.remove() }
        let names = ["PlaybackIntents.swiftconstvalues", "NavigationIntents.swiftconstvalues", "MusicShortcuts.swiftconstvalues"]
        try fixture.write(names, configuration: "Debug", architecture: "arm64")
        try fixture.write(names, configuration: "Debug", architecture: "x86_64")
        try fixture.write(names, configuration: "Debug", architecture: "arm64", target: "YTMusicMac-testable-t.build")
        #expect(try fixture.run() == 0)
        let inputs = try String(contentsOf: fixture.output.appendingPathComponent("constants.txt"), encoding: .utf8)
        #expect(inputs.split(separator: "\n").count == 3)
        #expect(!inputs.contains("testable"))
        #expect(!inputs.contains("x86_64"))
    }

    @Test func optimizedReleaseUsesTheWholeModuleAggregate() throws {
        let fixture = try MetadataInputsFixture()
        defer { fixture.remove() }
        try fixture.write(["YTMusicMac-primary.swiftconstvalues"], configuration: "Release", architecture: "arm64")
        #expect(try fixture.run(configuration: "release") == 0)
        let inputs = try String(contentsOf: fixture.output.appendingPathComponent("constants.txt"), encoding: .utf8)
        #expect(inputs.split(separator: "\n").count == 1)
        #expect(inputs.contains("YTMusicMac-primary.swiftconstvalues"))
    }

    @Test func conventionalSwiftPackageReleaseLayoutIsAccepted() throws {
        let fixture = try MetadataInputsFixture()
        defer { fixture.remove() }
        let directory = fixture.scratch.appendingPathComponent("x86_64-apple-macosx/release/YTMusicMac.build")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("YTMusicMac.swiftconstvalues"))
        #expect(try fixture.run(configuration: "release", architecture: "x86_64") == 0)
        #expect(try fixture.run(configuration: "release", architecture: "arm64") != 0)
    }

    @Test func partialAndAmbiguousCompilerOutputsFailBeforeExtraction() throws {
        let fixture = try MetadataInputsFixture()
        defer { fixture.remove() }
        try fixture.write(["MusicShortcuts.swiftconstvalues"], configuration: "Debug", architecture: "arm64")
        #expect(try fixture.run() != 0)
        try fixture.write(["NavigationIntents.swiftconstvalues", "PlaybackIntents.swiftconstvalues"], configuration: "Debug", architecture: "arm64")
        try fixture.write(["YTMusicMac-primary.swiftconstvalues"], configuration: "Debug", architecture: "arm64", prefix: "stale")
        #expect(try fixture.run() != 0)
    }
}

private struct MetadataInputsFixture {
    let directory: URL
    var scratch: URL { directory.appendingPathComponent("scratch") }
    var output: URL { directory.appendingPathComponent("metadata") }
    var project: URL { directory.appendingPathComponent("project") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("IntentInputTests-" + UUID().uuidString)
        let source = project.appendingPathComponent("Sources/YTMusicMac")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("import Foundation\n".utf8).write(to: source.appendingPathComponent("Fixture.swift"))
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func write(_ names: [String], configuration: String, architecture: String,
               target: String = "YTMusicMac-p.build", prefix: String = "current") throws {
        let directory = scratch.appendingPathComponent("\(prefix)/YTMusicMac.build/\(configuration)/\(target)/Objects-normal/\(architecture)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in names { try Data("{}".utf8).write(to: directory.appendingPathComponent(name)) }
    }

    func run(configuration: String = "debug", architecture: String = "arm64") throws -> Int32 {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", root.appendingPathComponent("Scripts/app-intent-inputs.py").path,
            scratch.path, configuration, architecture, project.path, output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
