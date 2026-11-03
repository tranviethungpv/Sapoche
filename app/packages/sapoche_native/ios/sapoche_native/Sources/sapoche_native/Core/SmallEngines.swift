import Foundation

enum Queues {
    /// The songs of [tracks] worth adding to [queue], whose song at [index] is the one playing: those not already
    /// waiting in it (playing now or still to come) and not repeated within [tracks]. A song that was played already
    /// may be added again, and so may one that autoplay lined up: the room takes that one off.
    static func fresh(_ tracks: [TrackRef], queue: [QueueItem], index: Int) -> [TrackRef] {
        var seen = Set(queue.dropFirst(max(index, 0)).enumerated().filter { $0.offset == 0 || !$0.element.auto }.map(\.element.videoId))
        return tracks.filter { seen.insert($0.videoId).inserted }
    }

    /// The most songs autoplay asks a radio for at once: more would be many requests for a room that has run dry.
    static let maxSeeds = 3

    /// The most songs autoplay asks for radios of in all, its own and the members' offers together.
    static let maxBlend = 5

    /// [base] (see `seeds`) with one song of each member's offer, to look for songs that suit the room and not only the last
    /// song: [offers] are the video ids each member offered, in the order they gave them. Which song of an offer, and which
    /// members when there are not places for all, goes round with [epoch], so the next time the room runs out it is others'.
    /// Songs already among the seeds are not taken twice. At most [max] come back in all.
    static func blend(_ base: [String], offers: [[String]], epoch: Int64, max: Int = Queues.maxBlend) -> [String] {
        var result = base
        let members = offers.filter { !$0.isEmpty }
        if members.isEmpty { return result }
        let start = Int(((epoch % Int64(members.count)) + Int64(members.count)) % Int64(members.count))
        for i in members.indices {
            if result.count >= max { break }
            let offer = members[(start + i) % members.count]
            let pick = offer.indices.map { offer[Int(((epoch + Int64($0)) % Int64(offer.count) + Int64(offer.count)) % Int64(offer.count))] }.first { !result.contains($0) }
            if let pick { result.append(pick) }
        }
        return result
    }

    /// The songs a room's autoplay looks for more of: [ask], the last song, then the songs of [queue] that members put
    /// there, the latest first, one for each member who has not a song among them yet. Songs autoplay itself put there
    /// are not a member's choice and are left out. A room where one member added everything gives [ask] alone, as it
    /// always did.
    static func seeds(_ queue: [QueueItem], ask: String, max: Int = Queues.maxSeeds) -> [String] {
        var seeds = [ask]
        var adders = Set<String>()
        if let asked = queue.last(where: { $0.videoId == ask && !$0.auto }) { adders.insert(asked.addedBy) }
        for item in queue.reversed() {
            if seeds.count >= max { break }
            if item.auto || seeds.contains(item.videoId) || !adders.insert(item.addedBy).inserted { continue }
            seeds.append(item.videoId)
        }
        return seeds
    }
}

/// Turns the songs YouTube lists beside a few seed songs into one list worth offering. YouTube's related lists hold
/// hour-long mixes and full albums beside songs, and songs the person already knows.
enum Suggestions {
    /// Songs shorter or longer than this are left out: what is left is mostly music.
    static let minMs: Int64 = 60_000
    static let maxMs: Int64 = 600_000

    static func isSong(_ track: TrackRef) -> Bool {
        track.durMs >= minMs && track.durMs <= maxMs
    }

    /// One list from several [lists], taking a song from each in turn so no seed crowds out the others. Songs in
    /// [exclude], repeats, non-songs and what [allow] refuses are dropped. At most [limit] come back.
    static func mix(_ lists: [[TrackRef]], exclude: Set<String>, limit: Int, allow: (TrackRef) -> Bool = { _ in true }) -> [TrackRef] {
        var seen = exclude
        var result: [TrackRef] = []
        var queues = lists.map { list in list.filter { isSong($0) && allow($0) }[...] }
        while result.count < limit && queues.contains(where: { !$0.isEmpty }) {
            for at in queues.indices {
                while let track = queues[at].popFirst() {
                    if !seen.insert(track.videoId).inserted { continue }
                    result.append(track)
                    break
                }
                if result.count >= limit { break }
            }
        }
        return result
    }

