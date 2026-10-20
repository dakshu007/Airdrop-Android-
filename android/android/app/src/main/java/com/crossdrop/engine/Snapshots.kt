package com.crossdrop.engine

import com.crossdrop.core.Json
import com.crossdrop.storage.MediaStoreStorage

/** Serialises engine state to the JSON shape in android/src/native/types.ts (Snapshot). */
object Snapshots {
    fun build(engine: Engine, s: SnapshotState): String {
        val activeIncoming = s.transfers.any { it.direction == "incoming" && !it.isFinished }
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
            ),
            "discovery" to linkedMapOf("active" to s.discoveryActive, "error" to s.discoveryError),
            "network" to linkedMapOf("localNetwork" to s.localNetwork),
            "nearby" to s.nearby.map {
                linkedMapOf(
                    "deviceId" to it.deviceId,
                    "name" to it.name,
                    "platform" to it.platform.wire,
                    "trusted" to (engine.trust.get(it.deviceId) != null),
                )
            },
            "trusted" to engine.trust.all().map {
                linkedMapOf(
                    "deviceId" to it.deviceId,
                    "name" to it.name,
                    "platform" to it.platform.wire,
                    "fingerprint" to it.fingerprint,
                    "pairedAt" to it.pairedAt,
                    "lastUsedAt" to it.lastUsedAt,
                    "autoAccept" to it.autoAccept,
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
                )
            },
            "shared" to s.shared.map { it.toJson() },
            "notificationPermission" to NotificationPermissions.status(engine.appContext, engine.prefs),
            "destinationLabel" to MediaStoreStorage.LABEL,
            "appVersion" to Engine.APP_VERSION,
            "wallpaper" to engine.prefs.wallpaper,
        )
        return Json.write(map)
    }
}
