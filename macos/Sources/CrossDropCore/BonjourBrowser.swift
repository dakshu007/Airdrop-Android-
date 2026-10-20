import Foundation
import Network

public struct DiscoveredDevice: Identifiable, Equatable {
    public var id: String { deviceId }
    public let deviceId: String
    public let name: String
    public let platform: String
    public let endpoint: NWEndpoint
}

/// Browses `_crossdrop._tcp`. Run it only while a send UI is visible.
public final class BonjourBrowser {
    public enum State: Equatable {
        case idle
        case browsing
        case localNetworkDenied
        case failed(String)
    }

    public var onDevicesChanged: (([DiscoveredDevice]) -> Void)?
    public var onStateChange: ((State) -> Void)?

    private let ownDeviceId: String
    private let queue = DispatchQueue(label: "app.crossdrop.browser")
    private var browser: NWBrowser?

    public init(ownDeviceId: String) {
        self.ownDeviceId = ownDeviceId
    }

    public var isRunning: Bool { browser != nil }

    public func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: ProtocolConstants.serviceType, domain: nil),
                                using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.onStateChange?(.browsing)
            case .waiting(let error), .failed(let error):
                self.onStateChange?(CrossDropServer.isPolicyDenied(error) ? .localNetworkDenied : .failed("\(error)"))
            case .cancelled:
                self.onStateChange?(.idle)
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.publish(results)
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        onDevicesChanged?([])
    }

    public func restart() {
        stop()
        start()
    }

    private func publish(_ results: Set<NWBrowser.Result>) {
        var devices: [String: DiscoveredDevice] = [:]
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint,
                  case let .bonjour(txt) = result.metadata else { continue }
            let entries = txt.dictionary
            guard let id = entries["id"], Hex.isLowerHex(id, length: 32), id != ownDeviceId,
                  let platform = entries["p"], platform == "android" || platform == "macos",
                  let version = entries["v"].flatMap({ Int($0) }), version >= 1 else { continue }
            devices[id] = DiscoveredDevice(deviceId: id, name: name, platform: platform, endpoint: result.endpoint)
        }
        let sorted = devices.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        onDevicesChanged?(sorted)
    }
}