    /// At most this many songs of one artist in a list of suggestions.
    static let maxPerArtist = 2

    /// Of every ten songs, these come from artists the person does not know yet (the rest from ones they do).
    private static let newArtistSlots: Set<Int> = [2, 5, 8]

    /// What the person should be offered, or nothing from artists they asked not to hear or left again and again.
    static func welcome(_ track: TrackRef, taste: Taste, block: Blocklist) -> Bool {
        isSong(track) && block.allows(track) && !taste.dislikes(track.artist)
    }

    /// The suggestions of the seeds ([lists], best loved seed first) as one list: songs by artists the person knows, with
    /// a few by artists they do not know in between, so the list is mostly what they like and a little of what they
    /// might. Songs in [exclude] and what is not welcome are left out, and no artist comes more than [maxPerArtist]
    /// times. At most [limit] come back.
    static func compose(_ lists: [[TrackRef]], taste: Taste, block: Blocklist, exclude: Set<String>, limit: Int) -> [TrackRef] {
        let wanted = lists.map { list in list.filter { welcome($0, taste: taste, block: block) } }
        var known = turns(wanted.map { list in list.filter { taste.knows($0.artist) } })[...]
        // An artist the person wants fewer suggestions of is not a stranger to be tried either
        var fresh = turns(wanted.map { list in list.filter { !taste.knows($0.artist) && !taste.isQuiet($0.artist) } })[...]
        var seen = exclude
        var perArtist: [String: Int] = [:]
        func take(_ queue: inout ArraySlice<TrackRef>) -> TrackRef? {
            while let track = queue.popFirst() {
                let artist = Taste.artistKey(track.artist)
                if seen.contains(track.videoId) || (perArtist[artist] ?? 0) >= Suggestions.maxPerArtist { continue }
                seen.insert(track.videoId)
                perArtist[artist, default: 0] += 1
                return track
            }
            return nil
        }
        var result: [TrackRef] = []
        while result.count < limit {
            let wantFresh = Suggestions.newArtistSlots.contains(result.count % 10)
            let next: TrackRef?
            if wantFresh {
                next = take(&fresh) ?? take(&known)
            } else {
                next = take(&known) ?? take(&fresh)
            }
            guard let track = next else { break }
            result.append(track)
        }
        return result
    }

    /// Only the songs by artists the person does not know yet, one of each artist: something new to try.
    static func discover(_ lists: [[TrackRef]], taste: Taste, block: Blocklist, exclude: Set<String>, limit: Int) -> [TrackRef] {
        let fresh = lists.map { list in list.filter { welcome($0, taste: taste, block: block) && !taste.knows($0.artist) && !taste.isQuiet($0.artist) } }
        var seen = exclude
        var artists = Set<String>()
        var result: [TrackRef] = []
        for track in turns(fresh) {
            if result.count >= limit { break }
            if seen.insert(track.videoId).inserted && artists.insert(Taste.artistKey(track.artist)).inserted { result.append(track) }
        }
        return result
    }

    /// Of every five songs, the last is for an artist the person does not know yet.
    private static let strangerEvery = 5

    /// Position counts for less the further down the radio's list a song stands: half as much at the eighth place.
    private static let positionSpan = 8.0

    /// How much knowing the artist adds to a song's score, as a share of the artist loved most.
    private static let affinityWeight = 0.35

