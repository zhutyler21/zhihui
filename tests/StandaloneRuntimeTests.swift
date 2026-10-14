import Foundation
import Darwin

private struct Failure: Error { let message: String }
private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(message: message) }
}
private func rejects(_ message: String, _ operation: () throws -> Void) throws {
    do { try operation() }
    catch { return }
    throw Failure(message: message)
}
private func snapshot(_ directory: URL) throws -> [String: Data] {
    var result: [String: Data] = [:]
    let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])!
    for case let url as URL in entries {
        if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(url.path.dropFirst(directory.path.count))] = try Data(contentsOf: url)
        }
    }
    return result
}
private func makeResourcesReadOnly(_ directory: URL, executablePaths: Set<String>) throws {
    let manager = FileManager.default
    let entries = manager.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey])!
    for case let url as URL in entries {
        let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        try manager.setAttributes([.posixPermissions: isDirectory || executablePaths.contains(url.path) ? 0o555 : 0o444], ofItemAtPath: url.path)
    }
    try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
}

@main struct StandaloneRuntimeTests {
    @MainActor static func main() async throws {
        let repository = URL(fileURLWithPath: "/Users/zhutyler21/我的项目仓库/知会本地会议", isDirectory: true)
        guard let location = ProcessInfo.processInfo.environment["ZHIHUI_STANDALONE_TEST_ROOT"] else { throw Failure(message: "Missing owned fixture") }
        let fixture = URL(fileURLWithPath: location, isDirectory: true).standardizedFileURL
        try require(fixture.path.hasPrefix(repository.appendingPathComponent("work/standalone-swift/").path + "/"), "Fixture must stay in this task's canonical work directory")
        let manager = FileManager.default
        try manager.createDirectory(at: fixture, withIntermediateDirectories: true)
        let original = fixture.appendingPathComponent("Build Output/知会.app")
        let resources = original.appendingPathComponent("Contents/Resources")
        let runtime = resources.appendingPathComponent("Runtime")
        let data = fixture.appendingPathComponent("User Support/知会")
        let support = fixture.appendingPathComponent("Default User Support")
        let python = runtime.appendingPathComponent("python/bin/python3")
        let helper = runtime.appendingPathComponent("scripts/setup-models.py")
        let files = ["backend/server.py", "scripts/run-backend.py", "bin/ffmpeg", "Resources/ModelCatalog.json", "python/bin/python3", "scripts/setup-models.py", "python/lib/python3.12/site-packages/certifi/cacert.pem"]
        for file in files {
            let url = runtime.appendingPathComponent(file)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        let actualPython = repository.appendingPathComponent(".venv/bin/python").path
        try require(manager.isExecutableFile(atPath: actualPython), "Known fixture Python must already exist")
        let quotedPython = "'" + actualPython.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try "#!/bin/sh\nexec \(quotedPython) \"$@\"\n".write(to: python, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.appendingPathComponent("bin/ffmpeg").path)
        let catalog: [[String: Any]] = ["asr", "embedding", "llm"].map {
            ["id": $0, "name": "fixture " + $0, "files": [["path": $0 + "/weights.bin", "size": 100]]]
        }
        try JSONSerialization.data(withJSONObject: ["models": catalog]).write(to: runtime.appendingPathComponent("Resources/ModelCatalog.json"))
        let helperSource = #"""
import json, os, pathlib, sys
destination=pathlib.Path(sys.argv[sys.argv.index('--model-dir')+1])
assert sys.flags.isolated and sys.dont_write_bytecode
assert all(key not in os.environ for key in ('PYTHONPATH','PYTHONHOME','VIRTUAL_ENV','__PYVENV_LAUNCHER__'))
destination.mkdir(parents=True,exist_ok=True)
if '--progress-json' in sys.argv:
    for model in ('asr','embedding','llm'):
        folder=destination/model
        folder.mkdir(exist_ok=True)
        (folder/'weights.bin').write_bytes(b'x'*100)
receipt={'isolated':sys.flags.isolated,'dont_write_bytecode':sys.dont_write_bytecode,'model_dir':str(destination),'path':os.environ['PATH'],'cwd':os.getcwd(),'cert':os.environ['SSL_CERT_FILE']}
(destination.parent/'helper-receipt.json').write_text(json.dumps(receipt))
models=[]
for model in ('asr','embedding','llm'):
    ready=(destination/model/'weights.bin').exists()
    models.append({'id':model,'name':'fixture '+model,'ready':ready,'completedBytes':100 if ready else 0,'totalBytes':100,'phase':'ready' if ready else 'waiting'})
print(json.dumps({'type':'complete','models':models}),flush=True)
"""#
        try helperSource.write(to: helper, atomically: true, encoding: .utf8)
        let launcherSource = #"""
import pathlib, runpy, sys
root=pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root))
runpy.run_path(str(root/'backend/server.py'),run_name='__main__')
"""#
        try launcherSource.write(to: runtime.appendingPathComponent("scripts/run-backend.py"), atomically: true, encoding: .utf8)
        let serverSource = #"""
import argparse, json, os, pathlib, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
parser=argparse.ArgumentParser()
parser.add_argument('--port',type=int,required=True)
parser.add_argument('--data-dir',type=pathlib.Path,required=True)
parser.add_argument('--models-dir',type=pathlib.Path,required=True)
parser.add_argument('--token-file',type=pathlib.Path,required=True)
parser.add_argument('--ffmpeg',type=pathlib.Path,required=True)
args=parser.parse_args()
assert sys.flags.isolated and sys.dont_write_bytecode
assert all(key not in os.environ for key in ('PYTHONPATH','PYTHONHOME','VIRTUAL_ENV','__PYVENV_LAUNCHER__'))
root=pathlib.Path(__file__).resolve().parents[1]
token=args.token_file.read_text().strip()
health={'ok':True,'app':'zhihui','version':1,'project_root':str(root),'data_dir':str(args.data_dir.resolve()),'models_dir':str(args.models_dir.resolve()),'ffmpeg_path':str(args.ffmpeg.resolve())}
receipt={'isolated':sys.flags.isolated,'dont_write_bytecode':sys.dont_write_bytecode,'path':os.environ['PATH'],'cert':os.environ['SSL_CERT_FILE'],'health':health}
(args.data_dir/'backend-fixture-receipt.json').write_text(json.dumps(receipt))
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        valid=self.headers.get('Authorization')=='Bearer '+token
        data=json.dumps(health if valid else {'error':'fixture unauthorized'}).encode()
        self.send_response(200 if valid else 401)
        self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self,*_):pass
