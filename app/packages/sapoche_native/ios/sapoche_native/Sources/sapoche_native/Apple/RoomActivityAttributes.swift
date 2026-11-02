#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// What the Live Activity of a room shows. The app starts and updates it; the widgets' target draws it. Both compile this
/// very file, because the system pairs the two by the name of the type.
@available(iOS 16.1, *)
public struct RoomActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var title: String
        public var artist: String
        public var playing: Bool
        public var members: Int
        /// While it plays: when the song began and will end, which the system counts by itself.
        public var startedAt: Date?
        public var endsAt: Date?

        public init(title: String, artist: String, playing: Bool, members: Int, startedAt: Date?, endsAt: Date?) {
            self.title = title
            self.artist = artist
            self.playing = playing
            self.members = members
            self.startedAt = startedAt
            self.endsAt = endsAt
        }
    }

    public var roomName: String
    public var roomCode: String

    public init(roomName: String, roomCode: String) {
        self.roomName = roomName
        self.roomCode = roomCode
    }
}
#endif
