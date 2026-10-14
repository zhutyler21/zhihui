import Foundation

struct AudioImportResult {
    var copiedPaths: [String]
    var errors: [String]
}
enum AudioImportSpool {
    static func copy(_ urls: [URL], into dataRoot: URL) -> AudioImportResult {
        let folder = dataRoot.appendingPathComponent("recordings/imports/\(UUID().uuidString)", isDirectory: true)
        var copied: [String] = []; var errors: [String] = []
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { return AudioImportResult(copiedPaths: [], errors: ["无法创建录音资料目录：\(error.localizedDescription)"]) }
        for url in urls {
            let original = url.resolvingSymlinksInPath()
            let file = folder.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            let temporary = folder.appendingPathComponent(UUID().uuidString + ".part")
            do {
                let before = try FileManager.default.attributesOfItem(atPath: original.path)
                guard before[.type] as? FileAttributeType == .typeRegular else { throw APIError(message: "请选择普通音频文件") }
                try FileManager.default.copyItem(at: original, to: temporary)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
                let after = try FileManager.default.attributesOfItem(atPath: original.path)
                let saved = try FileManager.default.attributesOfItem(atPath: temporary.path)
                guard (before[.size] as? NSNumber) == (after[.size] as? NSNumber),
                      (before[.modificationDate] as? Date) == (after[.modificationDate] as? Date),
                      (before[.size] as? NSNumber) == (saved[.size] as? NSNumber) else { throw APIError(message: "音频文件在复制期间发生变化，请等录音文件保存完后再导入") }
                try FileManager.default.moveItem(at: temporary, to: file); copied.append(file.path)
            } catch { try? FileManager.default.removeItem(at: temporary); errors.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        return AudioImportResult(copiedPaths: copied, errors: errors)
    }
}
