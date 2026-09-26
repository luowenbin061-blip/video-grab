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
//      现代网页一秒能变几十次 DOM，于是每秒几十次把整个 DOM 序列化成字符串。
//      实测（_probe_tmp/bench_regex*.js）：正则本身很便宜（130KB 页面约 0.1 ms，
//      1MB 最坏 13 ms 且无回溯爆炸）；贵的是 innerHTML 那一步的序列化与字符串
//      分配，它随 DOM 复杂度线性上涨，而且每跑一次都要让 GC 收拾一次大对象。
//      所以修法是「把它从热路径上拿掉」，不是去优化正则。
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
  // 只在两处调用：页面加载完成之后、用户手动刷新/长按时。
  // 绝不放回定时器或 MutationObserver —— 那里一秒能跑几十次。
  //
  // ★ 时间保护（v1.0.86）：这一步是**同步**的，中途打不断 ——
  //   所以只能「做之前先看成本，太大就直接放弃」。这就是为什么这里不是"超时中断"，
  //   而是"先看大小再决定"。
  //   ★ 成本指标用**元素个数**而不是 HTML 长度：想量长度就得先序列化，
  //     那正是要避免的那一步；元素个数是浏览器现成维护的计数，几乎零成本。
  var MAX_HEAVY_NODES = 40000;     // 元素数超过这个 = 页面太重，重活直接跳过
  var heavySkipUntil = 0;          // 放弃之后的冷却期（epoch 毫秒）

  function scanPageHtml() {
    try {
      if (nowMs() < heavySkipUntil) return;
      var nodeCount = document.getElementsByTagName
        ? document.getElementsByTagName('*').length : 0;
      if (nodeCount > MAX_HEAVY_NODES) {
        heavySkipUntil = nowMs() + 30000;      // 太重 → 这 30 秒不再试，别每次都白跑
        return;
      }
      var t0 = nowMs();
      var html = document.documentElement ? document.documentElement.innerHTML : '';
      if (!html) return;
      scanText(html, 'page-html');
      // 事后记账：这一次实际花了多久。真超了（说明元素个数不是好指标）→ 再冷一会儿。
      if (nowMs() - t0 > 300) heavySkipUntil = nowMs() + 30000;
    } catch (e) {}
  }

  // 轻活合集 —— 定时器 / MutationObserver 只用这个
  //
  // ★ 自保（v1.0.79）：单次轻活超过 60ms，说明这个页面的 DOM 太重
  //   （几万节点那种），后面 4 轮先跳过扫描。宁可少嗅探一点，
  //   也绝不能把页面的 JS 主线程占住 —— 用户实测过「页面还在、但按钮点不动」，
  //   那就是主线程被堵：滚动还能用（合成线程），点击的回调排不上队。
  var slowSkips = 0;
  function scanLive() {
    var t0 = nowMs();
    scanMediaEls();
    scanGlobals();
    if (nowMs() - t0 > 60) { slowSkips = 4; }
  }

  // ---------- 7. performance 资源回溯 ----------
  // ★ v1.0.79：这里原来有两套在干同一件事 ——
  //   ① 一个「每 3 秒遍历 performance.getEntriesByType('resource')」的全量轮询；
  //   ② 一个 PerformanceObserver（事件驱动、只给新增条目）。
  //   ① 是**随时间变慢**的：那个数组会一直涨（页面活得越久越长），每 3 秒全量走一遍
  //   纯属浪费 —— 而 ② 本来就覆盖了它。所以**只留 ②，把 ① 整个删掉**。
  //   这是用户报的「页面用久了就卡、按钮点不动」的元凶之一。
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
    scanPageHtml();
    report(true);
    return payload().length;
  };

  // ---------- 10. 长按视频：只回答原生「这一点上有没有视频」 ----------
  // 触发是原生的长按手势（见 app/LongPressMenu.swift）。这里不再自己监听手势、
  // 也不往界面推任何东西 —— 长按只弹下载菜单，绝不弹嗅探面板。
  (function () {
    // ─── 长按视频：命中测试（原生长按手势来问）+ 一条 JS 兜底 ───
    //
    // 为什么不再自己盖透明 <a>：WebKit 在 touchstart 那一瞬间就把长按目标锁死了，
    // 之后插进去的 <a> 永远不参与本次命中测试；而且系统那个菜单回调只对链接/图片
    // 触发，<video> 默认不触发。那条路原理上不通（实测两版都是「长按毫无反应」）。
    // 现在：原生长按手势负责触发，这里只回答「这个点上有没有视频、地址是什么」，
    // 菜单本身由原生画（见 app/LongPressMenu.swift）。
    (function () {
      function findMedia(node) {
        var el = node;
        var depth = 0;
        while (el && el !== document && depth < 12) {
          if (el.tagName === 'VIDEO' || el.tagName === 'AUDIO') return el;
          el = el.parentNode;
          depth++;
        }
        return null;
      }

      // ★ 按几何找：哪个 video 的矩形盖住了这个点（有多个时取最小 = 最贴切的那个）。
      // 为什么必须有这条：多数播放器把「封面图 / 大播放按钮 / 控制条」做成 video 的
      // **兄弟元素**压在它上面 —— 这时 elementFromPoint 命中的是那层 div，
      // 顺着祖先链怎么走都走不到 video，于是被判成「不是视频」→ 长按不弹菜单。
      // 实测症状就是「有些页能弹、大多数不弹」。
      function videoUnder(doc, x, y) {
        var list = null, best = null, bestArea = 0;
        try { list = doc.querySelectorAll('video'); } catch (e) { return null; }
        for (var i = 0; i < list.length; i++) {
          var r = list[i].getBoundingClientRect();
          if (r.width < 40 || r.height < 40) continue;
          if (x < r.left || x > r.right || y < r.top || y > r.bottom) continue;
          var area = r.width * r.height;
          if (!best || area < bestArea) { best = list[i]; bestArea = area; }
        }
        return best;
      }

      // 没命中视频时报一下「页内最大的那个视频框在哪」——
      // 原生探测点和网页实际位置如果有整体偏差（安全区/缩放），日志里一眼就能看出来
      function biggestVideoBox(doc) {
        var list = null, best = null, bestArea = 0;
        try { list = doc.querySelectorAll('video'); } catch (e) { return null; }
        for (var i = 0; i < list.length; i++) {
          var r = list[i].getBoundingClientRect();
          if (r.width < 40 || r.height < 40) continue;
          var area = r.width * r.height;
          if (!best || area > bestArea) { best = r; bestArea = area; }
        }
        if (!best) return null;
        return '最大视频框 x ' + Math.round(best.left) + '-' + Math.round(best.right)
             + '  y ' + Math.round(best.top) + '-' + Math.round(best.bottom);
      }

      function countVideos(doc) {
        try { return doc.querySelectorAll('video').length; } catch (e) { return -1; }
      }

      // 日志里要能看出「手指底下到底是什么」—— 命中不到视频时必须知道是谁挡着
      function clipOf(el) {
        var c = '';
        try { c = String(el.className || ''); } catch (e) { c = ''; }
        c = c.replace(/\s+/g, ' ').replace(/^ | $/g, '').slice(0, 40);
        return el.tagName + (c ? '.' + c : '');
      }

      function mediaInfo(v, doc, via) {
        var r = v.getBoundingClientRect();
        return {
          hit: 'media',
          via: via,
          url: v.currentSrc || v.src || '',
          poster: v.poster || '',
          title: ((doc && doc.title) || document.title || '').slice(0, 140),
          w: Math.round(r.width),
          h: Math.round(r.height)
        };
      }

      // 递归命中测试：同源 iframe 能直接进去看；跨域的进不去（同源策略），
      // 那就老实回报「这里是 iframe」，由原生侧写进诊断日志。
      function hitIn(doc, x, y, depth) {
        if (!doc || depth > 4) return null;
        var el = doc.elementFromPoint(x, y);
        if (!el) return null;
        var v = findMedia(el);
        if (v) return mediaInfo(v, doc, 'dom');

        // 点在 iframe 上 → 先钻进去看：里面的东西一定比「外面盖着它的」更贴切。
        // （顺序很重要：先几何兜底的话，外层某个 video 会把它抢走 —— 离线回归用例③逮到过）
        var frameInfo = null;
        if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') {
          var ir = el.getBoundingClientRect();
          // ★ v1.0.86 修掉的一句谎话：以前"拿不到 document"就一律 cross=true，
          //   于是「同源、只是还没加载完」被谎报成「跨域」，诊断日志把人带偏。
          //   能区分两者的只有一点：**访问 contentWindow.document 抛不抛异常** ——
          //   抛（SecurityError）= 真跨域；不抛但为 null = 同源、还没加载完。
          var inner = null;
          var cross = false;
          try {
            inner = el.contentDocument || (el.contentWindow && el.contentWindow.document);
          } catch (e) {
            cross = true;                    // 只有抛异常才是真跨域
          }
          if (inner) {
            var sub = hitIn(inner, x - ir.left, y - ir.top, depth + 1);
            if (sub && sub.hit === 'media') return sub;
          }
          frameInfo = {
            hit: 'iframe', cross: cross, src: el.src || '',
            x: ir.left, y: ir.top, w: ir.width, h: ir.height
          };
          if (!inner) return frameInfo;      // 进不去（跨域 / 还没加载完）—— 只能回报它本身
        }

        // ★ 按几何找（封面图/控制条是 video 的兄弟元素压在上面时，只有这条能认出来）
        v = videoUnder(doc, x, y);
        if (v) return mediaInfo(v, doc, 'geo');

        if (frameInfo) return frameInfo;
        return {
          hit: 'other', tag: el.tagName, cls: clipOf(el), vids: countVideos(doc),
          near: biggestVideoBox(doc)
        };
      }

      // 原生侧调这个。坐标是页面 CSS 像素。
      window.__vgHit = function (x, y) {
        try {
          return hitIn(document, x, y, 0) || { hit: 'none' };
        } catch (e) {
          return { hit: 'error', msg: String((e && e.message) || e) };
        }
      };

      // ── 这里原来有一条「按住 900ms 还没等到原生菜单就报给原生、弹嗅探面板」的兜底。
      //    已删除：用户明确说「长按不该把嗅探结果弹出来」。嗅探那套是后台自动跑的，
      //    跟手势没有任何关系；面板只该由右下角那个按钮/底栏入口打开，不该自己冒出来。
      //    （代价：万一哪天某个页面把原生长按手势吃掉，长按就什么都不会发生 ——
      //      这种情况请打开「长按诊断」反馈，而不是让面板乱弹。）
    })();
  })();

  // ---------- 11. 定时 + DOM 变化时自动扫（都只做轻活；重活见 scanPageHtml） ----------

  // 首扫推迟到 DOM 建好之后。以前在 document-start 就扫一遍：那时 DOM 还是空的，
  // 等于白跑一次整页序列化。而且本脚本同步阻塞解析（必须抢在页面之前装 hook），
  // 越早做重活越拖首屏。
  function boot() {
    scanLive();
    report(true);
    // DOMContentLoaded 之后有些播放器才把地址注进页面，稍后补一次重活
    setTimeout(function () { scanPageHtml(); report(false); }, 1200);
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }

  // 定时：1.5 秒 → 3 秒，且只做轻活（不再含整页序列化）。
  setInterval(function () {
    if (slowSkips > 0) { slowSkips--; return; }   // 页面太重就先歇一轮（见 scanLive 的自保）
    scanLive();
    report(false);
  }, 3000);

  // DOM 变化：合并 400ms 内的所有变动，只跑一次轻活。
  // 原来是「每变一次就全量扫一次」。另外补上 attributes 过滤：有些播放器用
  // setAttribute('src', ...) 写地址，那条路不经过我们 hook 的 setter，只能靠这里兜。
  try {
    var moTimer = null;
    // ★ v1.0.79：原来这里一有 DOM 变化（合并 400ms）就跑 scanLive()，
    //   而 scanLive 里是**全文档** querySelectorAll —— 弹幕、计时器、广告轮播这类
    //   每秒都在改 DOM 的页面会一直重扫，把页面自己的主线程挤住。
    //   改成先做一次**极便宜的判断**：这次变化里有没有跟媒体相关的节点？
    //   没有就直接 return，什么都不做。
    var mo = new MutationObserver(function (recs) {
      var relevant = false;
      for (var i = 0; i < recs.length && !relevant; i++) {
        var r = recs[i];
        // src / data-src 变了 → 可能是播放器换了地址，值得扫
        if (r.type === 'attributes') { relevant = true; break; }
        var ns = r.addedNodes;
        if (!ns || !ns.length) continue;
        for (var j = 0; j < ns.length; j++) {
          var nd = ns[j];
          if (!nd || nd.nodeType !== 1) continue;
          var tn = nd.tagName;
          if (tn === 'VIDEO' || tn === 'AUDIO' || tn === 'SOURCE' || tn === 'IFRAME') {
            relevant = true; break;
          }
          // 只在这棵**新子树**里找（不是全文档）—— 便宜得多
          try {
            if (nd.querySelector && nd.querySelector('video, audio, source')) {
              relevant = true; break;
            }
          } catch (e) {}
        }
      }
      if (!relevant) return;
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
