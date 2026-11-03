import XCTest
@testable import SapocheCore

final class TasteTests: XCTestCase {
    private let day: Int64 = 24 * 60 * 60 * 1000
    private let now: Int64 = 1_000 * 24 * 60 * 60 * 1000

    private func song(_ id: String, _ artist: String? = nil) -> TrackRef {
        TrackRef(videoId: id, title: "Title \(id)", artist: artist ?? "Artist \(id)", thumb: nil, durMs: 200_000)
    }

    private func heard(_ id: String, _ daysAgo: Int64 = 1, _ artist: String? = nil) -> Stamped {
        Stamped(track: song(id, artist), at: now - daysAgo * day)
    }

    private func make(heard: [Stamped] = [], liked: [Stamped] = [], skipped: [Stamped] = [], hourOf: ((Int64) -> Int)? = nil) -> Taste {
        Taste(heard: heard, liked: liked, skipped: skipped, now: now, hourOf: hourOf ?? { _ in 12 })
    }

    func testAnArtistIsKnownOnceListenedTo() {
        let taste = make(heard: [heard("a", 1, "Jack, K-ICM")])
        XCTAssertTrue(taste.knows("Jack"))
        XCTAssertTrue(taste.knows("jack - Topic"))
        XCTAssertFalse(taste.knows("Someone else"))
    }

    func testOldListensCountForLessThanNewOnes() {
        let taste = make(heard: [heard("old", 90), heard("new", 1)])
        // Three half-lives later a listen is worth an eighth: the artist is not known any more
        XCTAssertFalse(taste.knows("Artist old"))
        XCTAssertTrue(taste.knows("Artist new"))
    }

    func testSongsLeftAgainAndAgainMakeAnArtistDisliked() {
        let skips = [heard("a", 1, "Same"), heard("b", 2, "Same")]
        XCTAssertTrue(make(skipped: skips).dislikes("Same"))
        // A heard song of the artist makes up for a skip
        XCTAssertFalse(make(heard: [heard("c", 1, "Same")], skipped: skips).dislikes("Same"))
    }

    func testASongAnotherMemberPickedCountsForLessThanOneChosen() {
        let others = Stamped(track: song("o"), at: now, weight: ListenSource.weight(ListenSource.roomOther))
        // Half a point is just the line for an artist to be known; a skipped one of theirs does not weigh a whole skip
        XCTAssertTrue(make(heard: [others]).knows("Artist o"))
        XCTAssertFalse(make(heard: [Stamped(track: song("o"), at: now, weight: 0.4)]).knows("Artist o"))
        let skipped = (["s", "t", "u"]).map { Stamped(track: song($0, "Same"), at: now - day, weight: ListenSource.weight(ListenSource.roomOther)) }
        XCTAssertFalse(make(skipped: skipped).dislikes("Same"))
        XCTAssertTrue(make(skipped: [heard("s", 1, "Same"), heard("t", 1, "Same"), heard("u", 1, "Same")]).dislikes("Same"))
    }

    func testOnlySongsAnotherMemberPickedAreWeighedDown() {
        XCTAssertEqual(ListenSource.weight(ListenSource.roomOther), 0.5)
        for source in [nil, ListenSource.chosen, ListenSource.auto, ListenSource.shelf] { XCTAssertEqual(ListenSource.weight(source), 1) }
    }

    func testListenSourcesRememberWhatAutoplayAndTheShelvesPutOnTheQueue() {
        let sources = ListenSources(keep: 3)
        XCTAssertEqual(sources.of("a"), ListenSource.chosen)
        sources.mark(["a", "b"], source: ListenSource.auto)
        sources.mark(["c"], source: ListenSource.shelf)
        XCTAssertEqual(["a", "b", "c"].map { sources.of($0) }, [ListenSource.auto, ListenSource.auto, ListenSource.shelf])
        // Put on the queue by hand later, it is a choice again
        sources.mark(["a"], source: ListenSource.chosen)
        XCTAssertEqual(sources.of("a"), ListenSource.chosen)
        // The oldest is forgotten past the limit
        sources.mark(["d", "e"], source: ListenSource.auto)
        XCTAssertEqual(sources.of("b"), ListenSource.chosen)
        XCTAssertEqual(sources.of("e"), ListenSource.auto)
    }

