package app.unison.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.schabi.newpipe.extractor.NewPipe
import org.schabi.newpipe.extractor.ServiceList
import org.schabi.newpipe.extractor.localization.Localization
import org.schabi.newpipe.extractor.playlist.PlaylistInfo
import org.schabi.newpipe.extractor.playlist.PlaylistInfoItem
import org.schabi.newpipe.extractor.search.SearchInfo
import org.schabi.newpipe.extractor.services.youtube.linkHandler.YoutubeSearchQueryHandlerFactory
import org.schabi.newpipe.extractor.stream.AudioStream
import org.schabi.newpipe.extractor.stream.StreamInfo
import org.schabi.newpipe.extractor.stream.StreamInfoItem
import org.schabi.newpipe.extractor.stream.StreamType
import org.schabi.newpipe.extractor.stream.VideoStream

class NewPipeResolver(downloader: OkHttpDownloader = OkHttpDownloader()) : StreamResolver {

    init {
        NewPipe.init(downloader, Localization("en", "US"))
    }

    private val youtube get() = ServiceList.YouTube

    override suspend fun search(query: String, limit: Int, songsOnly: Boolean): List<TrackInfo> =
        withContext(Dispatchers.IO) {
            val filter = if (songsOnly) YoutubeSearchQueryHandlerFactory.MUSIC_SONGS else YoutubeSearchQueryHandlerFactory.VIDEOS
            val handler = youtube.searchQHFactory.fromQuery(query, listOf(filter), "")
            SearchInfo.getInfo(youtube, handler).relatedItems
                .filterIsInstance<StreamInfoItem>()
                // Live streams have no length and cannot be put on a shared queue
                .filter { it.duration > 0 && it.streamType != StreamType.LIVE_STREAM }
                .take(limit)
                .map { it.toTrack() }
        }

    override suspend fun searchPlaylists(query: String, limit: Int): List<PlaylistRef> =
        withContext(Dispatchers.IO) {
            val handler = youtube.searchQHFactory.fromQuery(
                query,
                listOf(YoutubeSearchQueryHandlerFactory.PLAYLISTS),
                "",
            )
            SearchInfo.getInfo(youtube, handler).relatedItems
                .filterIsInstance<PlaylistInfoItem>()
                // Auto-generated mixes have no playlist page we can list
                .mapNotNull { item ->
                    val id = YoutubeLinks.playlistId(item.url) ?: return@mapNotNull null
                    PlaylistRef(
                        id = id,
                        title = item.name,
                        uploader = item.uploaderName ?: "",
                        thumbUrl = item.thumbnails.maxByOrNull { it.width }?.url,
                        songCount = item.streamCount,
                    )
                }
                .take(limit)
        }

    override suspend fun resolve(videoId: String): Resolved = withContext(Dispatchers.IO) {
        val t0 = System.nanoTime()
        val info = StreamInfo.getInfo(youtube, "https://www.youtube.com/watch?v=$videoId")
        val ms = (System.nanoTime() - t0) / 1_000_000

        if (info.streamType != StreamType.VIDEO_STREAM && info.streamType != StreamType.AUDIO_STREAM) {
            error("Unsupported stream type: ${info.streamType}")
        }

        val sources = info.audioStreams
            .filter { it.isUrl && !it.content.isNullOrBlank() }
            .map { it.toSource() }
            .sortedByDescending { it.bitrateKbps }

        check(sources.isNotEmpty()) { "No audio stream available for $videoId" }

        val videos = info.videoOnlyStreams
            .filter { it.isUrl && !it.content.isNullOrBlank() && it.height > 0 }
            .map { it.toSource() }
            .sortedByDescending { it.height }

        Resolved(
            track = TrackInfo(
                videoId = videoId,
                title = info.name,
                artist = info.uploaderName ?: "",
                thumbUrl = info.thumbnails.maxByOrNull { it.width }?.url,
                durationSec = info.duration,
            ),
            best = sources.first(),
            all = sources,
            resolveMs = ms,
            videos = videos,
        )
    }

    override suspend fun playlist(playlistId: String, limit: Int): Playlist = withContext(Dispatchers.IO) {
        val info = PlaylistInfo.getInfo(youtube, "https://www.youtube.com/playlist?list=$playlistId")
        val tracks = info.relatedItems
            .filterIsInstance<StreamInfoItem>()
            // Deleted and private videos show up with no length
            .filter { it.duration > 0 && it.url.contains("v=") }
            .take(limit)
            .map { it.toTrack() }
        Playlist(info.name, tracks)
    }

    private fun StreamInfoItem.toTrack() = TrackInfo(
        videoId = url.substringAfter("v=").substringBefore('&'),
        title = name,
        artist = uploaderName ?: "",
        thumbUrl = thumbnails.maxByOrNull { it.width }?.url,
        durationSec = duration,
    )

    private fun VideoStream.toSource() = VideoSource(
        url = content,
        height = height,
        format = format?.name ?: "?",
        codec = codec ?: "",
        bitrateKbps = bitrate / 1000,
        contentLength = itagItem?.contentLength ?: -1,
        itag = id.toIntOrNull() ?: itagItem?.id ?: -1,
    )

    private fun AudioStream.toSource() = AudioSource(
        url = content,
        codec = format?.name ?: "?",
        bitrateKbps = averageBitrate,
        contentLength = itagItem?.contentLength ?: -1,
        itag = id.toIntOrNull() ?: itagItem?.id ?: -1,
    )
}
