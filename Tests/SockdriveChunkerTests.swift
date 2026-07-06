import XCTest
@testable import PocketDOS

/// Exercises the sockdrive chunker against SYNTHETIC raw images with
/// hand-placed zero runs, asserting the chunk set, the zero-range dropping,
/// and the manifest against hand-computed values. Byte-parity with the Rust
/// CLI on the real install image is the oracle run outside the suite; these
/// tests pin the ported semantics so a refactor can't quietly bend them.
final class SockdriveChunkerTests: XCTestCase {

    /// A tiny template so tests move ~1 MB, not ~240 MB: 1124 KiB is
    /// deliberately NOT a multiple of 256 KiB, giving 4 full ranges plus a
    /// 100 KiB partial fifth — the zero-padding edge case.
    private static let testTemplate = SockdriveChunker.DriveTemplate(
        name: "test-1m", sizeKiB: 1124, heads: 2, cylinders: 4, sectors: 8, sectorSize: 512)

    private static let ahead = SockdriveChunker.aheadReadSize // 262144

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunker-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Writes a raw image of the test template's size with the given
    /// (offset, byte) pokes on an otherwise all-zero canvas.
    private func writeRaw(at url: URL, pokes: [(offset: Int, byte: UInt8)]) throws {
        var data = Data(count: Self.testTemplate.sizeKiB * 1024)
        for poke in pokes { data[poke.offset] = poke.byte }
        try data.write(to: url)
    }

    // MARK: - Chunking semantics

    func testChunkSetDroppedRangesAndZeroPadding() throws {
        let dir = try makeTempDir()
        let raw = dir.appendingPathComponent("test.raw")
        // Ranges: 0 marked at its first byte, 1 all-zero, 2 marked at its
        // LAST byte (boundary off-by-ones die here), 3 all-zero, 4 partial
        // (100 KiB of image) marked inside.
        try writeRaw(at: raw, pokes: [
            (0, 0xAB),
            (3 * Self.ahead - 1, 0xCD),
            (4 * Self.ahead + 5, 0xEF),
        ])

        let out = dir.appendingPathComponent("drive")
        let summary = try SockdriveChunker.makeDrive(from: raw, to: out,
                                                     templates: [Self.testTemplate])

        XCTAssertEqual(summary.writtenChunks, 3)
        XCTAssertEqual(summary.manifest.range_count, 5)
        XCTAssertEqual(summary.manifest.dropped_ranges, [1, 3])

        let listing = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        XCTAssertEqual(listing, ["0.raw", "2.raw", "4.raw", "sockdrive.metaj"])

        // Every written chunk is full-length; the partial range 4 is padded
        // with zeros past the image's end, exactly like the Rust mkd.
        let chunk0 = try Data(contentsOf: out.appendingPathComponent("0.raw"))
        let chunk2 = try Data(contentsOf: out.appendingPathComponent("2.raw"))
        let chunk4 = try Data(contentsOf: out.appendingPathComponent("4.raw"))
        XCTAssertEqual(chunk0.count, Self.ahead)
        XCTAssertEqual(chunk2.count, Self.ahead)
        XCTAssertEqual(chunk4.count, Self.ahead)
        XCTAssertEqual(chunk0[0], 0xAB)
        XCTAssertEqual(chunk2[Self.ahead - 1], 0xCD)
        XCTAssertEqual(chunk4[5], 0xEF)
        // The image contributes only 100 KiB to range 4; the rest is padding.
        let imageTail = Self.testTemplate.sizeKiB * 1024 - 4 * Self.ahead
        XCTAssertTrue(chunk4[imageTail...].allSatisfy { $0 == 0 })
    }

