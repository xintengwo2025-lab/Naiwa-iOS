import UIKit
import WebKit
import Photos
import CryptoKit

private let TAG = "奶蛙"

/// 主窗口触摸事件回调，用于同步器广播
typealias SyncTouchListener = (Float, Float) -> Void

/// 对应 android.util.Log，这里统一用 print 输出，tag 作为前缀。
private enum Log {
    static func i(_ tag: String, _ msg: String) { print("[I][\(tag)] \(msg)") }
    static func d(_ tag: String, _ msg: String) { print("[D][\(tag)] \(msg)") }
    static func w(_ tag: String, _ msg: String) { print("[W][\(tag)] \(msg)") }
    static func e(_ tag: String, _ msg: String) { print("[E][\(tag)] \(msg)") }
}

/// 用户脚本源（id / 名称 / 源码）。对应原 Kotlin 的 Triple<String, String, String>。
struct UserScriptSource {
    let id: String
    let name: String
    let source: String
}

/// 已发布（落盘）的用户脚本（id / 名称 / 可访问的相对 URL）。
struct PublishedScript {
    let id: String
    let name: String
    let url: String
}

// MARK: - 用户脚本发布缓存

/**
 * 把启用的脚本落盘到本地静态根目录下，页面用 <script src> 加载。
 *
 * 为什么不直接把代码塞进 evaluateJavaScript：
 * 大脚本 base64 后体积膨胀，超限会被静默截断——不抛异常、不进 console，
 * 表现就是脚本"一直不显示"。改走本地伺服后只传几十字节的 URL，
 * 多大的脚本都不受影响。
 */
enum ScriptCache {

    private static let tag = "奶蛙-脚本缓存"
    private static let subdir = "userscripts"

    /// 文件名按内容哈希，内容不变就不重写，也天然避开中文名转义问题。
    /// 原 Kotlin 用 SHA-1，iOS 侧用 CryptoKit 的 SHA-256（同样取前 16 位十六进制）。
    /// 哈希算法只是本地缓存键，两端独立，无需与 Android 一致。
    private static func keyOf(id: String, code: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(id.utf8))
        hasher.update(data: Data(code.utf8))
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    /// 写入脚本并返回可访问的相对路径。
    /// - Parameter root: 本地静态根目录（GameSchemeHandler 的 rootDirectory）。
    static func publish(root: URL, scripts: [UserScriptSource]) -> [PublishedScript] {
        let dir = root.appendingPathComponent(subdir, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            Log.e(tag, "无法创建脚本目录: \(error.localizedDescription)")
            return []
        }

        var alive = Set<String>()
        var out: [PublishedScript] = []

        for s in scripts {
            let fileName = keyOf(id: s.id, code: s.source) + ".js"
            let file = dir.appendingPathComponent(fileName)
            alive.insert(fileName)

            let exists = FileManager.default.fileExists(atPath: file.path)
            var isEmpty = false
            if exists {
                let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
                isEmpty = ((attrs?[.size] as? NSNumber)?.int64Value ?? 0) == 0
            }
            if !exists || isEmpty {
                do {
                    try Data(s.source.utf8).write(to: file, options: .atomic)
                } catch {
                    Log.w(tag, "写入失败 \(s.name): \(error.localizedDescription)")
                    continue
                }
            }
            out.append(PublishedScript(id: s.id, name: s.name, url: "\(subdir)/\(fileName)"))
        }

        // 脚本被改动或删除后，旧的哈希文件不会再被引用，清掉省空间
        if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for name in files where !alive.contains(name) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }

        Log.i(tag, "已发布 \(out.count) 个脚本到 \(dir.path)")
        return out
    }
}

// MARK: - 自定义 scheme 网络拦截

/**
 * 自定义 scheme 处理器：把 `game://` 请求映射到本地游戏资源并伺服，
 * 替代原 http://127.0.0.1 本地服务器。页面内资源引用改写为 game://xxx
 * 后由这里伺服，绕开 ATS 与同源限制。
 */