    /// [list], a radio's songs in the order YouTube gives them, put in the order that suits this person: the nearer the
    /// top the better, plus a little for songs by artists they love. A song they left more than they heard is dropped,
    /// every fifth place is kept for an artist they do not know yet if the list has one, and no artist comes more than
    /// [maxPerArtist] times. The order is the same whenever the same list and the same taste are given.
    static func rank(_ list: [TrackRef], taste: Taste) -> [TrackRef] {
        let strongest = taste.strongestArtist
        func affinity(_ track: TrackRef) -> Double { strongest <= 0 ? 0 : min(max(taste.artistScore(track.artist) / strongest, 0), 1) }
        var ordered = Array(list.enumerated()).filter { taste.songScore($0.element.videoId) >= 0 }.map { entry in
            (index: entry.offset, track: entry.element, score: 1 / (1 + Double(entry.offset) / positionSpan) + affinityWeight * affinity(entry.element))
        }
        ordered.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        var taken = Set<String>()
        var perArtist: [String: Int] = [:]
        var result: [TrackRef] = []
        func fits(_ track: TrackRef) -> Bool {
            !taken.contains(track.videoId) && (perArtist[Taste.artistKey(track.artist)] ?? 0) < maxPerArtist
        }
        while true {
            let stranger = result.count % strangerEvery == strangerEvery - 1
            let next = (stranger ? ordered.first { fits($0.track) && !taste.knows($0.track.artist) && !taste.isQuiet($0.track.artist) } : nil) ?? ordered.first { fits($0.track) }
            guard let pick = next else { break }
            taken.insert(pick.track.videoId)
            perArtist[Taste.artistKey(pick.track.artist), default: 0] += 1
            result.append(pick.track)
        }
        return result
    }

    /// The lists read in turns, one song from each at a time.
    private static func turns(_ lists: [[TrackRef]]) -> [TrackRef] {
        var queues = lists.map { ArraySlice($0) }
        var result: [TrackRef] = []
        while queues.contains(where: { !$0.isEmpty }) {
            for at in queues.indices {
                if let track = queues[at].popFirst() { result.append(track) }
            }
        }
        return result
    }
}

/// Decides when a song counts as heard: after [heardMs] of playing it, or half of it when it is shorter than a
/// minute. Only time spent playing counts, so pauses and buffering do not, and seeking neither adds nor skips anything.
///
/// A song that is left before it counts, after a few seconds, is reported as skipped.
///
/// It keeps no clock and no timer. The caller passes the time in and asks [msUntilHeard] how long to wait before
/// calling [check], so it works the same for the personal queue, a room, and a test.
final class ListenTracker {
    static let heardMs: Int64 = 30_000

    /// A song left after at least this long, and before it counted, was skipped; less is a change of mind or a glitch.
    static let skippedMs: Int64 = 3_000

    /// Called once per song, with its id and the length last reported (0 if unknown).
    private let heard: (_ id: String, _ durationMs: Int64) -> Void

    /// Called once for a song left after a few seconds, before it counted, with its id and length: the person did not want it.
    private let skipped: (_ id: String, _ durationMs: Int64) -> Void
    private var id: String?
    private var durationMs: Int64 = 0
    private var playedMs: Int64 = 0
    private var playingSince: Int64?
    private var counted = false

    init(heard: @escaping (_ id: String, _ durationMs: Int64) -> Void,
         skipped: @escaping (_ id: String, _ durationMs: Int64) -> Void = { _, _ in }) {
        self.heard = heard
        self.skipped = skipped
    }

    /// A different song is now loaded, or with nil nothing is.
    func begin(songId: String?, durationMs: Int64, now: Int64) {
        check(now)
        if let leaving = id, !counted, playedMs + (playingSince.map { now - $0 } ?? 0) >= Self.skippedMs {
            skipped(leaving, self.durationMs)
        }
        id = songId
        self.durationMs = max(durationMs, 0)
        playedMs = 0
        playingSince = nil
        counted = false
    }

    /// The song's length became known.
    func setDuration(_ ms: Int64) {
        if ms > 0 { durationMs = ms }
    }

    func setPlaying(_ playing: Bool, now: Int64) {
        if id == nil { return }
        check(now)
        if playing && playingSince == nil {
            playingSince = now
        } else if !playing, let since = playingSince {
            playedMs += now - since
            playingSince = nil
        }
    }

