// crossdrop-cli: headless sender/receiver used by the CI interop job.
// Auto-confirms pairing and auto-accepts offers. Test use only: it prints the
// pairing code so the CI job can compare both sides.
import Foundation
import Network
import UniformTypeIdentifiers
import CrossDropCore

setvbuf(stdout, nil, _IOLBF, 0)

func emit(_ line: String) {
    print(line)
    fflush(stdout)
}

func fail(_ code: String) -> Never {
    FileHandle.standardError.write(Data("ERROR \(code)\n".utf8))
    exit(1)
}

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage:
      crossdrop-cli receive --port <p> --dir <dir> --identity <file> [--name <n>] [--once]
      crossdrop-cli send --host <h> --port <p> --identity <file> [--name <n>] <file>...

    """.utf8))
    exit(2)
}

struct Options {
    var command = ""
    var values: [String: String] = [:]
    var flags: Set<String> = []
    var positional: [String] = []
}

func parse(_ args: [String]) -> Options {
    var options = Options()
    guard let command = args.first else { usage() }
    options.command = command
    var index = 1
    while index < args.count {
        let arg = args[index]
        if arg == "--once" {
            options.flags.insert("once")
        } else if arg.hasPrefix("--") {
            guard index + 1 < args.count else { usage() }
            options.values[String(arg.dropFirst(2))] = args[index + 1]
            index += 1
        } else {
            options.positional.append(arg)
        }
        index += 1
    }
    return options
}

final class CLIDelegate: CrossDropDelegate {
    let once: Bool
    private let lock = NSLock()
    private var reported: Set<String> = []

    init(once: Bool) {
        self.once = once
    }

    func crossDropPairingRequested(_ prompt: PairingPrompt, decision: Decision) {
        emit("SAS \(prompt.code)")
        decision.resolve(true)
    }

    func crossDropPairingFinished(id: String, success: Bool) {}

    func crossDropOfferReceived(_ offer: OfferPrompt, decision: Decision) {
        decision.resolve(true)
    }

    func crossDropOfferFinished(transferId: String) {}

    func crossDropTransferUpdated(_ snapshot: TransferSnapshot) {
        guard snapshot.direction == .incoming, snapshot.phase.isFinished else { return }
        lock.lock()
        let fresh = reported.insert(snapshot.id).inserted
        lock.unlock()
        guard fresh else { return }
        if snapshot.phase == .completed {
            for file in snapshot.files {
                emit("RECEIVED \(file.savedURL?.lastPathComponent ?? file.name) \(file.sha256 ?? "")")
            }
            emit("COMPLETE \(snapshot.id)")
            if once {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
            }
        } else {
            let code = snapshot.error?.code ?? snapshot.rejectReason ?? snapshot.phase.rawValue
            FileHandle.standardError.write(Data("ERROR \(code)\n".utf8))
            if once {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(1) }
            }
        }
    }
}

func mimeType(for url: URL) -> String? {
    UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
}

let options = parse(Array(CommandLine.arguments.dropFirst()))
guard let identityPath = options.values["identity"] else { usage() }
let identity: DeviceIdentity
do {
    identity = try FileIdentityStore.loadOrCreate(at: URL(fileURLWithPath: identityPath))
} catch {
    fail(ErrorCode.internalError)
}
let local = LocalInfo(name: options.values["name"] ?? "crossdrop-cli", platform: "macos", appVersion: "0.1.0-cli")
let trust = InMemoryTrustStore()
let delegate = CLIDelegate(once: options.flags.contains("once"))

switch options.command {
case "receive":
    guard let portText = options.values["port"], let port = UInt16(portText),
          let dir = options.values["dir"] else { usage() }
    let directory = URL(fileURLWithPath: dir, isDirectory: true)
    let server = CrossDropServer(configuration: .init(identity: identity, local: local, trust: trust,
                                                      destination: { directory }))
    server.delegate = delegate
    var announced = false
    server.onStateChange = { state in
        switch state {
        case .ready(let boundPort):
            if !announced {
                announced = true
                emit("LISTENING \(boundPort)")
            }
        case .failed:
            fail(ErrorCode.internalError)
        default:
            break
        }
    }
    do {
        try server.start(port: port, advertise: false)
    } catch {
        fail(ErrorCode.internalError)
    }
    withExtendedLifetime(server) {
        dispatchMain()
    }

case "send":
    guard let host = options.values["host"], let portText = options.values["port"],
          let portValue = UInt16(portText), let port = NWEndpoint.Port(rawValue: portValue),
          !options.positional.isEmpty else { usage() }
    let files = options.positional.map { path -> OutgoingFile in
        let url = URL(fileURLWithPath: path)
        return OutgoingFile(url: url, mime: mimeType(for: url))
    }
    let transfer = OutgoingTransfer(endpoint: .hostPort(host: NWEndpoint.Host(host), port: port),
                                    peerName: host, peerId: nil, peerPlatform: nil, files: files,
                                    identity: identity, local: local, trust: trust, delegate: delegate)
    Task {
        let result = await transfer.run()
        if result.phase == .completed {
            emit("COMPLETE \(result.id)")
            exit(0)
        }
        fail(result.error?.code ?? result.rejectReason ?? result.phase.rawValue)
    }
    dispatchMain()

default:
    usage()
}
