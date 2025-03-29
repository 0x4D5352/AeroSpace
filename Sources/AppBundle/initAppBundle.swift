import AppKit
import Common
import Foundation

@MainActor public func initAppBundle() {
    initTerminationHandler()
    isCli = false
    initServerArgs()
    if isDebug {
        sendCommandToReleaseServer(args: ["enable", "off"])
        interceptTermination(SIGINT)
        interceptTermination(SIGKILL)
    }
    if !reloadConfig() {
        check(reloadConfig(forceConfigUrl: defaultConfigUrl))
    }
    if serverArgs.startedAtLogin && !config.startAtLogin {
        printStderr("--started-at-login is passed but 'started-at-login = false' in the config. Terminating...")
        terminateApp()
    }

    checkAccessibilityPermissions()
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
    startUnixSocketServer()
    GlobalObserver.initObserver()
    Task {
        try await refreshAndLayout(.startup1, screenIsDefinitelyUnlocked: false, startup: true)
        try await refreshSession(.startup2, screenIsDefinitelyUnlocked: false) {
            try await allowOnlyCancellationError { // Swift, are you drunk?
                if serverArgs.startedAtLogin {
                    _ = try await config.afterLoginCommand.runCmdSeq(.defaultEnv, .emptyStdin)
                }
                _ = try await config.afterStartupCommand.runCmdSeq(.defaultEnv, .emptyStdin)
            }
        }
    }

    let thread = Thread {
        print("start run loop")
        CFRunLoopRun()
        print("exit run loop")
    }
    thread.start()
    // thread.runInLoopAsync { job in
    // }
    thread.runInLoopAsync { job in
        sleep(3)
        print("signal to stop run loop")
        CFRunLoopStop(CFRunLoopGetCurrent())
    }
    thread.runInLoopAsync { job in
        print("submitted later")
    }

    // Task.detached {
    //     let thread = Thread {
    //         let timer = CFRunLoopTimerCreateWithHandler(
    //                 kCFAllocatorDefault,
    //                 CFAbsoluteTimeGetCurrent(),
    //                 10000, 0, 0
    //                 ) { _ in }
    //         CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .defaultMode)
    //
    //         // sleep(3)
    //         print("CFRunLoopRun")
    //         CFRunLoopRun()
    //         print("wtf")
    //     }
    //     thread.name = "suka"
    //     thread.start()
    //
    //     // sleep(3)
    //
    //     check(thread.isExecuting)
    //
    //     print("task started")
    //     print("Thread.schedule")
    //     thread.runInLoopAsync {
    //         print("--- 1 \(Thread.current.name ?? "")")
    //     }
    //     thread.runInLoopAsync {
    //         print("--- 2 \(Thread.current.name ?? "")")
    //     }
    // }


    // print("isExecuting: \(thread.isExecuting)")

    // var runLoop: CFRunLoop? = nil
    // Thread.detachNewThread {
    //     runLoop = CFRunLoopGetCurrent()
    //     print("--- run detachNewThread.main")
    //     print(runLoop)
    //     CFRunLoopRun()
    // }

    // CFRunLoopPerformBlock(runLoop!, CFRunLoopMode.defaultMode.rawValue) {
    //     print("--- 1 \(Thread.current.name)")
    // }
    // CFRunLoopWakeUp(runLoop)
    // NSObject.perform

    // Task {
    //     try await Task.sleep(for: .seconds(1))
    //     print("--- here")
    //     print("\(runLoop)")
    //     CFRunLoopPerformBlock(runLoop!, CFRunLoopMode.commonModes.rawValue) {
    //         print("--- 1 \(Thread.current.name)")
    //     }
    //     CFRunLoopWakeUp(runLoop)
    // }

    // CFRunLoopPerformBlock(thread.runLoop, CFRunLoopMode.defaultMode.rawValue) {
    //     print("---  \(Thread.current.name)")
    // }

    // Thread.detachNewThread {
    //     CFRunLoopGetCurrent()
    //     CFRunLoopRun()
    // }

    // var foo = 1

    // let thread = Thread {
    //     RunLoop.current.perform { }
    // }
    // thread.start()

    // let foo = SelectorLambda0 {}


    // Thread.detachNewThread {
    //     Thread.current.name = "suka"
    //     print(Thread.current.name)
    //     let finder = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }!
    //     let macApp = MacApp.get(finder, mainThread: false)
    //     CFRunLoopRun()
    // }
}

