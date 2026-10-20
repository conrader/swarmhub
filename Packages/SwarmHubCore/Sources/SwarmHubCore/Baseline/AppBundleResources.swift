import Foundation

/// Trust comes from the installed app's code signature and sealed resource list. Never search the checkout,
/// working directory, executable siblings or a downloaded resource bundle for bootstrap material.
public enum AppBundleResources {
    public static func directory(_ name: String, in bundle: Bundle = .main) -> URL? {
        guard bundle.bundleURL.pathExtension == "app", !name.contains("/"), name != ".", name != "..",
              let resources = bundle.resourceURL else { return nil }
        let app = bundle.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let root = resources.resolvingSymlinksInPath().standardizedFileURL
        guard contains(root, in: app) else { return nil }
        let directory = root.appending(path: name).resolvingSymlinksInPath().standardizedFileURL
        guard contains(directory, in: root),
              (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        return directory
    }

    /// Every read stays inside its sealed directory, including through symlinked parent directories.
    public static func read(_ path: String, in directory: URL) throws -> Data {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let file = directory.appending(path: path).resolvingSymlinksInPath().standardizedFileURL
        guard contains(file, in: root),
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw CocoaError(.fileReadNoPermission)
        }
        return try Data(contentsOf: file)
    }

    private static func contains(_ url: URL, in directory: URL) -> Bool {
        url.path == directory.path || url.path.hasPrefix(directory.path + "/")
    }
}
