package com.crossdrop.engine

import com.crossdrop.core.Json
import com.crossdrop.queue.SendQueue

/** Serialises engine state to the JSON shape in android/src/native/types.ts (Snapshot). */
object Snapshots {
    fun build(engine: Engine, s: SnapshotState): String {
        val activeIncoming = s.transfers.any { it.direction == "incoming" && !it.isFinished }
        val activeRooms = engine.rooms.active()
        val roomHints = activeRooms.map { it.hint }.toSet()
        val map = linkedMapOf<String, Any?>(
            "local" to linkedMapOf(
                "deviceId" to engine.deviceId,
                "name" to engine.prefs.deviceName,
                "fingerprint" to engine.fingerprint,
            ),
            "receiving" to linkedMapOf(
                "enabled" to s.receivingEnabled,
                "port" to s.receivingPort,
                "error" to s.receivingError,
                "autoOffAt" to if (activeIncoming) null else s.autoOffAt,
                "mode" to s.mode,
                "base" to engine.prefs.receiveBase,
            ),
            "discovery" to linkedMapOf("active" to s.discoveryActive, "error" to s.discoveryError),
            "network" to linkedMapOf("localNetwork" to s.localNetwork),
            "nearby" to s.nearby.map {
                linkedMapOf(
                    "deviceId" to it.deviceId,
                    "name" to (engine.trust.get(it.deviceId)?.name ?: it.name),
                    "platform" to it.platform.wire,
                    "trusted" to (engine.trust.get(it.deviceId) != null),
                    "remembered" to false,
                    "inRoom" to it.roomHints.any { h -> h in roomHints },
                )
            } + engine.trust.all().filter { p -> s.nearby.none { it.deviceId == p.deviceId } && engine.trust.lastAddress(p.deviceId) != null }.map {
                // Paired but not seen by discovery: reachable at its last address, maybe.
                linkedMapOf(
                    "deviceId" to it.deviceId,
                    "name" to it.name,
                    "platform" to it.platform.wire,
                    "trusted" to true,
                    "remembered" to true,
                    "inRoom" to false,
                )
            },
            "newestDeviceAt" to s.newestDeviceAt,
            "trusted" to engine.trust.all().map {
                linkedMapOf(
                    "deviceId" to it.deviceId,
                    "name" to it.name,
                    "platform" to it.platform.wire,
                    "fingerprint" to it.fingerprint,
                    "pairedAt" to it.pairedAt,
                    "lastUsedAt" to it.lastUsedAt,
                    "autoAccept" to it.autoAccept,
                    "expiresAt" to it.expiresAt,
                )
            },
            "transfers" to s.transfers.reversed().map { t ->
                linkedMapOf(
                    "id" to t.id,
                    "direction" to t.direction,
                    "peerId" to t.peerId,
                    "peerName" to t.peerName,
                    "peerPlatform" to t.peerPlatform,
                    "status" to t.status,
                    "files" to t.files.map {
                        linkedMapOf("name" to it.name, "size" to it.size, "mime" to it.mime, "bytes" to it.bytes, "uri" to it.uri)
                    },
                    "totalBytes" to t.totalBytes,
                    "bytesTransferred" to t.bytesTransferred,
                    "bytesPerSecond" to if (t.status == "transferring") t.rate.bytesPerSecond() else null,
                    "startedAt" to t.startedAt,
                    "updatedAt" to t.updatedAt,
                    "error" to t.error?.let { linkedMapOf("code" to it, "message" to null) },
                    "rejectReason" to t.rejectReason,
                    "canRetry" to t.canRetry,
                    "kind" to t.kind,
                    "text" to t.text?.take(4096),
                    "expiresAfter" to t.expiresAfter,
                    "deleteAt" to t.deleteAt,
                    "streams" to t.streams,
                    "queueId" to t.queueId,
                    "answersCapture" to (t.captureRequestId != null),
                )
            },
            "pairing" to s.pairing.map {
                linkedMapOf(
                    "sessionId" to it.prompt.sessionId,
                    "peerId" to it.prompt.peer.deviceId,
                    "peerName" to it.prompt.peer.name,
                    "peerPlatform" to it.prompt.peer.platform.wire,
                    "code" to it.prompt.code,
                    "role" to it.prompt.role.name.lowercase(),
                    "waitingForPeer" to it.waitingForPeer,
                    "expiresAt" to it.prompt.expiresAt,
                )
            },
            "offers" to s.offers.map { o ->
                linkedMapOf(
                    "transferId" to o.transferId,
                    "peerId" to o.peer.deviceId,
                    "peerName" to o.peer.name,
                    "peerPlatform" to o.peer.platform.wire,
                    "files" to o.files.map { linkedMapOf("name" to it.name, "size" to it.size, "mime" to it.mime) },
                    "totalBytes" to o.totalBytes,
                    "expiresAt" to o.expiresAt,
                    "kind" to o.kind.wire,
                    "expiresAfter" to o.expiresAfter,
                    "answersCapture" to (o.requestId != null),
                )
            },
            "history" to engine.history.all().map { h ->
                linkedMapOf(
                    "id" to h.id,
                    "direction" to h.direction,
                    "peerName" to h.peerName,
                    "peerPlatform" to h.peerPlatform,
                    "status" to h.status,
                    "files" to h.files.map { linkedMapOf("name" to it.name, "size" to it.size, "uri" to it.uri) },
                    "totalBytes" to h.totalBytes,
                    "finishedAt" to h.finishedAt,
                    "errorCode" to h.errorCode,
                    "peerId" to h.peerId,
                    "kind" to h.kind,
                    "link" to h.link,
                    "canSendAgain" to (h.direction == "outgoing" && h.peerId != null &&
                        (h.kind == "link" || (h.kind == "files" && h.files.isNotEmpty() && h.files.all { it.uri?.startsWith("content://") == true }))),
                    "deleteAt" to h.deleteAt,
                )
            },
            "shared" to s.shared.map { it.toJson() },
            "sharedText" to s.sharedText?.toJson(),
            "lastDeviceId" to engine.prefs.lastDeviceId,
            "notificationPermission" to NotificationPermissions.status(engine.appContext, engine.prefs),
            "destinationLabel" to engine.destinationLabel,
            "appVersion" to Engine.APP_VERSION,
            "prefs" to linkedMapOf(
                "sound" to engine.prefs.sound,
                "haptics" to engine.prefs.haptics,
                "welcomed" to engine.prefs.welcomed,
                "screenshotOffer" to engine.prefs.screenshotOffer,
                "sortByType" to engine.prefs.sortByType,
                "turbo" to engine.prefs.turbo,
            ),
            "screenshotPermission" to s.screenshotPermission,
            "hotspot" to linkedMapOf(
                "state" to engine.hotspot.state,
                "ssid" to engine.hotspot.ssid,
                "password" to engine.hotspot.password,
                "error" to engine.hotspot.error,
            ),
            "queue" to engine.queue.all().map { q ->
                val peer = engine.trust.get(q.deviceId)
                linkedMapOf(
                    "id" to q.id,
                    "deviceId" to q.deviceId,
                    "deviceName" to (peer?.name ?: "Unpaired device"),
                    "devicePlatform" to peer?.platform?.wire,
                    "paired" to (peer != null),
                    "kind" to q.kind,
                    "files" to q.files.map { linkedMapOf("name" to it.name, "size" to it.size, "mime" to it.mime, "copied" to it.copied) },
                    "preview" to q.text?.take(200),
                    "totalBytes" to q.totalBytes,
                    "createdAt" to q.createdAt,
                    "status" to q.status,
                    "error" to q.error,
                    "attempts" to q.attempts,
                    "transferId" to q.transferId,
                    "expiresAfter" to q.expiresAfter,
                )
            },
            "queueStorage" to linkedMapOf(
                "usedBytes" to engine.queue.usedBytes(),
                "limitBytes" to SendQueue.LIMIT_BYTES,
                "searching" to s.queueWindowOpen,
            ),
            "captureRequests" to s.captures.map {
                linkedMapOf(
                    "requestId" to it.requestId,
                    "peerId" to it.peerId,
                    "peerName" to it.peerName,
                    "kind" to it.kind.wire,
                    "expiresAt" to it.expiresAt,
                    "state" to it.state,
                )
            },
            "captureFocus" to s.captureFocus?.takeIf { id -> s.captures.any { it.requestId == id } },
            "pocket" to engine.pocket.all().map {
                linkedMapOf(
                    "id" to it.id,
                    "uri" to it.uri,
                    "name" to it.name,
                    "size" to it.size,
                    "mime" to it.mime,
                    "receivedAt" to it.receivedAt,
                    "from" to it.from,
                    "fromPlatform" to it.fromPlatform,
                    "deleteAt" to it.deleteAt,
                )
            },
            "clip" to s.clip?.let {
                linkedMapOf(
                    "transferId" to it.transferId,
                    "from" to it.from,
                    "fromPlatform" to it.fromPlatform,
                    "preview" to it.text.take(200),
                    "length" to it.text.length,
                    "expiresAt" to it.expiresAt,
                )
            },
            "pendingTarget" to s.pendingTarget?.let { id ->
                engine.trust.get(id)?.let { p ->
                    linkedMapOf("deviceId" to p.deviceId, "name" to p.name, "platform" to p.platform.wire, "at" to s.pendingTargetAt)
                }
            },
            "room" to activeRooms.firstOrNull()?.let { r ->
                linkedMapOf(
                    "id" to r.id,
                    "name" to r.name,
                    "expiresAt" to r.expiresAtMillis,
                    "hosting" to (s.roomHosting == r.id),
                    "invite" to if (s.roomHosting == r.id) s.roomInvite else null,
                    "members" to s.nearby.count { d -> d.roomHints.any { it == r.hint } },
                )
            },
            "roomDurations" to Engine.ROOM_MINUTES.sorted(),
        )
        return Json.write(map)
    }
}