extension Thread {
    @discardableResult
    func runInLoopAsync(
        job: RunLoopJob = RunLoopJob(),
        disableImplicitCancellation: Bool = false,
        _ body: @Sendable @escaping (RunLoopJob) -> ()
    ) -> RunLoopJob {
        let action = RunLoopAction(job: job, disableImplicitCancellation: disableImplicitCancellation, body)
        // Alternative: CFRunLoopPerformBlock + CFRunLoopWakeUp
        action.perform(#selector(action.action), on: self, with: nil, waitUntilDone: false)
        return job
    }

    func runInLoop<T>(_ body: @Sendable @escaping (RunLoopJob) -> T) async throws(CancellationError) -> T {
        try checkCancellation()
        let job = RunLoopJob()
        return try await allowOnlyCancellationError {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    // It's unsafe to implicitly cancel because cont.resume should be invoked exactly once
                    self.runInLoopAsync(job: job, disableImplicitCancellation: true) { job in
                        if job.isCancelled {
                            cont.resume(throwing: CancellationError())
                        } else {
                            cont.resume(returning: body(job))
                        }
                    }
                }
            } onCancel: {
                job.cancel()
            }
        }
    }
}

final class RunLoopAction: NSObject {
    private let _action: (RunLoopJob) -> ()
    let job: RunLoopJob
    private let disableImplicitCancellation: Bool
    init(job: RunLoopJob, disableImplicitCancellation: Bool, _ action: @escaping @Sendable (RunLoopJob) -> ()) {
        self.job = job
        self.disableImplicitCancellation = disableImplicitCancellation
        _action = action
    }
    @objc func action() {
        if disableImplicitCancellation || !job.isCancelled {
            _action(job)
        }
    }
}

final class RunLoopJob: Sendable, AeroAny {
    private let cancellationLatch = OneTimeLatch()
    var isCancelled: Bool { cancellationLatch.isTriggered }
    func cancel() { cancellationLatch.trigger() }

    static let cancelled: RunLoopJob = RunLoopJob().also { $0.cancel() }
}

// final class SerialRunLoopDedicatedThreadExecutor: SerialExecutor {
//     let someThread = Thread {
//         CFRunLoopRun()
//     }
//
//     func enqueue(_ job: consuming ExecutorJob) {
//         let unownedJob = UnownedExecutorJob(job) // in order to escape it to the run{} closure
//         someThread.run {
//             unownedJob.runSynchronously(on: self)
//         }
//     }
//
//     func asUnownedSerialExecutor() -> UnownedSerialExecutor {
//         UnownedSerialExecutor(ordinary: self)
//     }
// }

// class MyThread : Thread {
//     var runLoop: CFRunLoop? = nil
//     override func main() {
//         runLoop = CFRunLoopGetCurrent()
//         name = "hello"
//         print("--- run MyThread.main")
//         print(runLoop)
//         CFRunLoopRun()
//     }
// }

// let queue = DispatchQueue(label: "hi") as! DispatchSerialQueue

// actor Wtf {
//     private let thread: Thread
//     private var runLoop: CFRunLoop? = nil
//     init() {
//         thread = Thread {
//             let _loop: CFRunLoop = CFRunLoopGetCurrent()
//             Task {
//                 await self.run { wtf in
//                     wtf.runLoop = _loop
//                 }
//             }
//             CFRunLoopRun()
//         }
//         thread.start()
//     }
//
//     nonisolated private func run<R: Sendable>(_ body: (isolated Wtf) async -> R) async -> R { await body(self) }
// }

struct ServerArgs: Sendable {
    var startedAtLogin = false
    var configLocation: String? = nil
}

private let serverHelp = """
    USAGE: \(CommandLine.arguments.first ?? "AeroSpace.app/Contents/MacOS/AeroSpace") [<options>]

    OPTIONS:
      -h, --help              Print help
      -v, --version           Print AeroSpace.app version
      --started-at-login      Make AeroSpace.app think that it is started at login
                              When AeroSpace.app starts at login it runs 'after-login-command' commands
      --config-path <path>    Config path. It will take priority over ~/.aerospace.toml
                              and ${XDG_CONFIG_HOME}/aerospace/aerospace.toml
    """

private nonisolated(unsafe) var _serverArgs = ServerArgs()
var serverArgs: ServerArgs { _serverArgs }
private func initServerArgs() {
    var args: [String] = Array(CommandLine.arguments.dropFirst())
    if args.contains(where: { $0 == "-h" || $0 == "--help" }) {
        print(serverHelp)
        exit(0)
    }
    while !args.isEmpty {
        switch args.first {
            case "--version", "-v":
                print("\(aeroSpaceAppVersion) \(gitHash)")
                exit(0)
            case "--config-path":
                if let arg = args.getOrNil(atIndex: 1) {
                    _serverArgs.configLocation = arg
                } else {
                    cliError("Missing <path> in --config-path flag")
                }
                args = Array(args.dropFirst(2))
            case "--started-at-login":
                _serverArgs.startedAtLogin = true
                args = Array(args.dropFirst())
            default:
                cliError("Unrecognized flag '\(args.first!)'")
        }
    }
    if let path = serverArgs.configLocation, !FileManager.default.fileExists(atPath: path) {
        cliError("\(path) doesn't exist")
    }
}
