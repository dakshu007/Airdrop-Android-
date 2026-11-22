package com.crossdrop.core

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Drip Room codes, hints and proofs (§9.9). The fixed values are shared with the Swift tests. */
class RoomsTest {
    private val id = "AAECAwQFBgcICQoLDA0ODw"
    private val key = ByteArray(32) { it.toByte() }
    private val exp = 1_800_000_000L
    private val now = exp - 3600
    private val fp = "ab".repeat(32)
    private val vectorUri = "crossdrop://room?v=1&id=AAECAwQFBgcICQoLDA0ODw&k=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8" +
        "&n=Team%20%26%20Sync%20%C3%BC&exp=1800000000&h=192.168.1.5%2Cfe80%3A%3A1%25en0&p=47100&fp=$fp"

    @Test
    fun buildsTheSharedVectorAndParsesItBack() {
        val invite = RoomInvite(Room(id, key, "Team & Sync ü", exp), listOf("192.168.1.5", "fe80::1%en0"), 47100, fp)
        assertEquals(vectorUri, invite.toUri())
        val parsed = assertNotNull(RoomInvite.parse(vectorUri, now))
        assertEquals(invite, parsed)
        assertContentEquals(key, parsed.room.key)
        assertEquals("Team & Sync ü", parsed.room.name)
        assertEquals(listOf("192.168.1.5", "fe80::1%en0"), parsed.hosts)
    }

    @Test
    fun hintAndProofsMatchVectors() {
        assertEquals("da19855d5fe9499b", Rooms.hint(id))
        val room = Room(id, key, "Room", exp)
        val th = ByteArray(32) { 0xab.toByte() }
        assertEquals("qGg0p52/zxclCMSFDlqgy6i0tL7dfuGc5AG1BGVwABk=", B64.encode(room.proof(th)))
        assertEquals("rLFTyt2qSBO6Y4akuh0ZM9XOeQgI+QtvAGidEQFTgGc=", B64.encode(room.confirmProof(th)))
        assertEquals(
            mapOf("v" to "1", "id" to "a".repeat(32), "p" to "android", "m" to "1", "r" to "da19855d5fe9499b"),
            Discovery.txtAttributes("a".repeat(32), Platform.ANDROID, true, listOf("da19855d5fe9499b", "nothex")),
        )
        assertEquals(listOf("da19855d5fe9499b", "0011223344556677"), Rooms.parseHints("da19855d5fe9499b, 0011223344556677,zz"))
        assertEquals(emptyList(), Rooms.parseHints(null))
        // Only ASCII spaces around a hint are ignored (identical to the Swift core).
        assertEquals(listOf("da19855d5fe9499b"), Rooms.parseHints("da19855d5fe9499b,\n0011223344556677,\t0011223344556677"))
    }

    @Test
    fun rejectsMalformedCodes() {
        fun variant(from: String, to: String) = vectorUri.replace(from, to).also { check(it != vectorUri || from == to) }
        val bad = listOf(
            "https://example.com/?v=1",
            vectorUri.replace("crossdrop://room?", "crossdrop://pair?"),
            variant("v=1", "v=2"),
            variant("id=AAECAwQFBgcICQoLDA0ODw", "id=AAECAwQFBgcICQoLDA0OD"), // 15.x bytes
            variant("id=AAECAwQFBgcICQoLDA0ODw", "id=AAECAwQFBgcICQoLDA0ODx"), // not canonical
            variant("id=AAECAwQFBgcICQoLDA0ODw", "id=AAECAwQFBgcICQoLDA0OD+"),
            variant("k=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8", "k=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh"),
            variant("exp=1800000000", "exp=1799996400"), // expired at `now`
            variant("exp=1800000000", "exp=1800014401"), // more than 4 h (+ skew) ahead
            variant("exp=1800000000", "exp=-5"),
            variant("&h=192.168.1.5%2Cfe80%3A%3A1%25en0", ""),
            variant("h=192.168.1.5", "h=192.168.1.5%2F..%2F"),
            variant("%2Cfe80", "%2C%0Afe80"), // newline before a host: no trimming
            variant("%2Cfe80", "%2C%20fe80"), // space before a host: no trimming
            variant("p=47100", "p=0"),
            variant("p=47100", "p=70000"),
            variant("fp=$fp", "fp=${fp.uppercase()}"),
            variant("fp=$fp", "fp=abc"),
            "$vectorUri&v=1", // duplicate key
            vectorUri.replace("n=Team%20", "n=Team%2"), // broken escape
            vectorUri.replace("n=Team", "n=Te am"), // raw space
            vectorUri + "&" + "x".repeat(2100),
        )
        for (raw in bad) assertNull(RoomInvite.parse(raw, now), raw)
        // Unknown keys are ignored; a missing name becomes "Room".
        assertNotNull(RoomInvite.parse("$vectorUri&future=1", now))
        assertEquals("Room", RoomInvite.parse(vectorUri.replace("&n=Team%20%26%20Sync%20%C3%BC", ""), now)?.room?.name)
    }

    @Test
    fun registryCreatesJoinsAndExpiresRooms() {
        val rooms = Rooms()
        val made = rooms.create("  Design\u0000 review ", 600)
        assertEquals("Design review", made.name)
        assertTrue(Rooms.isValidId(made.id))
        assertEquals(32, made.key.size)
        assertEquals(made, rooms.get(made.id))
        assertEquals(listOf(made.hint), rooms.hints())
        assertEquals(made, rooms.forHint(made.hint))
        assertFailsWith<IllegalArgumentException> { rooms.create("x", Protocol.ROOM_MAX_TTL_S + 1) }

        val nowS = System.currentTimeMillis() / 1000
        assertEquals(false, rooms.join(Room(id, key, "Old", nowS - 1)))
        assertEquals(false, rooms.join(Room(id, key, "Too long", nowS + Protocol.ROOM_MAX_TTL_S + Protocol.ROOM_CLOCK_SKEW_S + 60)))
        assertTrue(rooms.join(Room(id, key, "Short", nowS + 2)))
        assertNotNull(rooms.get(id))
        Thread.sleep(3100)
        assertNull(rooms.get(id))
        assertEquals(listOf(made), rooms.active())
        rooms.leave(made.id)
        assertTrue(rooms.active().isEmpty())
    }

    @Test
    fun expiredTrustIsUntrusted() {
        val store = InMemoryTrustStore()
        val identity = SoftwareIdentity.generate().first
        val peer = PeerInfo(identity.deviceId, "Phone", Platform.ANDROID, "t", identity.publicKey)
        store.trust(peer, false, System.currentTimeMillis() + 60_000)
        assertNotNull(store.get(peer.deviceId))
        store.trust(peer, false, System.currentTimeMillis() - 1)
        assertNull(store.get(peer.deviceId))
        store.trust(peer, true)
        assertEquals(null, store.get(peer.deviceId)?.expiresAt)
        assertTrue(store.supportsTrustExpiry)
    }
}
