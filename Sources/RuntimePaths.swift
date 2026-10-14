import Foundation

/// Bundled releases resolve all executable resources from their current location.
/// Writable meeting data and downloaded models stay outside the app bundle.
struct RuntimePaths {
    let isBundled: Bool
    let projectRoot: URL
    let dataRoot: URL
    let modelRoot: URL
    let python: URL
    let modelHelper: URL
    let backendLauncher: URL
    let ffmpeg: URL?
    let certificateFile: URL?
    let port: Int
    private let resourcesRoot: URL
    private let bundleRoot: URL
    private let configurationError: String?

    init(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(info: bundle.infoDictionary ?? [:],
                  resourcesRoot: bundle.resourceURL ?? bundle.bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true),
                  bundleRoot: bundle.bundleURL,
                  environment: environment,
                  applicationSupportRoot: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }

    init(info: [String: Any], resourcesRoot: URL, bundleRoot: URL? = nil,
         environment: [String: String], applicationSupportRoot: URL) {
        self.resourcesRoot = resourcesRoot.standardizedFileURL
        self.bundleRoot = (bundleRoot ?? resourcesRoot.deletingLastPathComponent().deletingLastPathComponent()).standardizedFileURL
        let layout = info["ZhihuiRuntimeLayout"] as? String ?? ""
        isBundled = info["ZhihuiRuntimeLayout"] != nil
        let developmentRoot = environment["ZHIHUI_PROJECT_ROOT"] ?? info["ZhihuiProjectRoot"] as? String ?? ""
        if isBundled {
            // An environment variable or a stale development plist can never select external code.
            projectRoot = resourcesRoot.appendingPathComponent("Runtime", isDirectory: true).standardizedFileURL
        } else {
            projectRoot = URL(fileURLWithPath: developmentRoot.isEmpty ? "/__zhihui_missing_development_runtime__" : developmentRoot,
                              isDirectory: true).standardizedFileURL
        }
        let configuredData = environment["ZHIHUI_DATA_DIR"] ?? info["ZhihuiDataDirectory"] as? String
        dataRoot = (configuredData.map { URL(fileURLWithPath: $0, isDirectory: true) }
                    ?? applicationSupportRoot.appendingPathComponent("知会", isDirectory: true)).standardizedFileURL
        modelRoot = (environment["ZHIHUI_MODEL_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                     ?? (isBundled ? dataRoot : projectRoot).appendingPathComponent("models", isDirectory: true)).standardizedFileURL
        python = projectRoot.appendingPathComponent(isBundled ? "python/bin/python3" : ".venv/bin/python3")
        modelHelper = projectRoot.appendingPathComponent("scripts/setup-models.py")
        backendLauncher = projectRoot.appendingPathComponent("scripts/run-backend.py")
        ffmpeg = isBundled ? projectRoot.appendingPathComponent("bin/ffmpeg") : nil
        certificateFile = isBundled ? projectRoot.appendingPathComponent("python/lib/python3.12/site-packages/certifi/cacert.pem") : nil
        port = Int(environment["ZHIHUI_PORT"] ?? "") ?? (info["ZhihuiPort"] as? NSNumber)?.intValue ?? 8768
        if isBundled && layout != "bundled-v1" {
            configurationError = "应用运行环境格式无法识别，请重新下载知会。"
        } else if !isBundled && (developmentRoot.isEmpty || !developmentRoot.hasPrefix("/")) {
            configurationError = "开发环境的项目目录未配置，请从项目重新构建知会。"
        } else if configuredData.map({ !$0.hasPrefix("/") }) == true || environment["ZHIHUI_MODEL_DIR"].map({ !$0.hasPrefix("/") }) == true {
            configurationError = "资料和模型目录必须使用完整路径。"
        } else {
            configurationError = nil
        }
    }

    var binaryDirectory: URL? { isBundled ? projectRoot.appendingPathComponent("bin", isDirectory: true) : nil }

    func validate() throws {
        if let configurationError { throw RuntimePathError(message: configurationError) }
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: python.path) else {
            throw RuntimePathError(message: isBundled ? "应用内的运行环境不完整，请重新下载知会。" : "本地 Python 环境尚未安装（项目 .venv）。")
        }
        guard manager.fileExists(atPath: projectRoot.appendingPathComponent("backend/server.py").path),
              manager.fileExists(atPath: modelHelper.path),
              manager.fileExists(atPath: projectRoot.appendingPathComponent("Resources/ModelCatalog.json").path) else {
            throw RuntimePathError(message: "找不到完整的本地运行文件，请重新下载或重新构建知会。")
        }
        if isBundled {
            guard let ffmpeg, let certificateFile, manager.isExecutableFile(atPath: ffmpeg.path),
                  manager.fileExists(atPath: backendLauncher.path), manager.fileExists(atPath: certificateFile.path) else {
                throw RuntimePathError(message: "应用内的音频或启动组件不完整，请重新下载知会。")
            }
            let resolvedRoot = projectRoot.resolvingSymlinksInPath()
            let resolvedBundle = bundleRoot.resolvingSymlinksInPath()
            let resolvedResources = resourcesRoot.resolvingSymlinksInPath()
            let resources = [python, modelHelper, backendLauncher, ffmpeg, certificateFile,
                             projectRoot.appendingPathComponent("backend/server.py"),
                             projectRoot.appendingPathComponent("Resources/ModelCatalog.json")]
            guard Self.contains(resolvedResources, in: resolvedBundle),
                  Self.contains(resolvedRoot, in: resolvedResources),
                  resources.allSatisfy({ Self.contains($0.resolvingSymlinksInPath(), in: resolvedRoot) }),
                  !Self.contains(modelRoot.resolvingSymlinksInPath(), in: resolvedBundle),
                  !Self.contains(dataRoot.resolvingSymlinksInPath(), in: resolvedBundle) else {
                throw RuntimePathError(message: "应用内的运行文件或资料目录无效，请重新下载知会。")
            }
        }
    }

    private static func contains(_ url: URL, in directory: URL) -> Bool {
        url.path == directory.path || url.path.hasPrefix(directory.path + "/")
    }
}

private struct RuntimePathError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
