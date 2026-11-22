package com.crossdrop.core.cli

import com.crossdrop.core.CaptureClient
import com.crossdrop.core.CaptureKind
import com.crossdrop.core.CaptureRequest
import com.crossdrop.core.CrossDropServer
import com.crossdrop.core.DirectoryStorage
import com.crossdrop.core.Hashing
import com.crossdrop.core.IdentityKey
import com.crossdrop.core.IncomingOffer
import com.crossdrop.core.IncomingTransfer
import com.crossdrop.core.InMemoryTrustStore
import com.crossdrop.core.LocalInfo
import com.crossdrop.core.OutgoingFile
import com.crossdrop.core.OfferKind
import com.crossdrop.core.OutgoingTransfer
import com.crossdrop.core.PairingPrompt
import com.crossdrop.core.PeerInfo
import com.crossdrop.core.Platform
import com.crossdrop.core.Protocol
import com.crossdrop.core.ProtocolException
import com.crossdrop.core.QrPairing
import com.crossdrop.core.ReceiverEvents
import com.crossdrop.core.RoomInvite
import com.crossdrop.core.SavedFile
import com.crossdrop.core.SendStage
import com.crossdrop.core.SenderEvents
import com.crossdrop.core.SoftwareIdentity
import com.crossdrop.core.TransferRejectedException
import com.crossdrop.core.hexToBytes
import com.crossdrop.core.toHex
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import kotlin.system.exitProcess

/**
 * Interop test tool (CI only). Auto-confirms pairing and auto-accepts offers.
 * Interface shared with the Swift `crossdrop-cli`:
 *   receive --port <p> --dir <dir> --identity <file> [--name <n>] [--once]
 *           [--private] [--token-out <file>]     (writes "<token> <fingerprint>")
 *           [--room-out <file>]                  (creates a Drip Room, writes its crossdrop://room URI)
 *           [--capture-file <file>]              (answers capture requests by sending this file back)
 *   send --host <h> --port <p> --identity <file> [--name <n>] <file>...
 *        [--path <a/b>] [--kind link|text --text <s>] [--qr <token>:<fingerprint>]
 *        [--die-after <bytes>]                   (exit abruptly mid-transfer)
 *        [--expires-after <seconds>] [--room <crossdrop://room URI>] [--request-id <id>]
 *        [--turbo <n>]                           (up to n connections for several files, §9.10; prints STREAMS <used>)
 *   capture --host <h> --port <p> --identity <file> --listen <port> --dir <dir> [--kind photo|pick]
 *        (asks the receiver for a photo, then waits for the answer on its own listening port)
 * Optional: --platform macos to present as a Mac (the emulator UI run uses it).
 * Output lines: SAS <code>, RECEIVED <name> <sha256>, TEXT <kind> <base64>,
 * RESUMED <bytes>, COMPLETE <id>, LISTENING <port>, PROMPT <id> (an offer asked the user),
 * CAPTURE <kind> <requestId>, ACK <requestId>, REPLY <requestId> (an answer to our request),
 * EXPIRES <seconds>, STREAMS <n> (connections a --turbo send used); errors go to stderr.
 */
fun main(args: Array<String>) {
    if (args.isEmpty()) usage()
    val opts = HashMap<String, String>()
    val positional = ArrayList<String>()
    var i = 1
    while (i < args.size) {
        val a = args[i]
        when {
            a == "--once" -> opts["once"] = "1"
            a == "--private" -> opts["private"] = "1"
            a.startsWith("--") -> {
                if (i + 1 >= args.size) usage()
                opts[a.removePrefix("--")] = args[i + 1]
                i++
            }
            else -> positional.add(a)
        }
        i++
    }
    val identity = loadIdentity(File(opts["identity"] ?: usage()))
    val platform = if (opts["platform"] == "macos") Platform.MACOS else Platform.ANDROID
    val local = LocalInfo(opts["name"] ?: "JVM CLI", platform, "0.1.0-cli")
    when (args[0]) {
        "receive" -> receive(identity, local, opts["port"]?.toInt() ?: usage(), File(opts["dir"] ?: usage()), opts.containsKey("once"), opts)
        "send" -> send(identity, local, opts["host"] ?: usage(), opts["port"]?.toInt() ?: usage(), positional, opts)
        "capture" -> capture(identity, local, opts["host"] ?: usage(), opts["port"]?.toInt() ?: usage(), opts)
        else -> usage()
    }
}

private fun usage(): Nothing {
    System.err.println("usage: crossdrop-cli receive --port <p> --dir <dir> --identity <file> [--name <n>] [--once]")
    System.err.println("       crossdrop-cli send --host <h> --port <p> --identity <file> [--name <n>] <file>...")
    System.err.println("       crossdrop-cli capture --host <h> --port <p> --identity <file> --listen <port> --dir <dir> [--kind photo|pick]")
    exitProcess(2)
}

