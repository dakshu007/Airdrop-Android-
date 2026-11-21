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
    @Volatile var acceptCapture = true
    private val captures = Collections.synchronizedList(ArrayList<CaptureRequest>())
    private val finished = Collections.synchronizedList(ArrayList<IncomingTransfer>())

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
        override fun onCompleted(transfer: IncomingTransfer) {
            finished.add(transfer)
            completed.countDown()
        }
        override fun onCaptureRequest(peer: PeerInfo, request: CaptureRequest): Boolean {
            captures.add(request)
            return acceptCapture
        }
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
        expiresAfter: Long? = null,
        room: Room? = null,
        identity: IdentityKey = clientIdentity,
        trust: TrustStore = clientTrust,
    ) = OutgoingTransfer(
        identity, LocalInfo("Test Phone", Platform.ANDROID, "test"), trust, "127.0.0.1", toPort,
        serverIdentity.deviceId, files, ev, kind = kind, qr = qr, expiresAfter = expiresAfter, room = room,
    )

    private val clientLocal = LocalInfo("Test Phone", Platform.ANDROID, "test")

    /** Events that fail the test if any prompt is shown. */
    private val noPrompt = object : SenderEvents {
        override fun onStage(stage: SendStage) {}
        override fun onPairingPrompt(prompt: PairingPrompt) = error("must not prompt")
        override fun onPairingClosed(prompt: PairingPrompt, paired: Boolean) {}
    }

    /** A second server: the requester's own receiver, which gets the answer to a capture request (§9.7). */
    private inner class Requester {
        val dir: java.nio.file.Path = Files.createTempDirectory("crossdrop-requester")
        @Volatile var acceptOffer = false
        val prompts = Collections.synchronizedList(ArrayList<IncomingOffer>())
        val done = Collections.synchronizedList(ArrayList<IncomingTransfer>())
        val server = CrossDropServer(
            clientIdentity, { LocalInfo("Test Mac", Platform.MACOS, "test") }, clientTrust, DirectoryStorage(dir),
            object : ReceiverEvents {
                override fun isReceiving() = true
                override fun onPairingPrompt(prompt: PairingPrompt) = prompt.respond(true)
                override fun onPairingClosed(prompt: PairingPrompt, paired: Boolean) {}
                override fun onOffer(offer: IncomingOffer) {
                    prompts.add(offer)
                    offer.respond(acceptOffer)
                }
                override fun onCompleted(transfer: IncomingTransfer) { done.add(transfer) }
            },
        )
        val port = server.start(0, InetAddress.getLoopbackAddress())

        /** Sends [data] to the requester as [fromIdentity] (trusting via [fromTrust]), answering [requestId]. */
        fun answer(requestId: String?, fromIdentity: IdentityKey = serverIdentity, fromTrust: TrustStore = serverTrust, expected: String? = clientIdentity.deviceId) =
            OutgoingTransfer(
                fromIdentity, LocalInfo("Phone", Platform.ANDROID, "test"), fromTrust, "127.0.0.1", port, expected,
                listOf(bytesFile("photo.jpg", byteArrayOf(1, 2, 3))), ClientEvents(), requestId = requestId,
            ).run()

        fun close() {
            server.stop()
            dir.toFile().deleteRecursively()
        }
    }

    private fun requestCapture(r: Requester, kind: CaptureKind = CaptureKind.PHOTO) =
        CaptureClient.request(clientIdentity, clientLocal, clientTrust, "127.0.0.1", port, serverIdentity.deviceId, kind, r.port, r.server.captureRequests)

    private fun pairClientWithServer() {
        transfer(listOf(bytesFile("warmup.txt", byteArrayOf(0)))).run()
        assertTrue(completed.await(5, TimeUnit.SECONDS))
    }

    /** Sends a hand-made `transfer.offer` with [extra] fields as the (paired) client; returns the server's answer. */
    private fun rawOffer(extra: Map<String, Any?>): Message {
        val c = Connection(Socket("127.0.0.1", port))
        try {
            Handshake.client(c, clientIdentity, clientLocal, clientTrust)
            val offer = Message.build(
                "transfer.offer", "transferId" to "raw-offer-1",
                "files" to listOf(mapOf("fileId" to 0, "name" to "a.txt", "size" to 1, "sha256" to "0".repeat(64))),
            ) as MutableMap<String, Any?>
            offer.putAll(extra)
            c.sendControl(offer)
            return (c.next(5_000) as Connection.Incoming.Control).message
        } finally {
            c.close()
        }
    }

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
        // The client returns once it has the server's confirmation; the server stores
        // trust when it reads the client's, a moment later.
        val deadline = System.currentTimeMillis() + 3000
        while (serverTrust.get(clientIdentity.deviceId) == null && System.currentTimeMillis() < deadline) Thread.sleep(20)
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

    // ---- §9.7 capture requests ----

    @Test
    fun captureRequestIsAcceptedAndItsAnswerArrivesWithoutPromptOnce() {
        pairClientWithServer()
        val r = Requester()
        try {
            val id = requestCapture(r)
            assertEquals(1, captures.size)
            val req = captures[0]
            assertEquals(id, req.requestId)
            assertEquals(CaptureKind.PHOTO, req.kind)
            assertEquals(clientIdentity.deviceId, req.peer.deviceId)
            assertEquals("127.0.0.1", req.replyHost)
            assertEquals(r.port, req.replyPort)
            assertEquals(1, r.server.captureRequests.outstanding)

            // The phone answers: accepted without a prompt (the requester would decline one).
            r.answer(id)
            assertTrue(r.prompts.isEmpty())
            assertEquals(id, r.done.single().requestId)

            // Single use: the same requestId again is just a normal offer, which is prompted (and declined).
            val e = assertFailsWith<TransferRejectedException> { r.answer(id) }
            assertEquals("declined", e.reason)
            assertEquals(1, r.prompts.size)
            assertEquals(null, r.prompts[0].requestId)
        } finally {
            r.close()
        }
    }

    @Test
    fun captureAnswerOnlyCountsFromTheDeviceItWasSentTo() {
        pairClientWithServer()
        val r = Requester()
        val otherIdentity = SoftwareIdentity.generate().first
        val otherTrust = InMemoryTrustStore()
        try {
            // Another device the requester has also paired with.
            r.acceptOffer = true
            r.answer(null, otherIdentity, otherTrust)
            r.acceptOffer = false
            r.prompts.clear()

            val id = requestCapture(r)
            val e = assertFailsWith<TransferRejectedException> { r.answer(id, otherIdentity, otherTrust) }
            assertEquals("declined", e.reason)
            assertEquals(1, r.prompts.size, "a foreign requestId is ignored, so the offer is prompted")
            // The real device still gets its answer through.
            r.answer(id)
            assertEquals(1, r.prompts.size)
            assertEquals(id, r.done.last().requestId)
        } finally {
            r.close()
        }
    }

    @Test
    fun declinedCaptureRequestIsForgotten() {
        pairClientWithServer()
        acceptCapture = false
        val r = Requester()
        try {
            val e = assertFailsWith<TransferRejectedException> { requestCapture(r, CaptureKind.PICK) }
            assertEquals("declined", e.reason)
            assertEquals(CaptureKind.PICK, captures.single().kind)
            assertEquals(0, r.server.captureRequests.outstanding)
        } finally {
            r.close()
        }
    }

    @Test
    fun captureRequestFromUnpairedDeviceIsRefused() {
        val r = Requester()
        try {
            // Not paired on either side: the client refuses to ask.
            val local = assertFailsWith<ProtocolException> { requestCapture(r) }
            assertEquals(ErrorCode.PAIRING_REQUIRED, local.code)
            // The client trusts the server, but the server doesn't know the client: pairing_required, no pairing.
            clientTrust.trust(PeerInfo(serverIdentity.deviceId, "Test Mac", Platform.MACOS, "t", serverIdentity.publicKey))
            val e = assertFailsWith<ProtocolException> { requestCapture(r) }
            assertEquals(ErrorCode.PAIRING_REQUIRED, e.code)
            assertTrue(e.remote)
            assertTrue(captures.isEmpty())
            assertEquals(null, serverTrust.get(clientIdentity.deviceId))
            assertEquals(null, serverSas)
            assertEquals(0, r.server.captureRequests.outstanding)
        } finally {
            r.close()
        }
    }

    @Test
    fun captureRequestsExpireAndAreBoundToOneDevice() {
        val reqs = CaptureRequests()
        reqs.expect("request-0001", "a".repeat(32))
        assertEquals(false, reqs.redeem("request-0001", "b".repeat(32)))
        assertEquals(true, reqs.redeem("request-0001", "a".repeat(32)))
        assertEquals(false, reqs.redeem("request-0001", "a".repeat(32)))
        reqs.expect("request-0002", "a".repeat(32), ttlMs = -1)
        assertEquals(false, reqs.redeem("request-0002", "a".repeat(32)))
        assertFailsWith<IllegalArgumentException> { reqs.expect("bad id!", "a".repeat(32)) }
    }

    // ---- §9.8 expiring drops ----

    @Test
    fun expiresAfterRoundTripsAndOutOfRangeIsRejected() {
        transfer(listOf(bytesFile("a.txt", byteArrayOf(1))), expiresAfter = 3600).run()
        assertTrue(completed.await(5, TimeUnit.SECONDS))
        assertEquals(3600L, finished.single().expiresAfter)

        assertFailsWith<IllegalArgumentException> { transfer(listOf(bytesFile("a.txt", byteArrayOf(1))), expiresAfter = 59) }
        assertFailsWith<IllegalArgumentException> { transfer(listOf(bytesFile("a.txt", byteArrayOf(1))), expiresAfter = 2_592_001) }
        for (bad in listOf<Any>(59L, 2_592_001L, "3600", 60.5)) {
            val answer = rawOffer(mapOf("expiresAfter" to bad))
            assertEquals("error", answer.type)
            assertEquals("bad_message", answer.fields["code"])
        }
        val badRequestId = rawOffer(mapOf("requestId" to "no spaces allowed"))
        assertEquals("bad_message", badRequestId.fields["code"])
    }

    // ---- §9.9 Drip Rooms ----

    @Test
    fun roomPairsWithoutPromptsAndTrustIsTemporary() {
        val room = server.rooms.create("Standup", 3600)
        acceptPairing = false // the server must not ask its user
        val ev = object : SenderEvents by noPrompt {
            val stages = Collections.synchronizedList(ArrayList<SendStage>())
            override fun onStage(stage: SendStage) { stages.add(stage) }
        }
        transfer(listOf(bytesFile("slides.pdf", byteArrayOf(1, 2))), ev, room = room).run()
        assertTrue(completed.await(5, TimeUnit.SECONDS))
        assertTrue(SendStage.PAIRING in ev.stages)
        assertEquals(null, serverSas)
        val onServer = assertNotNull(serverTrust.get(clientIdentity.deviceId))
        val onClient = assertNotNull(clientTrust.get(serverIdentity.deviceId))
        assertEquals(room.expiresAtMillis, onServer.expiresAt)
        assertEquals(room.expiresAtMillis, onClient.expiresAt)
        assertEquals(false, onServer.autoAccept)

        // When the room ends, so does the trust: the next transfer has to pair again, with codes.
        serverTrust.trust(PeerInfo(clientIdentity.deviceId, "Test Phone", Platform.ANDROID, "t", clientIdentity.publicKey), false, System.currentTimeMillis() - 1)
        assertEquals(null, serverTrust.get(clientIdentity.deviceId))
        acceptPairing = true
        transfer(listOf(bytesFile("b.txt", byteArrayOf(3)))).run()
        assertNotNull(serverSas, "expired room trust means comparing codes again")
        assertEquals(null, serverTrust.get(clientIdentity.deviceId)?.expiresAt)
    }

    @Test
    fun wrongRoomKeyFallsBackToCodeComparison() {
        val room = server.rooms.create("Standup", 3600)
        val forged = Room(room.id, ByteArray(32) { 9 }, room.name, room.expiresAt)
        val ev = ClientEvents()
        transfer(listOf(bytesFile("a.txt", byteArrayOf(1))), ev, room = forged).run()
        assertTrue(completed.await(5, TimeUnit.SECONDS))
        assertNotNull(serverSas)
        assertEquals(ev.sas, serverSas)
        assertEquals(null, serverTrust.get(clientIdentity.deviceId)?.expiresAt, "code-compared trust is permanent")
    }

    @Test
    fun privateModeAcceptsRoomProofAndRoomCodeNamesTheHost() {
        privateMode = true
        val room = server.rooms.create("Standup", 3600)
        val invite = RoomInvite(room, listOf("127.0.0.1"), port, serverFingerprint)
        val parsed = assertNotNull(RoomInvite.parse(invite.toUri()))

        // A code naming another device's key is refused before pairing.
        val wrongHost = RoomInvite(parsed.room, parsed.hosts, parsed.port, "0".repeat(64))
        val e = assertFailsWith<ProtocolException> { RoomPairingClient.pairOnly(clientIdentity, clientLocal, clientTrust, wrongHost, noPrompt) }
        assertEquals(ErrorCode.AUTH_FAILED, e.code)

        acceptPairing = false
        val peer = RoomPairingClient.pairOnly(clientIdentity, clientLocal, clientTrust, parsed, noPrompt)
        assertEquals(serverIdentity.deviceId, peer.deviceId)
        val deadline = System.currentTimeMillis() + 3000
        while (serverTrust.get(clientIdentity.deviceId) == null && System.currentTimeMillis() < deadline) Thread.sleep(20)
        assertEquals(room.expiresAtMillis, serverTrust.get(clientIdentity.deviceId)?.expiresAt)
        // Now a (temporary) paired device, it gets through "My devices only".
        transfer(listOf(bytesFile("a.txt", byteArrayOf(1))), noPrompt).run()
        assertTrue(completed.await(5, TimeUnit.SECONDS))
        assertEquals(null, serverSas)
    }
}