HTTPServer(('127.0.0.1',args.port),Handler).serve_forever()
"""#
        try serverSource.write(to: runtime.appendingPathComponent("backend/server.py"), atomically: true, encoding: .utf8)
        let info: [String: Any] = ["CFBundleIdentifier": "io.local.zhihui.runtime-fixture", "CFBundlePackageType": "APPL",
                                  "CFBundleName": "知会", "ZhihuiRuntimeLayout": "bundled-v1", "ZhihuiProjectRoot": repository.path]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: original.appendingPathComponent("Contents/Info.plist"))
        let moved = fixture.appendingPathComponent("Moved Applications/知会' App.app")
        try manager.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.moveItem(at: original, to: moved)
        let movedResources = moved.appendingPathComponent("Contents/Resources")
        let configured: [String: String] = ["ZHIHUI_PROJECT_ROOT": repository.path, "ZHIHUI_DATA_DIR": data.path, "ZHIHUI_PORT": "18894"]
        let paths = RuntimePaths(info: info, resourcesRoot: movedResources, environment: configured, applicationSupportRoot: support)
        try require(paths.projectRoot.path == movedResources.appendingPathComponent("Runtime").path, "Moving a bundle must move runtime resolution even with stale plist and original repository override")
        try require(paths.modelRoot.path == data.appendingPathComponent("models").path, "Bundled models must default to the writable user data directory")
        try require(paths.port == 18894, "Existing isolated port override must remain available")
        try paths.validate()
        guard let bundle = Bundle(url: moved) else { throw Failure(message: "Fixture must be recognized as a real bundle") }
        let liveBundlePaths = RuntimePaths(bundle: bundle, environment: configured)
        try require(liveBundlePaths.projectRoot.path == paths.projectRoot.path, "Production Bundle.resourceURL resolution must follow the relocated bundle")
        let defaults = RuntimePaths(info: info, resourcesRoot: movedResources, environment: [:], applicationSupportRoot: support)
        try require(defaults.dataRoot.path == support.appendingPathComponent("知会").path && defaults.modelRoot.path == support.appendingPathComponent("知会/models").path, "An ordinary fresh user has no repository dependency for data or model defaults")
        let custom = fixture.appendingPathComponent("Shared Models")
        let overridden = RuntimePaths(info: info, resourcesRoot: movedResources, environment: configured.merging(["ZHIHUI_MODEL_DIR": custom.path], uniquingKeysWith: { _, new in new }), applicationSupportRoot: support)
        try require(overridden.modelRoot.path == custom.path, "Isolated QA model directory override must remain explicit")
        let development = RuntimePaths(info: ["ZhihuiProjectRoot": repository.path], resourcesRoot: movedResources, environment: ["ZHIHUI_DATA_DIR": data.path], applicationSupportRoot: support)
        try require(!development.isBundled && development.projectRoot.path == repository.path && development.modelRoot.path == repository.appendingPathComponent("models").path && development.python.path.hasSuffix(".venv/bin/python3"), "Source development must retain its existing venv and model defaults")

        let forbidden = RuntimePaths(info: info, resourcesRoot: movedResources, environment: configured.merging(["ZHIHUI_MODEL_DIR": movedResources.appendingPathComponent("models").path], uniquingKeysWith: { _, new in new }), applicationSupportRoot: support)
        try rejects("A model override inside app Resources must be refused") { try forbidden.validate() }
        let insideAppData = moved.appendingPathComponent("Contents/MacOS/data")
        let dataInMacOS = RuntimePaths(info: info, resourcesRoot: movedResources,
                                      environment: configured.merging(["ZHIHUI_DATA_DIR": insideAppData.path, "ZHIHUI_MODEL_DIR": custom.path], uniquingKeysWith: { _, new in new }),
                                      applicationSupportRoot: support)
        try rejects("A backend data directory inside app MacOS must be refused even with models stored externally") { try dataInMacOS.validate() }
        let invalidHost = BackendHost(paths: dataInMacOS)
        var launchRejected = false
        do { _ = try await invalidHost.start() }
        catch { launchRejected = true }
        invalidHost.shutdown()
        try require(launchRejected && invalidHost.childPID == nil && invalidHost.client == nil, "Native backend startup must refuse app-internal data before creating tokens or launching a child")
        try require(!manager.fileExists(atPath: insideAppData.path), "Rejecting a data path inside the signed app must not create it")
        let modelsInMacOS = RuntimePaths(info: info, resourcesRoot: movedResources,
                                        environment: configured.merging(["ZHIHUI_MODEL_DIR": moved.appendingPathComponent("Contents/MacOS/models").path], uniquingKeysWith: { _, new in new }),
                                        applicationSupportRoot: support)
        try rejects("A model directory anywhere inside the signed app must be refused") { try modelsInMacOS.validate() }
        let invalidModelPreparation = ModelPreparation(projectRoot: paths.projectRoot, modelRoot: modelsInMacOS.modelRoot,
                                                       executable: paths.python, helper: paths.modelHelper,
                                                       isolatedPython: true, binaryDirectory: paths.binaryDirectory,
                                                       certificateFile: paths.certificateFile)
        await invalidModelPreparation.download()
        try require(!invalidModelPreparation.verificationComplete && !invalidModelPreparation.canUseModels && !invalidModelPreparation.isBusy &&
                    !invalidModelPreparation.message.isEmpty && !manager.fileExists(atPath: modelsInMacOS.modelRoot.path),
                    "The downloader's own guard must reject models inside the whole app even without a supplied runtime validation callback")
        let siblingData = moved.deletingLastPathComponent().appendingPathComponent("知会' App.app-data")
        let similarlyNamedSibling = RuntimePaths(info: info, resourcesRoot: movedResources,
                                                environment: configured.merging(["ZHIHUI_DATA_DIR": siblingData.path], uniquingKeysWith: { _, new in new }),
                                                applicationSupportRoot: support)
        try similarlyNamedSibling.validate()
        let absent = RuntimePaths(info: info, resourcesRoot: fixture.appendingPathComponent("Missing App/Contents/Resources"), environment: configured, applicationSupportRoot: support)
        try rejects("An incomplete bundle must never fall back to the still-present source repository") { try absent.validate() }
        let unknown = RuntimePaths(info: ["ZhihuiRuntimeLayout": "future-unsupported", "ZhihuiProjectRoot": repository.path], resourcesRoot: movedResources, environment: configured, applicationSupportRoot: support)
        try rejects("An unknown layout must fail closed") { try unknown.validate() }
        let malformed = RuntimePaths(info: ["ZhihuiRuntimeLayout": 1, "ZhihuiProjectRoot": repository.path], resourcesRoot: movedResources, environment: configured, applicationSupportRoot: support)
        try rejects("A malformed bundled layout marker must not select the development fallback") { try malformed.validate() }
        let escapedResources = fixture.appendingPathComponent("Escaped App/Contents/Resources")
        try manager.createDirectory(at: escapedResources, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: escapedResources.appendingPathComponent("Runtime"), withDestinationURL: paths.projectRoot)
        let escaped = RuntimePaths(info: info, resourcesRoot: escapedResources, environment: configured, applicationSupportRoot: support)
        try rejects("A bundled Runtime symlink to external code must be refused") { try escaped.validate() }
        let escapedAppResources = fixture.appendingPathComponent("Resource Symlink App/Contents/Resources")
        try manager.createDirectory(at: escapedAppResources.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: escapedAppResources, withDestinationURL: movedResources)
        let escapedApp = RuntimePaths(info: info, resourcesRoot: escapedAppResources, environment: configured, applicationSupportRoot: support)
        try rejects("An app Resources symlink to code in another app must be refused") { try escapedApp.validate() }

        try makeResourcesReadOnly(movedResources, executablePaths: [paths.python.path, paths.ffmpeg!.path])
        let initialResources = try snapshot(movedResources)
        let initialBundle = try snapshot(moved)
        let preparation = ModelPreparation(projectRoot: paths.projectRoot, modelRoot: paths.modelRoot, executable: paths.python,
                                           helper: paths.modelHelper, isolatedPython: true, binaryDirectory: paths.binaryDirectory,
                                           certificateFile: paths.certificateFile,
                                           runtimeValidation: { try paths.validate() })
        // Inherited Python configuration must not corrupt the isolated bundled helper.
        let poisonKeys = ["PYTHONPATH", "PYTHONHOME", "VIRTUAL_ENV", "__PYVENV_LAUNCHER__"]
        let inherited = poisonKeys.map { key in (key, ProcessInfo.processInfo.environment[key]) }
        for key in poisonKeys { setenv(key, "/nonexistent-user-python", 1) }
        defer { for (key, value) in inherited { if let value { setenv(key, value, 1) } else { unsetenv(key) } } }
        await preparation.check()
        try require(preparation.verificationComplete && !preparation.canUseModels, "An empty writable model directory must report incomplete preparation")
        await preparation.download()
        try require(preparation.canUseModels && preparation.preparedCount == 3 && preparation.totalBytes == 300, "Model helper must publish verified files to the explicit writable destination")
        let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: data.appendingPathComponent("helper-receipt.json"))) as! [String: Any]
        try require(receipt["model_dir"] as? String == paths.modelRoot.path && receipt["path"] as? String == paths.binaryDirectory!.path + ":/usr/bin:/bin", "The real child must use the chosen model directory and bundled-only binary search path")
        try require(receipt["cert"] as? String == paths.certificateFile!.path, "First-run HTTPS must receive the bundled CA certificate path")
        let finalResources = try snapshot(movedResources)
        try require(finalResources == initialResources, "Model checks and downloads must leave read-only app Resources byte-for-byte unchanged")
        let invalidPreparation = ModelPreparation(projectRoot: paths.projectRoot, modelRoot: paths.modelRoot, executable: paths.python,
                                                 helper: paths.modelHelper, isolatedPython: true, binaryDirectory: paths.binaryDirectory,
                                                 runtimeValidation: { try absent.validate() })
        await invalidPreparation.check()
        try require(!invalidPreparation.verificationComplete && !invalidPreparation.canUseModels && !invalidPreparation.isBusy && !invalidPreparation.message.isEmpty, "Missing runtime preflight must reject entry before running a valid model helper")

        let host = BackendHost(paths: paths)
        defer { host.shutdown() }
        let health = try await host.start()
        try require(host.childPID != nil && health["models_dir"] as? String == paths.modelRoot.path, "Actual native launcher must own the bundled backend child with the intended model identity")
        let backendReceipt = try JSONSerialization.jsonObject(with: Data(contentsOf: data.appendingPathComponent("backend-fixture-receipt.json"))) as! [String: Any]
        try require(backendReceipt["path"] as? String == paths.binaryDirectory!.path + ":/usr/bin:/bin" && backendReceipt["cert"] as? String == paths.certificateFile!.path, "Actual backend child must receive restricted PATH and bundled CA certificates")
        guard let api = host.client else { throw Failure(message: "Actual launched backend must expose an authenticated client") }
        let reused = BackendHost(paths: paths)
        _ = try await reused.start()
        try require(reused.childPID == nil, "Matching bundled runtime health reuses a child without taking ownership")
        reused.shutdown()
        _ = try await api.call("/api/health")
        let valid: JSONObject = ["ok": true, "app": "zhihui", "version": 1, "project_root": paths.projectRoot.path,
                                 "data_dir": paths.dataRoot.path, "models_dir": paths.modelRoot.path, "ffmpeg_path": paths.ffmpeg!.path]
        try host.verify(valid)
        var mismatched = valid; mismatched["models_dir"] = repository.appendingPathComponent("models").path
        try rejects("An otherwise matching service with the wrong model directory must not be reused") { try host.verify(mismatched) }
        mismatched = valid; mismatched["ffmpeg_path"] = "/opt/homebrew/bin/ffmpeg"
        try rejects("A bundled service must bind the actual packaged audio executable") { try host.verify(mismatched) }
        mismatched = valid; mismatched.removeValue(forKey: "models_dir")
        try rejects("Old health without model identity must not pass the new contract") { try host.verify(mismatched) }
        host.shutdown()
        var stopped = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if (try? await api.call("/api/health")) == nil { stopped = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try require(stopped, "The owned backend listener must stop on native shutdown")
        let finalBackendResources = try snapshot(movedResources)
        try require(finalBackendResources == initialResources, "Actual backend launch must preserve read-only Resources without bytecode files")
        let finalBundle = try snapshot(moved)
        try require(finalBundle == initialBundle, "Backend and model operations must preserve the whole signed app byte-for-byte")
        print("PASS standalone native runtime: moved Bundle.resourceURL; ignored source override; user models/data defaults; QA override; development compatibility; missing/unknown runtime and code symlink rejection; whole-app data/model write rejection before launch; similarly named sibling allowed; whole app and read-only Resources unchanged; isolated real helper and backend child; explicit model destination; restricted PATH and CA; authenticated matching child reuse; owned child shutdown; strict model and ffmpeg health identity")
    }
}
