import Foundation

/// Minimal FAT12 WRITE support for exactly TWO in-place operations on a 1.44 MB
/// floppy image: replacing an existing root-directory file's content, and
/// renaming a root-directory file.
///
/// Why so narrow: the install wizard boots the El Torito floppy extracted from
/// the USER'S Windows 98 CD, and the only edits it ever needs are swapping
/// AUTOEXEC.BAT / CONFIG.SYS for unattended equivalents and renaming JO.SYS out
/// of IO.SYS's sight (see InstallMediaBuilder). Rewriting in place — same
/// directory entry, same cluster chain, content zero-padded to the chain's
/// capacity — needs no allocation policy, no chain growth, no long-filename
/// bookkeeping, and cannot disturb the boot sector or the system files that
/// make the floppy bootable. Content larger than the existing chain is an ERROR
/// by design: growing a file means allocating clusters, and this type refuses
/// to learn how.
///
/// Geometry is READ from the boot-sector BPB (reserved sectors, FAT count and
/// size, root-entry count) rather than hardcoded, with sanity checks that pin
/// the things this code does assume: a 1,474,560-byte image, 512-byte sectors,
/// and a cluster count in FAT12 range (so a mislabeled FAT16 volume can't be
/// silently corrupted by 12-bit FAT walks).
enum FAT12Floppy {

    /// 1.44 MB: 2880 × 512 — the only media this supports, and exactly what
    /// `ISO9660Image.extractElToritoBootImage()` returns for media type 2.
    static let imageBytes = 1_474_560

