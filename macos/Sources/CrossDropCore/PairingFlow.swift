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
            do {
                try await channel.sendControl(WireMessage.make("pair.confirm", ["accepted": true]))
            } catch {
                // The peer may have declined and closed before our confirmation went out;
                // report its answer rather than the broken connection.
                if let answer = try? await peerAnswer.value,
                   answer.type == "pair.confirm", answer.bool("accepted") == false {
                    throw CrossDropError.peer(ErrorCode.pairingRejected)
                }
                throw error
            }
        case .declined, .timedOut:
            try? await channel.sendControl(WireMessage.make("pair.confirm", ["accepted": false]))
            await drainPeerAnswer(peerAnswer)
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

    /// After declining, waits briefly for the peer's own answer before the
    /// connection is closed. Closing a TCP socket with unread data sends a reset,
    /// which can discard our decline before the peer reads it, so the peer would
    /// report a lost connection instead of a declined pairing.
    private static func drainPeerAnswer(_ peerAnswer: Task<WireMessage, Error>) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await peerAnswer.value }
            group.addTask { try? await Task.sleep(nanoseconds: 1_500_000_000) }
            _ = await group.next()
            group.cancelAll()
        }
    }
}
