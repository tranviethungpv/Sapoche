import AVFoundation
import Foundation

/// Hands Apple's player the playlists kept in [HlsPlaylists]: the player asks for an address of their scheme, and this
/// answers with the text. The pieces those playlists list are https addresses, which the player fetches by itself.
final class PlaylistLoader: NSObject, AVAssetResourceLoaderDelegate {
    let queue = DispatchQueue(label: "app.unison.playlists")
    private let playlists: HlsPlaylists
    private let log: (String) -> Void

    init(playlists: HlsPlaylists, log: @escaping (String) -> Void) {
        self.playlists = playlists
        self.log = log
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, url.scheme == HlsPlaylists.scheme else { return false }
        guard let text = playlists.text(for: url) else {
            // Let go to make room for newer ones: the item fails, and whoever plays it loads it again
            let log = log
            let name = url.lastPathComponent
            DispatchQueue.main.async { log("the player asked for a playlist that is no longer kept: \(name)") }
            loadingRequest.finishLoading(with: URLError(.fileDoesNotExist))
            return true
        }
        let data = Data(text.utf8)
        if let information = loadingRequest.contentInformationRequest {
            information.contentType = "public.m3u-playlist"
            information.contentLength = Int64(data.count)
            information.isByteRangeAccessSupported = false
        }
        if let request = loadingRequest.dataRequest {
            let start = Int(min(max(request.requestedOffset, 0), Int64(data.count)))
            let end = request.requestsAllDataToEndOfResource ? data.count : min(data.count, start + request.requestedLength)
            request.respond(with: data.subdata(in: start..<end))
        }
        loadingRequest.finishLoading()
        return true
    }
}