    enum FloppyError: Error, LocalizedError, Equatable {
        case notAFloppyImage(String)
        case invalidName(String)
        case fileNotFound(String)
        case duplicateName(String)
        case contentTooLarge(file: String, size: Int, capacity: Int)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .notAFloppyImage(let why):
                return "Not a usable 1.44 MB boot floppy: \(why)."
            case .invalidName(let name):
                return "\"\(name)\" is not an 8.3 UPPERCASE DOS name."
            case .fileNotFound(let name):
                return "\(name) does not exist in the floppy's root directory."
            case .duplicateName(let name):
                return "\(name) already exists in the floppy's root directory."
            case .contentTooLarge(let file, let size, let capacity):
                return "\(file): new content is \(size) bytes but the file's cluster chain "
                    + "only holds \(capacity) — in-place replacement never grows a file."
            case .malformed(let what): return "The floppy image is damaged: \(what)."
            }
        }
    }

    private static let sectorSize = 512

    /// Replaces `name`'s content in place: locate its 8.3 root entry, walk its
    /// FAT12 cluster chain, write `content` across the chain in chain order,
    /// zero-fill the remainder of the chain, and update the entry's file size.
    /// The FAT itself and every other byte of the image are left untouched.
    static func replaceRootFile(in data: inout Data, name: String, content: Data) throws {
        let geo = try parseGeometry(data)
        guard let entryOffset = try locateRootFile(in: data, geometry: geo, name: name) else {
            throw FloppyError.fileNotFound(name)
        }

        // Walk the chain. FAT12 packs two 12-bit entries into three bytes:
        // entry n lives at byte offset 3n/2 — an EVEN n is the low 12 bits of
        // the u16 there, an ODD n the high 12 bits of the (overlapping) u16.
        // ≥ 0xFF8 ends the chain; 0xFF7 (bad cluster), 0/1, or out-of-range
        // values mid-chain mean the image is corrupt, as does a chain longer
        // than the volume has clusters (a cycle).
        var chain: [Int] = []
        var cluster = Int(data.u16le(entryOffset + 26))
        if cluster != 0 { // 0 = zero-length file owning no clusters
            while true {
                guard cluster >= 2, cluster <= geo.maxCluster else {
                    throw FloppyError.malformed("\(name) chain points at cluster \(cluster)")
                }
                chain.append(cluster)
                guard chain.count <= geo.clusterCount else {
                    throw FloppyError.malformed("\(name) cluster chain cycles")
                }
                let raw = Int(data.u16le(geo.fatOffset + cluster * 3 / 2))
                let next = cluster % 2 == 0 ? raw & 0xFFF : raw >> 4
                if next >= 0xFF8 { break }
                cluster = next
            }
        }

        let capacity = chain.count * geo.clusterBytes
        guard content.count <= capacity else {
            throw FloppyError.contentTooLarge(file: name, size: content.count, capacity: capacity)
        }

        // Write cluster-by-cluster in chain order, padding each cluster's tail
        // (and every wholly-unused trailing cluster) with zeros so no stale
        // bytes of the old content survive past the new file size.
        for (index, cluster) in chain.enumerated() {
            let sliceStart = min(index * geo.clusterBytes, content.count)
            let sliceEnd = min(sliceStart + geo.clusterBytes, content.count)
            var block = content.subdata(in: (content.startIndex + sliceStart)..<(content.startIndex + sliceEnd))
            block.append(Data(count: geo.clusterBytes - block.count))
            let target = data.startIndex + geo.dataOffset + (cluster - 2) * geo.clusterBytes
            data.replaceSubrange(target..<(target + geo.clusterBytes), with: block)
        }

        // Directory entry: only the 32-bit file size changes.
        let size = entryOffset + 28
        data[data.startIndex + size] = UInt8(content.count & 0xFF)
        data[data.startIndex + size + 1] = UInt8((content.count >> 8) & 0xFF)
        data[data.startIndex + size + 2] = UInt8((content.count >> 16) & 0xFF)
        data[data.startIndex + size + 3] = UInt8((content.count >> 24) & 0xFF)
    }

    /// Renames a root-directory file in place: rewrites the entry's 11 name
    /// bytes and NOTHING else — content, chain, size and attributes all stay.
    /// Refuses a `to` name that already exists (two identical names would make
    /// the directory ambiguous). The wizard uses this to take JO.SYS out of
    /// IO.SYS's boot path; the file itself must stay intact and recoverable.
    static func renameRootFile(in data: inout Data, from: String, to: String) throws {
        let geo = try parseGeometry(data)
        guard let to11 = FAT16ImageBuilder.shortName(to) else {
            throw FloppyError.invalidName(to)
        }
        guard try locateRootFile(in: data, geometry: geo, name: to) == nil else {
            throw FloppyError.duplicateName(to)
        }
        guard let entryOffset = try locateRootFile(in: data, geometry: geo, name: from) else {
            throw FloppyError.fileNotFound(from)
        }
        data.replaceSubrange((data.startIndex + entryOffset)..<(data.startIndex + entryOffset + 11),
                             with: to11)
    }

    // MARK: - Root-directory scan

    /// Byte offset of `name`'s root entry, or nil. 0x00 first byte = end-of-
    /// directory marker, 0xE5 = deleted; attribute 0x0F is a long-filename
    /// entry whose 11 "name" bytes are checksum/fragment data that could
    /// collide with a real 8.3 name, so LFN (and volume label / directory)
    /// entries are skipped by attribute BEFORE any name comparison.
    private static func locateRootFile(in data: Data, geometry geo: Geometry,
                                       name: String) throws -> Int? {
        guard let name11 = FAT16ImageBuilder.shortName(name) else {
            throw FloppyError.invalidName(name)
        }
        for index in 0..<geo.rootEntries {
            let e = geo.rootOffset + index * 32
            switch data.u8(e) {
            case 0x00: return nil
            case 0xE5: continue
            default: break
            }
            let attributes = data.u8(e + 11)
            if attributes == 0x0F || attributes & 0x18 != 0 { continue } // LFN, label, dir
            if Array(data[(data.startIndex + e)..<(data.startIndex + e + 11)]) == name11 {
                return e
            }
        }
        return nil
    }

    // MARK: - BPB parsing

    private struct Geometry {
        let fatOffset: Int      // byte offset of FAT copy 1
        let rootOffset: Int     // byte offset of the root directory
        let rootEntries: Int
        let dataOffset: Int     // byte offset of cluster 2
        let clusterBytes: Int
        let clusterCount: Int
        var maxCluster: Int { clusterCount + 1 }
    }

    private static func parseGeometry(_ data: Data) throws -> Geometry {
        guard data.count == imageBytes else {
            throw FloppyError.notAFloppyImage("\(data.count) bytes, expected \(imageBytes)")
        }
        guard data.u8(510) == 0x55, data.u8(511) == 0xAA else {
            throw FloppyError.notAFloppyImage("boot sector missing its 55AA signature")
        }
        guard Int(data.u16le(0x0B)) == sectorSize else {
            throw FloppyError.notAFloppyImage("sector size is not 512")
        }
        let sectorsPerCluster = Int(data.u8(0x0D))
        guard sectorsPerCluster >= 1, sectorsPerCluster <= 128,
              sectorsPerCluster & (sectorsPerCluster - 1) == 0 else {
            throw FloppyError.notAFloppyImage("bad sectors-per-cluster \(sectorsPerCluster)")
        }
        let reserved = Int(data.u16le(0x0E))
        let fatCount = Int(data.u8(0x10))
        let rootEntries = Int(data.u16le(0x11))
        let fatSectors = Int(data.u16le(0x16))
        guard reserved >= 1, fatCount >= 1, fatSectors >= 1, rootEntries >= 1,
              rootEntries * 32 % sectorSize == 0 else {
            throw FloppyError.notAFloppyImage("implausible BPB layout fields")
        }
        // Total sectors: the 16-bit field, or the 32-bit one when it is 0.
        let totalSectors16 = Int(data.u16le(0x13))
        let totalSectors = totalSectors16 != 0 ? totalSectors16 : Int(data.u32le(0x20))
        guard totalSectors * sectorSize <= data.count else {
            throw FloppyError.notAFloppyImage("BPB claims more sectors than the image holds")
        }

        let rootOffset = (reserved + fatCount * fatSectors) * sectorSize
        let dataOffset = rootOffset + rootEntries * 32
        guard dataOffset < totalSectors * sectorSize else {
            throw FloppyError.notAFloppyImage("no data region after the FAT structures")
        }
        let clusterBytes = sectorsPerCluster * sectorSize
        let clusterCount = (totalSectors * sectorSize - dataOffset) / clusterBytes
        // < 4085 clusters is the FAT-family boundary: at or above it the volume
        // is FAT16 and 12-bit FAT walks would read garbage — refuse it here.
        guard clusterCount < 4085 else {
            throw FloppyError.notAFloppyImage("\(clusterCount) clusters is FAT16 territory, not FAT12")
        }
        // Every FAT12 entry we might read must live inside FAT copy 1.
        guard (clusterCount + 1) * 3 / 2 + 1 < fatSectors * sectorSize else {
            throw FloppyError.notAFloppyImage("FAT too small for its own cluster count")
        }
        return Geometry(fatOffset: reserved * sectorSize, rootOffset: rootOffset,
                        rootEntries: rootEntries, dataOffset: dataOffset,
                        clusterBytes: clusterBytes, clusterCount: clusterCount)
    }
}

// MARK: - Little-endian field access

private extension Data {
    /// Relative to `startIndex`, so slices can't silently shift every read.
    func u8(_ offset: Int) -> UInt8 { self[startIndex + offset] }
    func u16le(_ offset: Int) -> UInt16 { UInt16(u8(offset)) | UInt16(u8(offset + 1)) << 8 }
    func u32le(_ offset: Int) -> UInt32 { UInt32(u16le(offset)) | UInt32(u16le(offset + 2)) << 16 }
}
