import SwiftUI
import WidgetKit

@main
struct SapocheWidgets: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        LockScreenWidget()
        RoomLiveActivity()
        if #available(iOS 18.0, *) {
            PlayPauseControl()
            OpenRoomControl()
        }
    }
}
