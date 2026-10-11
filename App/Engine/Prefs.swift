import Foundation

// MARK: - 设置项枚举

enum ArchiveFormat: String, CaseIterable, Identifiable {
    case sevenZ = "7z"
    case zip = "zip"
    case tarGz = "tar.gz"
    case tarXz = "tar.xz"

    var id: String { rawValue }
    var fileExtension: String { rawValue }
    var title: String {
        switch self {
        case .sevenZ: return "7z（压缩率高）"
        case .zip:    return "zip（兼容性好）"
        case .tarGz:  return "tar.gz"
        case .tarXz:  return "tar.xz"
        }
    }
    var supportsEncryption: Bool { self == .sevenZ || self == .zip }
    var isTarStream: Bool { self == .tarGz || self == .tarXz }
}

enum CompressionLevel: Int, CaseIterable, Identifiable {
    case store = 0, fastest = 1, fast = 3, normal = 5, maximum = 7, ultra = 9
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .store:   return "仅存储"
        case .fastest: return "最快"
        case .fast:    return "快速"
        case .normal:  return "标准"
        case .maximum: return "最大"
        case .ultra:   return "极限"
        }
    }
}

enum EncryptionMode: String, CaseIterable, Identifiable {
    case off, ask, fixed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off:   return "不加密"
        case .ask:   return "每次压缩时询问密码"
        case .fixed: return "使用固定密码"
        }
    }
}

enum FolderMode: String, CaseIterable, Identifiable {
    case smart, always, never
    var id: String { rawValue }
    var title: String {
        switch self {
        case .smart:  return "智能（只有一个顶层项目时直接放出，否则建同名文件夹）"
        case .always: return "总是新建同名文件夹"
        case .never:  return "从不新建文件夹"
        }
    }
}

enum ConflictMode: String, CaseIterable, Identifiable {
    case rename, overwrite
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rename:    return "自动改名（如“资料 2”）"
        case .overwrite: return "替换（旧的移到废纸篓）"
        }
    }
}

enum ZipCodePage: Int, CaseIterable, Identifiable {
    case autoGBK = 936, big5 = 950, shiftJIS = 932, utf8 = 65001
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .autoGBK:  return "自动（UTF-8 优先，其次 GBK）"
        case .big5:     return "繁体中文 Big5"
        case .shiftJIS: return "日文 Shift-JIS"
        case .utf8:     return "UTF-8"
        }
    }
}

// MARK: - UserDefaults 键与读取

enum PrefKey {
    static let format          = "compress.format"
    static let level           = "compress.level"
    static let solid           = "compress.solid"
    static let threads         = "compress.threads"
    static let encryption      = "compress.encryption"
    static let encryptNames    = "compress.encryptNames"
    static let volumeMB        = "compress.volumeMB"
    static let excludeJunk     = "compress.excludeMacJunk"

    static let folderMode      = "extract.folderMode"
    static let conflict        = "extract.conflict"
    static let zipCodePage     = "extract.zipCodePage"
    static let unwrapTar       = "extract.unwrapTar"
    static let removeJunk      = "extract.removeMacJunk"
    static let revealInFinder  = "extract.revealInFinder"
    static let trashArchive    = "extract.trashArchive"
    static let quarantine      = "extract.propagateQuarantine"

    static let showProgress    = "general.showProgress"
}

enum Prefs {
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            PrefKey.format: ArchiveFormat.sevenZ.rawValue,
            PrefKey.level: CompressionLevel.normal.rawValue,
            PrefKey.solid: true,
            PrefKey.threads: 0,
            PrefKey.encryption: EncryptionMode.off.rawValue,
            PrefKey.encryptNames: true,
            PrefKey.volumeMB: 0,
            PrefKey.excludeJunk: true,

            PrefKey.folderMode: FolderMode.smart.rawValue,
            PrefKey.conflict: ConflictMode.rename.rawValue,
            PrefKey.zipCodePage: ZipCodePage.autoGBK.rawValue,
            PrefKey.unwrapTar: true,
            PrefKey.removeJunk: true,
            PrefKey.revealInFinder: false,
            PrefKey.trashArchive: false,
            PrefKey.quarantine: true,

            PrefKey.showProgress: true,
        ])
    }

    private static var d: UserDefaults { .standard }

    static var format: ArchiveFormat { ArchiveFormat(rawValue: d.string(forKey: PrefKey.format) ?? "") ?? .sevenZ }
    static var level: CompressionLevel { CompressionLevel(rawValue: d.integer(forKey: PrefKey.level)) ?? .normal }
    static var solid: Bool { d.bool(forKey: PrefKey.solid) }
    static var threads: Int { d.integer(forKey: PrefKey.threads) }
    static var encryption: EncryptionMode { EncryptionMode(rawValue: d.string(forKey: PrefKey.encryption) ?? "") ?? .off }
    static var encryptNames: Bool { d.bool(forKey: PrefKey.encryptNames) }
    static var volumeMB: Int { max(0, d.integer(forKey: PrefKey.volumeMB)) }
    static var excludeJunk: Bool { d.bool(forKey: PrefKey.excludeJunk) }

    static var folderMode: FolderMode { FolderMode(rawValue: d.string(forKey: PrefKey.folderMode) ?? "") ?? .smart }
    static var conflict: ConflictMode { ConflictMode(rawValue: d.string(forKey: PrefKey.conflict) ?? "") ?? .rename }
    static var zipCodePage: ZipCodePage { ZipCodePage(rawValue: d.integer(forKey: PrefKey.zipCodePage)) ?? .autoGBK }
    static var unwrapTar: Bool { d.bool(forKey: PrefKey.unwrapTar) }
    static var removeJunk: Bool { d.bool(forKey: PrefKey.removeJunk) }
    static var revealInFinder: Bool { d.bool(forKey: PrefKey.revealInFinder) }
    static var trashArchive: Bool { d.bool(forKey: PrefKey.trashArchive) }
    static var quarantine: Bool { d.bool(forKey: PrefKey.quarantine) }

    static var showProgress: Bool { d.bool(forKey: PrefKey.showProgress) }
}
