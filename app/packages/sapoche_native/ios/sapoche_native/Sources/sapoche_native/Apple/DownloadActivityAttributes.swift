#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// The Live Activity of a run of downloads. The app starts and updates it; the widgets' target draws it. Both compile this
/// very file, because the system pairs the two by the name of the type.
@available(iOS 16.1, *)
public struct DownloadActivityAttributes: ActivityAttributes {
    public typealias ContentState = DownloadActivityContent

    public init() {}
}
#endif
