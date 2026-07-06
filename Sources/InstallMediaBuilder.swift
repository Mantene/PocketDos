import Foundation
import ZIPFoundation

/// Assembles everything one Windows 98 install run needs, from exactly two
/// user-supplied inputs (their CD image + their product key), into a game
/// folder the install harness can boot:
///
///   <destination>/boot-floppy.zip        the CD's own El Torito boot floppy,
///                                        AUTOEXEC.BAT (and CONFIG.SYS) swapped
///                                        for unattended equivalents, zipped as
///                                        exactly `boot.img` — the shape
///                                        `?instfloppy=` feeds `bundle.extract`
///   <destination>/src-drive/drive/       the D: install source (\WIN98 CABs +
///                                        MSBATCH.INF) as a sockdrive
///   <destination>/target-drive/drive/    the blank C: target, unpacked from
///                                        the bundled license-clean template
///
/// In production `destination` is Documents/Games/<id>/ and the template is
/// `Web/install/win98-blank-c.zip` from the app bundle; both are parameters so
/// tests (and the macOS verification driver) can point everything at fixtures.
///
/// The product key flows into `FAT16ImageBuilder.msbatchINF` and NOWHERE else:
/// it is never logged, never put in an error, never echoed through `Progress`.
enum InstallMediaBuilder {

    /// Coarse wizard-progress milestones, in emission order: `floppyReady`,
    /// `buildingSource(0...100)`, `chunking`, `done`.
    enum Progress: Equatable {
        case buildingSource(percent: Int)
        case chunking
        case floppyReady
        case done
    }

    enum BuildError: Error, LocalizedError, Equatable {
        case notAWin98CD
        case templateInvalid(String)

        var errorDescription: String? {
            switch self {
            case .notAWin98CD:
                return "That CD image doesn't look like a Windows 98 SE install CD "
                    + "(no \\WIN98 folder with SETUP.EXE and its .CAB archives)."
            case .templateInvalid(let why):
                return "The bundled blank-drive template is unusable: \(why)."
            }
        }
    }

    /// The app-bundled blank C: template. Web/ is a folder reference, so the
    /// zip keeps its install/ subpath inside the bundle.
    static var bundledBlankTargetTemplate: URL? {
        Bundle.main.url(forResource: "win98-blank-c", withExtension: "zip",
                        subdirectory: "Web/install")
    }

    // MARK: - Build

    static func build(isoAt isoURL: URL, productKey: String,
                      into destination: URL, blankTargetTemplate: URL,
                      progress: (Progress) -> Void = { _ in }) throws {
        let fm = FileManager.default

        // (a) The ISO must be a plausible Win98 SE install CD before anything
        // is written — rejecting here keeps a wrong pick a five-second error.
        let iso = try ISO9660Image(url: isoURL)
        guard iso.looksLikeWin98CD() else { throw BuildError.notAWin98CD }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        // (b) Boot floppy: the CD's own El Torito image with its startup files
        // swapped in place (same clusters — see FAT12Floppy) for unattended
        // ones. CONFIG.SYS is best-effort: a floppy without one boots on
        // IO.SYS defaults and Setup loads its own XMS manager, so its absence
        // is not worth failing the wizard over. A missing AUTOEXEC.BAT IS
        // fatal — with nothing to auto-run Setup, the install can't start.
        var floppy = try iso.extractElToritoBootImage()
        try FAT12Floppy.replaceRootFile(in: &floppy, name: "AUTOEXEC.BAT",
                                        content: unattendedAutoexec)
        do {
            try FAT12Floppy.replaceRootFile(in: &floppy, name: "CONFIG.SYS",
                                            content: menulessConfigSys)
        } catch FAT12Floppy.FloppyError.fileNotFound {
        }
        // JO.SYS is the retail CD-boot chooser: when IO.SYS finds it on the
        // boot floppy it runs it, and its DEFAULT option chains into the hard
        // disk's boot sector — our blank C: has none, which crashes the WASM
        // guest outright ("null function", Chrome-reproduced 2026-07-06; the
        // LEG 7 spike never hit this because its hand-built floppy was
        // EBD-based, with no JO.SYS). Renaming it makes IO.SYS boot straight
        // through CONFIG.SYS → AUTOEXEC → Setup. Rename rather than overwrite:
        // the file stays intact on the user's floppy image, just out of the
        // boot path. EBD-style floppies have no JO.SYS — that's fine.
        do {
            try FAT12Floppy.renameRootFile(in: &floppy, from: "JO.SYS", to: "JO.OFF")
        } catch FAT12Floppy.FloppyError.fileNotFound {
        }

        // (c) Zip it as exactly `boot.img` at the archive root — the layout
        // the harness's `bundle.extract(<instfloppy>)` drops into C:\ so that
        // `imgmount a: boot.img` finds it (same mechanism the Chrome-proven
        // spike used with its hand-built boot-floppy.zip).
        let floppyZip = destination.appendingPathComponent("boot-floppy.zip")
        try? fm.removeItem(at: floppyZip)
        let archive = try Archive(url: floppyZip, accessMode: .create)
        try archive.addEntry(with: "boot.img", type: .file,
                             uncompressedSize: Int64(floppy.count),
                             compressionMethod: .deflate) { position, size in
            let start = Int(position)
            return floppy.subdata(in: start..<min(start + size, floppy.count))
        }
        progress(.floppyReady)

        // (d) D: install source: FAT16 image (streamed, ~240 MB, sparse) then
        // chunked into <dest>/src-drive/drive. The raw is a sibling temp file
        // (same volume, deleted on every exit path) — never /tmp.
        progress(.buildingSource(percent: 0))
        let rawURL = destination.appendingPathComponent("src-drive.tmp.raw")
        defer { try? fm.removeItem(at: rawURL) }
        try FAT16ImageBuilder.buildInstallSource(from: iso, productKey: productKey,
                                                 at: rawURL) { copied, total in
            progress(.buildingSource(percent: total > 0 ? min(100, copied * 100 / total) : 0))
        }
        progress(.buildingSource(percent: 100))
        progress(.chunking)
        let srcParent = destination.appendingPathComponent("src-drive")
        try fm.createDirectory(at: srcParent, withIntermediateDirectories: true)
        try SockdriveChunker.makeDrive(from: rawURL,
                                       to: srcParent.appendingPathComponent("drive"))

        // (e) Blank C: target: unpack the license-clean template (zeros + FAT
        // structures, pre-chunked) — its zip already carries the drive/ folder.
        let targetParent = destination.appendingPathComponent("target-drive")
        try fm.createDirectory(at: targetParent, withIntermediateDirectories: true)
        try fm.unzipItem(at: blankTargetTemplate, to: targetParent)
        let metaj = targetParent.appendingPathComponent("drive/sockdrive.metaj")
        guard fm.fileExists(atPath: metaj.path) else {
            throw BuildError.templateInvalid("no drive/sockdrive.metaj inside the template zip")
        }
        progress(.done)
    }

