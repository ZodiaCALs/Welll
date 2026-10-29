import AppKit

@main
@MainActor
enum WelllMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        // NSApplication only holds its delegate weakly.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