final class GameSchemeHandler: NSObject, WKURLSchemeHandler {

    /// 本地资源根目录（解包后的 renderer/ 目录，含 userscripts/ 子目录）
    var rootDirectory: URL?

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let root = rootDirectory else {
            fail(urlSchemeTask, code: -1, msg: "无 URL 或根目录未设置")
            return
        }

        // game://host/path -> 本地文件 root/path；空路径回落到 index.html
        let trimmed = url.path.drop(while: { $0 == "/" })
        let rel = trimmed.isEmpty ? "index.html" : String(trimmed)
        let fileURL = root.appendingPathComponent(rel)

        // 防目录穿越：解析后的真实路径必须仍在根目录内
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalTarget = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
        if canonicalTarget != canonicalRoot && !canonicalTarget.hasPrefix(canonicalRoot + "/") {
            respond(urlSchemeTask, url: url, status: 403, mime: "text/plain; charset=utf-8", data: Data("Forbidden".utf8))
            return
        }

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir)
        if exists && isDir.boolValue {
            let index = fileURL.appendingPathComponent("index.html")
            if FileManager.default.fileExists(atPath: index.path) {
                serve(index, to: urlSchemeTask, url: url)
            } else {
                respond(urlSchemeTask, url: url, status: 404, mime: "text/plain; charset=utf-8", data: Data("Not Found".utf8))
            }
            return
        }
        guard exists else {
            respond(urlSchemeTask, url: url, status: 404, mime: "text/plain; charset=utf-8", data: Data("Not Found".utf8))
            return
        }
        serve(fileURL, to: urlSchemeTask, url: url)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // 本地文件直接伺服，无需取消
    }

    private func serve(_ fileURL: URL, to task: WKURLSchemeTask, url: URL) {
        guard let data = try? Data(contentsOf: fileURL) else {
            respond(task, url: url, status: 404, mime: "text/plain; charset=utf-8", data: Data("读取失败".utf8))
            return
        }
        respond(task, url: url, status: 200, mime: mimeType(for: fileURL.pathExtension), data: data)
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, status: Int, mime: String, data: Data) {
        let headers = [
            "Content-Type": mime,
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache",
        ]
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
            ?? URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8")
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: WKURLSchemeTask, code: Int, msg: String) {
        task.didFailWithError(NSError(domain: "GameSchemeHandler", code: code,
                                      userInfo: [NSLocalizedDescriptionKey: msg]))
    }

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "wasm": return "application/wasm"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "mp3": return "audio/mpeg"
        case "ogg": return "audio/ogg"
        case "wav": return "audio/wav"
        case "ttf": return "font/ttf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - 游戏容器

/**
 * 游戏容器，对应 iOS 版的 GameWebView + Coordinator。
 * 不包含连点器。
 */
final class GameWebViewHolder: NSObject {

    private let ctx: UIViewController            // 用于 Toast / 相册等，对应原 Context
    private let binHex: String
    private let binLabel: String
    private let rendererDirectory: URL
    private let scriptsProvider: () -> [UserScriptSource]
    private let syncEnabled: Bool
    private let onSyncTouch: SyncTouchListener?
    private let onScriptStatus: ((String) -> Void)?
    private let schemeHandler: GameSchemeHandler

    let webView: WKWebView

    private var pageReady = false
    private var backgrounded = false
    /// 渲染进程已终止，此 WebView 不可再用
    private var renderGone = false

    private static let customScheme = "game"     // 自定义 scheme，如 game://local/
    private static let BG_FPS = 5
    private static let FG_FPS = 60

