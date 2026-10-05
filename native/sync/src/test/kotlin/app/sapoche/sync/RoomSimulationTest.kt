package app.sapoche.sync

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlin.math.abs
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Whole rooms of simulated phones, each running the real [GroupSession] and [ClockSync] against a small room that
 * follows the server's rules (barrier, start lead, pause, seek, gapless advance). Virtual time is the truth: the room's
 * clock reads it, every phone's own clock is off by an offset and runs a few parts per million fast or slow, links are
 * asymmetric with jitter, speakers start late, the audio clock drifts, and the position a player reports carries the
 * sawtooth noise measured on real phones. What is asserted is what people would hear: how far apart the phones are.
 *
 * Bars: each phone within 40 ms of the room once settled (the drift controller's own dead band; Jellyfin SyncPlay
 * only starts correcting at 60 ms). Two phones may then be up to 80 ms apart by design; the spread between them is held
 * to 60 ms at the 95th percentile (at about 40 ms two speakers in one room start to sound like an echo, so a tighter
 * dead band is the knob if that matters). A newcomer in step within 5 seconds (docs/PLAN.md), no gap at a natural
 * change of song. Everything runs on virtual time with fixed seeds, so the numbers are the same on every run; each
 * scenario prints them with a [sim] prefix.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class RoomSimulationTest {

    // ------------------------------------------------------------------ the room

    /** One phone's link: messages each way arrive in order, after a base delay plus jitter. */
    private class Link(val upMs: Long, val downMs: Long, val jitterMs: Long, val random: Random) {
        var cut = false
        private var lastUp = 0L
        private var lastDown = 0L

        fun upAt(now: Long): Long = maxOf(lastUp, now + upMs + random.nextLong(jitterMs + 1)).also { lastUp = it }
        fun downAt(now: Long): Long = maxOf(lastDown, now + downMs + random.nextLong(jitterMs + 1)).also { lastDown = it }
    }

    /** The parts of the server that decide timing, written after server/src/room.ts. */
    private class Room(private val scope: CoroutineScope, private val now: () -> Long, val queue: List<QueueItem>) {
        val phones = mutableListOf<Phone>()
        var index = 0
        var phase = "idle"
        var startedAt = 0L
        var positionMs = 0L
        var epoch = 0L
        private val ready = mutableSetOf<Phone>()
        /** The round trip each phone last reported with its pings, as the server keeps it. */
        private val rtt = mutableMapOf<Phone, Long>()
        var lastLeadMs = LEAD_MS
        private var barrier: Job? = null
        private var end: Job? = null
        var prepares = 0
        var advances = 0

        fun state(phone: Phone) = ServerMessage.State(
            serverNow = now(),
            you = phone.id,
            state = RoomState(queue, index, phase, startedAt, positionMs, epoch),
            members = phones.map { Member(it.id, it.id, ready = it in ready) },
            protocol = 9,
        )

        private fun broadcast(message: (Phone) -> ServerMessage) = phones.forEach { it.deliver(message(it)) }

        fun begin(at: Int, seekToMs: Long = 0) {
            index = at
            epoch++
            phase = "preparing"
            positionMs = seekToMs
            ready.clear()
            end?.cancel()
            barrier?.cancel()
            barrier = scope.launch {
                delay(BARRIER_TIMEOUT_MS)
                if (phase == "preparing") startPlayback()
            }
            prepares++
            broadcast { state(it) }
            broadcast { ServerMessage.Prepare(epoch, index, queue[index], seekToMs) }
        }

        private fun startPlayback() {
            barrier?.cancel()
            lastLeadMs = if (phones.all { it in rtt }) (phones.maxOf { rtt.getValue(it) } + LEAD_MARGIN_MS).coerceIn(MIN_LEAD_MS, LEAD_MS) else LEAD_MS
            val startAt = now() + lastLeadMs
            phase = "playing"
            startedAt = startAt - positionMs
            ready.clear()
            scheduleEnd()
            broadcast { ServerMessage.Start(epoch, startAt, positionMs) }
        }

        private fun scheduleEnd() {
            end?.cancel()
            val item = queue[index]
            end = scope.launch {
                delay(startedAt + item.durMs + END_GRACE_MS - now())
                if (phase == "playing") next()
            }
        }

        fun next() {
            if (index + 1 < queue.size) begin(index + 1) else {
                phase = "idle"
                epoch++
                end?.cancel()
                broadcast { state(it) }
            }
        }

        fun pause() {
            if (phase != "playing") return
            positionMs = now() - startedAt
            phase = "paused"
            epoch++
            end?.cancel()
            broadcast { ServerMessage.Pause(epoch, positionMs) }
        }

        fun play() {
            if (phase != "paused") return
            epoch++
            startPlayback()
        }

        fun seek(to: Long) {
            positionMs = to
            when (phase) {
                "playing" -> {
                    epoch++
                    startPlayback()
                }
                "paused" -> {
                    epoch++
                    broadcast { ServerMessage.Pause(epoch, positionMs) }
                }
            }
        }

        /** A message from [phone], as the server would take it. */
        fun receive(phone: Phone, text: String) {
            val msg = Json.parseToJsonElement(text).jsonObject
            fun long(key: String) = msg[key]!!.jsonPrimitive.long
            when (msg["t"]!!.jsonPrimitive.content) {
                "ping" -> {
                    msg["rtt"]?.let { rtt[phone] = it.jsonPrimitive.long }
                    phone.deliver(ServerMessage.Pong(long("c0"), now()))
                }
                "ready" -> if (phase == "preparing" && long("epoch") == epoch) {
                    ready += phone
                    if (phones.all { it in ready }) startPlayback()
                }
                "ended" -> if (phase == "playing" && long("epoch") == epoch && now() - startedAt >= queue[index].durMs - 5000) next()
                "advanced" -> {
                    val itemId = msg["itemId"]!!.jsonPrimitive.content
                    val at = long("startedAt")
                    val nextItem = queue.getOrNull(index + 1)
                    val plausible = at <= now() + 500 && at >= now() - 10_000 && now() - startedAt >= queue[index].durMs - 15_000
                    if (phase == "playing" && long("epoch") == epoch && nextItem?.id == itemId && plausible) {
                        index++
                        epoch++
                        positionMs = 0
                        startedAt = at
                        advances++
                        scheduleEnd()
                        broadcast { ServerMessage.Advance(epoch, index, startedAt) }
                    }
                }
                "resync" -> phone.deliver(state(phone))
            }
        }

        /** Where the room is heard right now, by its own clock. */
        fun roomPositionMs(): Long = if (phase == "playing") now() - startedAt else positionMs

        companion object {
            const val LEAD_MS = 1500L
            const val MIN_LEAD_MS = 600L
            const val LEAD_MARGIN_MS = 400L
            const val BARRIER_TIMEOUT_MS = 8000L
            const val END_GRACE_MS = 5000L
        }
    }

    // ------------------------------------------------------------------ a phone

    /**
     * A player with a speaker that starts [startLatencyMs] after play(), an audio clock running at [audioRate] of real
     * time, seeks that take [seekCostMs], loads that take [loadMs], and a reported position with a sawtooth error of
     * [noiseMs] peak to peak (3.5 s period) on top of what is really heard.
     */
    private class SimPlayer(
        private val now: () -> Long,
        private val audioRate: Double,
        private val startLatencyMs: Long,
        private val seekCostMs: Long,
        var loadMs: Long,
        private val noiseMs: Long,
        private val noisePhase: Long,
    ) : PlayerPort {
        var loaded: QueueItem? = null
        private var next: QueueItem? = null
        private var heard = 0.0
        private var playing = false
        private var audibleFrom = 0L
        private var speed = 1.0
        private var last = 0L

        override var onEnded: (() -> Unit)? = null
        override var onAdvanced: (() -> Unit)? = null
        override var onError: ((Exception) -> Unit)? = null

        private fun advance() {
            val t = now()
            if (playing) {
                val from = maxOf(last, audibleFrom)
                if (t > from) heard += (t - from) * speed * audioRate
            }
            last = t
        }

        /** True when sound is coming out. */
        val audible: Boolean get() = playing && now() >= audibleFrom && loaded != null

        /** The position of what is coming out of the speaker now. */
        fun heardMs(): Double {
            advance()
            return heard
        }

        /** Runs the end of an item: the queued one carries on with no gap, or the player stops. */
        fun tick() {
            advance()
            val item = loaded ?: return
            if (!playing || heard < item.durMs) return
            val successor = next
            if (successor != null) {
                heard -= item.durMs
                loaded = successor
                next = null
                onAdvanced?.invoke()
            } else {
                playing = false
                onEnded?.invoke()
            }
        }

        override suspend fun prepare(item: QueueItem, seekToMs: Long) {
            delay(loadMs)
            advance()
            loaded = item
            next = null
            heard = seekToMs.toDouble()
            playing = false
        }

        override fun refresh(videoId: String) = Unit

        override suspend fun seekTo(positionMs: Long) {
            advance()
            val wasPlaying = playing
            playing = false // silent while the seek runs
            delay(seekCostMs)
            advance()
            heard = positionMs.toDouble()
            playing = wasPlaying || playing
            if (playing) audibleFrom = now() + startLatencyMs / 3
        }

        override fun play() {
            advance()
            if (playing) return
            playing = true
            audibleFrom = now() + startLatencyMs
        }

        override fun pause() {
            advance()
            playing = false
        }

        override fun stop() {
            pause()
            loaded = null
        }

        override fun setSpeed(speed: Float) {
            advance()
            this.speed = speed.toDouble()
        }

        override fun setNext(item: QueueItem?) {
            if (loaded != null) next = item
        }

        override fun positionMs(): Long {
            advance()
            if (noiseMs == 0L) return heard.toLong()
            val phase = ((now() + noisePhase) % NOISE_PERIOD_MS).toDouble() / NOISE_PERIOD_MS
            return (heard + (phase - 0.5) * noiseMs).toLong()
        }

        override fun isPlaying(): Boolean = playing

        companion object {
            const val NOISE_PERIOD_MS = 3500L
        }
    }

    /** What makes one phone differ from another. */
    private data class Profile(
        val clockOffsetMs: Long,
        val clockPpm: Double = 0.0,
        val audioPpm: Double = 0.0,
        val upMs: Long = 40,
        val downMs: Long = 40,
        val jitterMs: Long = 20,
        val startLatencyMs: Long = 250,
        val seekCostMs: Long = 80,
        val loadMs: Long = 900,
        val noiseMs: Long = 200,
    )

    private inner class Phone(val id: String, val scope: TestScope, val room: Room, profile: Profile, random: Random) {
        private val t0 = scope.currentTime
        // A monotonic clock counts from boot, so it is never negative: this phone booted [BOOT_MS] before the room's zero
        val nowLocal: () -> Long = { BOOT_MS + profile.clockOffsetMs + ((scope.currentTime - t0) * (1 + profile.clockPpm / 1e6)).toLong() + t0 }
        val link = Link(profile.upMs, profile.downMs, profile.jitterMs, random)
        val clock = ClockSync()
        val player = SimPlayer(
            now = { scope.currentTime },
            audioRate = 1 + profile.audioPpm / 1e6,
            startLatencyMs = profile.startLatencyMs,
            seekCostMs = profile.seekCostMs,
            loadMs = profile.loadMs,
            noiseMs = profile.noiseMs,
            noisePhase = random.nextLong(SimPlayer.NOISE_PERIOD_MS),
        )
        var debug = false
        val session = GroupSession(scope.backgroundScope, player, clock, nowLocal, ::send, log = { if (debug) println("[$id ${scope.currentTime}] $it") })

        /** How wrong this phone's idea of the room's clock is right now, in ms. */
        fun clockErrorMs(): Double = clock.toServer(nowLocal()) - scope.currentTime.toDouble()

        private fun send(text: String) {
            if (link.cut) return
            val at = link.upAt(scope.currentTime)
            scope.backgroundScope.launch {
                delay(at - scope.currentTime)
                room.receive(this@Phone, text)
            }
        }

        fun deliver(message: ServerMessage) {
            if (link.cut) return
            val at = link.downAt(scope.currentTime)
            scope.backgroundScope.launch {
                delay(at - scope.currentTime)
                if (message is ServerMessage.Pong) clock.addSample(message.c0, nowLocal(), message.s1) else session.onMessage(message)
            }
        }

        /** The connection layer: a burst of pings to sync the clock, then one every 30 seconds, as RoomClient does. */
        fun connect() {
            scope.backgroundScope.launch {
                repeat(8) {
                    send(Protocol.ping(nowLocal(), clock.bestRttMs()))
                    delay(250)
                }
                while (isActive) {
                    delay(30_000)
                    send(Protocol.ping(nowLocal(), clock.bestRttMs()))
                }
            }
            scope.backgroundScope.launch {
                while (isActive) {
                    delay(20)
                    player.tick()
                }
            }
        }

        /**
         * How far what this phone plays is from where the room is, in ms; null when it is silent. A phone that already
         * moved on to the next song by itself, before the room heard about it, is compared with where that song started.
         */
        fun errorMs(): Double? {
            if (!player.audible || room.phase != "playing") return null
            val current = room.queue[room.index]
            return when (player.loaded?.id) {
                current.id -> player.heardMs() - room.roomPositionMs()
                room.queue.getOrNull(room.index + 1)?.id -> player.heardMs() - (room.roomPositionMs() - current.durMs)
                else -> null
            }
        }
    }

    // ------------------------------------------------------------------ measuring

    /** Spread between the phones (max minus min of their errors) and each phone's own error, sampled over time. */
    private class Stats {
        val spreads = mutableListOf<Double>()
        val errors = mutableListOf<Double>()
        val clockErrors = mutableListOf<Double>()
        var silentSamples = 0

        fun p(values: List<Double>, q: Double): Double = values.sorted().let { if (it.isEmpty()) Double.NaN else it[((it.size - 1) * q).toInt()] }
        fun spreadP50() = p(spreads, 0.5)
        fun spreadP95() = p(spreads, 0.95)
        fun spreadMax() = spreads.maxOrNull() ?: Double.NaN
        fun errorP95() = p(errors.map { abs(it) }, 0.95)
        fun clockP95() = p(clockErrors.map { abs(it) }, 0.95)
        override fun toString() =
            "spread p50=${spreadP50().toInt()}ms p95=${spreadP95().toInt()}ms max=${spreadMax().toInt()}ms, |error| p95=${errorP95().toInt()}ms, " +
                "|clock| p95=${clockP95().toInt()}ms, samples=${spreads.size}, silent=$silentSamples"
    }

    private fun TestScope.measure(phones: List<Phone>, forMs: Long, everyMs: Long = 100, stats: Stats = Stats()): Stats {
        var left = forMs
        while (left > 0) {
            advanceTimeBy(everyMs)
            runCurrent()
            left -= everyMs
            stats.clockErrors += phones.map { it.clockErrorMs() }
            val errors = phones.map { it.errorMs() }
            if (errors.any { it == null }) {
                stats.silentSamples++
                continue
            }
            val known = errors.filterNotNull()
            stats.errors += known
            stats.spreads += known.max() - known.min()
        }
        return stats
    }

    private fun TestScope.run(ms: Long) {
        advanceTimeBy(ms)
        runCurrent()
    }

    private fun items(count: Int, durMs: Long) = List(count) { QueueItem("q$it", "vid${it}xxxxxx".take(11), "Song $it", "A", null, durMs, "p0") }

    private fun TestScope.room(profiles: List<Profile>, queue: List<QueueItem>, seed: Int = 7): Pair<Room, List<Phone>> {
        val random = Random(seed)
        val room = Room(backgroundScope, { currentTime }, queue)
        val phones = profiles.mapIndexed { i, profile -> Phone("p$i", this, room, profile, random) }
        room.phones += phones
        phones.forEach {
            it.connect()
            it.deliver(room.state(it))
        }
        run(3000) // the first clock samples
        return room to phones
    }

    private companion object {
        const val BOOT_MS = 50_000_000L
    }

    private val threePhones = listOf(
        Profile(clockOffsetMs = -3_200, clockPpm = 40.0, audioPpm = 60.0, startLatencyMs = 180, loadMs = 700),
        Profile(clockOffsetMs = 1_700, clockPpm = -25.0, audioPpm = -80.0, startLatencyMs = 260, loadMs = 1400),
        Profile(clockOffsetMs = 2_700_000, clockPpm = 10.0, audioPpm = 30.0, startLatencyMs = 340, loadMs = 2200),
    )

    // ------------------------------------------------------------------ scenarios

    @Test
    fun `three phones with their own clocks, speakers and audio drift stay within 40 ms of the room for ten minutes`() = runTest {
        val (room, phones) = room(threePhones, items(1, 15 * 60_000L))
        room.begin(0)
        run(Room.LEAD_MS + 3000)
        val settling = measure(phones, 30_000)
        val steady = measure(phones, 10 * 60_000L)
        println("[sim] ten minutes, symmetric links: settling $settling; steady $steady")
        assertTrue(steady.errorP95() <= 40, "a phone strays from the room: $steady")
        assertTrue(steady.spreadP95() <= 60, "phones drift apart: $steady")
        assertTrue(steady.spreadMax() <= 80, "a moment where phones were far apart: $steady")
        assertEquals(0, steady.silentSamples, "a phone went silent while the room played")
    }

    @Test
    fun `after a few songs each phone has learned its speaker delay and songs start together`() = runTest {
        val (room, phones) = room(threePhones, items(6, 40_000L))
        // Songs change through the barrier (as after a skip), so every start is a cold start
        val firstSeconds = mutableListOf<Stats>()
        repeat(6) { song ->
            if (song == 0) room.begin(0) else room.next()
            run(Room.LEAD_MS + 2600) // loads are up to 2.2 s, then the lead
            firstSeconds += measure(phones, 3000)
            run(20_000)
        }
        firstSeconds.forEachIndexed { i, s -> println("[sim] start of song ${i + 1}: $s") }
        val last = firstSeconds.takeLast(2)
        assertTrue(last.all { it.spreadP95() <= 40 }, "songs still start apart after learning: ${last.joinToString()}")
        assertTrue(firstSeconds.last().spreadP95() < firstSeconds.first().spreadP95(), "nothing was learned")
    }

    /** A phone that has played before: it kept what it learned about its speaker's delay, as the app stores it. */
    @Test
    fun `a phone that has played before joins a playing room in step within five seconds`() = runTest {
        val (room, phones) = room(threePhones.take(2), items(1, 10 * 60_000L))
        room.begin(0)
        run(40_000)
        val late = Phone("late", this, room, Profile(clockOffsetMs = -77_000, clockPpm = -30.0, audioPpm = 50.0, startLatencyMs = 300, loadMs = 1800), Random(99))
        late.session.startBiasMs = 300
        room.phones += late
        late.connect()
        run(2000) // its clock burst
        late.deliver(room.state(late))
        run(5000)
        val after = measure(phones + late, 20_000)
        println("[sim] late joiner that has played before, from 5 s after it got the state: $after")
        assertTrue(after.spreadP95() <= 40 && after.errorP95() <= 40, "the newcomer is not in step 5 s after joining: $after")
    }

    /**
     * A phone that never played anything does not know how late its speaker is, so its first start is off by that much.
     * The drift loop sees it within three readings, learns from it and fixes it with one seek, instead of pulling in at
     * 3 % for ten seconds or more (which measured about 300 ms off five seconds after joining).
     */
    @Test
    fun `a phone that has never played is in step within five seconds too`() = runTest {
        val (room, phones) = room(threePhones.take(2), items(1, 10 * 60_000L))
        room.begin(0)
        run(40_000)
        val late = Phone("late", this, room, Profile(clockOffsetMs = -77_000, clockPpm = -30.0, audioPpm = 50.0, startLatencyMs = 300, loadMs = 1800), Random(99))
        room.phones += late
        late.connect()
        run(2000)
        late.deliver(room.state(late))
        run(5000)
        val at5 = measure(phones + late, 1000)
        run(14_000)
        val at20 = measure(phones + late, 10_000)
        println("[sim] late joiner never played before: 5 s after the state $at5; 20 s after $at20")
        assertTrue(at5.spreadP95() <= 60 && at5.errorP95() <= 60, "not in step 5 s after joining: $at5")
        assertTrue(at20.spreadP95() <= 40 && at20.errorP95() <= 40, "still not in step 20 s after joining: $at20")
        assertTrue(late.session.startBiasMs > 150, "the speaker's delay was not learned: ${late.session.startBiasMs}")
    }

    @Test
    fun `a seek, a pause and a resume land on every phone together`() = runTest {
        val (room, phones) = room(threePhones, items(1, 10 * 60_000L))
        room.begin(0)
        run(60_000)
        room.seek(120_000)
        run(Room.LEAD_MS + 1000)
        val afterSeek = measure(phones, 10_000)
        room.pause()
        run(1000)
        val stillPlaying = phones.count { it.player.audible }
        run(5000)
        room.play()
        run(Room.LEAD_MS + 1000)
        val afterResume = measure(phones, 10_000)
        println("[sim] after seek $afterSeek; after resume $afterResume")
        assertEquals(0, stillPlaying, "a phone kept playing a second after the room paused")
        assertTrue(afterSeek.spreadP95() <= 80, "apart after a seek: $afterSeek")
        assertTrue(afterResume.spreadP95() <= 60, "apart after a resume: $afterResume")
    }

    /**
     * The phones stay together across a change, but the whole room may shift by up to the noise of one position reading
     * for a few seconds: the first phone to move on reports the new song's start from a single noisy reading, and
     * everybody, itself included, then pulls toward it. Phones are held to 40 ms of each other and to 100 ms of the room.
     */
    @Test
    fun `songs change with no gap and no barrier when they run out by themselves`() = runTest {
        val (room, phones) = room(threePhones, items(4, 60_000L))
        room.begin(0)
        run(Room.LEAD_MS + 30_000) // past the first, cold start
        val prepares = room.prepares
        val across = measure(phones, 3 * 60_000L - 25_000)
        println("[sim] three natural song changes: $across, advances=${room.advances}")
        assertEquals(prepares, room.prepares, "a natural change went through the barrier")
        assertEquals(3, room.advances)
        assertTrue(across.silentSamples <= 3, "silence at a song change: $across")
        assertTrue(across.spreadP95() <= 40, "apart across song changes: $across")
        assertTrue(across.errorP95() <= 100, "the room's start for the next song is further off than one reading's noise: $across")
    }

    @Test
    fun `a phone that loses the network for twelve seconds keeps playing in step`() = runTest {
        val (room, phones) = room(threePhones, items(1, 10 * 60_000L))
        room.begin(0)
        run(60_000)
        phones[1].link.cut = true
        val during = measure(phones, 12_000)
        phones[1].link.cut = false
        phones[1].deliver(room.state(phones[1])) // joining again brings the state
        phones[1].session.onReconnected()
        val after = measure(phones, 20_000)
        println("[sim] offline for 12 s: during $during; after $after")
        assertEquals(0, during.silentSamples + after.silentSamples, "the phone stopped")
        assertTrue(after.spreadP95() <= 40, "apart after coming back: $after")
    }

    @Test
    fun `an hour with clocks 100 ppm apart and a jittery network stays in step`() = runTest {
        val drifting = listOf(
            Profile(clockOffsetMs = 0, clockPpm = 50.0, audioPpm = 50.0, jitterMs = 40),
            Profile(clockOffsetMs = 5_000, clockPpm = -50.0, audioPpm = -50.0, jitterMs = 40),
        )
        val (room, phones) = room(drifting, items(1, 70 * 60_000L))
        room.begin(0)
        run(60_000)
        val hour = measure(phones, 60 * 60_000L, everyMs = 500)
        println("[sim] one hour, 50 ppm apart each way: $hour")
        // Harsher than real phones on purpose. With the clock picking its sample by round trip alone this measured
        // |error| p95 50 ms and spread p95 91 ms; weighing each sample's age as well brought it to 40 and 71
        assertTrue(hour.errorP95() <= 45, "a phone strays from the room over an hour: $hour")
        assertTrue(hour.spreadP95() <= 80, "phones drift apart over an hour: $hour")
    }

    @Test
    fun `a slow phone holds the start up to the barrier timeout, then catches up`() = runTest {
        val profiles = threePhones.take(2) + Profile(clockOffsetMs = 900, loadMs = 11_000)
        val (room, phones) = room(profiles, items(1, 10 * 60_000L))
        room.begin(0)
        run(Room.BARRIER_TIMEOUT_MS + Room.LEAD_MS + 500)
        val playing = phones.take(2).all { it.player.audible }
        val slowSilent = !phones[2].player.audible
        run(20_000) // the slow one finishes loading, starts behind by its speaker delay and pulls in
        val after = measure(phones, 15_000)
        println("[sim] slow phone: $after")
        assertTrue(playing && slowSilent, "the others should start without the slow phone")
        assertTrue(after.spreadP95() <= 40, "the slow phone did not catch up: $after")
    }

    /**
     * Sixty rooms of two to five phones drawn at random within what real phones and networks do, each through a start,
     * ten minutes of play, a seek, a pause and resume, and one phone dropping off the network for a while. Every phone
     * must stay within 40 ms of the room plus what its link's asymmetry costs the clock (half the difference between
     * its two directions, which no NTP-style clock can see), two phones within the sum of their two bounds, and none may
     * fall silent while the room plays.
     */
    @Test
    fun `sixty random rooms within real-world ranges all stay in step`() {
        val failures = mutableListOf<String>()
        var worstError = 0.0
        var worstSpread = 0.0
        // One virtual-time test per room, so that each room's phones stop with it
        for (seed in 1..60) runTest {
            val r = Random(seed * 7919)
            val count = 2 + r.nextInt(4)
            val profiles = List(count) {
                val up = 10L + r.nextLong(141)
                val down = 10L + r.nextLong(141)
                Profile(
                    // Booted anywhere from ten seconds to thirty days ago: a monotonic clock is never negative
                    clockOffsetMs = r.nextLong(-BOOT_MS + 10_000, 30L * 86_400_000),
                    clockPpm = r.nextDouble(-60.0, 60.0),
                    audioPpm = r.nextDouble(-100.0, 100.0),
                    upMs = up,
                    downMs = down,
                    jitterMs = r.nextLong(51),
                    startLatencyMs = 100L + r.nextLong(301),
                    seekCostMs = 30L + r.nextLong(171),
                    loadMs = 300L + r.nextLong(2701),
                    noiseMs = 100L + r.nextLong(151),
                )
            }
            val (room, phones) = room(profiles, items(1, 30 * 60_000L), seed = seed)
            phones.forEach { it.session.startBiasMs = r.nextLong(0, 300) } // whatever earlier songs taught them
            room.begin(0)
            run(Room.BARRIER_TIMEOUT_MS + Room.LEAD_MS + 30_000)
            val steady = measure(phones, 10 * 60_000L, everyMs = 250)
            room.seek(r.nextLong(60_000, 1_200_000))
            run(Room.LEAD_MS + 15_000)
            room.pause()
            run(3000)
            room.play()
            run(Room.LEAD_MS + 15_000)
            val dropped = phones[r.nextInt(count)]
            dropped.link.cut = true
            val offline = measure(phones, 10_000L + r.nextLong(20_000), everyMs = 250)
            dropped.link.cut = false
            dropped.deliver(room.state(dropped))
            dropped.session.onReconnected()
            run(15_000)
            val after = measure(phones, 60_000, everyMs = 250)
            // What the asymmetry of each link costs, as the clock cannot see it
            val skew = profiles.map { abs(it.upMs - it.downMs) / 2.0 }
            // Each phone may be 40 ms plus its own link's skew off the room; two phones off in opposite directions may
            // then be apart by both of those together
            val errorBar = 40 + skew.max() + 10
            val spreadBar = 2 * 40 + (skew.max() + skew.sorted().let { it[it.size - 2] }) + 10
            for ((name, stats) in listOf("steady" to steady, "offline" to offline, "after" to after)) {
                worstError = maxOf(worstError, stats.errorP95())
                worstSpread = maxOf(worstSpread, stats.spreadP95())
                if (stats.errorP95() > errorBar || stats.spreadP95() > spreadBar || stats.silentSamples > 0) {
                    failures += "seed $seed ($count phones) $name: $stats, bars error ${errorBar.toInt()} spread ${spreadBar.toInt()}"
                }
            }
        }
        println("[sim] sixty random rooms: worst |error| p95 ${worstError.toInt()} ms, worst spread p95 ${worstSpread.toInt()} ms, ${failures.size} failing")
        failures.take(10).forEach { println("[sim]   $it") }
        assertTrue(failures.isEmpty(), failures.take(5).joinToString("\n"))
    }

    /**
     * A known limit, recorded rather than hidden: an NTP-style clock cannot see how a round trip splits between the
     * two directions, so a link that is slower one way skews that phone by half the difference. Mobile uplinks are
     * often slower than downlinks. This pins how large the effect is, so a change that makes it worse shows up.
     */
    @Test
    fun `asymmetric links skew a phone by half the difference, and no more`() = runTest {
        val asymmetric = listOf(
            Profile(clockOffsetMs = 0, upMs = 20, downMs = 20, jitterMs = 5),
            Profile(clockOffsetMs = 3_000, upMs = 110, downMs = 20, jitterMs = 5), // uplink 90 ms slower
        )
        val (room, phones) = room(asymmetric, items(1, 10 * 60_000L))
        room.begin(0)
        run(60_000)
        val stats = measure(phones, 60_000)
        println("[sim] one link 90 ms slower upstream: $stats (expected about 45 ms from the clock alone)")
        assertTrue(stats.spreadP50() in 25.0..75.0, "the skew is not what the clock model predicts: $stats")
    }
}