    /// How long until the song counts if it keeps playing, or nil when that is not going to happen.
    func msUntilHeard(_ now: Int64) -> Int64? {
        guard let since = playingSince, id != nil, !counted else { return nil }
        return max(threshold() - playedMs - (now - since), 0)
    }

    /// Counts the song if it has been played long enough by [now].
    func check(_ now: Int64) {
        guard let current = id, !counted else { return }
        let total = playedMs + (playingSince.map { now - $0 } ?? 0)
        if total < threshold() { return }
        counted = true
        heard(current, durationMs)
    }

    private func threshold() -> Int64 {
        durationMs > 0 ? min(Self.heardMs, durationMs / 2) : Self.heardMs
    }
}

/// What the sleep timer is set to.
enum Sleep: Equatable {
    case off
    /// Stops the music at [endsAtMs] (wall clock, so the UI can show the hour).
    case at(endsAtMs: Int64)
    /// Stops the music when the song that plays now is over.
    case songEnd
}

/// Stops the music after a while so that the person can fall asleep to it. The volume goes down over the last
/// [fadeMs] so that it does not end with a jolt.
///
/// [stop] pauses this device; [fade] sets the volume (1 is full) and [pauseAtSongEnd] asks the player to pause when
/// the song is over. The host calls [songEnded] once that happened.
@MainActor
final class SleepTimer {
    static let fadeMs: Int64 = 15_000
    static let fadeStepMs: Int64 = 500
    static let maxMinutes = 12 * 60

    private let scope: Scope
    private let time: TimeSource
    private let wallClock: () -> Int64
    private let stop: () -> Void
    private let fade: (Float) -> Void
    private let pauseAtSongEnd: (Bool) -> Void

    let state = StateFlow<Sleep>(.off)
    private var job: Job?

    init(scope: Scope, time: TimeSource? = nil, wallClock: @escaping () -> Int64,
         stop: @escaping () -> Void, fade: @escaping (Float) -> Void, pauseAtSongEnd: @escaping (Bool) -> Void) {
        self.scope = scope
        self.time = time ?? SystemTime.shared
        self.wallClock = wallClock
        self.stop = stop
        self.fade = fade
        self.pauseAtSongEnd = pauseAtSongEnd
    }

    /// Stops in [minutes], replacing what was set before.
    func startIn(minutes: Int) {
        let ms = Int64(min(max(minutes, 1), Self.maxMinutes)) * 60_000
        reset()
        state.set(.at(endsAtMs: wallClock() + ms))
        job = scope.launch { [weak self] in
            guard let self else { return }
            do {
                try await self.time.sleep(ms: max(ms - Self.fadeMs, 0))
                var left = min(ms, Self.fadeMs)
                while left > 0 {
                    self.fade(Float(left) / Float(Self.fadeMs))
                    let step = min(left, Self.fadeStepMs)
                    try await self.time.sleep(ms: step)
                    left -= step
                }
                self.fire()
            } catch {
                // Cancelled: the timer was set again or turned off
            }
        }
    }

    /// Stops at the end of the song playing now.
    func startAtSongEnd() {
        reset()
        state.set(.songEnd)
        pauseAtSongEnd(true)
    }

    func cancel() {
        reset()
        state.set(.off)
    }

    /// The player paused at the end of a song, or the queue ran out.
    func songEnded() {
        if state.value == .songEnd { fire() }
    }

    private func fire() {
        // Silence first: the volume only comes back once the player is paused
        stop()
        reset()
        state.set(.off)
    }

    /// Undoes what the timer did to the player.
    private func reset() {
        job?.cancel()
        job = nil
        fade(1)
        pauseAtSongEnd(false)
    }
}

/// What to let go of when nobody has been listening or looking for a while.
enum IdleAction {
    /// In a room: close the connection. Nothing is forgotten; it comes back when someone looks or presses play.
    case suspendRoom
    /// Outside a room: let go of what is only there for playing.
    case stopService
}

