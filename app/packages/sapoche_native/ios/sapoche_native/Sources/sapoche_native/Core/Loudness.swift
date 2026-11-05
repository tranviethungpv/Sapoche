import Foundation

/// Evens out how loud songs are, as YouTube does: a song that is above its reference level (-14 LKFS; `loudnessDb` of a
/// stream says by how much) is played quieter by that much, one that is below it is left as it is. A player's volume only
/// goes down from full, so a quiet song cannot be raised without a limiter to keep it from distorting.
enum Loudness {
    /// The most a song is turned down, in dB, whatever its stream claims.
    static let maxCutDb = 12.0

    /// The volume factor (0...1) for a song [db] above the reference level; 1 when it is not known or not above.
    static func gain(_ db: Double?) -> Float {
        guard let db, !db.isNaN, db > 0 else { return 1 }
        return Float(pow(10, -min(db, maxCutDb) / 20))
    }
}
