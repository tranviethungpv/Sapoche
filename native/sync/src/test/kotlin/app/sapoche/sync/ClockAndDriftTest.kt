package app.sapoche.sync

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ClockSyncTest {

    @Test
    fun `no samples means no sync and zero offset`() {
        val clock = ClockSync()
        assertFalse(clock.hasSync())
        assertEquals(0.0, clock.offsetMs())
        assertNull(clock.bestRttMs())
    }

    @Test
    fun `offset is server time minus the local midpoint of the exchange`() {
        val clock = ClockSync()
        // Sent at local 1000, answered at 1040, server read 6020: midpoint 1020, so offset 5000
        clock.addSample(c0 = 1000, c2 = 1040, s1 = 6020)
        assertEquals(5000.0, clock.offsetMs())
        assertEquals(40.0, clock.bestRttMs())
        assertEquals(6500L, clock.toServer(1500))
        assertEquals(1500L, clock.toLocal(6500))
    }

    @Test
    fun `the lowest latency sample wins`() {
        val clock = ClockSync()
        clock.addSample(0, 400, 5000 + 200 + 90)   // slow and lopsided: offset estimate 5090
        clock.addSample(1000, 1020, 6010)          // fast: offset 5000
        clock.addSample(2000, 2300, 7100)          // slow again
        assertEquals(5000.0, clock.offsetMs())
        assertEquals(20.0, clock.bestRttMs())
    }

    @Test
    fun `old samples fall out of the window`() {
        val clock = ClockSync(windowSize = 3)
        clock.addSample(0, 10, 5005)       // rtt 10, offset 5000
        repeat(3) { clock.addSample(100L * it, 100L * it + 50, 9000) } // rtt 50 each
        assertEquals(50.0, clock.bestRttMs(), "the very fast sample must have expired")
    }

    @Test
    fun `negative round trips are discarded`() {
        val clock = ClockSync()
        clock.addSample(c0 = 1000, c2 = 900, s1 = 5000)
        assertFalse(clock.hasSync())
    }
}

class DriftControllerTest {

    @Test
    fun `inside the deadband nothing happens`() {
        val c = DriftController()
        assertEquals(DriftAction.None, c.decide(0))
        assertEquals(DriftAction.None, c.decide(39))
        assertEquals(DriftAction.None, c.decide(-40))
    }

    @Test
    fun `ahead means slow down and behind means speed up`() {
        assertEquals(DriftAction.SetSpeed(0.97f), DriftController().decide(100))
        assertEquals(DriftAction.SetSpeed(1.03f), DriftController().decide(-100))
    }

    @Test
    fun `beyond the seek threshold it seeks`() {
        assertEquals(DriftAction.Seek, DriftController().decide(401))
        assertEquals(DriftAction.Seek, DriftController().decide(-2000))
    }

    @Test
    fun `speed change holds until nearly aligned then restores`() {
        val c = DriftController()
        assertEquals(DriftAction.SetSpeed(0.97f), c.decide(100))
        assertEquals(DriftAction.None, c.decide(60))   // still correcting, no repeat
        assertEquals(DriftAction.None, c.decide(20))   // above the settle threshold
        assertEquals(DriftAction.SetSpeed(1f), c.decide(10))
        assertEquals(DriftAction.None, c.decide(10))   // back in the deadband
    }

    @Test
    fun `overshooting restores normal speed at once`() {
        val c = DriftController()
        c.decide(100)
        assertEquals(DriftAction.SetSpeed(1f), c.decide(-30))
    }

    @Test
    fun `hysteresis - a drift of 30ms does not restart correction after settling`() {
        val c = DriftController()
        c.decide(100)
        c.decide(5) // settled
        assertEquals(DriftAction.None, c.decide(30))
    }
}

class ProtocolTest {

    @Test
    fun `parses an advance message`() {
        val msg = Protocol.parse("""{"t":"advance","epoch":7,"index":2,"startedAt":1790660600123}""")
        assertIs<ServerMessage.Advance>(msg)
        assertEquals(7L, msg.epoch)
        assertEquals(2, msg.index)
        assertEquals(1790660600123L, msg.startedAt)
    }

