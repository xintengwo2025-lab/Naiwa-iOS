import Foundation
import GCDWebServer

class LocalHttpServer {
    private let server = GCDWebServer()
    private let htmlRoot: String

    init(htmlRoot: String) {
        self.htmlRoot = htmlRoot
        setupRoutes()
    }

    private func setupRoutes() {
        // 托管前端静态资源
        server.addGETHandler(forBasePath: "/", directoryPath: htmlRoot, indexFilename: "index.html", cacheAge: 0, allowRangeRequests: true)

        // 自定义 API 路由与代理拦截
        server.addHandler(forMethod: "GET", pathRegex: "/api/.*", request: GCDWebServerRequest.self) { request in
            let path = request.path
            // 简单的 mock 或重定向响应处理
            let response = GCDWebServerDataResponse(jsonObject: ["status": "ok", "path": path])
            response?.statusCode = 200
            response?.setValue("*", forAdditionalHeader: "Access-Control-Allow-Origin")
            return response
        }
    }

    func start(port: UInt = 8080) {
        guard !server.isRunning else { return }

        // 修复 1：将字典强制转换为 [String: String] 以满足 GCDWebServer 要求
        let options: [String: Any] = [
            GCDWebServerOption_Port: NSNumber(value: port),
            GCDWebServerOption_BindToLocalhost: true
        ]

        do {
            try server.start(options: options)
            print("LocalHttpServer started on port \(port)")
        } catch {
            print("Failed to start LocalHttpServer: \(error)")
        }
    }

    func stop() {
        if server.isRunning {
            server.stop()
            print("LocalHttpServer stopped")
        }
    }
}

// 辅助扩展：用于安全构造响应，修复可选类型报错
extension LocalHttpServer {
    static func createHtmlResponse(html: String) -> GCDWebServerDataResponse? {
        guard let data = html.data(using: .utf8) else { return nil }
        let response = GCDWebServerDataResponse(data: data, contentType: "text/html; charset=utf-8")
        response.statusCode = 200
        response.setValue("*", forAdditionalHeader: "Access-Control-Allow-Origin")
        response.setValue("no-cache", forAdditionalHeader: "Cache-Control")
        return response
    }

    static func createJsonResponse(jsonObject: [AnyHashable: Any]) -> GCDWebServerDataResponse? {
        let response = GCDWebServerDataResponse(jsonObject: jsonObject)
        response?.statusCode = 200
        response?.setValue("*", forAdditionalHeader: "Access-Control-Allow-Origin")
        return response
    }
}
