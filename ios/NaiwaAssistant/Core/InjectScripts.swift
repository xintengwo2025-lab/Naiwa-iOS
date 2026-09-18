import WebKit

/**
 * 注入到 WebView 的 JS 片段，移植自 iOS 版原生壳内嵌的脚本。
 *
 * 注意：iOS 版中的「连点器」(autoClicker) 已按需求移除，本文件不包含该功能。
 *
 * 每个片段统一包装为 WKUserScript：
 *  - injectEarly 的脚本（COMPAT / GM_SHIM / XHR_INTERCEPT / activateBin）
 *    注入时机为 .atDocumentStart，对应原 Kotlin 的 onPageStarted 注入。
 *  - injectLate 的脚本（VH_FIX / SCRIPT_UI_FIX / CANVAS_GUARD / SYNCER_*）
 *    注入时机为 .atDocumentEnd，对应原 Kotlin 的 onPageFinished 注入。
 *  - setFrameRate / activateBin 是带参数的运行时脚本，返回 WKUserScript；
 *    需要动态执行时由调用方取 .source 走 evaluateJavaScript。
 */
enum InjectScripts {

    /// 把原始 JS 片段包装成 WKUserScript。
    private static func script(_ source: String,
                               at time: WKUserScriptInjectionTime,
                               mainFrameOnly: Bool = true) -> WKUserScript {
        WKUserScript(source: source, injectionTime: time, forMainFrameOnly: mainFrameOnly)
    }