    @Test
    fun `builds the queue messages`() {
        assertEquals("""{"t":"jump","id":"q9"}""", Protocol.jump("q9"))
        assertEquals("""{"t":"queue.clear"}""", Protocol.queueClear())
        assertEquals("""{"t":"queue.move","id":"q3","toIndex":0}""", Protocol.queueMove("q3", 0))
        assertEquals(
            """{"t":"queue.swap","id":"q3","track":{"videoId":"vid","title":"T","artist":"A","durMs":5}}""",
            Protocol.queueSwap("q3", TrackRef("vid", "T", "A", null, 5)),
        )
        val next = Protocol.queueAdd("bNp9pn0ni3I", "Song", "Artist", null, 1000, playNext = true)
        assertTrue(next.contains(""""next":true"""), next)
        assertTrue(!Protocol.queueAdd("bNp9pn0ni3I", "Song", "Artist", null, 1000).contains("\"next\""))
    }

    @Test
    fun `builds the playlist and repeat messages`() {
        assertEquals("""{"t":"repeat","mode":"one"}""", Protocol.repeat("one"))
        val many = Protocol.queueAddMany(
            listOf(TrackRef("bNp9pn0ni3I", "A", "X", null, 1000), TrackRef("UoXllQoqEBY", "B", "Y", "http://t/1.jpg", 2000)),
            playNext = true,
        )
        assertEquals(
            """{"t":"queue.addMany","tracks":[{"videoId":"bNp9pn0ni3I","title":"A","artist":"X","durMs":1000},""" +
                """{"videoId":"UoXllQoqEBY","title":"B","artist":"Y","thumb":"http://t/1.jpg","durMs":2000}],"next":true}""",
            many,
        )
    }

    @Test
    fun `repeat defaults to off for a server that does not send it`() {
        val text = """{"t":"state","serverNow":1,"you":"a","state":{"queue":[],"index":0,"phase":"idle","startedAt":0,"positionMs":0,"epoch":0},"members":[]}"""
        assertEquals("off", (Protocol.parse(text) as ServerMessage.State).state.repeat)
        val one = text.replace(""""epoch":0}""", """"epoch":0,"repeat":"one"}""")
        assertEquals("one", (Protocol.parse(one) as ServerMessage.State).state.repeat)
    }

    @Test
    fun `an older server without a protocol field still parses`() {
        val text = """{"t":"state","serverNow":1,"you":"a","state":{"queue":[],"index":0,"phase":"idle","startedAt":0,"positionMs":0,"epoch":0},"members":[]}"""
        val msg = Protocol.parse(text)
        assertIs<ServerMessage.State>(msg)
        assertEquals(0, msg.protocol)
    }

    @Test
    fun `builds the join with and without the create flag`() {
        assertEquals("""{"t":"join","clientId":"c","name":"N"}""", Protocol.join("c", "N"))
        assertEquals("""{"t":"join","clientId":"c","name":"N","create":true}""", Protocol.join("c", "N", create = true))
        assertEquals("""{"t":"join","clientId":"c","name":"N","create":false}""", Protocol.join("c", "N", create = false))
    }

    @Test
    fun `builds the owner and room messages`() {
        assertEquals("""{"t":"bye"}""", Protocol.bye())
        assertEquals("""{"t":"kick","id":"dev-b"}""", Protocol.kick("dev-b"))
        assertEquals("""{"t":"room.name","name":"Family"}""", Protocol.roomName("Family"))
        assertEquals("""{"t":"room.settings","guestControl":"add"}""", Protocol.roomSettings("add"))
    }

