import Foundation
import GCDWebServer

private let TAG = "奶蛙-HTTP"

/// 对应 android.util.Log，这里统一用 print 输出，tag 作为前缀。
private enum Log {
    static func i(_ tag: String, _ msg: String) { print("[I][\(tag)] \(msg)") }
    static func w(_ tag: String, _ msg: String) { print("[W][\(tag)] \(msg)") }
    static func e(_ tag: String, _ msg: String) { print("[E][\(tag)] \(msg)") }
}

/**
 * 对应 iOS 版的 LocalHTTPServer，用 GCDWebServer 替代手写的 Socket 服务器。
 *
 * 游戏必须通过 http:// 而非 file:// 加载：Cocos 引擎会做跨域检查，
 * 且 WebGL 上下文在 file:// 下受限。这里起一个只监听回环地址的
 * 极简 HTTP 服务，把解包后的 renderer/ 目录当静态根目录提供。
 */
final class LocalHttpServer {

    private static let authHint: NSRegularExpression = {
        // 用户脚本自带后端的典型路径，命中说明脚本把请求发错了地方
        try! NSRegularExpression(
            pattern: "device-auth|card-keys|device-config|licen[cs]e|/auth/",
            options: .caseInsensitive
        )
    }()

    private static let mime: [String: String] = [
        "html": "text/html; charset=utf-8",
        "js": "application/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json",
        "wasm": "application/wasm",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "webp": "image/webp",
        "ico": "image/x-icon",
        "mp3": "audio/mpeg",
        "ogg": "audio/ogg",
        "wav": "audio/wav",
        "ttf": "font/ttf",
        "woff": "font/woff",
        "woff2": "font/woff2",
    ]

    private let rootDir: URL
    private let server = GCDWebServer()

    private(set) var port: Int = 0

    var baseUrl: String {
        "http://127.0.0.1:\(port)"
    }

    init(rootDir: URL) {
        self.rootDir = rootDir
    }

    /// 启动服务；成功返回 baseUrl，失败返回 nil
    @discardableResult
    func start() -> String? {
        var isDir: ObjCBool = false
        let rootExists = FileManager.default.fileExists(atPath: rootDir.path, isDirectory: &isDir)
        guard rootExists && isDir.boolValue else {
            Log.e(TAG, "目录不存在: \(rootDir.path)")
            return nil
        }

        // 用 GCDWebServer 的 addHandler 替代手写的 acceptLoop + handle + 线程池：
        // "/*" 匹配所有路径。request.path 已做 URL 解码并去掉查询串，
        // 对应原代码里的 URLDecoder.decode + substringBefore('?')/('#')。
        server.addHandler(
            forMethod: "GET",
            path: "/*",
            request: GCDWebServerRequest.self
        ) { [weak self] request in
            guard let self = self else {
                return GCDWebServerResponse(statusCode: 500)
            }
            return self.serveFile(path: request.path)
        }

        // 端口传 0 让系统自动分配，避免固定端口被占用；只监听回环地址。
        // MaxPendingConnections: 8 对应原来的 ServerSocket(0, 8, loopback) 的 backlog。
        let options: [AnyHashable: Any] = [
            GCDWebServerOption_Port: 0,
            GCDWebServerOption_BindToLocalhost: true,
            GCDWebServerOption_MaxPendingConnections: 8,
            GCDWebServerOption_AutomaticallyMapHEADToGET: true,
        ]

        do {
            try server.start(options: options)
            port = Int(server.port)
            Log.i(TAG, "服务器已就绪: \(baseUrl)")
            return baseUrl
        } catch {
            Log.e(TAG, "无法创建监听器: \(error.localizedDescription)")
            return nil
        }
    }

    func stop() {
        server.stop()
        Log.i(TAG, "服务器已停止")
    }

    private func serveFile(path: String) -> GCDWebServerResponse {
        // 去掉开头的斜杠；空路径回落到 index.html（对应 trimStart('/').ifEmpty）
        let trimmed = path.drop(while: { $0 == "/" })
        let rel = trimmed.isEmpty ? "index.html" : String(trimmed)

        let target = rootDir.appendingPathComponent(rel)

        // 防目录穿越：解析后的真实路径必须仍在根目录内
        let canonicalRoot = rootDir.resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalTarget = target.resolvingSymlinksInPath().standardizedFileURL.path
        if canonicalTarget != canonicalRoot && !canonicalTarget.hasPrefix(canonicalRoot + "/") {
            Log.w(TAG, "路径越界拒绝: \(path)")
            return statusResponse(code: 403, text: "Forbidden")
        }

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir)
        if !exists || isDir.boolValue {
            // 脚本用 location.origin 拼接自己的后端地址时，请求会打到这里。
            // 这类路径不是缺文件，而是脚本在找它自己的服务器，单独记一条
            // 日志便于排查。
            let range = NSRange(location: 0, length: rel.utf16.count)
            if Self.authHint.firstMatch(in: rel, range: range) != nil {
                Log.w(TAG, "脚本把后端请求发到了本地服务: /\(rel)")
            } else {
                Log.w(TAG, "文件未找到: \(path)")
            }
            return statusResponse(code: 404, text: "Not Found")
        }

        let ext = target.pathExtension.lowercased()
        let mime = Self.mime[ext] ?? "application/octet-stream"

        let response = GCDWebServerFileResponse(file: target.path, isAttachment: false)
        response.contentType = mime
        response.setValue("*", forAdditionalHeader: "Access-Control-Allow-Origin")
        response.setValue("no-cache", forAdditionalHeader: "Cache-Control")
        // GCDWebServerFileResponse 内部按块流式读取文件，而不是一次性 readBytes：
        // 游戏资源和大脚本动辄几 MB，整份读进内存在多开时会叠加，容易触发 OOM
        // 把渲染进程带崩。
        return response
    }

    private func statusResponse(code: Int, text: String) -> GCDWebServerResponse {
        // 对应原 writeStatus：text/plain; charset=utf-8 的纯文本状态响应
        let response = GCDWebServerDataResponse(text: text)
        response.statusCode = code
        return response
    }
}
