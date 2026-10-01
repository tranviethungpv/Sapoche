import Foundation

/// YouTube serves its audio as a "DASH" MP4: an empty `moov`, then the song in many `moof` + `mdat` fragments. A player
/// built for streaming copes, but Apple's player is not reliable with such a file once it is on the disk. This writes the
/// same samples again as an ordinary MP4: one full `moov`, one `mdat`, nothing re-encoded.
enum Mp4Remux {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Box {
        let type: String
        let start: Int
        let size: Int
        let header: Int

        var payload: Range<Int> { (start + header)..<(start + size) }
    }

    private struct Sample {
        let offset: Int
        let size: Int
        let duration: Int
    }

    private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "edts"]

    // ------------------------------------------------------------------ entry points

    /// Whether the MP4 at [file] is in fragments. Reads only box headers.
    static func isFragmented(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        var offset: UInt64 = 0
        while true {
            guard (try? handle.seek(toOffset: offset)) != nil, let head = try? handle.read(upToCount: 16), head.count >= 8 else { return false }
            var size = UInt64(be32(head, 0))
            let type = String(decoding: head[head.startIndex + 4..<head.startIndex + 8], as: UTF8.self)
            if type == "moof" { return true }
            if type == "mdat" && size != 1 { return false }
            if size == 1 {
                guard head.count >= 16 else { return false }
                size = UInt64(be32(head, 8)) << 32 | UInt64(be32(head, 12))
            }
            if size < 8 { return false }
            offset += size
        }
    }

    /// Rewrites the fragmented MP4 at [file] as an ordinary one, in place. A file that is not in fragments is left alone.
    /// Throws, with the file untouched, when the file is not one this understands.
    @discardableResult
    static func makeProgressive(_ file: URL) throws -> Bool {
        guard isFragmented(file) else { return false }
        let input = try Data(contentsOf: file, options: .mappedIfSafe)
        let output = try progressive(input)
        let temporary = file.appendingPathExtension("remux")
        try output.write(to: temporary)
        let manager = FileManager.default
        try? manager.removeItem(at: file)
        try manager.moveItem(at: temporary, to: file)
        return true
    }

    /// The fragmented MP4 in [data] as an ordinary MP4. Only a file of one audio track is understood.
    static func progressive(_ data: Data) throws -> Data {
        let top = try boxes(data, 0, data.count)
        guard let moov = top.first(where: { $0.type == "moov" }) else { throw Failure(message: "no moov") }

        let moovChildren = try boxes(data, moov.payload.lowerBound, moov.payload.upperBound)
        guard moovChildren.filter({ $0.type == "trak" }).count == 1 else { throw Failure(message: "not a single track") }
        var defaults = (duration: 0, size: 0)
        if let mvex = moovChildren.first(where: { $0.type == "mvex" }),
           let trex = try boxes(data, mvex.payload.lowerBound, mvex.payload.upperBound).first(where: { $0.type == "trex" }) {
            // version+flags, track id, description index, then the defaults
            defaults = (Int(be32(data, trex.payload.lowerBound + 12)), Int(be32(data, trex.payload.lowerBound + 16)))
        }

        var samples: [Sample] = []
        var chunks: [Int] = []
        for fragment in top where fragment.type == "moof" {
            for traf in try boxes(data, fragment.payload.lowerBound, fragment.payload.upperBound) where traf.type == "traf" {
                try collect(data, traf, moofStart: fragment.start, defaults: defaults, samples: &samples, chunks: &chunks)
            }
        }
        guard !samples.isEmpty else { throw Failure(message: "no samples") }

        let mdatSize = samples.reduce(0) { $0 + $1.size }
        let leading = ftypBox()
        // The size of the moov does not depend on where the data starts, so it is measured once and then built for real
        let measured = try moovBox(data, moovChildren, samples, chunks, firstChunkAt: 0)
        let dataStart = leading.count + measured.count + 8
        let rebuilt = try moovBox(data, moovChildren, samples, chunks, firstChunkAt: dataStart)

        var out = Data()
        out.reserveCapacity(leading.count + rebuilt.count + 8 + mdatSize)
        out.append(leading)
        out.append(rebuilt)
        out.append(be32Bytes(UInt32(8 + mdatSize)))
        out.append(contentsOf: Array("mdat".utf8))
        for sample in samples { out.append(data[data.startIndex + sample.offset..<data.startIndex + sample.offset + sample.size]) }
        return out
    }

    // ------------------------------------------------------------------ reading

    private static func boxes(_ data: Data, _ from: Int, _ to: Int) throws -> [Box] {
        var found: [Box] = []
        var at = from
        while at + 8 <= to {
            var size = Int(be32(data, at))
            let type = String(decoding: data[data.startIndex + at + 4..<data.startIndex + at + 8], as: UTF8.self)
            var header = 8
            if size == 1 {
                guard at + 16 <= to else { throw Failure(message: "cut box header") }
                size = Int(be32(data, at + 8)) << 32 | Int(be32(data, at + 12))
                header = 16
            } else if size == 0 {
                size = to - at
            }
            guard size >= header, at + size <= to else { throw Failure(message: "box \(type) runs past its parent") }
            found.append(Box(type: type, start: at, size: size, header: header))
            at += size
        }
        return found
    }

    /// The samples of one track fragment: where they are in the file, how big and how long.
    private static func collect(_ data: Data, _ traf: Box, moofStart: Int, defaults: (duration: Int, size: Int),
                                samples: inout [Sample], chunks: inout [Int]) throws {
        let children = try boxes(data, traf.payload.lowerBound, traf.payload.upperBound)
        guard let tfhd = children.first(where: { $0.type == "tfhd" }) else { throw Failure(message: "no tfhd") }
        let flags = Int(be32(data, tfhd.payload.lowerBound)) & 0xFFFFFF
        var at = tfhd.payload.lowerBound + 8 // version+flags, track id
        var base = moofStart
        if flags & 0x1 != 0 {
            base = Int(be32(data, at)) << 32 | Int(be32(data, at + 4))
            at += 8
        }
        if flags & 0x2 != 0 { at += 4 }
        var duration = defaults.duration
        var size = defaults.size
        if flags & 0x8 != 0 { duration = Int(be32(data, at)); at += 4 }
        if flags & 0x10 != 0 { size = Int(be32(data, at)); at += 4 }

        for trun in children where trun.type == "trun" {
            let runFlags = Int(be32(data, trun.payload.lowerBound)) & 0xFFFFFF
            let count = Int(be32(data, trun.payload.lowerBound + 4))
            var cursor = trun.payload.lowerBound + 8
            var position = base
            if runFlags & 0x1 != 0 {
                position += Int(Int32(bitPattern: be32(data, cursor)))
                cursor += 4
            } else if let last = samples.last {
                position = last.offset + last.size
            }
            if runFlags & 0x4 != 0 { cursor += 4 }
            var added = 0
            for _ in 0..<count {
                var sampleDuration = duration
                var sampleSize = size
                if runFlags & 0x100 != 0 { sampleDuration = Int(be32(data, cursor)); cursor += 4 }
                if runFlags & 0x200 != 0 { sampleSize = Int(be32(data, cursor)); cursor += 4 }
                if runFlags & 0x400 != 0 { cursor += 4 }
                if runFlags & 0x800 != 0 { cursor += 4 }
                guard sampleSize > 0, position >= 0, position + sampleSize <= data.count else { throw Failure(message: "sample outside the file") }
                samples.append(Sample(offset: position, size: sampleSize, duration: sampleDuration))
                position += sampleSize
                added += 1
            }
            if added > 0 { chunks.append(added) }
        }
    }

    // ------------------------------------------------------------------ writing

    /// What an audio MP4 that any player knows starts with; the brand of the original ("dash") is the thing to leave behind.
    private static func ftypBox() -> Data {
        var body = Data(Array("M4A ".utf8))
        body.append(be32Bytes(0))
        for brand in ["M4A ", "mp42", "isom"] { body.append(contentsOf: Array(brand.utf8)) }
        return box("ftyp", body)
    }

    /// How long the song is, in the units of the media and of the movie.
    private struct Length {
        let media: Int
        let movie: Int
    }

    private static func moovBox(_ data: Data, _ children: [Box], _ samples: [Sample], _ chunks: [Int], firstChunkAt: Int) throws -> Data {
        let media = samples.reduce(0) { $0 + $1.duration }
        guard let mvhd = children.first(where: { $0.type == "mvhd" }),
              let mediaScale = try timescale(data, in: children, path: ["trak", "mdia", "mdhd"]),
              mediaScale > 0 else { throw Failure(message: "no timescale") }
        let movieScale = Int(be32(data, mvhd.payload.lowerBound + (data[data.startIndex + mvhd.payload.lowerBound] == 1 ? 20 : 12)))
        let length = Length(media: media, movie: media * movieScale / mediaScale)
        var body = Data()
        for child in children where child.type != "mvex" {
            body.append(try rewrite(data, child, length: length, samples: samples, chunks: chunks, firstChunkAt: firstChunkAt))
        }
        return box("moov", body)
    }

    private static func timescale(_ data: Data, in boxes: [Box], path: [String]) throws -> Int? {
        guard let step = path.first, let found = boxes.first(where: { $0.type == step }) else { return nil }
        if path.count == 1 {
            return Int(be32(data, found.payload.lowerBound + (data[data.startIndex + found.payload.lowerBound] == 1 ? 20 : 12)))
        }
        return try timescale(data, in: try Self.boxes(data, found.payload.lowerBound, found.payload.upperBound), path: Array(path.dropFirst()))
    }

    /// Copies a box, changing what a fragmented file leaves empty or wrong: durations, and the tables of samples.
    private static func rewrite(_ data: Data, _ source: Box, length: Length, samples: [Sample], chunks: [Int], firstChunkAt: Int) throws -> Data {
        let payload = Data(data[data.startIndex + source.payload.lowerBound..<data.startIndex + source.payload.upperBound])
        switch source.type {
        case "mvhd": return box("mvhd", settingDuration(payload, v0: 16..<20, v1: 24..<32, to: length.movie))
        case "tkhd": return box("tkhd", settingDuration(payload, v0: 20..<24, v1: 28..<36, to: length.movie))
        case "mdhd": return box("mdhd", settingDuration(payload, v0: 16..<20, v1: 24..<32, to: length.media))
        case "elst": return box("elst", settingDuration(payload, v0: 8..<12, v1: 8..<16, to: length.movie, entries: true))
        case "stts": return box("stts", sampleDurations(samples))
        case "stsc": return box("stsc", sampleToChunk(chunks))
        case "stsz":
            var body = Data(count: 4)
            body.append(be32Bytes(0))
            body.append(be32Bytes(UInt32(samples.count)))
            for sample in samples { body.append(be32Bytes(UInt32(sample.size))) }
            return box("stsz", body)
        case "stco":
            var body = Data(count: 4)
            body.append(be32Bytes(UInt32(chunks.count)))
            var at = firstChunkAt
            var index = 0
            for count in chunks {
                body.append(be32Bytes(UInt32(at)))
                for _ in 0..<count {
                    at += samples[index].size
                    index += 1
                }
            }
            return box("stco", body)
        default:
            guard containers.contains(source.type) else { return box(source.type, payload) }
            var body = Data()
            for child in try boxes(data, source.payload.lowerBound, source.payload.upperBound) {
                body.append(try rewrite(data, child, length: length, samples: samples, chunks: chunks, firstChunkAt: firstChunkAt))
            }
            return box(source.type, body)
        }
    }

    /// A header with its duration field set; the field is where the version of the box says it is. [entries] marks an
    /// edit list, whose first entry's length is the one set, and only when it has an entry.
    private static func settingDuration(_ payload: Data, v0: Range<Int>, v1: Range<Int>, to value: Int, entries: Bool = false) -> Data {
        var body = payload
        let range = body.first == 1 ? v1 : v0
        guard body.count >= range.upperBound else { return body }
        if entries && be32(body, 4) == 0 { return body }
        for (index, at) in range.enumerated() {
            body[body.startIndex + at] = UInt8((value >> (8 * (range.count - 1 - index))) & 0xFF)
        }
        return body
    }

    private static func sampleDurations(_ samples: [Sample]) -> Data {
        var runs: [(count: Int, duration: Int)] = []
        for sample in samples {
            if let last = runs.last, last.duration == sample.duration {
                runs[runs.count - 1].count += 1
            } else {
                runs.append((1, sample.duration))
            }
        }
        var body = Data(count: 4)
        body.append(be32Bytes(UInt32(runs.count)))
        for run in runs {
            body.append(be32Bytes(UInt32(run.count)))
            body.append(be32Bytes(UInt32(run.duration)))
        }
        return body
    }

    private static func sampleToChunk(_ chunks: [Int]) -> Data {
        var entries: [(first: Int, perChunk: Int)] = []
        for (index, count) in chunks.enumerated() where entries.last?.perChunk != count {
            entries.append((index + 1, count))
        }
        var body = Data(count: 4)
        body.append(be32Bytes(UInt32(entries.count)))
        for entry in entries {
            body.append(be32Bytes(UInt32(entry.first)))
            body.append(be32Bytes(UInt32(entry.perChunk)))
            body.append(be32Bytes(1))
        }
        return body
    }

    private static func box(_ type: String, _ body: Data) -> Data {
        var out = be32Bytes(UInt32(8 + body.count))
        out.append(contentsOf: Array(type.utf8))
        out.append(body)
        return out
    }

    private static func be32(_ data: Data, _ at: Int) -> UInt32 {
        let base = data.startIndex + at
        return UInt32(data[base]) << 24 | UInt32(data[base + 1]) << 16 | UInt32(data[base + 2]) << 8 | UInt32(data[base + 3])
    }

    private static func be32Bytes(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
}