    /// AndroidBridge 适配 shim：把 JS 里的 AndroidBridge.xxx 转发到 webkit.messageHandlers
    private static let bridgeShim = """
(function(){
  if (window.AndroidBridge) return;
  window.AndroidBridge = {
    onScriptStatus: function(msg){ window.webkit.messageHandlers.AndroidBridge.postMessage({type:'onScriptStatus', msg:String(msg)}); },
    onSyncTouch: function(json){ window.webkit.messageHandlers.AndroidBridge.postMessage({type:'onSyncTouch', json:String(json)}); },
    gmRequest: function(reqId, optionsJson){ window.webkit.messageHandlers.AndroidBridge.postMessage({type:'gmRequest', reqId:String(reqId), optionsJson:String(optionsJson)}); },
    setClipboard: function(text){ window.webkit.messageHandlers.AndroidBridge.postMessage({type:'setClipboard', text:String(text)}); },
    saveImage: function(dataUrl){ window.webkit.messageHandlers.AndroidBridge.postMessage({type:'saveImage', dataUrl:String(dataUrl)}); }
  };
})();
"""

    /// 控制台桥接：把 console 输出转发到原生，对应 WebChromeClient.onConsoleMessage
    private static let consoleShim = """
(function(){
  var levels = {log:'JS', info:'JS', debug:'JS', warn:'JS警告', error:'JS错误'};
  ['log','info','warn','error','debug'].forEach(function(lv){
    var orig = console[lv];
    console[lv] = function(){
      try {
        window.webkit.messageHandlers.AndroidBridge.postMessage({
          type:'console', level: levels[lv] || 'JS',
          msg: Array.prototype.map.call(arguments, function(a){
            try { return typeof a === 'object' ? JSON.stringify(a) : String(a); }
            catch(e){ return String(a); }
          }).join(' ')
        });
      } catch(e){}
      if (orig) orig.apply(console, arguments);
    };
  });
})();
"""