/// Says when nobody is listening ([playing] false) or looking ([visible] false) for long enough that something which
/// costs battery should go: after [roomAfterMs] in a room its connection, whose pings keep the radio awake all day,
/// and after [serviceAfterMs] outside a room the playback machinery. Anyone playing or looking again cancels the wait,
/// and a wait that ended is not repeated until something changes.
///
/// The wait is made of short sleeps of [checkEveryMs], after each of which the clock is asked how long it has really
/// been, so a clock that counts the time the device sleeps ends it on time.
@MainActor
final class IdleWatch {
    private let scope: Scope
    private let time: TimeSource
    private let roomAfterMs: Int64
    private let serviceAfterMs: Int64?
    private let checkEveryMs: Int64
    private let act: (IdleAction) -> Void

    private var inRoom = false
    private var playing = false
    private var visible = false
    private var job: Job?

    init(scope: Scope, time: TimeSource? = nil, roomAfterMs: Int64, serviceAfterMs: Int64?,
         checkEveryMs: Int64 = 30_000, act: @escaping (IdleAction) -> Void) {
        self.scope = scope
        self.time = time ?? SystemTime.shared
        self.roomAfterMs = roomAfterMs
        self.serviceAfterMs = serviceAfterMs
        self.checkEveryMs = checkEveryMs
        self.act = act
        restart()
    }

    func update(inRoom: Bool? = nil, playing: Bool? = nil, visible: Bool? = nil) {
        let before = (self.inRoom, self.playing, self.visible)
        if let inRoom { self.inRoom = inRoom }
        if let playing { self.playing = playing }
        if let visible { self.visible = visible }
        if before != (self.inRoom, self.playing, self.visible) { restart() }
    }

    private func restart() {
        job?.cancel()
        job = nil
        if playing || visible { return }
        let room = inRoom
        guard let wait = room ? roomAfterMs : serviceAfterMs else { return }
        job = scope.launch { [weak self] in
            guard let self else { return }
            let quietSince = self.time.nowMs()
            do {
                while self.time.nowMs() - quietSince < wait {
                    try await self.time.sleep(ms: min(self.checkEveryMs, wait - (self.time.nowMs() - quietSince)))
                }
            } catch {
                return
            }
            self.act(room ? .suspendRoom : .stopService)
        }
    }

    func cancel() {
        job?.cancel()
        job = nil
    }
}

/// The reactions that came while nobody looked at the screen, for the screen that comes back. The room keeps no
/// reaction, so what this device heard while it lay in a pocket is all there is of them. Only the last `keepMs` count:
/// a heart from an hour ago is no longer a reaction to anything.
final class MissedReactions {
    /// `n` taps of `e` by member `by`.
    struct Missed: Equatable {
        let by: String
        let e: String
        let n: Int
    }

    static let keepMs: Int64 = 5 * 60_000
    /// More than this many in a pocket are not kept: the oldest go.
    static let maxEntries = 200

    private struct Entry {
        let by: String
        let e: String
        let n: Int
        let at: Int64
    }

    private let now: () -> Int64
    private var entries: [Entry] = []

    /// `now` is a clock that keeps counting while the device sleeps.
    init(now: @escaping () -> Int64) { self.now = now }

    func add(by: String, e: String, n: Int) {
        entries.append(Entry(by: by, e: e, n: n, at: now()))
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
    }

    /// What is still worth showing, the taps of each member on each emoji added up in the order they began. Empties the list.
    func take() -> [Missed] {
        let from = now() - Self.keepMs
        var order: [String] = []
        var sums: [String: Missed] = [:]
        for entry in entries where entry.at >= from {
            let key = entry.by + "\u{0}" + entry.e
            if let seen = sums[key] {
                sums[key] = Missed(by: seen.by, e: seen.e, n: seen.n + entry.n)
            } else {
                order.append(key)
                sums[key] = Missed(by: entry.by, e: entry.e, n: entry.n)
            }
        }
        entries.removeAll()
        return order.compactMap { sums[$0] }
    }
}
