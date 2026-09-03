import AppKit

@main
struct ATFMMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--probe") {
            Probe.run()
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
