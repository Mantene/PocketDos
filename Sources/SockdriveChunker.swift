import Foundation

/// Splits a raw disk image into the sockdrive server layout js-dos streams
/// from: a directory of 256 KiB chunk files named `<range>.raw` plus a
/// `sockdrive.metaj` manifest.
///
/// This is a Swift port of `mkd` from the sockdrive Rust CLI
/// (sockdrive/src/main.rs), replicated semantic-for-semantic because the
/// js-dos sockdrive client parses the manifest and fetches chunks by these
/// exact rules:
///  - Chunks are AHEAD_READ_SIZE = 256 KiB. Every written chunk file is
///    exactly that long — a partial final range is zero-PADDED, not shortened.
///  - All-zero ranges produce no file at all; their indices land in the
///    manifest's `dropped_ranges` and the client synthesizes zeros for them.
///    (This is why the mostly-empty tail of an install image costs nothing.)
///  - The image must byte-for-byte match one of the known drive templates —
///    the manifest's geometry (cylinders/heads/sectors) comes from the
///    matched template, not from anything read out of the image.
///  - `preload_ranges` is a HINT LIST (fetch-first ordering for fast boot),
///    filtered to ranges that exist: in-bounds and not dropped, original
///    order kept. The default list is the CLI's hand-tuned boot profile.
///
/// Reads stream through one reused 256 KiB buffer; peak memory is independent
/// of image size, so chunking the ~240 MB install source is iPhone-safe.
enum SockdriveChunker {

    /// One range = one chunk file = the client's read-ahead unit.
    static let aheadReadSize = 256 * 1024

    // MARK: - Drive templates

    /// Geometry manifest seed, mirroring sockdrive/drives/*.json. `sizeKiB`
    /// doubles as the match key: mkd identifies the template by the image's
    /// exact byte size and refuses anything else.
    struct DriveTemplate: Equatable {
        let name: String
        let sizeKiB: Int
        let heads: Int
        let cylinders: Int
        let sectors: Int
        let sectorSize: Int

        var sizeBytes: Int { sizeKiB * 1024 }

        /// 489/16/63 — what FAT16ImageBuilder's production geometry produces.
        static let fat16_256m = DriveTemplate(
            name: "fat16-256m", sizeKiB: 246_456, heads: 16, cylinders: 489,
            sectors: 63, sectorSize: 512)

        /// The blank-C: target template (520/128/63), listed for parity with
        /// the CLI; the wizard's on-device chunking only ever sees D: images.
        static let fat32_2gb = DriveTemplate(
            name: "fat32-2gb", sizeKiB: 2_097_152, heads: 128, cylinders: 520,
            sectors: 63, sectorSize: 512)
    }

    // MARK: - Errors

    enum ChunkerError: Error, LocalizedError, Equatable {
        case inputUnreadable(String, String)
        case sizeMismatch(actual: Int, expected: [Int])
        case outputExists(String)
        case shortRead(range: Int)
        case ioFailure(String)

        var errorDescription: String? {
            switch self {
            case .inputUnreadable(let path, let why):
                return "Couldn't open the disk image \(path): \(why)"
            case .sizeMismatch(let actual, let expected):
                return "The image is \(actual) bytes; sockdrive templates require "
                    + expected.map(String.init).joined(separator: " or ") + "."
            case .outputExists(let path):
                return "The output directory \(path) already exists."
            case .shortRead(let range):
                return "The image ended early while reading range \(range)."
            case .ioFailure(let why): return "Couldn't write the sockdrive: \(why)"
            }
        }
    }

    // MARK: - Manifest

    /// The metaj manifest, one field per key the js-dos client reads. Encoded
    /// with sorted keys and no whitespace, which reproduces serde_json's
    /// output byte-for-byte (its Value maps are BTreeMaps — also
    /// alphabetical) — handy for oracle comparisons against the Rust CLI.
    struct Metaj: Codable, Equatable {
        let ahead_read: Int
        let cylinders: Int
        let dropped_ranges: [UInt32]
        let heads: Int
        let name: String
        let preload_ranges: [UInt32]
        let range_count: Int
        let sector_size: Int
        let sectors: Int
        let size: Int
    }

    /// What a build produced, mostly for progress/telemetry and tests; the
    /// on-disk `sockdrive.metaj` is the artifact of record.
    struct Summary: Equatable {
        let manifest: Metaj
        let writtenChunks: Int
    }

    // MARK: - mkd