    @Test
    fun `parses the owner name and guest control, and an older server without them`() {
        val text = """{"t":"state","serverNow":1,"you":"a","state":{"queue":[],"index":0,"phase":"idle","startedAt":0,"positionMs":0,"epoch":0,"name":"Family","ownerId":"a","guestControl":"add"},"members":[{"id":"a","name":"Anna","ready":false,"owner":true},{"id":"b","name":"Ben","ready":false}]}"""
        val msg = Protocol.parse(text) as ServerMessage.State
        assertEquals("Family", msg.state.name)
        assertEquals("a", msg.state.ownerId)
        assertEquals("add", msg.state.guestControl)
        assertEquals(listOf(true, false), msg.members.map { it.owner })

        val older = Protocol.parse(text.replace(""","name":"Family","ownerId":"a","guestControl":"add"""", "")) as ServerMessage.State
        assertEquals(null, older.state.name)
        assertEquals(null, older.state.ownerId)
        assertEquals("all", older.state.guestControl)
    }

    @Test
    fun `builds an advanced report`() {
        val text = Protocol.advanced(epoch = 4, itemId = "q2", startedAt = 1790660600123)
        assertEquals("""{"t":"advanced","epoch":4,"itemId":"q2","startedAt":1790660600123}""", text)
    }

    @Test
    fun `parses a state message from the server`() {
        val text = """{"t":"state","serverNow":1790660604078,"you":"dev-a","state":{"queue":[{"id":"q1","videoId":"bNp9pn0ni3I","title":"Song","artist":"A","durMs":200000,"addedBy":"dev-a"}],"index":0,"phase":"playing","startedAt":1790660600000,"positionMs":0,"epoch":3},"members":[{"id":"dev-a","name":"Anna","ready":false}]}"""
        val msg = Protocol.parse(text)
        assertIs<ServerMessage.State>(msg)
        assertEquals("playing", msg.state.phase)
        assertEquals("bNp9pn0ni3I", msg.state.current?.videoId)
        assertEquals(1, msg.members.size)
    }

    @Test
    fun `parses transport messages`() {
        assertIs<ServerMessage.Start>(Protocol.parse("""{"t":"start","epoch":2,"startAt":1000,"positionMs":500}"""))
        assertIs<ServerMessage.Pause>(Protocol.parse("""{"t":"pause","epoch":2,"positionMs":500}"""))
        assertIs<ServerMessage.Pong>(Protocol.parse("""{"t":"pong","c0":1,"s1":2}"""))
        val prepare = Protocol.parse("""{"t":"prepare","epoch":2,"index":0,"item":{"id":"q","videoId":"bNp9pn0ni3I","title":"T","artist":"A","durMs":1000,"addedBy":"x"},"seekToMs":0}""")
        assertIs<ServerMessage.Prepare>(prepare)
    }

    @Test
    fun `unknown or broken input yields null instead of throwing`() {
        assertNull(Protocol.parse("not json"))
        assertNull(Protocol.parse("""{"t":"something-new"}"""))
        assertNull(Protocol.parse("""{"t":"start","epoch":"x"}"""))
        assertNull(Protocol.parse("""{"no":"type"}"""))
    }

    @Test
    fun `client messages are valid JSON with the expected type`() {
        val join = Protocol.join("dev-a", "Anna")
        assertTrue(join.contains("\"t\":\"join\"") && join.contains("\"clientId\":\"dev-a\""))
        val add = Protocol.queueAdd("bNp9pn0ni3I", "Song", "Artist", null, 200000)
        assertNotNull(add)
        assertFalse(add.contains("thumb"))
        assertTrue(Protocol.ready(7).contains("\"epoch\":7"))
    }
}

class DriftFilterTest {

    @Test
    fun `averages a sawtooth down to its mean`() {
        val f = DriftFilter(size = 8)
        // Sawtooth around -200ms: rises 65ms per sample then drops
        val wave = listOf(-318L, -256, -192, -122, -323, -255, -191, -130)
        wave.forEachIndexed { i, d -> f.add(i * 500L, d) }
        val estimate = f.estimate(8 * 500L)!!
        assertTrue(kotlin.math.abs(estimate - (-224)) < 15, "estimate $estimate")
    }

    @Test
    fun `is not full until the window fills`() {
        val f = DriftFilter(size = 4, minSamplesForLargeDrift = 2)
        f.add(0, 100)
        assertTrue(!f.isFull && !f.hasLargeDriftEvidence)
        f.add(500, 100)
        assertTrue(!f.isFull && f.hasLargeDriftEvidence)
        f.add(1000, 100)
        f.add(1500, 100)
        assertTrue(f.isFull)
    }

    @Test
    fun `speed changes are not mistaken for drift`() {
        val f = DriftFilter(size = 4)
        f.setSpeed(0, 0.97f)
        // True uncorrected drift is a constant +100ms; slowing by 3% removes 15ms per 500ms
        for (i in 1..4) f.add(i * 500L, 100 - 15L * i)
        val estimate = f.estimate(2000)!!
        assertTrue(kotlin.math.abs(estimate - 40) < 2, "estimate $estimate")
    }

    @Test
    fun `reset forgets old readings`() {
        val f = DriftFilter()
        f.add(0, 500)
        f.reset(1000)
        assertEquals(null, f.estimate(1000))
    }
}