    init(
        ctx: UIViewController,
        binHex: String,
        binLabel: String,
        rendererDirectory: URL,
        scriptsProvider: @escaping () -> [UserScriptSource],
        isSyncMaster: Bool,
        syncEnabled: Bool,
        onSyncTouch: SyncTouchListener?,
        onScriptStatus: ((String) -> Void)? = nil
    ) {
        self.ctx = ctx
        self.binHex = binHex
        self.binLabel = binLabel
        self.rendererDirectory = rendererDirectory
        self.scriptsProvider = scriptsProvider
        self.syncEnabled = syncEnabled
        self.onSyncTouch = onSyncTouch
        self.onScriptStatus = onScriptStatus
        self.syncMaster = isSyncMaster

        let handler = GameSchemeHandler()
        handler.rootDirectory = rendererDirectory
        self.schemeHandler = handler

        let config = WKWebViewConfiguration()
        // javaScriptEnabled：WKWebView 始终启用 JS，无需也无法关闭。
        // mediaPlaybackRequiresUserGesture = false
        config.mediaTypesRequiringUserActionForPlayback = []
        // javaScriptCanOpenWindowsAutomatically = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        // 注册自定义 scheme 处理器（拦截并伺服本地游戏资源，替代 http://127.0.0.1 本地服务器）
        config.setURLSchemeHandler(handler, forURLScheme: Self.customScheme)

        let controller = WKUserContentController()
        // 先注入 JS 桥与控制台转发，供后续脚本调用 window.AndroidBridge
        controller.addUserScript(WKUserScript(source: Self.bridgeShim, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        controller.addUserScript(WKUserScript(source: Self.consoleShim, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        // 页面开始加载时就要注入的脚本，越早越好（对应原 injectEarly）
        controller.addUserScript(InjectScripts.compat)
        // 油猴 API 必须在任何用户脚本之前就位：脚本拿不到 GM_* 会静默退出
        controller.addUserScript(InjectScripts.gmShim)
        controller.addUserScript(InjectScripts.activateBin(hex: binHex, label: binLabel))
        controller.addUserScript(InjectScripts.xhrIntercept)
        // 页面加载完成后注入（对应原 injectLate），WKUserScript 在每次导航都会自动重跑
        controller.addUserScript(InjectScripts.vhFix)
        controller.addUserScript(InjectScripts.scriptUiFix)
        controller.addUserScript(InjectScripts.canvasGuard)
        if syncEnabled {
            // 两端都装：谁当同步源由 syncMaster 在运行时判断
            controller.addUserScript(InjectScripts.syncerSender)
            controller.addUserScript(InjectScripts.syncerReceiver)
        }
        config.userContentController = controller

        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        // 必须在 super.init() 之后把 self 注册为消息处理器（会强引用 self，destroy 时移除）
        webView.configuration.userContentController.add(self, name: "AndroidBridge")
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "AndroidBridge")
    }

    func load(_ url: String) {
        Log.i(TAG, "加载: \(url)")
        guard let u = URL(string: url) else { return }
        webView.load(URLRequest(url: u))
    }

    func destroy() {
        webView.stopLoading()
        // 移除消息处理器，断开 WKUserContentController 对 self 的强引用（否则形成循环引用）
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "AndroidBridge")
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    func reload() {
        Log.i(TAG, "收到刷新通知")
        pageReady = false
        // 页面重载后 window 上下文重建，已注入记录随之失效，无需手动清理
        webView.reload()
    }

    func clearCache() {
        // 原 webView.clearCache(true)：WKWebView 走 WKWebsiteDataStore
        WKWebsiteDataStore.default().removeData(
            ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache],
            modifiedSince: Date(timeIntervalSince1970: 0)
        ) {
            Log.i(TAG, "缓存已清除")
        }
    }

    func onLowMemory() {
        eval(InjectScripts.lowMemory)
    }

    /**
     * 标签模式下切到后台的窗口降到 5 帧，切回前台恢复。
     * 游戏逻辑与脚本靠 setInterval / 事件驱动，不受渲染帧率影响。
     */
    func setBackgrounded(_ background: Bool) {
        if renderGone { return }
        if backgrounded == background { return }
        backgrounded = background
        // INVISIBLE 保留布局尺寸（不触发 WebView 重排导致画面错乱），
        // 但完全跳过绘制：后台窗口不再占用绘制与合成开销，JS 与定时器照常运行。
        // 对应 android.view.View.INVISIBLE / VISIBLE。
        webView.isHidden = background
        if !pageReady { return }
        eval(InjectScripts.setFrameRate(fps: background ? Self.BG_FPS : Self.FG_FPS))
    }

    /// 标签模式下同步源会随当前标签变化，需要运行时可改
    var syncMaster: Bool

    /// 副窗口收到主窗口的同步坐标
    func applySyncTouch(x: Float, y: Float) {
        if !pageReady { return }
        eval("window.__applySyncTouch && window.__applySyncTouch(\(x), \(y));")
    }

    private func eval(_ js: String) {
        if renderGone { return }
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func eval(_ script: WKUserScript) {
        eval(script.source)
    }

    /// 页面加载完成后注入
    private func injectLate() {
        // 所有内置脚本已通过 WKUserScript 在 documentStart/documentEnd 自动注入，
        // 每次导航都会重跑，无需像原 Kotlin 那样在 onPageFinished 里手动重注。
        // 这里只需注入用户脚本（依赖 window.__require），并补上降帧请求。
        injectUserScripts()
        if backgrounded {
            eval(InjectScripts.setFrameRate(fps: Self.BG_FPS))
        }
    }

    /**
     * 注入用户脚本。内容通过 provider 实时读取而非构造时快照，
     * 因此脚本页改开关后无需重开窗口。
     *
     * 关键点：这些脚本依赖 window.__require，而它由游戏主包（从 CDN 拉的
     * game bundle）在运行时创建，onPageFinished 时通常还不存在。所以先
     * 轮询等待 __require 就绪再注入，而不是立刻执行。
     */
    func injectUserScripts() {
        if renderGone {
            onScriptStatus?("渲染已终止，请刷新")
            return
        }
        if !pageReady {
            onScriptStatus?("页面未就绪")
            return
        }
        let list = scriptsProvider()
        if list.isEmpty {
            onScriptStatus?("无启用脚本")
            return
        }

        // 落盘后用 <script src> 加载，不把代码塞进 evaluateJavaScript。
        let published = ScriptCache.publish(root: rendererDirectory, scripts: list)
        if published.isEmpty {
            onScriptStatus?("脚本写入失败")
            return
        }

        // 逐个脚本独立注入并按 id 记录，已注入过的永不重复执行。
        let entries = published.map {
            "{id:\(jsStr($0.id)),name:\(jsStr($0.name)),url:\(jsStr($0.url))}"
        }.joined(separator: ",")

        let js = """
(function(){
  var items = [\(entries)];
  window.__injectedScriptIds = window.__injectedScriptIds || {};
  var done = window.__injectedScriptIds;
  var live = {};
  items.forEach(function(it){ live[it.id] = 1; });
  // 已注入但现在被关掉的脚本：JS 执行过就无法撤销，只能刷新页面。
  // 明确告知而不是让用户反复点补注入却看不出变化。
  var stale = 0;
  for (var k in done) { if (done[k] && !live[k]) stale++; }
  var pending = items.filter(function(it){ return !done[it.id]; });
  if (pending.length === 0) {
    AndroidBridge.onScriptStatus(
      stale ? ('已关闭' + stale + '个，需刷新生效') : ('已全部注入 (' + items.length + ')')
    );
    return stale ? 'need_reload' : 'already';
  }
  // 按 src 逐个加载。串行执行是必须的：脚本之间可能有依赖，
  // 并行加载完成顺序不确定。
  function runAll(){
    var ok = 0, fail = 0, i = 0;
    function report(){
      AndroidBridge.onScriptStatus(
        '已注入 ' + ok + '/' + items.length +
        (fail ? (' 失败' + fail) : '') +
        (stale ? (' 关闭' + stale + '需刷新') : '')
      );
    }
    function next(){
      if (i >= pending.length) { report(); return; }
      var it = pending[i++];
      if (done[it.id]) { next(); return; }
      done[it.id] = true;    // 先置位，脚本内部报错也不重复执行
      var el = document.createElement('script');
      el.type = 'text/javascript';
      el.async = false;
      el.src = it.url;
      el.onload = function(){
        ok++;
        el.parentNode && el.parentNode.removeChild(el);
        next();
      };
      el.onerror = function(){
        fail++;
        // 加载失败要撤销标记，否则「补注入」会永远跳过这个脚本。
        // 与执行报错不同：文件没取到，脚本一行都没跑，重试是安全的。
        delete done[it.id];
        console.error('[奶蛙] 脚本加载失败: ' + it.name + ' <- ' + it.url);
        el.parentNode && el.parentNode.removeChild(el);
        next();
      };
      document.head.appendChild(el);
      // 每装一个就刷一次状态，大脚本加载慢时能看到进度
      if (i % 3 === 0) report();
    }
    next();
  }
  var tries = 0;
  function wait(){
    tries++;
    if (typeof window.__require === 'function') { runAll(); return; }
    if (tries > 240) {
      AndroidBridge.onScriptStatus('超时: 游戏模块未就绪，仍尝试注入');
      runAll();
      return;
    }
    if (tries % 20 === 0) {
      AndroidBridge.onScriptStatus('等待游戏加载... ' + Math.round(tries / 2) + 's');
    }
    setTimeout(wait, 500);
  }
  wait();
  return 'waiting:' + pending.length;
})();
"""

        webView.evaluateJavaScript(js) { value, error in
            if let value = value {
                Log.i(TAG, "脚本注入流程: \(value)")
            } else if let error = error {
                Log.i(TAG, "脚本注入流程错误: \(error)")
            }
        }
    }

    private func jsStr(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "'\(escaped)'"
    }

    // MARK: - GM_xmlhttpRequest 原生转发

    /**
     * GM_xmlhttpRequest 的原生转发。
     *
     * 油猴脚本靠它做跨域请求，而页面内的 XHR/fetch 受同源策略限制
     * 打不到外部域名。放到原生侧发就没有跨域概念，这也是油猴本身
     * 的实现方式。
     */
    private func doGmRequest(reqId: String, optionsJson: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result: [String: Any]
            do {
                result = try self.performGmRequest(optionsJson: optionsJson)
            } catch {
                result = ["error": error.localizedDescription, "status": 0]
            }
            let payloadData = (try? JSONSerialization.data(withJSONObject: result)) ?? Data()
            let payloadStr = String(data: payloadData, encoding: .utf8) ?? "{}"
            let js = "window.__gmResolve && window.__gmResolve(\(self.jsStr(reqId)), \(self.jsStr(payloadStr)))"
            DispatchQueue.main.async { [weak self] in
                guard let self = self, !self.renderGone else { return }
                self.webView.evaluateJavaScript(js, completionHandler: nil)
            }
        }
    }

    /// 在后台线程执行 GM_xmlhttpRequest，返回给 JS 的结果对象
    private func performGmRequest(optionsJson: String) throws -> [String: Any] {
        guard let data = optionsJson.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let urlString = o["url"] as? String,
              let url = URL(string: urlString) else {
            throw NSError(domain: TAG, code: -1, userInfo: [NSLocalizedDescriptionKey: "无效 URL"])
        }

        let method = ((o["method"] as? String) ?? "GET").uppercased()
        let body = o["data"] as? String
        let timeoutMs = max((o["timeout"] as? NSNumber)?.intValue ?? 20000, 1000)

        var request = URLRequest(url: url)
        request.httpMethod = method
        // connectTimeout / readTimeout 统一为 timeoutInterval（单位秒）
        request.timeoutInterval = TimeInterval(timeoutMs) / 1000.0
        // instanceFollowRedirects = true：URLSession 默认跟随重定向
        if let headers = o["headers"] as? [String: Any] {
            for (k, v) in headers {
                request.setValue("\(v)", forHTTPHeaderField: k)
            }
        }
        if let body = body {
            request.httpBody = body.data(using: .utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json;charset=utf-8", forHTTPHeaderField: "Content-Type")
            }
        }

        // URLSession 是异步的，用信号量转为同步等待（已在后台线程执行，不阻塞主线程）
        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: Any] = [:]
        var resultError: Error?

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                resultError = error
                return
            }
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            // 4xx/5xx 的内容也在 data 里，脚本往往要读错误详情
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            var headersText = ""
            if let all = http?.allHeaderFields as? [String: Any] {
                for (k, v) in all {
                    headersText += "\(k): \(v)\r\n"
                }
            }
            result = [
                "status": code,
                "statusText": HTTPURLResponse.localizedString(forStatusCode: code),
                "responseText": text,
                "responseHeaders": headersText,
                "finalUrl": http?.url?.absoluteString ?? url.absoluteString,
            ]
        }
        task.resume()
        semaphore.wait()

