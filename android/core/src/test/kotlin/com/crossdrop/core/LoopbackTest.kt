package com.crossdrop.core

import java.io.ByteArrayInputStream
import java.io.DataOutputStream
import java.io.File
import java.net.InetAddress
import java.net.Socket
import java.nio.file.Files
import java.util.Collections
import java.util.Random
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/** End-to-end tests over 127.0.0.1 with real sockets, both roles in-process. */
class LoopbackTest {
    private val dir = Files.createTempDirectory("crossdrop-test")
    private val serverIdentity = SoftwareIdentity.generate().first
    private val clientIdentity = SoftwareIdentity.generate().first
    private val serverTrust = InMemoryTrustStore()
    private val clientTrust = InMemoryTrustStore()
    private val failures = Collections.synchronizedList(ArrayList<ErrorCode>())
    private val saved = Collections.synchronizedList(ArrayList<SavedFile>())
    private val completed = CountDownLatch(1)
    private val failed = CountDownLatch(1)
    @Volatile var serverSas: String? = null
    @Volatile var acceptPairing = true
    @Volatile var acceptOffer = true
    @Volatile var receiving = true
    @Volatile var onStarted: ((IncomingTransfer) -> Unit)? = null
    @Volatile var privateMode = false
    @Volatile var receivedText: Pair<OfferKind, String>? = null

    private val events = object : ReceiverEvents {
        override fun isReceiving() = receiving
        override fun onPairingPrompt(prompt: PairingPrompt) {
            serverSas = prompt.code
            prompt.respond(acceptPairing)
        }
        override fun onPairingClosed(prompt: PairingPrompt, paired: Boolean) {}
        override fun onOffer(offer: IncomingOffer) = offer.respond(acceptOffer)
        override fun onTransferStarted(transfer: IncomingTransfer) { onStarted?.invoke(transfer) }
        override fun onFileSaved(transfer: IncomingTransfer, fileIndex: Int, saved: SavedFile) { this@LoopbackTest.saved.add(saved) }
        override fun onCompleted(transfer: IncomingTransfer) = completed.countDown()
        override fun onTextReceived(transfer: IncomingTransfer, kind: OfferKind, text: String) { receivedText = kind to text }
        override fun onFailed(transfer: IncomingTransfer?, peer: PeerInfo?, error: ProtocolException) {
            failures.add(error.code)
            failed.countDown()
        }
    }

    private val server = CrossDropServer(
        serverIdentity, { LocalInfo("Test Mac", Platform.MACOS, "test") }, serverTrust, DirectoryStorage(dir), events, { privateMode },
    )
    private val port = server.start(0, InetAddress.getLoopbackAddress())

    @AfterTest
    fun tearDown() {
        server.stop()
        dir.toFile().deleteRecursively()
    }

    private inner class ClientEvents : SenderEvents {
        @Volatile var sas: String? = null
        val stages = Collections.synchronizedList(ArrayList<SendStage>())
        override fun onStage(stage: SendStage) { stages.add(stage) }
        override fun onPairingPrompt(prompt: PairingPrompt) {
            sas = prompt.code
            prompt.respond(true)
        }
        override fun onPairingClosed(prompt: PairingPrompt, paired: Boolean) {}
    }

    private fun bytesFile(name: String, data: ByteArray) = OutgoingFile(name, data.size.toLong(), "application/octet-stream") { ByteArrayInputStream(data) }

    private fun transfer(
        files: List<OutgoingFile>,
        ev: SenderEvents = ClientEvents(),
        toPort: Int = port,
        kind: OfferKind = OfferKind.FILES,
        qr: QrPairing? = null,
    ) = OutgoingTransfer(
        clientIdentity, LocalInfo("Test Phone", Platform.ANDROID, "test"), clientTrust, "127.0.0.1", toPort,
        serverIdentity.deviceId, files, ev, kind = kind, qr = qr,
    )

    private val serverFingerprint get() = Hashing.sha256(serverIdentity.publicKey).toHex()