    /// Chunks `rawImage` into `outputDir` (created here; erroring if it
    /// already exists, exactly like the CLI — a half-written drive directory
    /// must never be silently topped up). Pass `preloadRanges` to override
    /// the CLI's default boot-profile hint list.
    @discardableResult
    static func makeDrive(from rawImage: URL, to outputDir: URL,
                          preloadRanges: [UInt32]? = nil,
                          templates: [DriveTemplate] = [.fat16_256m, .fat32_2gb]) throws -> Summary {
        let inputSize: Int
        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: rawImage)
            inputSize = Int(try input.seekToEnd())
            try input.seek(toOffset: 0)
        } catch {
            throw ChunkerError.inputUnreadable(rawImage.path, error.localizedDescription)
        }
        defer { try? input.close() }

        guard let template = templates.first(where: { $0.sizeBytes == inputSize }) else {
            throw ChunkerError.sizeMismatch(actual: inputSize,
                                            expected: templates.map(\.sizeBytes))
        }

        let rangeCount = (inputSize + aheadReadSize - 1) / aheadReadSize

        guard !FileManager.default.fileExists(atPath: outputDir.path) else {
            throw ChunkerError.outputExists(outputDir.path)
        }
        do {
            // Deliberately NOT withIntermediateDirectories — same contract as
            // the CLI's create_dir: a missing parent is a caller bug.
            try FileManager.default.createDirectory(at: outputDir,
                                                    withIntermediateDirectories: false)
        } catch {
            throw ChunkerError.ioFailure(error.localizedDescription)
        }

        // The chunk loop. One reused buffer; the final partial range is
        // zero-filled first so its written form is full-length, matching mkd.
        var dropped: [UInt32] = []
        var written = 0
        for range in 0..<rangeCount {
            let start = range * aheadReadSize
            let wanted = min(aheadReadSize, inputSize - start)
            var buffer: Data
            do {
                buffer = try input.read(upToCount: wanted) ?? Data()
            } catch {
                throw ChunkerError.ioFailure(error.localizedDescription)
            }
            guard buffer.count == wanted else { throw ChunkerError.shortRead(range: range) }
            if buffer.count < aheadReadSize {
                buffer.append(Data(count: aheadReadSize - buffer.count))
            }

            let isAllZero = buffer.withUnsafeBytes { raw in
                !raw.contains { $0 != 0 }
            }
            if isAllZero {
                dropped.append(UInt32(range))
            } else {
                do {
                    try buffer.write(to: outputDir.appendingPathComponent("\(range).raw"))
                } catch {
                    throw ChunkerError.ioFailure(error.localizedDescription)
                }
                written += 1
            }
        }

        // Preload hints survive only if they point at fetchable ranges. The
        // CLI applies the same two filters to its DEFAULT_PRELOAD (which
        // deliberately includes out-of-range entries like 7195 — it is shared
        // across drive sizes).
        let droppedSet = Set(dropped)
        let preload = (preloadRanges ?? defaultPreload).filter {
            $0 < UInt32(rangeCount) && !droppedSet.contains($0)
        }

        let manifest = Metaj(
            ahead_read: aheadReadSize,
            cylinders: template.cylinders,
            dropped_ranges: dropped,
            heads: template.heads,
            name: template.name,
            preload_ranges: preload,
            range_count: rangeCount,
            sector_size: template.sectorSize,
            sectors: template.sectors,
            size: template.sizeKiB)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(manifest)
                .write(to: outputDir.appendingPathComponent("sockdrive.metaj"))
        } catch {
            throw ChunkerError.ioFailure(error.localizedDescription)
        }

        return Summary(manifest: manifest, writtenChunks: written)
    }

    // MARK: - Default preload profile

    /// The CLI's DEFAULT_PRELOAD, ported verbatim (same string form, parsed
    /// once) — a hand-tuned fetch-first ordering covering boot sector, FATs,
    /// directories and the early Setup files. Entries beyond a drive's range
    /// (7195) or landing on dropped ranges are filtered per drive at mkd time.
    static let defaultPreload: [UInt32] = defaultPreloadString
        .split(separator: ",")
        .compactMap { UInt32($0) }

    private static let defaultPreloadString = "0,16,1,52,50,68,51,145,280,152,291,227,234,"
        + "226,207,279,7195,257,233,179,231,390,177,346,66,71,96,197,297,70,90,113,146,87,"
        + "89,98,2,93,199,236,54,198,129,228,296,299,311,180,20,100,208,218,219,232,276,"
        + "300,24,114,143,195,229,239,253,241,277,289,49,155,240,21,23,99,116,151,217,97,"
        + "202,429,32,157,262,327,200,201,25,156,237,278,329,82,141,142,154,158,178,338,"
        + "339,84,78,65,148,160,271,282,117,119,144,275,83,85,92,3,159,242,274,105,118,"
        + "543,64,187,261,269,86,225,545,22,38,57,188,287,330,176,359,544,56,281,295,245,"
        + "79,30,407,165,194,235,285,465,101,238,411,58,138,193,293,394,133,134,168,412,"
        + "6,55,62,163,333,343,112,172,428,430,17,18,19,67,184,332,171,104,7,36,284,334,"
        + "386,395,139,167,357,431,37,76,140,460,244,258,331,532,290,12,13,14,69,153,272,"
        + "328,396,461,675,175,663,664,149,405,531,15,123,63,464,53,31,221,252,294,340,"
        + "344,35,60,72,288,246,459,462,463,4,513,546,677,9,75,94,164,216,251,363,220,"
        + "658,701,397,59,196,230,354,364,667,323,533,729"
}
