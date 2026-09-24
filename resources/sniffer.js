// VideoGrab 嗅探脚本
// ---------------------------------------------------------------------------
// 由 WKUserScript 在 document-start 注入到【每一个 frame】（forMainFrameOnly=false），
// 且必须在 page world（WKContentWorld.page）—— 因为要 hook 页面自己的 fetch/XHR，
// 也要读页面上的全局变量（苹果 CMS 的 var now / player_aaaa）。
//
// 设计依据（经五家 AI 交叉审查后修正）：
//   1. MediaSource.addSourceBuffer 的第一个参数是 MIME 不是 URL —— 拿不到地址，
//      只作为「这个页面在用 MSE」的信号。（原方案搞错了）
//   2. URL.createObjectURL 返回 blob: 没有真实源 —— 只作信号，不当地址用。
//   3. 主力 = fetch/XHR 劫持 + performance 资源计时回溯 + 读页面全局变量 + 扫 DOM。
//      其中 performance 的跨域 entry 的 name 仍是完整 URL（只有 timing 字段被清零），
//      所以「视频已经播了一会儿」这种情况也能回溯到。
//   4. hook 时保留原生引用，防止站点二次覆写把我们顶掉。
//   5. iOS 16 的 WebKit 不支持 MediaSource —— 所以靠 MSE 的播放器会回退到原生 HLS
//      （video.src = xxx.m3u8），这对我们反而有利：地址直接落在 DOM 里。
//   6. 扫描按代价分三层：媒体元素 + 页面全局变量是「轻活」，定时跑；把整页 HTML
//      序列化再跑正则是「重活」，只在页面加载完成和用户手动触发时各跑一次。
//      原来这三样全挂在 1.5 秒定时器 + 无节流的 MutationObserver 上 ——
//      现代网页一秒能变几十次 DOM，于是每秒几十次全页序列化，
//      这是「比 Safari 慢、滑动不跟手」的实证来源。
// ---------------------------------------------------------------------------
(function () {
  'use strict';

  if (window.__vgInstalled) return;
  window.__vgInstalled = true;

  var MEDIA_RE = /\.(m3u8|m3u8\?|mp4|m4v|mov|webm|mkv|flv|f4v|ts|m4s|mpd)([?#]|$)/i;
  var found = {};          // key: 去掉 fragment 的 url
  var dirty = false;       // 有变化待上报
  var mseSeen = false;     // 页面是否用过 MSE

  // ★ 必须用绝对时钟（epoch 毫秒）。之前用 performance.now()（页面加载后
  //   经过的毫秒数），被原生当成 1970 年起点 → 面板时间全显示「01-01 08:00」。
  function nowMs() {
    return Date.now();
  }

  function kindOf(u) {
    if (/^blob:/i.test(u)) return 'blob';
    if (/\.m3u8([?#]|$)/i.test(u)) return 'hls';
    if (/\.mpd([?#]|$)/i.test(u)) return 'dash';
    if (/\.(ts|m4s)([?#]|$)/i.test(u)) return 'segment';
    if (/\.(mp4|m4v|mov|webm|mkv|flv|f4v)([?#]|$)/i.test(u)) return 'file';
    return 'other';
  }

  function add(url, src) {
    if (!url || typeof url !== 'string') return;
    url = url.trim();
    if (!url) return;
    if (/^(data|javascript|about|mailto):/i.test(url)) return;

    var isBlob = /^blob:/i.test(url);
    if (!isBlob && !MEDIA_RE.test(url)) return;
    // 页面自身 HTML 不要
    try {
      if (url.split('#')[0] === location.href.split('#')[0]) return;
    } catch (e) {}

    var key = url.split('#')[0];
    if (found[key]) {
      var f = found[key];
      f.last = nowMs();
      // perf 回溯和 DOM 轮询是「回读」不是新请求 —— 照旧累计的话数字会
      // 膨胀到上千次（实测见过 1,268 次），反而失去参考价值。
      // 只有 fetch / xhr / video.src / 解析出的正文这类真实事件才 +1。
      if (!/^(perf|dom)/.test(src)) f.hits = (f.hits || 1) + 1;
      if (/^video/.test(src)) f.playing = true;
      return;
    }

    // 相对路径补全成绝对地址
    var abs = url;
    try {
      if (!/^[a-z][a-z0-9+.-]*:/i.test(url)) abs = new URL(url, location.href).href;
    } catch (e) {}

    found[key] = {
      url: abs,
      raw: url,
      kind: kindOf(url),
      src: src,
      page: (function () { try { return location.href; } catch (e) { return ''; } })(),
      // 页面上下文：下载分片、取 AES key 时都要带上（防盗链校验 Referer / 登录态靠 Cookie）
      ref: (function () { try { return document.referrer || ''; } catch (e) { return ''; } })(),
      ua: (function () { try { return navigator.userAgent || ''; } catch (e) { return ''; } })(),
      ck: (function () { try { return document.cookie || ''; } catch (e) { return ''; } })(),
      first: nowMs(),
      last: nowMs(),
      hits: 1,
      playing: /^video/.test(src)
    };
    dirty = true;
  }

  // ---------- 1. hook fetch（保留原生引用，防二次覆写） ----------
  try {
    var _fetch = window.fetch;
    if (typeof _fetch === 'function') {
      var wrappedFetch = function (input, init) {
        try {
          var u = (typeof input === 'string') ? input : (input && input.url);
          add(u, 'fetch');
        } catch (e) {}
        return _fetch.apply(this, arguments);
      };
      wrappedFetch.__vgNative = _fetch;
      window.fetch = wrappedFetch;
    }
  } catch (e) {}

  // ---------- 2. hook XHR ----------
  try {
    var _open = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (m, u) {
      try { add(u, 'xhr'); } catch (e) {}
      return _open.apply(this, arguments);
    };
    var _send = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.send = function () {
      var self = this;
      try {
        this.addEventListener('load', function () {
          try {
            if (self.responseType === '' || self.responseType === 'text') {
              var t = self.responseText || '';
              if (t.length < 20000) scanText(t, 'xhr-body');
            }
          } catch (e) {}
        });
      } catch (e) {}
      return _send.apply(this, arguments);
    };
  } catch (e) {}

  // ---------- 3. hook HTMLMediaElement.prototype.src 的 setter ----------
  // iOS 16 不支持 MSE → 播放器多半走原生 HLS，也就是直接 set video.src = xxx.m3u8。
  // 这是最可靠的一处。
  try {
    var desc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
    if (desc && desc.set && desc.get) {
      Object.defineProperty(HTMLMediaElement.prototype, 'src', {
        configurable: true,
        enumerable: desc.enumerable,
        get: function () { return desc.get.call(this); },
        set: function (v) {
          try { add(v, 'video.src'); } catch (e) {}
          return desc.set.call(this, v);
        }
      });
    }
  } catch (e) {}

  try {
    var dSrc = Object.getOwnPropertyDescriptor(HTMLSourceElement.prototype, 'src');
    if (dSrc && dSrc.set && dSrc.get) {
      Object.defineProperty(HTMLSourceElement.prototype, 'src', {
        configurable: true,
        enumerable: dSrc.enumerable,
        get: function () { return dSrc.get.call(this); },
        set: function (v) {
          try { add(v, 'source.src'); } catch (e) {}
          return dSrc.set.call(this, v);
        }
      });
    }
  } catch (e) {}

  // ---------- 4. MSE 只作信号（参数是 MIME，不是 URL） ----------
  try {
    if (window.MediaSource && MediaSource.prototype.addSourceBuffer) {
      var _asb = MediaSource.prototype.addSourceBuffer;
      MediaSource.prototype.addSourceBuffer = function (mime) {
        mseSeen = true;
        dirty = true;
        return _asb.apply(this, arguments);
      };
    }
    if (window.ManagedMediaSource && ManagedMediaSource.prototype.addSourceBuffer) {
      var _asb2 = ManagedMediaSource.prototype.addSourceBuffer;
      ManagedMediaSource.prototype.addSourceBuffer = function () {
        mseSeen = true;
        dirty = true;
        return _asb2.apply(this, arguments);
      };
    }
  } catch (e) {}

  // ---------- 5. 从文本里正则捞地址（XHR 响应体 / 页面 HTML） ----------
  function scanText(text, src) {
    if (!text || typeof text !== 'string') return;
    var re = /(https?:\\?\/\\?\/[^\s"'\\<>()]{6,400}?\.(?:m3u8|mp4|m4v|mov|flv|mpd)(?:\?[^\s"'\\<>()]{0,300})?)/gi;
    var m;
    var n = 0;
    while ((m = re.exec(text)) !== null && n < 40) {
      add(m[1].replace(/\\\//g, '/'), src);
      n++;
    }
  }

  // ---------- 6. 扫媒体元素（轻活：只查三个标签，走元素索引，代价很小） ----------
  function scanMediaEls() {
    try {
      var els = document.querySelectorAll('video, audio, source');
      for (var i = 0; i < els.length; i++) {
        var el = els[i];
        // ★ 正在播的 video 元素：它的地址就是「当前视频」—— 面板绿标的来源
        var isLive = false;
        try { isLive = !el.paused && !el.ended && el.currentTime > 0; } catch (e) {}
        var cur = null;
        try { if (el.currentSrc) cur = el.currentSrc; } catch (e) {}
        try { if (!cur && el.src) cur = el.src; } catch (e) {}
        if (cur) add(cur, isLive ? 'video-playing' : 'dom-currentSrc');
        try { if (el.src) add(el.src, 'dom-src'); } catch (e) {}
        try {
          var a = el.getAttribute && el.getAttribute('src');
          if (a) add(a, 'dom-attr');
        } catch (e) {}
        try {
          var ss = el.querySelectorAll ? el.querySelectorAll('source') : [];
          for (var j = 0; j < ss.length; j++) {
            var s = ss[j].getAttribute('src');
            if (s) add(s, 'dom-source');
          }
        } catch (e) {}
      }
    } catch (e) {}
  }

  // ---------- 6b. 读页面全局变量（轻活：只是几次属性读取） ----------
  // 苹果 CMS：真实地址常明文写在播放页的 var 里
  // var now="...m3u8";  var player_aaaa={"url":"..."};  var player_data={...}
  function scanGlobals() {
    try { if (typeof window.now === 'string') add(window.now, 'var now'); } catch (e) {}
    try {
      var cands = [window.player_aaaa, window.player_data, window.player_bbb,
                   window.MacPlayerData, window.videoUrl, window.url];
      for (var k = 0; k < cands.length; k++) {
        var c = cands[k];
        if (!c) continue;
        if (typeof c === 'string') { add(c, 'global'); continue; }
        if (typeof c === 'object') {
          ['url', 'url_next', 'url_pre', 'src', 'video', 'playUrl', 'm3u8'].forEach(function (f) {
            try { if (typeof c[f] === 'string') add(c[f], 'global.' + f); } catch (e) {}
          });
        }
      }
    } catch (e) {}
  }

  // ---------- 6c. 重活：把整页 HTML 序列化再跑正则 ----------
  // 一次就是几百 KB ~ 几 MB 的字符串 + 全量正则。只在两处调用：
  // 页面加载完成之后、用户手动刷新/长按时。绝不放回定时器或 MutationObserver。
  function scanPageHtml() {
    try {
      var html = document.documentElement ? document.documentElement.innerHTML : '';
      if (!html) return;
      // 极廉价的预筛：正则只认这几个扩展名，页面里连子串都没有就不可能匹配。
      // 一次 indexOf（约 1ms）换掉一次全量正则。
      if (html.indexOf('.m3u8') < 0 && html.indexOf('.mp4') < 0
          && html.indexOf('.m4v') < 0 && html.indexOf('.mov') < 0
          && html.indexOf('.flv') < 0 && html.indexOf('.mpd') < 0) return;
      scanText(html, 'page-html');
    } catch (e) {}
  }

  // 轻活合集 —— 定时器 / MutationObserver 只用这个
  function scanLive() {
    scanMediaEls();
    scanGlobals();
  }

  // ---------- 7. performance 资源计时回溯 ----------
  var perfSeen = {};   // 每个 URL 只记一次 —— getEntriesByType 会返回全部历史，
                       // 每 1.5 秒全量重报会把「出现次数」撑到上千
  function scanPerf() {
    try {
      var es = performance.getEntriesByType('resource');
      for (var i = 0; i < es.length; i++) {
        var n = es[i] && es[i].name;
        if (!n) continue;
        if (perfSeen[n]) continue;
        perfSeen[n] = 1;
        add(n, 'perf');
      }
    } catch (e) {}
  }

  try {
    new PerformanceObserver(function (list) {
      var es = list.getEntries();
      for (var i = 0; i < es.length; i++) {
        if (es[i] && es[i].name) add(es[i].name, 'perf-live');
      }
    }).observe({ entryTypes: ['resource'] });
  } catch (e) {}

  // ---------- 8. 上报给原生 ----------
  function payload() {
    var out = [];
    for (var k in found) {
      if (!Object.prototype.hasOwnProperty.call(found, k)) continue;
      out.push(found[k]);
    }
    // 排序：hls > file > dash > blob > other > segment
    var order = { hls: 0, file: 1, dash: 2, blob: 3, other: 4, segment: 9 };
    out.sort(function (a, b) {
      var d = (order[a.kind] || 5) - (order[b.kind] || 5);
      if (d !== 0) return d;
      return (b.last || 0) - (a.last || 0);
    });
    return out.slice(0, 60);
  }

  // 上报最小间隔 500ms。跨进程 postMessage 不免费 —— 原生每收到一次都要重排
  // 整个列表并刷新界面。短时间内的多次变化合并成一次；force（手动刷新 / 长按）
  // 不受限，必须立刻到。
  var reportTimer = null;
  var lastReportAt = 0;

  function flush(force) {
    if (reportTimer) { clearTimeout(reportTimer); reportTimer = null; }
    if (!dirty && !force) return;
    dirty = false;
    lastReportAt = nowMs();
    try {
      window.webkit.messageHandlers.vgSniff.postMessage({
        type: 'sniff',
        href: location.href,
        mse: mseSeen,
        items: payload()
      });
    } catch (e) {}
  }

  function report(force) {
    if (force) { flush(true); return; }
    if (reportTimer) return;                 // 已经排过一次，等它就行
    var wait = 500 - (nowMs() - lastReportAt);
    reportTimer = setTimeout(function () { reportTimer = null; flush(false); },
                             wait > 0 ? wait : 0);
  }

  // 手动触发（原生下拉刷新 / 页面加载完成）：轻活 + 重活都跑，并立刻上报
  window.__vgScan = function () {
    scanLive();
    scanPerf();
    scanPageHtml();
    report(true);
    return payload().length;
  };

  // ---------- 10. 长按视频 → 通知原生弹面板 ----------
  // 用捕获阶段监听，抢在播放器自己的处理器之前拿到事件；
  // 不去 preventDefault，免得把播放器的控件、全屏按钮弄坏。
  (function () {
    var timer = null;

    function videoAncestor(node) {
      var el = node;
      var depth = 0;
      while (el && el !== document && depth < 12) {
        if (el.tagName === 'VIDEO' || el.tagName === 'AUDIO') return el;
        el = el.parentNode;
        depth++;
      }
      return null;
    }

    function fire() {
      try {
        window.webkit.messageHandlers.vgSniff.postMessage({ type: 'longpress' });
      } catch (e) {}
    }

    function trigger() {
      scanLive();
      scanPerf();
      scanPageHtml();
      report(true);
      fire();
    }

    document.addEventListener('touchstart', function (e) {
      if (!videoAncestor(e.target)) return;
      if (timer) { clearTimeout(timer); timer = null; }
      timer = setTimeout(function () { timer = null; trigger(); }, 550);
    }, true);

    ['touchend', 'touchmove', 'touchcancel'].forEach(function (ev) {
      document.addEventListener(ev, function () {
        if (timer) { clearTimeout(timer); timer = null; }
      }, true);
    });

    // 桌面/鼠标右键兜底
    document.addEventListener('contextmenu', function (e) {
      if (videoAncestor(e.target)) { e.preventDefault(); trigger(); }
    }, true);
  })();

  // ---------- 11. 定时 + DOM 变化时自动扫（都只做轻活；重活见 scanPageHtml） ----------

  // 首扫推迟到 DOM 建好之后。以前在 document-start 就扫一遍：那时 DOM 还是空的，
  // 等于白跑一次整页序列化。而且本脚本同步阻塞解析（必须抢在页面之前装 hook），
  // 越早做重活越拖首屏。
  function boot() {
    scanLive();
    scanPerf();
    report(true);
    // DOMContentLoaded 之后有些播放器才把地址注进页面，稍后补一次重活
    setTimeout(function () { scanPageHtml(); scanPerf(); report(false); }, 1200);
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }

  // 定时：1.5 秒 → 3 秒，且只做轻活（不再含整页序列化）。
  setInterval(function () {
    scanLive();
    scanPerf();
    report(false);
  }, 3000);

  // DOM 变化：合并 400ms 内的所有变动，只跑一次轻活。
  // 原来是「每变一次就全量扫一次」。另外补上 attributes 过滤：有些播放器用
  // setAttribute('src', ...) 写地址，那条路不经过我们 hook 的 setter，只能靠这里兜。
  try {
    var moTimer = null;
    var mo = new MutationObserver(function () {
      if (moTimer) return;
      moTimer = setTimeout(function () { moTimer = null; scanLive(); report(false); }, 400);
    });
    var start = function () {
      try {
        mo.observe(document.documentElement || document, {
          childList: true,
          subtree: true,
          attributes: true,
          attributeFilter: ['src', 'data-src']
        });
      } catch (e) {}
    };
    if (document.documentElement) start();
    else document.addEventListener('DOMContentLoaded', start);
  } catch (e) {}
})();