    func testInARoomTheQueueItemSaysWhetherItWasAutoplaysOrAnotherMembers() {
        let sources = ListenSources()
        sources.mark(["v"], source: ListenSource.shelf)
        func item(_ by: String, auto: Bool = false) -> QueueItem { QueueItem(id: "i", videoId: "v", title: "T", artist: "A", thumb: nil, durMs: 1000, addedBy: by, auto: auto) }
        XCTAssertEqual(sources.of("v", item: item("dev-b", auto: true), you: "dev-a"), ListenSource.auto)
        XCTAssertEqual(sources.of("v", item: item("dev-b"), you: "dev-a"), ListenSource.roomOther)
        XCTAssertEqual(sources.of("v", item: item("dev-a"), you: "dev-a"), ListenSource.shelf)
    }

    func testASongThePersonAskedNotToCountIsLeftOutOfEverythingItDid() {
        let listens = [heard("a", 1, "Adele"), heard("a", 2, "Adele"), heard("b", 1, "Beck")]
        XCTAssertTrue(make(heard: listens).knows("Adele"))
        let quiet = Taste(heard: listens, liked: [], skipped: [], now: now, hourOf: { _ in 12 }, quietSongs: ["a"])
        XCTAssertFalse(quiet.knows("Adele"), "the plays of that song were all of the artist's")
        XCTAssertEqual(quiet.songScore("a"), 0)
        XCTAssertTrue(quiet.knows("Beck"))
        XCTAssertEqual(quiet.seeds(5), ["b"])
    }

    func testAnArtistThePersonWantsFewerSuggestionsOfHasNoScoreIsNoSeedAndIsNeverOffered() {
        let listens = [heard("a", 1, "Adele"), heard("b", 1, "Beck"), heard("c", 1, "Cher")]
        let quiet = Taste(heard: listens, liked: [], skipped: [], now: now, hourOf: { _ in 12 }, quietArtists: ["beck"])
        XCTAssertTrue(quiet.isQuiet("Beck - Topic"))
        XCTAssertFalse(quiet.knows("Beck"))
        XCTAssertEqual(quiet.artistScore("Beck"), 0)
        XCTAssertEqual(quiet.seeds(5).sorted(), ["a", "c"])
        XCTAssertEqual(quiet.offer(5).map(\.videoId).sorted(), ["a", "c"], "and a room is not told of them")
        // The songs are still in the taste, so they can still be played and shown where they were
        XCTAssertGreaterThan(quiet.songScore("b"), 0)
    }

