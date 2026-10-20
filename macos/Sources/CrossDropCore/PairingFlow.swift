import Foundation

/// Pairing exchange after the handshake (docs/protocol-v1.md §5). Used by both roles.
enum PairingFlow {
    /// Runs the mutual confirmation. Returns normally only when both users accepted
    /// and trust was stored; throws otherwise.
    ///
    /// - autoConfirm: this side already trusts the peer, so no local prompt is shown.
    static func run(channel: SecureChannel,
                    peer: PeerInfo,
                    sas: String,
                    role: PairingPrompt.Role,
                    autoConfirm: Bool,
                    trust: TrustProvider,
                    delegate: CrossDropDelegate?,
                    onDecision: ((Decision) -> Void)? = nil) async throws {
        let decision = Decision()
        onDecision?(decision)

        // Read the peer's answer concurrently with the local prompt so that a
        // decline or disconnect on the other side dismisses our prompt.
        let peerAnswer = Task<WireMessage, Error> {
            do {
                let message = try await channel.receiveControl(timeout: ProtocolConstants.humanTimeout + 15)
                if !(message.type == "pair.confirm" && message.bool("accepted") == true) {
                    decision.cancel()
                }
                return message
            } catch {
                decision.cancel()
                throw error
            }
        }

        let outcome: Decision.Outcome
        var prompted = false
        if autoConfirm {
            decision.resolve(true)
            outcome = .accepted
        } else {
            let prompt = PairingPrompt(id: decision.id, peer: peer, code: sas, role: role,
                                       expiresAt: Date().addingTimeInterval(ProtocolConstants.humanTimeout))
            prompted = true
            delegate?.crossDropPairingRequested(prompt, decision: decision)
            outcome = await decision.wait(timeout: ProtocolConstants.humanTimeout)
        }

        var success = false
        defer {
            if prompted { delegate?.crossDropPairingFinished(id: decision.id, success: success) }
        }

        switch outcome {
        case .accepted:
            try await channel.sendControl(WireMessage.make("pair.confirm", ["accepted": true]))
        case .declined, .timedOut:
            try? await channel.sendControl(WireMessage.make("pair.confirm", ["accepted": false]))
            throw CrossDropError.local(ErrorCode.pairingRejected, outcome == .timedOut ? "timed out" : "declined")
        case .cancelled:
            break
        }

        let answer = try await peerAnswer.value
        switch answer.type {
        case "pair.confirm":
            guard try answer.requireBool("accepted") else {
                throw CrossDropError.peer(ErrorCode.pairingRejected)
            }
        case "error":
            throw answer.peerError()
        case "transfer.cancel":
            throw CrossDropError.peer(ErrorCode.cancelled)
        default:
            throw CrossDropError.violation(ErrorCode.unexpectedMessage)
        }
        guard outcome == .accepted else {
            // Cancelled locally without an answer from the user.
            throw CrossDropError.local(ErrorCode.cancelled)
        }
        trust.storeTrust(for: peer)
        success = true
    }
}
