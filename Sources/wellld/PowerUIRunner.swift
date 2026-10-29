import Foundation
import CWelll

/// Runs each call into macOS's private charge-limit API in a short-lived child process
/// (this same binary, started with --powerui), so a crash or hang inside Apple's code can't
/// take the helper down with it.
enum PowerUIRunner {
    struct Reply: Codable {
        var ok = false
        var available: Int?
        var supported: Int?
        var enabled: Int?
        var limit: Int?
        var message: String?
    }

    enum Outcome {
        case reply(Reply)
        case failed(String)
    }

    // MARK: Parent side

    static func run(_ command: [String], timeout: TimeInterval = 8) -> Outcome {
        let process = Process()
        process.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--powerui"] + command
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return .failed("couldn't start a charge limit check: \(error.localizedDescription)")
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
            return .failed("macOS's charge limit service didn't answer within \(Int(timeout)) seconds")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        if process.terminationReason == .uncaughtSignal {
            return .failed("macOS's charge limit service crashed (signal \(process.terminationStatus))")
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            return .failed("macOS's charge limit service gave no answer (exit code \(process.terminationStatus))")
        }
        return .reply(reply)
    }

    // MARK: Child side

    static func runChild(_ command: [String]) -> Never {
        var reply = Reply()
        switch command.first ?? "" {
        case "state":
            reply.available = Int(CPUIAvailable())
            if reply.available == 1 {
                reply.supported = Int(CPUIIsSupported())
                reply.enabled = Int(CPUIIsEnabled())
                let limit = CPUIGetLimit()
                reply.limit = limit > 0 ? Int(limit) : nil
            }
            reply.ok = true
        case "set":
            if command.count > 1, let value = Int32(command[1]) {
                _ = call { CPUIEnable($0, $1) }
                let result = call { CPUISetLimit(value, $0, $1) }
                reply.ok = result.ok
                reply.message = result.ok ? nil : result.message
            } else {
                reply.message = "set needs a percentage"
            }
        case "enable":
            let result = call { CPUIEnable($0, $1) }
            reply.ok = result.ok
            reply.message = result.ok ? nil : result.message
        case "disable":
            let result = call { CPUIDisable($0, $1) }
            reply.ok = result.ok
            reply.message = result.ok ? nil : result.message
        default:
            reply.message = "unknown charge limit command"
        }
        if let data = try? JSONEncoder().encode(reply) {
            FileHandle.standardOutput.write(data)
        }
        exit(0)
    }

    private static func call(_ body: (UnsafeMutablePointer<CChar>, Int32) -> Int32) -> (ok: Bool, message: String) {
        var buffer = [CChar](repeating: 0, count: 512)
        let ok = buffer.withUnsafeMutableBufferPointer { pointer -> Bool in
            body(pointer.baseAddress!, Int32(pointer.count)) == 1
        }
        return (ok, String(cString: buffer))
    }
}
