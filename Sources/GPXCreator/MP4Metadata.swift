import Foundation

/// Restores MP4 metadata that FFmpeg cannot carry through a video encode.
/// Media data remains in place; only small movie/sample-description atoms are read.
enum MP4Metadata {
    struct Atom {
        var type: String
        var payload: Data
        var data: Data {
            var result = integer(UInt64(payload.count + 8), bytes: 4)
            result.append(Data(type.utf8)); result.append(payload); return result
        }
    }
    static func integer(_ value: UInt64, bytes: Int) -> Data {
        Data((0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    static func number(_ data: Data, _ offset: Int, _ count: Int) throws -> UInt64 {
        guard offset >= 0, count <= 8, offset + count <= data.count else { throw VideoToolError(message: "Invalid MP4 metadata structure.") }
        return data.subdata(in: offset..<offset+count).reduce(0) { ($0 << 8) | UInt64($1) }
    }
    static func atoms(_ data: Data) throws -> [Atom] {
        var result: [Atom] = []; var offset = 0
        while offset < data.count {
            guard data.count-offset >= 8 else { throw VideoToolError(message: "Truncated MP4 metadata.") }
            var size = try number(data, offset, 4); var header = 8
            let type = String(data: data.subdata(in: offset+4..<offset+8), encoding: .ascii) ?? ""
            if size == 1 { size = try number(data, offset+8, 8); header = 16 }
            if size == 0 { size = UInt64(data.count-offset) }
            guard size >= header, size <= data.count-offset else { throw VideoToolError(message: "Invalid MP4 atom size.") }
            result.append(Atom(type: type, payload: data.subdata(in: offset+header..<offset+Int(size))))
            offset += Int(size)
        }
        return result
    }
    static func joined(_ atoms: [Atom]) -> Data { atoms.reduce(into: Data()) { $0.append($1.data) } }
    static func movie(_ url: URL) throws -> (UInt64, UInt64, Atom) {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let end = try file.seekToEnd(); var offset: UInt64 = 0
        while offset + 8 <= end {
            try file.seek(toOffset: offset)
            let header = try file.read(upToCount: 16) ?? Data()
            var size = try number(header, 0, 4); var length = 8
            let type = String(data: header.subdata(in: 4..<8), encoding: .ascii)
            if size == 1 { size = try number(header, 8, 8); length = 16 }
            if size == 0 { size = end-offset }
            guard size >= length, size <= end-offset else { throw VideoToolError(message: "Invalid MP4 file structure.") }
            if type == "moov" {
                guard size < 128*1024*1024 else { throw VideoToolError(message: "MP4 metadata is too large to restore safely.") }
                try file.seek(toOffset: offset + UInt64(length))
                let payload = try file.read(upToCount: Int(size)-length) ?? Data()
                guard payload.count == Int(size)-length else { throw VideoToolError(message: "Truncated MP4 movie atom.") }
                return (offset, size, Atom(type: "moov", payload: payload))
            }
            offset += size
        }
        throw VideoToolError(message: "MP4 movie metadata was not found.")
    }
    static func child(_ atom: Atom, _ path: [String]) throws -> Atom? {
        guard let first = path.first else { return atom }
        guard let next = try atoms(atom.payload).first(where: { $0.type == first }) else { return nil }
        return try child(next, Array(path.dropFirst()))
    }
    static func modify(_ atom: Atom, path: [String], transform: (Atom) throws -> Atom) throws -> Atom {
        guard let first = path.first else { return try transform(atom) }
        let children = try atoms(atom.payload).map { item in
            item.type == first ? try modify(item, path: Array(path.dropFirst()), transform: transform) : item
        }
        return Atom(type: atom.type, payload: joined(children))
    }
    static func handler(_ track: Atom) throws -> String {
        guard let handler = try child(track, ["mdia", "hdlr"]), handler.payload.count >= 12 else { return "" }
        return String(data: handler.payload.subdata(in: 8..<12), encoding: .ascii) ?? ""
    }
    static func restore(source: URL, output: URL) throws {
        let (_, _, original) = try movie(source)
        let (offset, _, encoded) = try movie(output)
        let sourceTracks = try atoms(original.payload).filter { $0.type == "trak" }
        var outputChildren = try atoms(encoded.payload)
        let originalVideo = try sourceTracks.first { try handler($0) == "vide" }
        if let originalVideo, let originalDescription = try child(originalVideo, ["mdia", "minf", "stbl", "stsd"]) {
            // VisualSampleEntry has a fixed 78-byte header after the atom header.
            let sourceEntries = try atoms(Data(originalDescription.payload.dropFirst(8)))
            if let sample = sourceEntries.first, sample.payload.count >= 78 {
                let spatial = try atoms(Data(sample.payload.dropFirst(78))).filter { ["sv3d", "st3d"].contains($0.type) }
                if !spatial.isEmpty {
                    for index in outputChildren.indices where outputChildren[index].type == "trak" {
                        guard try handler(outputChildren[index]) == "vide" else { continue }
                        outputChildren[index] = try modify(outputChildren[index], path: ["mdia", "minf", "stbl", "stsd"]) { description in
                            var entries = try atoms(Data(description.payload.dropFirst(8)))
                            guard !entries.isEmpty, entries[0].payload.count >= 78 else { throw VideoToolError(message: "Invalid encoded video sample description.") }
                            let others = try atoms(Data(entries[0].payload.dropFirst(78))).filter { !["sv3d", "st3d"].contains($0.type) }
                            entries[0].payload = Data(entries[0].payload.prefix(78)) + joined(others + spatial)
                            return Atom(type: description.type, payload: Data(description.payload.prefix(8)) + joined(entries))
                        }
                    }
                }
            }
        }
        let file = try FileHandle(forUpdating: output); defer { try? file.close() }
        for track in sourceTracks where try handler(track) == "tmcd" {
            // Camera timecode tracks normally contain a single four-byte start-frame sample.
            guard let stsz = try child(track, ["mdia", "minf", "stbl", "stsz"]),
                  try number(stsz.payload, 8, 4) == 1,
                  let chunks = try child(track, ["mdia", "minf", "stbl", "stco"]) ?? child(track, ["mdia", "minf", "stbl", "co64"]),
                  try number(chunks.payload, 4, 4) == 1 else { throw VideoToolError(message: "This timecode track has an unsupported layout. No export was saved.") }
            let fixedSize = try number(stsz.payload, 4, 4)
            let sampleSize = fixedSize > 0 ? fixedSize : try number(stsz.payload, 12, 4)
            guard sampleSize > 0, sampleSize < 1024*1024 else { throw VideoToolError(message: "Invalid timecode sample size.") }
            let sourceOffset = try number(chunks.payload, 8, chunks.type == "co64" ? 8 : 4)
            let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
            try input.seek(toOffset: sourceOffset)
            let sample = try input.read(upToCount: Int(sampleSize)) ?? Data()
            guard sample.count == sampleSize else { throw VideoToolError(message: "Truncated source timecode track.") }
            let end = try file.seekToEnd()
            try file.write(contentsOf: Atom(type: "mdat", payload: sample).data)
            let copied = try modify(track, path: ["mdia", "minf", "stbl"]) { table in
                var children = try atoms(table.payload).filter { !["stco", "co64"].contains($0.type) }
                children.append(Atom(type: "co64", payload: Data(repeating: 0, count: 4) + integer(1, bytes: 4) + integer(end+8, bytes: 8)))
                return Atom(type: "stbl", payload: joined(children))
            }
            // Keep the source track ID and reference; FFmpeg's retained streams use the same IDs.
            if let tkhd = try child(copied, ["tkhd"]) {
                let id = try number(tkhd.payload, tkhd.payload.first == 1 ? 20 : 12, 4)
                for existing in outputChildren where existing.type == "trak" {
                    if let header = try child(existing, ["tkhd"]), try number(header.payload, header.payload.first == 1 ? 20 : 12, 4) == id {
                        throw VideoToolError(message: "Timecode track ID conflicts with an exported track.")
                    }
                }
                // The movie header's next_track_ID must exceed the restored track ID.
                if let i = outputChildren.firstIndex(where: { $0.type == "mvhd" }), outputChildren[i].payload.count >= 4 {
                    let count = outputChildren[i].payload.count
                    let next = try number(outputChildren[i].payload, count-4, 4)
                    outputChildren[i].payload.replaceSubrange(count-4..<count, with: integer(max(next, id+1), bytes: 4))
                }
            }
            outputChildren.append(copied)
        }
        if let originalVideo, let references = try child(originalVideo, ["tref"]) {
            for i in outputChildren.indices where outputChildren[i].type == "trak" {
                if try handler(outputChildren[i]) == "vide" {
                    var children = try atoms(outputChildren[i].payload).filter { $0.type != "tref" }
                    children.append(references); outputChildren[i].payload = joined(children)
                }
            }
        }
        // Replace the old moov with free space, append the restored moov without shifting media offsets.
        try file.seek(toOffset: offset+4); try file.write(contentsOf: Data("free".utf8))
        try file.seekToEnd(); try file.write(contentsOf: Atom(type: "moov", payload: joined(outputChildren)).data)
        try file.synchronize()
    }
}