    /** 登录请求体替换：把发往登录接口的 POST body 换成当前选中账号的 bin 数据 */
    static var xhrIntercept: WKUserScript {
        script(#"""
(function(){
    if(window.__xhrIntercepted) return;
    window.__xhrIntercepted = true;
    var _open = XMLHttpRequest.prototype.open;
    var _send = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function(m, u){
        this._m = m; this._u = u;
        this._isTarget = (m === 'POST' &&
            /hortorgames\.com\/login\/(authuser|serverlist)/.test(u));
        return _open.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function(b){
        if (this._isTarget && window.__activeBinHex) {
            console.log('[奶蛙] 拦截XHR:', this._u);
            var hex = window.__activeBinHex;
            var arr = new Uint8Array(hex.length / 2);
            for (var i = 0; i < arr.length; i++) {
                arr[i] = parseInt(hex.substr(i * 2, 2), 16);
            }
            return _send.call(this, arr.buffer);
        }
        return _send.call(this, b);
    };
    console.log('[奶蛙] XHR拦截已启动');
})();
"""#, at: .atDocumentStart)
    }

    /** 全局错误吞噬 + 安全剪贴板 + execCommand 兜底 */
    static var compat: WKUserScript {
        script(#"""
(function(){
    if(window.__compatInstalled) return;
    window.__compatInstalled = true;

    // 1. 全局错误吞噬：游戏在缺少原生 SDK 时会抛异常，放行会中断加载
    window.onerror = function(){ return true; };
    window.addEventListener('error', function(e){
        e.preventDefault(); e.stopPropagation();
    }, true);
    window.addEventListener('unhandledrejection', function(e){
        e.preventDefault(); e.stopPropagation();
    }, true);

    // 2. 安全剪贴板
    var _cb = '';
    window.setClipboard = function(t){
        if (t === undefined || t === null) return;
        var text = (typeof t === 'object') ? (t.text || JSON.stringify(t)) : String(t);
        try {
            if (window.AndroidBridge && AndroidBridge.setClipboard) {
                AndroidBridge.setClipboard(text);
                return;
            }
        } catch(e) {}
        _cb = text;
    };

    // 3. 安全 execCommand：拦掉 copy/paste 避免游戏内触发系统面板
    try {
        var _ec = document.execCommand;
        document.execCommand = function(cmd){
            if (cmd === 'copy') {
                try {
                    _cb = window.getSelection ? window.getSelection().toString() : '';
                } catch(e) {}
                return true;
            }
            if (cmd === 'paste') return true;
            return _ec.apply(this, arguments);
        };
    } catch(e) {}

    // 4. 防止 copy 冒泡到系统
    document.addEventListener('copy', function(e){ e.stopPropagation(); }, true);

    console.log('[奶蛙] 兼容脚本已注入');
})();
"""#, at: .atDocumentStart)
    }

    /**
     * 油猴（Tampermonkey）兼容层。
     *
     * 部分脚本依赖这些 API，缺了会静默退出：拿不到 `unsafeWindow` 或
     * `GM_xmlhttpRequest` 就一直空转轮询，表现为什么都不显示。
     *
     * GM_xmlhttpRequest 必须转发到原生：脚本要访问外部域名，
     * 页面内的 XHR/fetch 会被同源策略拦掉。油猴自己也是这么实现的。
     */
    static var gmShim: WKUserScript {
        script(#"""
(function(){
    if(window.__gmShimInstalled) return;
    window.__gmShimInstalled = true;

    // 没有沙箱隔离，unsafeWindow 就是 window 本身
    if (!window.unsafeWindow) window.unsafeWindow = window;

    // ---- 存储：GM_setValue / GM_getValue ----
    var PREFIX = '__gm_';
    if (!window.GM_setValue) window.GM_setValue = function(k, v){
        try { localStorage.setItem(PREFIX + k, JSON.stringify(v)); } catch(e) {}
    };
    if (!window.GM_getValue) window.GM_getValue = function(k, def){
        try {
            var s = localStorage.getItem(PREFIX + k);
            return s === null ? def : JSON.parse(s);
        } catch(e) { return def; }
    };
    if (!window.GM_deleteValue) window.GM_deleteValue = function(k){
        try { localStorage.removeItem(PREFIX + k); } catch(e) {}
    };
    if (!window.GM_listValues) window.GM_listValues = function(){
        var out = [];
        try {
            for (var i = 0; i < localStorage.length; i++) {
                var k = localStorage.key(i);
                if (k && k.indexOf(PREFIX) === 0) out.push(k.slice(PREFIX.length));
            }
        } catch(e) {}
        return out;
    };

    // ---- 样式 ----
    if (!window.GM_addStyle) window.GM_addStyle = function(css){
        var s = document.createElement('style');
        s.textContent = css;
        (document.head || document.documentElement).appendChild(s);
        return s;
    };

    // ---- 跨域请求：转发到原生 ----
    var pending = {};
    var seq = 0;
    window.__gmResolve = function(id, json){
        var cb = pending[id];
        if (!cb) return;
        delete pending[id];
        var res;
        try { res = JSON.parse(json); } catch(e) { res = { status: 0, error: 'bad response' }; }
        res.readyState = 4;
        res.response = res.responseText;
        // 脚本自己的回调抛错不能冒泡出去，否则会打断后续脚本
        try {
            if (res.error || !res.status) {
                cb.onerror && cb.onerror(res);
            } else {
                cb.onload && cb.onload(res);
            }
            cb.onreadystatechange && cb.onreadystatechange(res);
        } catch(e) {
            console.warn('[奶蛙] 脚本请求回调异常: ' + (e && e.message));
        }
    };

    function gmxhr(opts){
        opts = opts || {};
        var id = 'gm' + (++seq) + '_' + Date.now();
        pending[id] = opts;
        var payload = {
            url: opts.url,
            method: (opts.method || 'GET').toUpperCase(),
            headers: opts.headers || {},
            data: (opts.data === undefined || opts.data === null) ? null : String(opts.data),
            timeout: opts.timeout || 20000,
        };
        try {
            AndroidBridge.gmRequest(id, JSON.stringify(payload));
        } catch(e) {
            // 原生桥不可用时退回普通 XHR，同源请求仍然能成
            delete pending[id];
            // 原生桥不可用时退回普通 XHR，同源请求仍然能work
            try {
                var x = new XMLHttpRequest();
                x.open(payload.method, payload.url, true);
                Object.keys(payload.headers).forEach(function(k){
                    try { x.setRequestHeader(k, payload.headers[k]); } catch(e2) {}
                });
                x.onload = function(){
                    opts.onload && opts.onload({
                        status: x.status, statusText: x.statusText,
                        responseText: x.responseText, response: x.responseText,
                        responseHeaders: x.getAllResponseHeaders(), readyState: 4,
                    });
                };
                x.onerror = function(){ opts.onerror && opts.onerror({ status: 0, error: 'network' }); };
                x.send(payload.data);
            } catch(e3) {
                opts.onerror && opts.onerror({ status: 0, error: String(e3 && e3.message) });
            }
        }
        return { abort: function(){ delete pending[id]; } };
    }
    if (!window.GM_xmlhttpRequest) window.GM_xmlhttpRequest = gmxhr;

    // 新版 GM.* 命名空间
    if (!window.GM) {
        window.GM = {
            xmlHttpRequest: gmxhr,
            setValue: function(k, v){ return Promise.resolve(window.GM_setValue(k, v)); },
            getValue: function(k, d){ return Promise.resolve(window.GM_getValue(k, d)); },
            deleteValue: function(k){ return Promise.resolve(window.GM_deleteValue(k)); },
            addStyle: function(c){ return Promise.resolve(window.GM_addStyle(c)); },
            setClipboard: function(t){ return Promise.resolve(window.GM_setClipboard(t)); },
        };
    }

    // ---- 其余零散 API ----
    if (!window.GM_setClipboard) window.GM_setClipboard = function(text){
        try { AndroidBridge.setClipboard(String(text)); return; } catch(e) {}
        try { navigator.clipboard && navigator.clipboard.writeText(String(text)); } catch(e) {}
    };
    // 单窗口环境开不了新标签，转成同窗口跳转的空操作，只记录避免脚本报错
    if (!window.GM_openInTab) window.GM_openInTab = function(url){
        console.log('[奶蛙] GM_openInTab 已忽略: ' + url);
        return { close: function(){}, closed: false };
    };
    if (!window.GM_notification) window.GM_notification = function(o){
        var text = (o && (o.text || o.title)) || String(o);
        console.log('[奶蛙] 脚本通知: ' + text);
    };
    if (!window.GM_registerMenuCommand) window.GM_registerMenuCommand = function(name){
        console.log('[奶蛙] 脚本菜单项(未挂载): ' + name);
        return name;
    };
    if (!window.GM_unregisterMenuCommand) window.GM_unregisterMenuCommand = function(){};
    // 有脚本会绑定 GM_download，缺了它取值为 undefined，调用即抛错
    if (!window.GM_download) window.GM_download = function(o){
        var url = (o && o.url) || o;
        console.log('[奶蛙] 脚本请求下载(已忽略): ' + String(url).slice(0, 120));
        if (o && o.onerror) o.onerror({ error: 'not_supported' });
    };
    if (!window.GM_getResourceText) window.GM_getResourceText = function(){ return ''; };
    if (!window.GM_getResourceURL) window.GM_getResourceURL = function(){ return ''; };
    if (!window.GM_log) window.GM_log = function(){ console.log.apply(console, arguments); };
    if (!window.GM_info) window.GM_info = {
        scriptHandler: 'NaiwaAssistant',
        version: '1.0',
        script: { name: 'userscript', version: '1.0', grant: ['none'] },
    };

    // 真机实测：游戏只给 ROLE.roleId，不给 ROLE.id。
    // 但多数脚本用 ROLE.id 判断"会话是否就绪"（游戏增强面板正是因此做了
    // id→roleId→userId 三级兜底），只认 id 的脚本会永远等不到、静默不工作。
    // 这里把 id 补成 roleId 的别名，取值时才计算，避免抢在游戏赋值之前。
    (function(){
        function alias(){
            var R = window.ROLE;
            if (!R || typeof R !== 'object') return false;
            if (R.id != null && R.id !== '') return true;
            var rid = R.roleId != null ? R.roleId : R.userId;
            if (rid == null || rid === '') return false;
            try {
                Object.defineProperty(R, 'id', {
                    get: function(){ return this.roleId != null ? this.roleId : this.userId; },
                    configurable: true,
                });
                console.log('[奶蛙] 已补 ROLE.id = ' + rid);
                return true;
            } catch(e) { try { R.id = rid; return true; } catch(e2) { return false; } }
        }
        if (alias()) return;
        // 角色数据在登录完成后才有，轮询到位为止（最多 120 秒）
        var t = 0;
        var iv = setInterval(function(){
            if (alias() || ++t > 240) clearInterval(iv);
        }, 500);
    })();

    console.log('[奶蛙] 油猴兼容层已注入');
})();
"""#, at: .atDocumentStart)
    }

    /**
     * 修 vh 单位失效。
     *
     * 真机实测：`100vh` 被算成 0px，而 `100%` 正常等于视口高度。
     * 原因是 WebSettings.useWideViewPort=true（多开缩放要用它）让 Blink
     * 的视口高度不确定，vh 基准退化为 0。
     *
     * 后果是所有用 vh 限高的脚本面板都被压扁：
     * 白玉彩玉 `max-height:88vh` 变 0，面板只剩 2px（一条白线）；
     * 无限阵容 `max-height:78vh` 变 0，只显示标题。
     *
     * 修法：遍历脚本插入的样式表，把 vh 换算成实际像素后重写规则。
     * 不用 CSS 硬编码具体选择器 —— 那样每加一个脚本都要改代码。
     */
    static var vhFix: WKUserScript {
        script(#"""
(function(){
    if(window.__vhFixInstalled) return;
    window.__vhFixInstalled = true;

    // 先确认 vh 真的坏了，正常的机型不要动
    var probe = document.createElement('div');
    probe.style.cssText = 'position:fixed;left:-9999px;top:0;width:1px;height:100vh;';
    document.body.appendChild(probe);
    var vh100 = probe.getBoundingClientRect().height;
    document.body.removeChild(probe);

    var real = window.innerHeight || document.documentElement.clientHeight;
    if (vh100 > real * 0.5) {
        console.log('[奶蛙] vh 正常(100vh=' + vh100.toFixed(0) + 'px)，无需修正');
        return;
    }
    console.log('[奶蛙] vh 失效(100vh=' + vh100.toFixed(0) +
        'px, 实际应为 ' + real + 'px)，开始替换');

    // vh -> px。放在 calc() 里也能正确参与运算。
    function toPx(css){
        return css.replace(/(-?[\d.]+)vh/g, function(_, n){
            return (parseFloat(n) * real / 100).toFixed(1) + 'px';
        });
    }

    var PROPS = ['max-height','min-height','height','top','bottom','padding-bottom','margin-bottom'];

    function patchSheet(sheet){
        var rules;
        try { rules = sheet.cssRules; } catch(e) { return 0; }   // 跨域样式表读不了
        if (!rules) return 0;
        var n = 0;
        for (var i = 0; i < rules.length; i++) {
            var r = rules[i];
            if (r.cssRules) { n += patchSheet(r); continue; }    // @media 等嵌套
            if (!r.style) continue;
            for (var p = 0; p < PROPS.length; p++) {
                var v = r.style.getPropertyValue(PROPS[p]);
                if (!v || v.indexOf('vh') < 0) continue;
                r.style.setProperty(PROPS[p], toPx(v), r.style.getPropertyPriority(PROPS[p]));
                n++;
            }
        }
        return n;
    }

    function patchAll(){
        var total = 0;
        for (var i = 0; i < document.styleSheets.length; i++) {
            total += patchSheet(document.styleSheets[i]);
        }
        // 行内样式里的 vh 同样要换
        document.querySelectorAll('[style*="vh"]').forEach(function(el){
            var s = el.getAttribute('style');
            if (s && /[\d.]vh/.test(s)) { el.setAttribute('style', toPx(s)); total++; }
        });
        return total;
    }

    console.log('[奶蛙] vh 替换 ' + patchAll() + ' 处');

    // 脚本是陆续注入的，新样式表要继续处理
    new MutationObserver(function(muts){
        var need = false;
        muts.forEach(function(m){
            Array.prototype.slice.call(m.addedNodes).forEach(function(n){
                if (n.nodeType === 1 && (n.tagName === 'STYLE' || n.tagName === 'LINK')) need = true;
            });
        });
        if (need) {
            var c = patchAll();
            if (c) console.log('[奶蛙] 新样式表 vh 替换 ' + c + ' 处');
        }
    }).observe(document.documentElement, { childList: true, subtree: true });
})();
"""#, at: .atDocumentEnd)
    }

    /**
     * UI 修正样式自检 + 面板布局上报。
     *
     * 修正规则本体在 renderer/naiwa-uifix.css。这里额外把脚本插到 body 的
     * 浮层尺寸和位置打到日志：面板"跑到下面"、"只显示标题"这类问题，
     * 靠看代码猜不出来（我已经猜错过几次），必须拿真机的实际数值。
     */
    static var scriptUiFix: WKUserScript {
        script(#"""
(function(){
    if(window.__scriptUiFixInstalled) return;
    window.__scriptUiFixInstalled = true;

    var applied = window.getComputedStyle(document.body).display === 'block';
    console.log('[奶蛙] UI修正样式' + (applied ? '已生效' : '未生效(检查 naiwa-uifix.css)'));

    // 面板布局只打到日志，供接 USB 时排查
    function logPanels(){
        var vw = window.innerWidth, vh = window.innerHeight;
        console.log('[奶蛙UI] 视口 ' + vw + 'x' + vh);
        Array.prototype.slice.call(document.body.children).forEach(function(el){
            if (el.id === 'Cocos2dGameContainer' || el.id === 'GameCanvas') return;
            if (el.tagName === 'SCRIPT' || el.tagName === 'STYLE' || el.tagName === 'LINK') return;
            var r = el.getBoundingClientRect();
            var cs = window.getComputedStyle(el);
            var flag = '';
            if (r.bottom > vh) flag += ' 超出底部' + Math.round(r.bottom - vh) + 'px';
            if (r.right > vw) flag += ' 超出右侧' + Math.round(r.right - vw) + 'px';
            if (r.height < 4 && cs.display !== 'none') flag += ' 高度塌陷';
            console.log('[奶蛙UI] <' + el.tagName.toLowerCase() +
                (el.id ? '#' + el.id : '') + '> ' +
                Math.round(r.width) + 'x' + Math.round(r.height) +
                ' @(' + Math.round(r.left) + ',' + Math.round(r.top) + ')' +
                ' pos=' + cs.position + ' disp=' + cs.display +
                ' top=' + cs.top + ' bottom=' + cs.bottom + flag);
        });
    }
    // 脚本建 UI 需要时间，延迟采样一次
    setTimeout(logPanels, 8000);
})();
"""#, at: .atDocumentEnd)
    }

    /**
     * canvas 触摸看护。
     *
     * 只做一件事：canvas 的 pointerEvents 被脚本改成 none 时恢复它。
     *
     * 原先还会把「高 zIndex 的大浮层」设成 display:none 来清理遮挡，
     * 但这条规则区分不了遮挡层和脚本面板，误杀很严重：
     * 无限阵容面板里的 hero-team-list 初始是空 div 且 flex:1 撑满，
     * 搜索框和按钮区同理，全被判成遮挡层隐藏掉 —— 表现就是面板
     * 「只显示队伍管理四个字」。隐藏元素的收益远小于风险，去掉。
     */
    static var canvasGuard: WKUserScript {
        script(#"""
(function(){
    if(window.__canvasGuardInstalled) return;
    window.__canvasGuardInstalled = true;
    setInterval(function(){
        var canvas = document.getElementById('GameCanvas');
        if (!canvas) return;
        if (window.getComputedStyle(canvas).pointerEvents === 'none') {
            canvas.style.pointerEvents = 'auto';
            console.log('[奶蛙] 恢复 canvas 触摸');
        }
    }, 5000);
})();
"""#, at: .atDocumentEnd)
    }

    /** 同步器发送端：主窗口把触摸坐标上报给原生，由原生广播给副窗口 */
    static var syncerSender: WKUserScript {
        script(#"""
(function(){
    if(window.__syncerSenderInstalled) return;
    window.__syncerSenderInstalled = true;
    // capture 阶段拦截，确保在游戏 stopPropagation 之前捕获
    document.addEventListener('touchstart', function(e){
        var touch = e.touches[0];
        if (!touch) return;
        try {
            AndroidBridge.onSyncTouch(JSON.stringify({
                x: touch.clientX, y: touch.clientY, t: Date.now()
            }));
        } catch(err) {}
    }, { capture: true, passive: true });
    console.log('[奶蛙] 同步器(发送端)已启用');
})();
"""#, at: .atDocumentEnd)
    }

    /** 同步器接收端：副窗口在指定坐标合成一次点击 */
    static var syncerReceiver: WKUserScript {
        script(#"""
(function(){
    if(window.__syncerRecvInstalled) return;
    window.__syncerRecvInstalled = true;
    window.__applySyncTouch = function(x, y){
        var canvas = document.getElementById('GameCanvas');
        if (!canvas) return;
        // Cocos2D 监听 canvas 上的 touch 事件，需要创建合法 Touch 对象
        function fire(type){
            var t;
            try {
                t = new Touch({
                    identifier: Date.now() % 100000, target: canvas,
                    clientX: x, clientY: y, pageX: x, pageY: y,
                    screenX: x, screenY: y
                });
            } catch(e) {
                t = { identifier: 1, target: canvas, clientX: x, clientY: y,
                      pageX: x, pageY: y, screenX: x, screenY: y };
            }
            var ev;
            try {
                ev = new TouchEvent(type, {
                    touches: type === 'touchend' ? [] : [t],
                    targetTouches: type === 'touchend' ? [] : [t],
                    changedTouches: [t],
                    bubbles: true, cancelable: true, view: window
                });
            } catch(e) {
                ev = document.createEvent('Event');
                ev.initEvent(type, true, true);
                ev.touches = type === 'touchend' ? [] : [t];
                ev.targetTouches = ev.touches;
                ev.changedTouches = [t];
            }
            canvas.dispatchEvent(ev);
        }
        fire('touchstart');
        setTimeout(function(){ fire('touchend'); }, 30);
    };
    console.log('[奶蛙] 同步器(接收端)已启用');
})();
"""#, at: .atDocumentEnd)
    }

    /**
     * 标签模式下给非激活窗口降帧，省电减热。
     * 只动渲染帧率，setInterval 与事件 hook 不受影响，
     * 所以脚本逻辑照常运行（那几个内置脚本都不依赖帧率）。
     *
     * 该方法带运行时参数，返回 WKUserScript；调用方取 .source 动态执行。
     */
    static func setFrameRate(fps: Int) -> WKUserScript {
        script(#"""
(function(){
  try {
    if (window.cc && cc.game && cc.game.setFrameRate) {
      cc.game.setFrameRate(\#(fps));
      console.log('[奶蛙] 帧率切换为 \#(fps)');
    }
  } catch(e) {}
})();
"""#, at: .atDocumentStart)
    }

    /** 内存告警时通知 JS 降频 + GC */
    static var lowMemory: WKUserScript {
        script(#"""
(function(){
    try {
        if (window.cc && cc.game) { cc.game.setFrameRate(30); }
        if (window.gc) window.gc();
        console.log('[奶蛙] 收到内存警告，已降频');
    } catch(e) {}
})();
"""#, at: .atDocumentStart)
    }

    /** 把选中账号的 bin 写入 window.__activeBinHex */
    static func activateBin(hex: String, label: String) -> WKUserScript {
        script(#"""
(function(){
    window.__activeBinHex = '\#(hex)';
    console.log('[奶蛙] 已注入BIN数据:', '\#(label)', \#(hex.count / 2));
})();
"""#, at: .atDocumentStart)
    }
}