    /**
     * Forwards one connection to the server and counts client-to-server bytes; with
     * [cutAfter] it drops the connection abruptly once that many bytes went through.
     */
    private inner class Proxy(private val cutAfter: Long = Long.MAX_VALUE) {
        private val listener = java.net.ServerSocket(0, 1, InetAddress.getLoopbackAddress())
        val port: Int = listener.localPort
        @Volatile var forwarded = 0L

        init {
            Thread {
                val client = listener.accept()
                val upstream = Socket(InetAddress.getLoopbackAddress(), this@LoopbackTest.port)
                Thread {
                    runCatching { upstream.getInputStream().copyTo(client.getOutputStream()) }
                    runCatching { client.close() }
                }.apply { isDaemon = true }.start()
                val buf = ByteArray(16 * 1024)
                runCatching {
                    val input = client.getInputStream()
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        upstream.getOutputStream().write(buf, 0, n)
                        forwarded += n
                        if (forwarded >= cutAfter) break
                    }
                }
                runCatching { upstream.close() }
                runCatching { client.close() }
                runCatching { listener.close() }
            }.apply { isDaemon = true }.start()
        }
    }

    @Test
    fun pairsAndTransfersFilesThenReusesTrust() {
        val big = ByteArray(1_000_003).also { Random(1).nextBytes(it) }
        val ev = ClientEvents()
        val peer = transfer(listOf(bytesFile("empty.txt", ByteArray(0)), bytesFile("../evil/big.bin", big)), ev).run()
        assertTrue(completed.await(5, TimeUnit.SECONDS))
        assertEquals(serverIdentity.deviceId, peer.deviceId)
        assertNotNull(ev.sas)
        assertEquals(ev.sas, serverSas, "both sides must show the same code")
        assertEquals(listOf("empty.txt", "big.bin"), saved.map { it.displayName })
        assertEquals(0, File(saved[0].location).length())
        assertContentEquals(big, File(saved[1].location).readBytes())
        assertNotNull(clientTrust.get(serverIdentity.deviceId))
        assertNotNull(serverTrust.get(clientIdentity.deviceId))

        // Second transfer: already paired, same name -> numbered copy, no pairing stage.
        val ev2 = ClientEvents()
        transfer(listOf(bytesFile("empty.txt", byteArrayOf(42))), ev2).run()
        assertTrue(SendStage.PAIRING !in ev2.stages)
        assertEquals("empty (1).txt", saved.last().displayName)
        assertTrue(dir.toFile().listFiles()!!.none { it.name.endsWith(".partial") })
    }

    @Test
    fun declinedOfferIsRejected() {
        acceptOffer = false
        val e = assertFailsWith<TransferRejectedException> { transfer(listOf(bytesFile("a.txt", byteArrayOf(1)))).run() }
        assertEquals("declined", e.reason)
        assertTrue(saved.isEmpty())
    }

    @Test
    fun declinedPairingStoresNoTrust() {
        acceptPairing = false
        val e = assertFailsWith<ProtocolException> { transfer(listOf(bytesFile("a.txt", byteArrayOf(1)))).run() }
        assertEquals(ErrorCode.PAIRING_REJECTED, e.code)
        assertEquals(null, clientTrust.get(serverIdentity.deviceId))
        assertEquals(null, serverTrust.get(clientIdentity.deviceId))
    }

    @Test
    fun receiverForgotSenderRequiresPairingAgain() {
        clientTrust.trust(PeerInfo(serverIdentity.deviceId, "Test Mac", Platform.MACOS, "t", serverIdentity.publicKey))
        val ev = ClientEvents()
        transfer(listOf(bytesFile("a.txt", byteArrayOf(1))), ev).run()
        assertTrue(SendStage.PAIRING in ev.stages)
        assertNotNull(serverTrust.get(clientIdentity.deviceId))
    }

    @Test
    fun notReceivingRefusesConnection() {
        receiving = false
        val e = assertFailsWith<ProtocolException> { transfer(listOf(bytesFile("a.txt", byteArrayOf(1)))).run() }
        assertEquals(ErrorCode.NOT_RECEIVING, e.code)
        assertTrue(e.remote)
    }

    @Test
    fun integrityFailureDeletesPartial() {
        var opens = 0
        val data = ByteArray(300_000) { 7 }
        val changing = OutgoingFile("x.bin", data.size.toLong(), null) {
            opens++
            ByteArrayInputStream(if (opens == 1) data else data.copyOf().also { it[5] = 8 })
        }
        val e = assertFailsWith<ProtocolException> { transfer(listOf(changing)).run() }
        assertEquals(ErrorCode.INTEGRITY_FAILED, e.code)
        assertTrue(failed.await(5, TimeUnit.SECONDS))
        assertEquals(ErrorCode.INTEGRITY_FAILED, failures.first())
        assertTrue(dir.toFile().listFiles()!!.isEmpty(), "partial file must be removed")
    }

    @Test
    fun receiverCancelStopsSender() {
        onStarted = { t -> Thread { Thread.sleep(50); t.cancel() }.start() }
        val slow = OutgoingFile("slow.bin", 50L * 1024 * 1024, null) {
            object : java.io.InputStream() {
                var left = 50L * 1024 * 1024
                override fun read(): Int = if (left-- > 0) 0 else -1
                override fun read(b: ByteArray, off: Int, len: Int): Int {
                    if (left <= 0) return -1
                    val n = minOf(len.toLong(), left).toInt()
                    java.util.Arrays.fill(b, off, off + n, 0)
                    left -= n
                    return n
                }
            }
        }
        val e = assertFailsWith<ProtocolException> { transfer(listOf(slow)).run() }
        assertEquals(ErrorCode.CANCELLED, e.code)
        assertTrue(failed.await(5, TimeUnit.SECONDS))
        assertEquals(ErrorCode.CANCELLED, failures.first())
        Thread.sleep(100)
        assertTrue(dir.toFile().listFiles()!!.isEmpty(), "left: " + dir.toFile().listFiles()!!.joinToString { it.name + ":" + it.length() })
    }

    @Test
    fun oversizedAndGarbageFramesAreRejected() {
        Socket("127.0.0.1", port).use { s ->
            DataOutputStream(s.getOutputStream()).apply { writeInt(70_000); flush() }
            s.soTimeout = 5000
            // Server answers with a plaintext error or just closes; either way it must not hang or crash.
            val bytes = s.getInputStream().readBytes()
            assertTrue(bytes.isEmpty() || String(bytes.copyOfRange(4, bytes.size)).contains("frame_too_large"))
        }
        Socket("127.0.0.1", port).use { s ->
            val junk = "{\"type\":\"hello\",\"v\":9,\"minV\":5}".toByteArray()
            DataOutputStream(s.getOutputStream()).apply { writeInt(junk.size); write(junk); flush() }
            s.soTimeout = 5000
            val bytes = s.getInputStream().readBytes()
            assertTrue(String(bytes.copyOfRange(4, bytes.size)).contains("unsupported_version"))
        }
    }

    @Test
    fun foldersKeepTheirStructureButNeverEscape() {
        val files = listOf(
            OutgoingFile("a.txt", 1, null, listOf("Trip", "Day 1")) { ByteArrayInputStream(byteArrayOf(1)) },
            OutgoingFile("b.txt", 1, null, listOf("..", "Trip", ".", "/etc")) { ByteArrayInputStream(byteArrayOf(2)) },
        )
        transfer(files).run()
        assertTrue(completed.await(5, TimeUnit.SECONDS))
        assertEquals(listOf("Trip/Day 1/a.txt", "Trip/etc/b.txt"), saved.map { it.displayName })
        assertTrue(File(saved[0].location).canonicalPath.startsWith(dir.toFile().canonicalPath))
        assertTrue(File(saved[1].location).canonicalPath.startsWith(dir.toFile().canonicalPath))
    }

    @Test
    fun linkArrivesAsTextAndIsNotSaved() {
        transfer(listOf(OutgoingFile.text("Link", "https://example.com/a?b=c")), kind = OfferKind.LINK).run()
        assertTrue(completed.await(5, TimeUnit.SECONDS))
        assertEquals(OfferKind.LINK to "https://example.com/a?b=c", receivedText)
        assertTrue(saved.isEmpty())
        assertTrue(dir.toFile().listFiles()!!.isEmpty())
    }

    @Test
    fun tooLargeTextOfferIsRefused() {
        val big = OutgoingFile("Text", 70_000, null) { ByteArrayInputStream(ByteArray(70_000)) }
        val e = assertFailsWith<ProtocolException> { transfer(listOf(big), kind = OfferKind.TEXT).run() }
        assertEquals(ErrorCode.BAD_MESSAGE, e.code)
    }

    @Test
    fun qrTokenPairsWithoutPromptsAndRemembersMine() {
        val token = server.pairingTokens.issue(mine = true)
        val noPrompt = object : SenderEvents {
            override fun onStage(stage: SendStage) {}
            override fun onPairingPrompt(prompt: PairingPrompt) = error("QR pairing must not prompt")
            override fun onPairingClosed(prompt: PairingPrompt, paired: Boolean) {}
        }
        acceptPairing = false // the server must not ask its user either
        val peer = QrPairingClient.pairOnly(
            clientIdentity, LocalInfo("Test Phone", Platform.ANDROID, "test"), clientTrust,
            listOf("127.0.0.1"), port, QrPairing(token, serverFingerprint, mine = true), noPrompt,
        )
        assertEquals(serverIdentity.deviceId, peer.deviceId)
        assertEquals(null, serverSas)
        assertEquals(true, clientTrust.get(serverIdentity.deviceId)?.autoAccept)
        assertEquals(true, serverTrust.get(clientIdentity.deviceId)?.autoAccept)
        Thread.sleep(300)
        assertTrue(failures.isEmpty(), "a pairing-only session ends quietly: $failures")
        // The token is single-use.
        assertEquals(null, server.pairingTokens.redeem(token))
    }

    @Test
    fun qrCodeForAnotherDeviceIsRefused() {
        val token = server.pairingTokens.issue(mine = false)
        val e = assertFailsWith<ProtocolException> {
            QrPairingClient.pairOnly(
                clientIdentity, LocalInfo("Test Phone", Platform.ANDROID, "test"), clientTrust,
                listOf("127.0.0.1"), port, QrPairing(token, "0".repeat(64), mine = false), ClientEvents(),
            )
        }
        assertEquals(ErrorCode.AUTH_FAILED, e.code)
        assertEquals(null, clientTrust.get(serverIdentity.deviceId))
    }

    @Test
    fun privateModeOnlyAcceptsPairedDevicesOrQrTokens() {
        privateMode = true
        val e = assertFailsWith<ProtocolException> { transfer(listOf(bytesFile("a.txt", byteArrayOf(1)))).run() }
        assertEquals(ErrorCode.NOT_RECEIVING, e.code)
        assertEquals(null, serverSas, "strangers never see a pairing prompt")

        // A QR token gets through, and afterwards the paired device sends normally.
        val token = server.pairingTokens.issue(mine = false)
        transfer(listOf(bytesFile("a.txt", byteArrayOf(1))), qr = QrPairing(token, serverFingerprint, mine = false)).run()
        assertTrue(completed.await(5, TimeUnit.SECONDS))
        assertEquals(listOf("a.txt"), saved.map { it.displayName })
    }

    @Test
    fun droppedTransferResumesWhereItStopped() {
        val big = ByteArray(3_000_000).also { Random(7).nextBytes(it) }
        // Pair first so both later connections go straight to the offer.
        transfer(listOf(bytesFile("warmup.txt", byteArrayOf(0)))).run()
        assertTrue(completed.await(5, TimeUnit.SECONDS))

        val cut = Proxy(cutAfter = 1_500_000)
        val e = assertFailsWith<ProtocolException> { transfer(listOf(bytesFile("video.bin", big)), toPort = cut.port).run() }
        assertTrue(e.code == ErrorCode.CONNECTION_LOST || e.code == ErrorCode.UNREACHABLE, "got ${e.code}")
        assertTrue(failed.await(5, TimeUnit.SECONDS))
        assertEquals(ErrorCode.CONNECTION_LOST, failures.last())
        assertTrue(dir.toFile().listFiles()!!.any { it.name.startsWith(".crossdrop-resume-") }, "the part so far is kept")

        val count = Proxy()
        transfer(listOf(bytesFile("video.bin", big)), toPort = count.port).run()
        assertContentEquals(big, File(saved.last().location).readBytes())
        assertEquals("video.bin", saved.last().displayName)
        assertTrue(count.forwarded < 2_500_000, "only the rest is sent again (sent ${count.forwarded})")
        assertTrue(dir.toFile().listFiles()!!.none { it.name.startsWith(".crossdrop-") })
    }
}
