// Run once on the release Mac. Never commit or print the private seed.
import Foundation
import CryptoKit

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--public-key" {
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    let seed = Data(base64Encoded: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))!
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    print(key.publicKey.rawRepresentation.base64EncodedString())
    exit(0)
}
if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--verify" {
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: CommandLine.arguments[2])!)
    let content = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]), options: .mappedIfSafe)
    let signature = Data(base64Encoded: CommandLine.arguments[4])!
    guard key.isValidSignature(signature, for: content) else { exit(1) }
    print("PASS Ed25519 signature")
    exit(0)
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let configURL = root.appendingPathComponent("Resources/Updates.json")
var config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as! [String: Any]
guard (config["public_key"] as? String ?? "").isEmpty else {
    fatalError("已配置更新公钥；不能自动轮换。请按发布文档备份和恢复原私钥。")
}
let directory = root.appendingPathComponent("work/update-signing", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
let keyURL = directory.appendingPathComponent("ed25519.private-key")
guard !FileManager.default.fileExists(atPath: keyURL.path) else { fatalError("私钥文件已存在，停止以防覆盖。") }
let key = Curve25519.Signing.PrivateKey()
let seed = key.rawRepresentation.base64EncodedString().data(using: .utf8)!
guard FileManager.default.createFile(atPath: keyURL.path, contents: seed, attributes: [.posixPermissions: 0o600]) else {
    fatalError("无法保存更新签名私钥。")
}
config["public_key"] = key.publicKey.rawRepresentation.base64EncodedString()
try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: configURL, options: .atomic)
print("更新公钥已写入 Resources/Updates.json；请安全备份 work/update-signing/ed25519.private-key，勿提交或上传。")