    func testASongANewPersonStartedWithCountsAsHeardWhenItWasChosen() {
        let label = #"{"videoId":"bNp9pn0ni3I","title":"Chiều hôm ấy","artist":"Jaykii","thumb":"https://x/t.jpg","durMs":215000}"#
        let stamped = TasteMarks.starter(label: label, at: now - day)!
        XCTAssertEqual(stamped.track, TrackRef(videoId: "bNp9pn0ni3I", title: "Chiều hôm ấy", artist: "Jaykii", thumb: "https://x/t.jpg", durMs: 215000))
        XCTAssertTrue(make(heard: [stamped]).knows("Jaykii"))
        XCTAssertNil(TasteMarks.starter(label: "not json", at: 1))
        XCTAssertNil(TasteMarks.starter(label: #"{"title":"no id"}"#, at: 1))
    }

    func testALikeWeighsMoreThanAListen() {
        let taste = make(heard: [heard("a"), heard("b"), heard("b", 2)], liked: [heard("a")])
        XCTAssertEqual(taste.seeds(2), ["a", "b"], "a: 1 listen and a like beat b: 2 listens")
    }

    func testSeedsAreTheBestLovedSongsOneForEachArtist() {
        let listens = [
            heard("a1", 1, "A"), heard("a1", 2, "A"), heard("a1", 3, "A"),
            heard("a2", 1, "A"), heard("a2", 2, "A"),
            heard("b1", 1, "B"),
            heard("c1", 1, "C"),
        ]
        XCTAssertEqual(make(heard: listens).seeds(3), ["a1", "b1", "c1"])
    }

    func testASecondSongOfAnArtistFillsASeedThatWouldBeEmpty() {
        let listens = [heard("a1", 1, "A"), heard("a1", 2, "A"), heard("a2", 1, "A"), heard("b1", 1, "B")]
        XCTAssertEqual(make(heard: listens).seeds(3), ["a1", "b1", "a2"])
    }

    func testSongsThatWereOnlySkippedAreNotSeedsNorAreBlockedOnes() {
        let taste = make(heard: [heard("a"), heard("b"), heard("c")], skipped: [heard("c"), heard("c", 2)])
        XCTAssertEqual(taste.seeds(5), ["a", "b"])
        XCTAssertEqual(taste.seeds(5, block: Blocklist(songs: ["a"])), ["b"])
        XCTAssertEqual(taste.seeds(5, block: Blocklist(artists: ["artist b"])), ["a"])
    }

    func testNothingIsKnownAboutSomeoneWhoHasNotListened() {
        let taste = make()
        XCTAssertEqual(taste.seeds(5), [])
        XCTAssertFalse(taste.knows("Anyone"))
        XCTAssertFalse(taste.dislikes("Anyone"))
    }

    func testTheTimeOfDayIsCutInFour() {
        XCTAssertEqual([4, 5, 10, 11, 16, 17, 21, 22].map(Taste.bucketOf),
                       ["night", "morning", "morning", "afternoon", "afternoon", "evening", "evening", "night"])
    }

    func testWhatIsPlayedAtThisHourSeedsTheMixForIt() {
        // Each listen has a moment of its own, so the test can say which hour it was at
        func at(_ id: String, _ daysAgo: Int64, _ ms: Int64) -> Stamped { Stamped(track: song(id), at: now - daysAgo * day - ms) }
        let morning = (1...5).map { at("m1", Int64($0), 1_000) } + (1...2).map { at("m2", Int64($0), 2_000) }
        let evening = (1...3).map { at("e1", Int64($0), 3_000) }
        let hours: [Int64: Int] = [1_000: 8, 2_000: 8, 3_000: 20]
        let taste = make(heard: morning + evening, hourOf: { hours[(self.now - $0) % self.day] ?? 12 })
        XCTAssertEqual(taste.contextSeeds("morning").map(\.videoId), ["m1", "m2"])
        XCTAssertEqual(taste.contextSeeds("evening").map(\.videoId), [], "three listens do not make a habit")
        XCTAssertEqual(taste.contextSeeds("night").map(\.videoId), [])
    }

    func testTwoSongsOfOneArtistAreOneSeedForATimeOfDay() {
        let listens = (1...4).map { heard("s1", Int64($0), "Same") } + (1...3).map { heard("s2", Int64($0), "Same") } + [heard("o", 1, "Other")]
        XCTAssertEqual(make(heard: listens).contextSeeds("afternoon").map(\.videoId), ["s1", "o"])
    }

    func testAnArtistIsANameInPlainLetters() {
        XCTAssertEqual(Taste.artistKey("Sơn Tùng M-TP"), "sơn tùng m tp")
        XCTAssertEqual(Taste.artistKey("Jack & K-ICM"), "jack")
        XCTAssertEqual(Taste.artistKey("Noo Phước Thịnh - Topic"), "noo phước thịnh")
        XCTAssertEqual(Taste.artistLabel("Jack, K-ICM"), "Jack")
    }
}
