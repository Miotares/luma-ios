import Foundation

/// Reads the embedded cover from a FLAC file. AVFoundation exposes a FLAC's Vorbis comments but
/// NOT its PICTURE metadata block, so FLAC albums used to import without artwork.
///
/// A FLAC stream is the marker "fLaC" followed by metadata blocks, each with a 4-byte header
/// (1 bit last-block flag, 7 bits type, 24 bits length). Block type 6 is a picture.
nonisolated enum FLACPicture {
    /// Returns the front cover if there is one, otherwise the first embedded picture.
    static func read(url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.read(upToCount: 4)) == Data("fLaC".utf8) else { return nil }

        var fallback: Data?
        // Bounded: a well-formed file has a handful of blocks; never loop on a corrupt one.
        for _ in 0..<64 {
            guard let header = try? handle.read(upToCount: 4), header.count == 4 else { break }
            let bytes = [UInt8](header)
            let isLast = bytes[0] & 0x80 != 0
            let type = bytes[0] & 0x7F
            let length = Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])

            if type == 6, length > 32, length <= 32 * 1024 * 1024,
               let block = try? handle.read(upToCount: length), block.count == length,
               let picture = parsePicture(block) {
                if picture.isFrontCover { return picture.data }
                if fallback == nil { fallback = picture.data }
            } else {
                guard let offset = try? handle.offset(),
                      (try? handle.seek(toOffset: offset + UInt64(length))) != nil else { break }
            }
            if isLast { break }
        }
        return fallback
    }

    /// Picture block layout (all integers big-endian): type, MIME length + MIME, description
    /// length + description, width, height, depth, colour count, data length + data.
    private static func parsePicture(_ block: Data) -> (data: Data, isFrontCover: Bool)? {
        let bytes = [UInt8](block)
        var cursor = 0
        func readUInt32() -> Int? {
            guard cursor + 4 <= bytes.count else { return nil }
            defer { cursor += 4 }
            return Int(bytes[cursor]) << 24 | Int(bytes[cursor + 1]) << 16
                | Int(bytes[cursor + 2]) << 8 | Int(bytes[cursor + 3])
        }
        guard let pictureType = readUInt32(), let mimeLength = readUInt32() else { return nil }
        cursor += mimeLength
        guard let descriptionLength = readUInt32() else { return nil }
        cursor += descriptionLength + 16   // skip width, height, depth, colour count
        guard let dataLength = readUInt32(), dataLength > 0,
              cursor + dataLength <= bytes.count else { return nil }
        return (Data(bytes[cursor..<cursor + dataLength]), pictureType == 3)
    }
}
