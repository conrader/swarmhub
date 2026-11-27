import Foundation

enum SampleScreenshot {
    static let name = "ui-bug.png"
    static let prompt = "Fix the contrast on this dialog button"
    static let png: Data? = {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        var roots = [Bundle.main.resourceURL, executable.appending(path: "AgentApp.resources")].compactMap { $0 }
        #if SWIFT_PACKAGE
        if Bundle.main.bundleURL.pathExtension != "app", let resources = Bundle.module.resourceURL { roots.append(resources) }
        #endif
        return roots.lazy.compactMap { try? Data(contentsOf: $0.appending(path: "Samples/" + name)) }.first
    }()
    static let dataURL = png.map { "data:image/png;base64," + $0.base64EncodedString() }
}
