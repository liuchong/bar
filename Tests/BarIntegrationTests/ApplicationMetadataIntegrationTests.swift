import AppKit
import Testing
@testable import Bar

@Suite("Installed application metadata")
struct ApplicationMetadataIntegrationTests {
    @Test @MainActor func unregisteredApplicationsWithShortIdentifiersAreFoundInApplicationDirectories() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let contents = directory.appendingPathComponent("Tools/Renamed.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let id = "local." + UUID().uuidString
        let info = ["CFBundleIdentifier": id, "CFBundleDisplayName": "Example Tool", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let main = try #require(ApplicationMetadata.resolve(id, applicationDirectories: [directory]))
        let helper = try #require(ApplicationMetadata.resolve(id + ".helper", applicationDirectories: [directory]))
        #expect(main.name == "Example Tool" && helper.name == "Example Tool")
        #expect(main.icon.size.width > 0)
        #expect(ApplicationMetadata.resolve("absent." + UUID().uuidString, applicationDirectories: [directory]) == nil)
    }

    @Test @MainActor func stoppedApplicationsAndNestedHelpersUseTheInstalledNameAndIcon() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("Example.app")
        let helper = app.appendingPathComponent("Contents/Frameworks/StatusHelper.app")
        for (url, name, id) in [(app, "Example", "test.example.app"), (helper, "Helper", "test.example.app.helper")] {
            let contents = url.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
        }
        let main = try #require(ApplicationMetadata.load(at: app))
        let nested = try #require(ApplicationMetadata.load(at: helper))
        #expect(main.name == "Example" && nested.name == "Example")
        #expect(main.icon.size.width > 0 && nested.icon.size.width > 0)
    }
}
