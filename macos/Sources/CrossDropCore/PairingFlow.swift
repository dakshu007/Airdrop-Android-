import Foundation

/// Pairing exchange after the handshake (docs/protocol-v1.md §5). Used by both roles.
enum PairingFlow {
    /// Runs the mutual confirmation. Returns normally only when both users accepted
    /// and trust was stored; throws otherwise.
    ///
    /// - autoConfirm: this side already trusts the peer, so no local prompt is shown.
    /// - autoMine: a QR code or room proof stood in for the prompt (§9.4, §9.9); its "This is my device" choice.
    /// - autoExpiresAt: the stored trust ends then (Drip Room, §9.9); nil = permanent.
    /// - confirmExtra: fields added to an automatic `pair.confirm` (the room proof, §9.9).
    /// - pendingAnswer: a read of the peer's next message that is already running (§9.9).
    static func run(channel: SecureChannel,
                    peer: PeerInfo,
                    sas: String,
                    role: PairingPrompt.Role,
                    autoConfirm: Bool,
                    autoMine: Bool? = nil,
                    autoExpiresAt: Date? = nil,
                    confirmExtra: [String: Any] = [:],
                    pendingAnswer: Task<WireMessage, Error>? = nil,
                    trust: TrustProvider,
                    delegate: CrossDropDelegate?,
                    onDecision: ((Decision) -> Void)? = nil) async throws {
        let decision = Decision()
        onDecision?(decision)

        // Read the peer's answer concurrently with the local prompt so that a
        // decline or disconnect on the other side dismisses our prompt.
        let peerAnswer = Task<WireMessage, Error> {
            do {
                let message: WireMessage
                if let pending = pendingAnswer {
                    message = try await pending.value
                } else {
                    message = try await channel.receiveControl(timeout: ProtocolConstants.humanTimeout + 15)
                }
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
        if autoConfirm || autoMine != nil {
            decision.resolve(true, mine: autoMine ?? false)
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
            var confirm: [String: Any] = ["accepted": true]
            if !prompted {
                for (key, value) in confirmExtra { confirm[key] = value }
            }
            do {
                try await channel.sendControl(WireMessage.make("pair.confirm", confirm))
            } catch {
                // The peer may have declined and closed before our confirmation went out;
                // report its answer rather than the broken connection.
                if let answer = try? await peerAnswer.value {
                    if answer.type == "pair.confirm", answer.bool("accepted") == false {
                        throw CrossDropError.peer(ErrorCode.pairingRejected)
                    }
                    if answer.type == "error" { throw answer.peerError() }
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
        if let expiresAt = autoExpiresAt, !prompted {
            trust.storeTrust(for: peer, autoAccept: false, expiresAt: expiresAt)
        } else if autoConfirm && autoMine == nil {
            trust.storeTrust(for: peer)
        } else {
            trust.storeTrust(for: peer, autoAccept: decision.mine)
        }
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
