import Foundation
import WelllCore

let launchArguments = CommandLine.arguments

// `wellld --powerui <command>` makes one call into macOS's private charge-limit API and
// exits. The daemon starts itself this way, so a crash or hang there can't take it down.
if launchArguments.count > 1 && launchArguments[1] == "--powerui" {
    PowerUIRunner.runChild(Array(launchArguments.dropFirst(2)))
}

guard getuid() == 0 else {
    FileHandle.standardError.write(Data("wellld must run as root. install.sh sets it up as a LaunchDaemon. To check it by hand: sudo \(launchArguments[0]) --self-test\n".utf8))
    exit(1)
}

if launchArguments.contains("--self-test") {
    SelfTest.run()
}

Log.event("wellld \(WelllConstants.version) starting")
let controller = ChargeController()

// Start listening before anything slow, so the app can connect right away.
let service = DaemonService(controller: controller)
let listenerDelegate = ListenerDelegate(service: service)
let listener = NSXPCListener(machServiceName: WelllConstants.machServiceName)
listener.delegate = listenerDelegate
listener.resume()

controller.start()

// launchd sends SIGTERM at shutdown and when the helper is removed.
var signalSources: [DispatchSourceSignal] = []
for signalNumber in [SIGTERM, SIGINT] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        controller.prepareForExit()
        Log.event("wellld stopping")
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

RunLoop.main.run()