    func testAllZeroImageDropsEveryRange() throws {
        let dir = try makeTempDir()
        let raw = dir.appendingPathComponent("zero.raw")
        try writeRaw(at: raw, pokes: [])
        let out = dir.appendingPathComponent("drive")
        let summary = try SockdriveChunker.makeDrive(from: raw, to: out,
                                                     templates: [Self.testTemplate])
        XCTAssertEqual(summary.writtenChunks, 0)
        XCTAssertEqual(summary.manifest.dropped_ranges, [0, 1, 2, 3, 4])
        XCTAssertEqual(summary.manifest.preload_ranges, [],
                       "every default preload hint points at a dropped range here")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path),
                       ["sockdrive.metaj"])
    }

    // MARK: - Manifest

    /// Byte-compares the manifest against serde_json's exact output shape:
    /// alphabetical keys, no whitespace. Numbers are hand-computed from the
    /// test template. Preload [4,0,2,1,9999] must filter to [4,0,2] — 1 is
    /// dropped, 9999 out of range — with the caller's ORDER preserved.
    func testMetajBytesMatchRustSerialization() throws {
        let dir = try makeTempDir()
        let raw = dir.appendingPathComponent("test.raw")
        try writeRaw(at: raw, pokes: [(0, 1), (2 * Self.ahead, 1), (4 * Self.ahead, 1)])
        let out = dir.appendingPathComponent("drive")
        try SockdriveChunker.makeDrive(from: raw, to: out,
                                       preloadRanges: [4, 0, 2, 1, 9999],
                                       templates: [Self.testTemplate])

        let metaj = try Data(contentsOf: out.appendingPathComponent("sockdrive.metaj"))
        let expected = #"{"ahead_read":262144,"cylinders":4,"dropped_ranges":[1,3],"# +
            #""heads":2,"name":"test-1m","preload_ranges":[4,0,2],"range_count":5,"# +
            #""sector_size":512,"sectors":8,"size":1124}"#
        XCTAssertEqual(String(decoding: metaj, as: UTF8.self), expected)
    }

    /// The production fat16-256m template accepts exactly the builder's image
    /// size and yields the ground-truth range count (963) — pinned against
    /// the metaj of the proven wizard-s0 install-source drive.
    func testProductionTemplateRangeCount() throws {
        let dir = try makeTempDir()
        let raw = dir.appendingPathComponent("prod.raw")
        // Sparse all-zero at exactly the template size; chunking reads it all
        // but writes nothing, so this stays fast.
        FileManager.default.createFile(atPath: raw.path, contents: nil)
        let handle = try FileHandle(forWritingTo: raw)
        try handle.truncate(atOffset: UInt64(246_456 * 1024))
        try handle.close()

        let out = dir.appendingPathComponent("drive")
        let summary = try SockdriveChunker.makeDrive(from: raw, to: out)
        XCTAssertEqual(summary.manifest.name, "fat16-256m")
        XCTAssertEqual(summary.manifest.range_count, 963)
        XCTAssertEqual(summary.manifest.cylinders, 489)
        XCTAssertEqual(summary.manifest.heads, 16)
        XCTAssertEqual(summary.manifest.sectors, 63)
        XCTAssertEqual(summary.manifest.sector_size, 512)
        XCTAssertEqual(summary.manifest.size, 246_456)
        XCTAssertEqual(summary.manifest.dropped_ranges.count, 963)
        XCTAssertEqual(summary.writtenChunks, 0)
    }

    // MARK: - Default preload port

    /// Guards the DEFAULT_PRELOAD transcription from the Rust CLI: right
    /// length, right head, right tail, and the two entries whose whole point
    /// is to be filtered later (7195 exceeds the 256 MB drive's range; 729 is
    /// dropped on the proven image) must be present here, unfiltered.
    func testDefaultPreloadMatchesRustCLI() {
        let preload = SockdriveChunker.defaultPreload
        XCTAssertEqual(preload.count, 254)
        XCTAssertEqual(Array(preload.prefix(4)), [0, 16, 1, 52])
        XCTAssertEqual(preload.last, 729)
        XCTAssertTrue(preload.contains(7195))
        XCTAssertEqual(preload[16], 7195, "7195 sits between 279 and 257 in the CLI string")
    }

    // MARK: - Failure modes

    func testExistingOutputDirectoryIsRefused() throws {
        let dir = try makeTempDir()
        let raw = dir.appendingPathComponent("test.raw")
        try writeRaw(at: raw, pokes: [(0, 1)])
        let out = dir.appendingPathComponent("drive")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        XCTAssertThrowsError(try SockdriveChunker.makeDrive(
            from: raw, to: out, templates: [Self.testTemplate])) { error in
            XCTAssertEqual(error as? SockdriveChunker.ChunkerError,
                           .outputExists(out.path))
        }
    }

    func testWrongSizeImageIsRefused() throws {
        let dir = try makeTempDir()
        let raw = dir.appendingPathComponent("odd.raw")
        try Data(count: 1000).write(to: raw)
        let out = dir.appendingPathComponent("drive")
        XCTAssertThrowsError(try SockdriveChunker.makeDrive(from: raw, to: out)) { error in
            XCTAssertEqual(error as? SockdriveChunker.ChunkerError,
                           .sizeMismatch(actual: 1000,
                                         expected: [246_456 * 1024, 2_097_152 * 1024]))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path),
                       "size is checked before the output directory is created")
    }
}