    // MARK: - Unattended startup files

    /// AUTOEXEC.BAT replacement, ported from the Chrome-proven generator
    /// (wizard-s0/build-unattend-floppy.js) and ADAPTED to the floppy it now
    /// patches. The generator targeted the EBD startup disk; the El Torito
    /// image on a retail Win98 SE CD is the CDBOOT floppy, which has NO
    /// SETRAMD.BAT / RAMDRIVE.SYS — keeping the generator's ramdrive plumbing
    /// would fail those calls and, worse, point COMSPEC at a drive that never
    /// mounts (which can wedge DOS the first time the shell's transient half
    /// reloads). So the preamble here mirrors the CDBOOT floppy's OWN stock
    /// preamble, and only the interactive tail is replaced by the unattended
    /// Setup invocation.
    ///
    /// The Setup line passes the answer file EXPLICITLY — `D:\MSBATCH.INF`,
    /// the root of the D: source image where `buildInstallSource` writes it.
    /// The explicit-argument form is the LEG 7-proven one; source-directory
    /// auto-apply is proven NOT to work (LEG 8). /IS skips ScanDisk, which
    /// would otherwise halt on our synthetic source volume.
    ///
    /// CRLF + Latin-1, like everything DOS parses.
    static let unattendedAutoexec: Data = dosText([
        "@ECHO OFF",
        "set EXPAND=YES",
        "SET DIRCMD=/O:N",
        "cls",
        "set temp=c:\\",
        "set tmp=c:\\",
        "path=a:\\",
        "echo.",
        "echo PocketDOS: starting UNATTENDED Windows 98 Setup (MSBATCH.INF)...",
        "echo.",
        "D:\\WIN98\\SETUP.EXE D:\\MSBATCH.INF /IS",
    ])

    /// CONFIG.SYS replacement: the CDBOOT floppy's stock CONFIG.SYS is a
    /// 3-option menu (30-second default) that then loads nine CD-ROM/SCSI
    /// drivers — pure dead weight here, since the install source is an HDD
    /// sockdrive, not a CD. This is the menu-free equivalent of its SETUP_CD
    /// branch: HIMEM (which IS on the floppy) plus the stock [COMMON] values,
    /// so the machine boots straight into AUTOEXEC.BAT with zero waiting —
    /// the same menu-less shape the LEG 7 floppy booted with.
    static let menulessConfigSys: Data = dosText([
        "device=himem.sys /testmem:off",
        "files=60",
        "buffers=20",
        "dos=high,umb",
        "stacks=9,256",
        "lastdrive=z",
    ])

    /// CRLF-joined Latin-1 bytes. All content above is ASCII, so the lossy
    /// flag is a formality that keeps this total.
    private static func dosText(_ lines: [String]) -> Data {
        let text = lines.joined(separator: "\r\n") + "\r\n"
        return text.data(using: .isoLatin1, allowLossyConversion: true) ?? Data(text.utf8)
    }
}