        if let resultError = resultError {
            throw resultError
        }
        return result
    }

    // MARK: - 剪贴板 / 保存图片

    private func setClipboard(_ text: String) {
        UIPasteboard.general.string = text
        toast("复制成功")
    }

    private func saveImage(_ dataUrl: String) {
        let b64: String
        if let range = dataUrl.range(of: "base64,") {
            b64 = String(dataUrl[range.upperBound...])
        } else {
            b64 = dataUrl
        }
        guard let data = Data(base64Encoded: b64), UIImage(data: data) != nil else {
            Log.w(TAG, "saveImage: base64 解码失败")
            return
        }
        savePNG(data)
        Log.i(TAG, "saveImage: 图片已保存到相册")
        toast("已保存到相册")
    }

    /// iOS 统一走 Photos 框架；原 Android 10+ MediaStore / 低版本 legacy 相册的
    /// 双路径在 iOS 上没有对应，直接写入相册（放入指定相册「再攀之王」）。
    /// 需要在 Info.plist 加 NSPhotoLibraryAddUsageDescription。
    private func savePNG(_ pngData: Data) {
        PHPhotoLibrary.requestAuthorization { [weak self] status in
            guard let self = self else { return }
            guard status == .authorized || status == .limited else {
                Log.w(TAG, "saveImage: 无相册权限")
                self.toast("无相册权限")
                return
            }
            self.writeToAlbum(pngData)
        }
    }

    private func writeToAlbum(_ pngData: Data) {
        let name = "xuebi_\(Int(Date().timeIntervalSince1970 * 1000)).png"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try pngData.write(to: tmp, options: .atomic)
        } catch {
            Log.w(TAG, "saveImage: 写入临时文件失败 \(error.localizedDescription)")
            return
        }

        fetchOrCreateAlbum(named: "再攀之王") { [weak self] album in
            guard let self = self, let album = album else {
                try? FileManager.default.removeItem(at: tmp)
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: tmp)
                if let placeholder = req?.placeholderForCreatedAsset,
                   let addReq = PHAssetCollectionChangeRequest(for: album) {
                    addReq.addAssets([placeholder] as NSArray)
                }
            }, completionHandler: { success, error in
                try? FileManager.default.removeItem(at: tmp)
                if !success {
                    Log.w(TAG, "saveImage: 保存失败 \(error?.localizedDescription ?? "")")
                }
            })
        }
    }

    private func fetchOrCreateAlbum(named name: String, completion: @escaping (PHAssetCollection?) -> Void) {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", name)
        let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options)
        if let album = existing.firstObject {
            completion(album)
            return
        }

        var placeholder: PHObjectPlaceholder?
        PHPhotoLibrary.shared().performChanges({
            let req = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            placeholder = req.placeholderForCreatedAssetCollection
        }, completionHandler: { success, _ in
            guard success, let placeholder = placeholder else {
                completion(nil)
                return
            }
            let result = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [placeholder.localIdentifier],
                options: nil
            )
            completion(result.firstObject)
        })
    }

    private func toast(_ s: String) {
        // iOS 无原生 Toast，用短暂弹窗代替
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let alert = UIAlertController(title: nil, message: s, preferredStyle: .alert)
            self.ctx.present(alert, animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                alert.dismiss(animated: true)
            }
        }
    }
}

