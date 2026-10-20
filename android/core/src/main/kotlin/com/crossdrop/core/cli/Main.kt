package com.crossdrop.core.cli

import com.crossdrop.core.CrossDropServer
import com.crossdrop.core.DirectoryStorage
import com.crossdrop.core.IdentityKey
import com.crossdrop.core.IncomingOffer
import com.crossdrop.core.IncomingTransfer
import com.crossdrop.core.InMemoryTrustStore
import com.crossdrop.core.LocalInfo
import com.crossdrop.core.OutgoingFile
import com.crossdrop.core.OutgoingTransfer
import com.crossdrop.core.PairingPrompt
import com.crossdrop.core.PeerInfo
import com.crossdrop.core.Platform
import com.crossdrop.core.ProtocolException
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
 *   send --host <h> --port <p> --identity <file> [--name <n>] <file>...
 * Optional: --platform macos to present as a Mac (the emulator UI run uses it).
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
        "receive" -> receive(identity, local, opts["port"]?.toInt() ?: usage(), File(opts["dir"] ?: usage()), opts.containsKey("once"))
        "send" -> send(identity, local, opts["host"] ?: usage(), opts["port"]?.toInt() ?: usage(), positional)
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

private fun receive(identity: IdentityKey, local: LocalInfo, port: Int, dir: File, once: Boolean) {
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
    val server = CrossDropServer(identity, { local }, InMemoryTrustStore(), DirectoryStorage(dir.toPath()), events)
    val bound = server.start(port)
    out("LISTENING $bound")
    done.await()
    server.stop()
    exitProcess(exitCode)
}

private fun send(identity: IdentityKey, local: LocalInfo, host: String, port: Int, paths: List<String>) {
    if (paths.isEmpty()) usage()
    val files = paths.map { p ->
        val f = File(p)
        OutgoingFile(f.name, f.length(), null) { f.inputStream() }
    }
    val events = object : SenderEvents {
        override fun onStage(stage: SendStage) {}
        override fun onPairingPrompt(prompt: PairingPrompt) {
            out("SAS ${prompt.code}")
            prompt.respond(true)
        }
        override fun onPairingClosed(prompt: PairingPrompt, paired: Boolean) {}
    }
    val transfer = OutgoingTransfer(identity, local, InMemoryTrustStore(), host, port, null, files, events)
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
