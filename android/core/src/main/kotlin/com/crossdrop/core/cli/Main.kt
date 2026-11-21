package com.crossdrop.core.cli

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
 *   send --host <h> --port <p> --identity <file> [--name <n>] <file>...
 *        [--path <a/b>] [--kind link|text --text <s>] [--qr <token>:<fingerprint>]
 *        [--die-after <bytes>]                   (exit abruptly mid-transfer)
 * Optional: --platform macos to present as a Mac (the emulator UI run uses it).
 * Output lines: SAS <code>, RECEIVED <name> <sha256>, TEXT <kind> <base64>,
 * RESUMED <bytes>, COMPLETE <id>, LISTENING <port>; errors go to stderr.
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
        else -> usage()
    }
}

private fun usage(): Nothing {
    System.err.println("usage: crossdrop-cli receive --port <p> --dir <dir> --identity <file> [--name <n>] [--once]")
    System.err.println("       crossdrop-cli send --host <h> --port <p> --identity <file> [--name <n>] <file>...")
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

private fun receive(identity: IdentityKey, local: LocalInfo, port: Int, dir: File, once: Boolean, opts: Map<String, String>) {
    val done = CountDownLatch(1)
    var exitCode = 0
    val events = object : ReceiverEvents {
        override fun isReceiving() = true
        override fun onPairingPrompt(prompt: PairingPrompt) {
            out("SAS ${prompt.code}")
            prompt.respond(true)
        }
        override fun onPairingClosed(prompt: PairingPrompt, paired: Boolean) {}
        override fun onOffer(offer: IncomingOffer) = offer.respond(true)
        override fun onFileSaved(transfer: IncomingTransfer, fileIndex: Int, saved: SavedFile) {
            out("RECEIVED ${saved.displayName} ${sha256(File(saved.location))}")
        }
        override fun onTextReceived(transfer: IncomingTransfer, kind: OfferKind, text: String) {
            out("TEXT ${kind.wire} ${java.util.Base64.getEncoder().encodeToString(text.toByteArray(Charsets.UTF_8))}")
        }
        override fun onCompleted(transfer: IncomingTransfer) {
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
    val private = opts.containsKey("private")
    val server = CrossDropServer(identity, { local }, InMemoryTrustStore(), DirectoryStorage(dir.toPath()), events, { private })
    opts["token-out"]?.let { File(it).writeText("${server.pairingTokens.issue(mine = false)} ${Hashing.sha256(identity.publicKey).toHex()}\n") }
    val bound = server.start(port)
    out("LISTENING $bound")
    done.await()
    server.stop()
    exitProcess(exitCode)
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
    val transfer = OutgoingTransfer(identity, local, InMemoryTrustStore(), host, port, null, files, events, kind = kind, qr = qr)
    try {
        transfer.run()
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
