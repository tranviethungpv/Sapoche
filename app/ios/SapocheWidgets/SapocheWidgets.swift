import SwiftUI
import WidgetKit

@main
struct SapocheWidgets: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        RoomsWidget()
        QuickWidget()
        LockScreenWidget()
        DownloadLiveActivity()
        if #available(iOS 18.0, *) {
            PlayPauseControl()
            OpenRoomControl()
        }
    }
}