private fun loadIdentity(file: File): IdentityKey {
    if (file.exists()) return SoftwareIdentity.fromScalar(file.readText().trim().hexToBytes())
    val (id, scalar) = SoftwareIdentity.generate()
    file.writeText(scalar.toHex())
    return id
}

private fun out(line: String) {
    synchronized(System.out) {
        println(line)
        System.out.flush()
    }
}

/** Receiver events shared by `receive` and `capture`: auto-confirm, auto-accept, print what happened. */
private open class CliReceiverEvents(private val once: Boolean, private val done: CountDownLatch) : ReceiverEvents {
    @Volatile var exitCode = 0
    override fun isReceiving() = true
    override fun onPairingPrompt(prompt: PairingPrompt) {
        out("SAS ${prompt.code}")
        prompt.respond(true)
    }
    override fun onPairingClosed(prompt: PairingPrompt, paired: Boolean) {}
    override fun onOffer(offer: IncomingOffer) {
        out("PROMPT ${offer.transferId}")
        offer.respond(true)
    }
    override fun onFileSaved(transfer: IncomingTransfer, fileIndex: Int, saved: SavedFile) {
        out("RECEIVED ${saved.displayName} ${sha256(File(saved.location))}")
    }
    override fun onTextReceived(transfer: IncomingTransfer, kind: OfferKind, text: String) {
        out("TEXT ${kind.wire} ${java.util.Base64.getEncoder().encodeToString(text.toByteArray(Charsets.UTF_8))}")
    }
    override fun onCompleted(transfer: IncomingTransfer) {
        transfer.expiresAfter?.let { out("EXPIRES $it") }
        transfer.requestId?.let { out("REPLY $it") }
        out("COMPLETE ${transfer.transferId}")
        if (once) done.countDown()
    }
    override fun onFailed(transfer: IncomingTransfer?, peer: PeerInfo?, error: ProtocolException) {
        System.err.println("ERROR ${error.code.wire}")
        if (once) {
            exitCode = 1
            done.countDown()
        }
    }
}

private fun receive(identity: IdentityKey, local: LocalInfo, port: Int, dir: File, once: Boolean, opts: Map<String, String>) {
    val done = CountDownLatch(1)
    val trust = InMemoryTrustStore()
    val captureFile = opts["capture-file"]?.let { File(it) }
    val events = object : CliReceiverEvents(once, done) {
        override fun onCaptureRequest(peer: PeerInfo, request: CaptureRequest): Boolean {
            out("CAPTURE ${request.kind.wire} ${request.requestId}")
            val file = captureFile ?: return true
            val replyPort = request.replyPort ?: return true
            // Like the phone app after the photo is taken: send it back, answering the request.
            Thread {
                Thread.sleep(300)
                val reply = OutgoingTransfer(
                    identity, local, trust, request.replyHost, replyPort, peer.deviceId,
                    listOf(OutgoingFile(file.name, file.length(), null) { file.inputStream() }), QuietSenderEvents,
                    requestId = request.requestId,
                )
                try {
                    reply.run()
                    out("REPLIED ${request.requestId}")
                } catch (e: ProtocolException) {
                    System.err.println("ERROR reply:${e.code.wire}")
                } catch (e: TransferRejectedException) {
                    System.err.println("ERROR reply:rejected:${e.reason}")
                }
            }.apply { isDaemon = true }.start()
            return true
        }
    }
    val private = opts.containsKey("private")
    val server = CrossDropServer(identity, { local }, trust, DirectoryStorage(dir.toPath()), events, { private })
    opts["token-out"]?.let { File(it).writeText("${server.pairingTokens.issue(mine = false)} ${Hashing.sha256(identity.publicKey).toHex()}\n") }
    val bound = server.start(port)
    opts["room-out"]?.let {
        val room = server.rooms.create("Interop room", 3600)
        File(it).writeText(RoomInvite(room, listOf("127.0.0.1"), bound, Hashing.sha256(identity.publicKey).toHex()).toUri() + "\n")
    }
    out("LISTENING $bound")
    done.await()
    server.stop()
    exitProcess(events.exitCode)
}

/** Sender events that auto-confirm pairing and print the code. */
private object QuietSenderEvents : SenderEvents {
    override fun onStage(stage: SendStage) {}
    override fun onPairingPrompt(prompt: PairingPrompt) {
        out("SAS ${prompt.code}")
        prompt.respond(true)
    }
    override fun onPairingClosed(prompt: PairingPrompt, paired: Boolean) {}
}

