import Foundation
import Network

/// Listens for incoming connections and optionally advertises over Bonjour.
public final class CrossDropServer {
    public enum State: Equatable {
        case stopped
        case starting
        case ready(port: UInt16)
        /// Local Network access was denied in System Settings.
        case localNetworkDenied
        case failed(String)
    }

    public struct Configuration {
        public var identity: DeviceIdentity
        public var local: LocalInfo
        public var trust: TrustProvider
        /// Folder for received files; evaluated per offer.
        public var destination: () -> URL

        public init(identity: DeviceIdentity, local: LocalInfo, trust: TrustProvider, destination: @escaping () -> URL) {
            self.identity = identity
            self.local = local
            self.trust = trust
            self.destination = destination
        }
    }

    public weak var delegate: CrossDropDelegate?
    public var onStateChange: ((State) -> Void)?

    private let configuration: Configuration
    private let queue = DispatchQueue(label: "app.crossdrop.listener")
    private let lock = NSLock()
    private var listener: NWListener?
    private var sessions: [String: IncomingSession] = [:]
    private var running = false

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// - Parameters:
    ///   - port: fixed port, or nil for any free port.
    ///   - advertise: publish `_crossdrop._tcp` with TXT v/id/p.
    public func start(port: UInt16? = nil, advertise: Bool) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        let listener: NWListener
        do {
            if let port = port, let nwPort = NWEndpoint.Port(rawValue: port) {
                listener = try NWListener(using: parameters, on: nwPort)
            } else {
                listener = try NWListener(using: parameters)
            }
        } catch {
            throw CrossDropError.local(ErrorCode.internalError, "listener: \(error)")
        }
        if advertise {
            listener.service = NWListener.Service(name: Self.serviceName(configuration.local.wireName),
                                                  type: ProtocolConstants.serviceType,
                                                  domain: nil,
                                                  txtRecord: Self.txtRecord(deviceId: configuration.identity.deviceId,
                                                                            platform: configuration.local.platform))
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self = self else { return }
            switch state {
            case .setup:
                break
            case .waiting(let error):
                self.onStateChange?(Self.isPolicyDenied(error) ? .localNetworkDenied : .starting)
            case .ready:
                self.onStateChange?(.ready(port: listener?.port?.rawValue ?? 0))
            case .failed(let error):
                self.onStateChange?(Self.isPolicyDenied(error) ? .localNetworkDenied : .failed("\(error)"))
            case .cancelled:
                self.onStateChange?(.stopped)
            @unknown default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        lock.lock()
        self.listener?.cancel()
        self.listener = listener
        running = true
        lock.unlock()
        onStateChange?(.starting)
        listener.start(queue: queue)
    }

    /// Stops listening and drops every open connection.
    public func stop() {
        lock.lock()
        let listener = self.listener
        self.listener = nil
        running = false
        let open = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        listener?.cancel()
        open.forEach { $0.close() }
    }

    /// Cancels an incoming transfer (or declines it while it awaits approval).
    public func cancelTransfer(id: String) {
        lock.lock()
        let session = sessions.values.first { $0.transferId == id }
        lock.unlock()
        session?.cancel()
    }

    public var activeConnectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.count
    }

    private func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func accept(_ connection: NWConnection) {
        let transport = NWTransport(connection: connection)
        lock.lock()
        let full = sessions.count >= ProtocolConstants.maxInboundConnections
        lock.unlock()
        if full {
            Task {
                do {
                    try await transport.start(timeout: 5)
                    try await SecureChannel(transport: transport)
                        .sendPlaintext(try WireMessage.encode(WireMessage.error(ErrorCode.busy)))
                } catch {}
                transport.close()
            }
            return
        }
        let config = configuration
        let session = IncomingSession(transport: transport, identity: config.identity, local: config.local,
                                      trust: config.trust, delegate: delegate,
                                      destination: config.destination,
                                      isReceiving: { [weak self] in self?.isRunning() ?? false })
        lock.lock()
        sessions[session.id] = session
        lock.unlock()
        Task.detached { [weak self] in
            await session.run()
            self?.remove(session.id)
        }
    }

    private func remove(_ id: String) {
        lock.lock()
        sessions[id] = nil
        lock.unlock()
    }

    static func serviceName(_ name: String) -> String {
        var result = ""
        for character in name {
            if (result + String(character)).utf8.count > 63 { break }
            result.append(character)
        }
        return result.isEmpty ? "Mac" : result
    }

    /// DNS-SD TXT wire format: each entry is a length byte followed by "key=value".
    static func txtRecord(deviceId: String, platform: String) -> Data {
        var data = Data()
        for entry in ["v=\(ProtocolConstants.version)", "id=\(deviceId)", "p=\(platform)"] {
            let bytes = Data(entry.utf8)
            data.append(UInt8(bytes.count))
            data.append(bytes)
        }
        return data
    }

    /// kDNSServiceErr_PolicyDenied: the user has not allowed Local Network access.
    static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error, code == -65570 { return true }
        return false
    }
}