// MARK: - WKScriptMessageHandler（对应 addJavascriptInterface 的 Bridge）

extension GameWebViewHolder: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "AndroidBridge",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "onScriptStatus":
            let msg = body["msg"] as? String ?? ""
            Log.i(TAG, "脚本状态: \(msg)")
            DispatchQueue.main.async { [weak self] in self?.onScriptStatus?(msg) }

        case "onSyncTouch":
            // 副窗口不广播；主窗口才转发
            guard syncEnabled, syncMaster else { return }
            guard let json = body["json"] as? String,
                  let data = json.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let x = (o["x"] as? NSNumber)?.floatValue,
                  let y = (o["y"] as? NSNumber)?.floatValue else { return }
            onSyncTouch?(x, y)

        case "gmRequest":
            let reqId = body["reqId"] as? String ?? ""
            let optionsJson = body["optionsJson"] as? String ?? ""
            doGmRequest(reqId: reqId, optionsJson: optionsJson)

        case "setClipboard":
            setClipboard(body["text"] as? String ?? "")

        case "saveImage":
            saveImage(body["dataUrl"] as? String ?? "")

        case "console":
            let level = body["level"] as? String ?? "JS"
            let msg = body["msg"] as? String ?? ""
            Log.d(TAG, "\(level): \(msg)")

        default:
            break
        }
    }
}

// MARK: - WKNavigationDelegate（对应 WebViewClient）

extension GameWebViewHolder: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        injectLate()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Log.w(TAG, "页面加载失败: \(error.localizedDescription)")
    }

    /**
     * 渲染进程崩溃（对应 onRenderProcessGone）。
     * iOS 上 WKWebView 内容进程崩溃不会带崩 App，但内容会白屏/失效，
     * 这里标记不可用并移出视图。iOS 无 didCrash 细节，无法区分崩溃与内存回收。
     */
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        renderGone = true
        pageReady = false
        webView.removeFromSuperview()
        onScriptStatus?("渲染进程已终止")
    }
}

// MARK: - WKUIDelegate（对应 javaScriptCanOpenWindowsAutomatically）

extension GameWebViewHolder: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}