/** Asks [host] for a capture, then receives the answer on our own server (§9.7). */
private fun capture(identity: IdentityKey, local: LocalInfo, host: String, port: Int, opts: Map<String, String>) {
    val done = CountDownLatch(1)
    val trust = InMemoryTrustStore()
    val events = CliReceiverEvents(once = true, done = done)
    val dir = File(opts["dir"] ?: usage())
    val server = CrossDropServer(identity, { local }, trust, DirectoryStorage(dir.toPath()), events)
    val bound = server.start(opts["listen"]?.toInt() ?: usage())
    out("LISTENING $bound")
    val kind = CaptureKind.fromWire(opts["kind"] ?: "photo")
    try {
        val id = CaptureClient.request(identity, local, trust, host, port, null, kind, bound, server.captureRequests, QuietSenderEvents)
        out("ACK $id")
    } catch (e: ProtocolException) {
        System.err.println("ERROR ${e.code.wire}")
        exitProcess(1)
    } catch (e: TransferRejectedException) {
        System.err.println("ERROR rejected:${e.reason}")
        exitProcess(1)
    }
    if (!done.await(60, java.util.concurrent.TimeUnit.SECONDS)) {
        System.err.println("ERROR no answer")
        exitProcess(1)
    }
    server.stop()
    exitProcess(events.exitCode)
}

private fun send(identity: IdentityKey, local: LocalInfo, host: String, port: Int, paths: List<String>, opts: Map<String, String>) {
    val kind = OfferKind.fromWire(opts["kind"])
    val folder = opts["path"]?.split('/')?.filter { it.isNotEmpty() } ?: emptyList()
    val dieAfter = opts["die-after"]?.toLong()
    val files = if (kind != OfferKind.FILES) {
        listOf(OutgoingFile.text(if (kind == OfferKind.LINK) "Link" else "Text", opts["text"] ?: usage()))
    } else {
        if (paths.isEmpty()) usage()
        paths.map { p ->
            val f = File(p)
            var opens = 0
            OutgoingFile(f.name, f.length(), null, folder) {
                opens++
                // The second open is the streaming pass (the first one hashes).
                if (dieAfter != null && opens == 2) DyingStream(f.inputStream(), dieAfter) else f.inputStream()
            }
        }
    }
    val qr = opts["qr"]?.split(':')?.let { QrPairing(it[0], it[1], mine = false) }
    val room = opts["room"]?.let { uri ->
        val invite = RoomInvite.parse(uri.trim()) ?: run { System.err.println("ERROR bad room code"); exitProcess(2) }
        invite.room
    }
    var firstSent: Long? = null
    val events = object : SenderEvents {
        override fun onStage(stage: SendStage) {}
        override fun onBytesSent(total: Long) {
            if (firstSent == null) {
                firstSent = total
                // A first report bigger than one record means the receiver let us skip ahead.
                if (total > Protocol.MAX_DATA_BODY) out("RESUMED $total")
            }
        }
        override fun onPairingPrompt(prompt: PairingPrompt) {
            out("SAS ${prompt.code}")
            prompt.respond(true)
        }
        override fun onPairingClosed(prompt: PairingPrompt, paired: Boolean) {}
    }
    val transfer = OutgoingTransfer(
        identity, local, InMemoryTrustStore(), host, port, null, files, events, kind = kind, qr = qr,
        requestId = opts["request-id"], expiresAfter = opts["expires-after"]?.toLong(), room = room,
        turbo = opts["turbo"]?.let { t -> t.toIntOrNull()?.takeIf { it in 1..Protocol.MAX_TURBO_STREAMS } ?: usage() } ?: 1,
    )
    try {
        transfer.run()
        if (opts.containsKey("turbo")) out("STREAMS ${transfer.streams}")
        out("COMPLETE ${transfer.transferId}")
        exitProcess(0)
    } catch (e: ProtocolException) {
        System.err.println("ERROR ${e.code.wire}")
    } catch (e: TransferRejectedException) {
        System.err.println("ERROR rejected:${e.reason}")
    }
    exitProcess(1)
}

private fun sha256(file: File): String {
    val md = MessageDigest.getInstance("SHA-256")
    file.inputStream().use { input ->
        val buf = ByteArray(1 shl 16)
        while (true) {
            val n = input.read(buf)
            if (n < 0) break
            md.update(buf, 0, n)
        }
    }
    return md.digest().toHex()
}

/** Reads normally, then kills the process once [limit] bytes have been read: an abrupt disconnect. */
private class DyingStream(private val inner: java.io.InputStream, private val limit: Long) : java.io.InputStream() {
    private var read = 0L
    private fun check() { if (read >= limit) Runtime.getRuntime().halt(3) }
    override fun read(): Int { check(); return inner.read().also { if (it >= 0) read++ } }
    override fun read(b: ByteArray, off: Int, len: Int): Int {
        check()
        val n = inner.read(b, off, minOf(len.toLong(), limit - read).toInt().coerceAtLeast(1))
        if (n > 0) read += n
        return n
    }
    override fun close() = inner.close()
}
