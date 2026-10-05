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

  // ★ v1.0.109：白名单从「只认视频」扩到 视频 + 音频 + 文档。
  //   图片不走这条（它有自己的一条正则和**另一个**列表，见 IMG_RE / foundImg）。
  var MEDIA_RE = /\.(m3u8|m3u8\?|mp4|m4v|mov|webm|mkv|flv|f4v|ts|m4s|mpd|mp3|m4a|aac|wav|flac|ogg|opus|pdf|zip|rar|7z|epub|txt|doc|docx|xls|xlsx|ppt|pptx)([?#]|$)/i;
  var IMG_RE = /\.(jpg|jpeg|png|webp|gif|heic|heif|avif|bmp|tiff|svg)([?#]|$)/i;
  var found = {};          // key: 去掉 fragment 的 url（视频/音频/文档）
  // ★ v1.0.109：图片单独一个字典 —— 「视频」和「图片」是两个 tab，
  //   各自独立的上限，互不挤占（一页几百张图不会把视频顶掉）。
  var foundImg = {};
  // 图片默认**不主动上报**（省跨进程开销）。原生在用户切到「图片」tab 时
  // 调 __vgSetImages(true) 打开它，并顺便扫一次当前页面。
  var wantImages = false;
  var dirty = false;       // 有变化待上报
  var mseSeen = false;     // 页面是否用过 MSE

  // ★ v1.0.104：「后台自动嗅探」开关（默认关）。这一行由原生在注入时替换成
  //   `var autoOn = true;`（见 BrowserModel.snifferSource(autoSniff:)）。
  //   关着的时候：下面那些 hook **照旧装**（抓请求的能力不能丢 —— 一闪而过的
  //   m3u8 全靠它），但**不**反复扫页面、**不**自动上报。用户点开「嗅探结果」
  //   面板时，原生会调 __vgScan() 手动扫一次（那才是"需要的时候"）。
  // ★ v1.0.214：页面视频清单（给地址栏左侧的「窗口」按钮用）。
  //   独立于 autoOn —— 那个开关默认是关的，而按钮要始终能用。
  //   只扫 <video>，不碰网络请求，所以不改变"自动嗅探"的语义。
  var pageVids = [];
  var vidTimer = null, vidLastAt = 0, vidObserver = null;

  var autoOn = false;
  var booted = false;      // 首扫只做一次

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
    // ★ v1.0.109：这三类以前全落到 other（而 other 又进不来）—— 现在各自有名有姓
    if (IMG_RE.test(u)) return 'image';
    if (/\.(mp3|m4a|aac|wav|flac|ogg|opus)([?#]|$)/i.test(u)) return 'audio';
    if (/\.(pdf|zip|rar|7z|epub|txt|doc|docx|xls|xlsx|ppt|pptx)([?#]|$)/i.test(u)) return 'doc';
    return 'other';
  }

  // ★ v1.0.110：URL 清洗 —— 必须在**入库前**做，否则后面全错。
  //
  //   踩到的坑（实测）：`el.getAttribute('src')` 返回的是 **HTML 原文**，
  //   里面可能带未解码的实体 `&amp;`。这种地址发给服务器 = 路径不存在 → 404，
  //   而 CDN（openresty 那类）返回的是 404 + text/html，
  //   看起来像"页面不存在"，根本看不出是 URL 被写坏了。
  //   浏览器自己的 property（`.src` / `.currentSrc`）是**解码过**的，所以优先用它们；
  //   凡是从 attribute 拿的，一律先过这道清洗。
  //   顺带清掉零宽字符（有些站从编辑器粘贴会带进来，肉眼看不见但会让 URL 失效）。
  function cleanURL(u) {
    if (typeof u !== 'string') return '';
    return u
      .replace(/&amp;/gi, '&')
      .replace(/&#0*38;/g, '&')
      .replace(/&quot;/gi, '"')
      .replace(/&#0*39;/g, "'")
      .replace(/[\u200b-\u200d\ufeff]/g, '')
      .trim();
  }

  function add(url, src) {
    if (!url || typeof url !== 'string') return;
    url = cleanURL(url);
    url = url.trim();
    if (!url) return;
    if (/^(data|javascript|about|mailto):/i.test(url)) return;

    var isBlob = /^blob:/i.test(url);
    var kind = kindOf(url);
    var isImg = (kind === 'image');
    // ★ v1.0.109：图片也收（进 foundImg），但**不是**走 MEDIA_RE 那条
    if (!isBlob && !MEDIA_RE.test(url) && !isImg) return;
    // 页面自身 HTML 不要
    try {
      if (url.split('#')[0] === location.href.split('#')[0]) return;
    } catch (e) {}

    var store = isImg ? foundImg : found;
    var key = url.split('#')[0];
    if (store[key]) {
      var f = store[key];
      f.last = nowMs();
      // perf 回溯和 DOM 轮询是「回读」不是新请求 —— 照旧累计的话数字会
      // 膨胀到上千次（实测见过 1,268 次），反而失去参考价值。
      // 只有 fetch / xhr / video.src / 解析出的正文这类真实事件才 +1。
      if (!/^(perf|dom)/.test(src)) f.hits = (f.hits || 1) + 1;
      if (/^video/.test(src)) f.playing = true;
      return;
    }

    // 相对路径补全成绝对地址。
    // ★ v1.0.110：**绝对地址也过一遍 URL()** —— 它会顺手把空格这类非法字符编码掉
    //（有些站把带空格的图片名直接写进 HTML，原样发出去必然 404）。
    // 对已经编码好的 URL，URL() 是幂等的，不会二次编码 %XX。
    var abs = url;
    try {
      abs = new URL(url, location.href).href;
    } catch (e) {}

    store[key] = {
      url: abs,
      raw: url,
      kind: kind,
      src: src,
      page: (function () { try { return location.href; } catch (e) { return ''; } })(),
      // 页面上下文：下载分片、取 AES key 时都要带上（防盗链校验 Referer / 登录态靠 Cookie）
      //
      // ★ v1.0.110：Referer 改成「**当前页面地址**优先，document.referrer 兜底」。
      //   原来只用 document.referrer —— 那是"我是从哪个页面**点进来**的"：
      //     直接输网址 / 从书签打开 / 刷新 / 站内跳转 → 它一律是**空的**。
      //   防盗链的图床/CDN 收到空 Referer 直接拒（openresty 那类常回 **404** 而不是 403，
      //   所以看起来像"地址不存在"，完全看不出是防盗链）。
      //   v1.0.106 修长按下载时已经这么改过（ctxFor），这里把嗅探这条路补齐。
      ref: (function () {
        try { return location.href || document.referrer || ''; } catch (e) { return ''; }
      })(),
      ua: (function () { try { return navigator.userAgent || ''; } catch (e) { return ''; } })(),
      ck: (function () { try { return document.cookie || ''; } catch (e) { return ''; } })(),
      first: nowMs(),
      last: nowMs(),
      hits: 1,
      playing: /^video/.test(src)
    };
    // 图片单独一个上限：不设的话，刷图站挂一晚上能攒几千条。
    // 超了就丢"最久没再出现过"的那些（last 最小的）。
    if (isImg) {
      var ks = Object.keys(foundImg);
      if (ks.length > 400) {
        ks.sort(function (a, b) { return (foundImg[a].last || 0) - (foundImg[b].last || 0); });
        for (var i2 = 0; i2 < ks.length - 400; i2++) delete foundImg[ks[i2]];
      }
    }
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

  // ---------- 6c. 页面视频清单（v1.0.214 新增） ----------
  // ★ 这一块**独立于 autoOn**：那个开关默认是关的，而「窗口」按钮要始终能用。
  //   只扫 <video>（很轻），只上报"有没有、像不像正片"的线索，不碰网络请求。
  //   原生侧拿到这些线索后**自己算置信度**（谁更可能是正片），JS 这边不做判断。
  // ★ v1.0.226：给「视频历史」抓一张封面帧。
  //   · 只有**同源**视频抓得到 —— 跨域画面会把 canvas "污染"，
  //     到 `toDataURL` 那一步直接抛 SecurityError，被下面 catch 吃掉、返回空串。
  //     所以这不是"漏了"，是浏览器规矩，别在这儿纠结。
  //   · 抓帧结果按 src 缓存（blob 用下标当 key）；**失败不缓存** ——
  //     视频刚进页面时 `readyState < 2`，那会儿画出来是黑的，等它加载好了下次再抓。
  //   · 页面一换就把缓存整个丢掉（下标会错位）。
  //   · 尺寸压到 240 宽 + 0.6 质量：postMessage 传大字符串很贵，封面够看就行。
  var shotCache = {};
  var shotPage = '';
  function grabShot(v, src, idx) {
    try {
      var page = location.href || '';
      if (page !== shotPage) { shotCache = {}; shotPage = page; }
      var key = src || ('idx' + idx);
      if (shotCache[key]) return shotCache[key];
      if (v.readyState < 2 || !v.videoWidth || !v.videoHeight) return '';
      var tw = 240, th = Math.round(v.videoHeight * tw / v.videoWidth);
      var c = document.createElement('canvas');
      c.width = tw; c.height = th;
      var ctx = c.getContext('2d');
      if (!ctx) return '';
      ctx.drawImage(v, 0, 0, tw, th);
      var s = c.toDataURL('image/jpeg', 0.6);   // ← 跨域在这一行抛
      if (!s || s.length > 60000) return '';    // 太大的不要
      shotCache[key] = s;
      return s;
    } catch (e) { return ''; }
  }

  // ★ v1.0.228：封面图**多来源**查找 —— 只认 `video.poster` 命中率太低（多数站根本不用它，
  //   用户实测「多数网站的视频都没有缩略图」）。
  //   顺序：① video 自己的 poster → ② 往上 3 层祖先的 background-image
  //        （很多站的封面是给播放器容器设的背景图）。
  //   都没找到就返回空串，再由原生侧决定"要不要抽帧"。
  function findCover(v) {
    try { if (v.poster) return v.poster; } catch (e) {}
    try {
      var p = v.parentElement;
      for (var k = 0; k < 3 && p; k++, p = p.parentElement) {
        var bg = '';
        try { bg = window.getComputedStyle(p).backgroundImage || ''; } catch (e) {}
        var m = /url\(["']?(.*?)["']?\)/.exec(bg);
        if (m && m[1] && !/^data:/i.test(m[1])) return m[1];
      }
    } catch (e) {}
    return '';
  }

  // ★ v1.0.228：页面级封面（og:image / twitter:image）—— 单视频页里它通常就是海报图。
  //   注意是**兜底**：多视频页会全都挂同一张图，所以只在 video 自己找不到时用。
  var ogCoverCache = null;
  function ogCover() {
    if (ogCoverCache !== null) return ogCoverCache;
    ogCoverCache = '';
    try {
      var sels = ['meta[property="og:image"]', 'meta[name="og:image"]',
                  'meta[name="twitter:image"]', 'meta[property="twitter:image"]'];
      for (var i = 0; i < sels.length; i++) {
        var m = document.querySelector(sels[i]);
        if (m && m.content) { ogCoverCache = m.content; break; }
      }
    } catch (e) {}
    return ogCoverCache;
  }

  // ★ v1.0.228：标题 —— 用户实测「大多显示站点名称」，根因是原来只用了 `document.title`
  //   （有些站的 title 就是站名，真名在 og:title / h1 里）。
  //   顺序：og:title → 第一个 h1 → document.title。
  var pageTitleCache = null;
  function pageTitle() {
    if (pageTitleCache !== null) return pageTitleCache;
    var t = '';
    try {
      var m = document.querySelector('meta[property="og:title"], meta[name="og:title"]');
      if (m && m.content) t = (m.content || '').trim();
    } catch (e) {}
    if (!t) { try { var h = document.querySelector('h1'); if (h) t = (h.textContent || '').trim(); } catch (e) {} }
    if (!t) { try { t = (document.title || '').trim(); } catch (e) {} }
    pageTitleCache = t.slice(0, 140);
    return pageTitleCache;
  }

  // ★ v1.0.228：视频**自己**的名字（有的播放器会写在 title / aria-label 上）
  function videoTitle(v) {
    try {
      var t = v.getAttribute('title') || v.getAttribute('aria-label') || '';
      if (t) return String(t).trim().slice(0, 140);
    } catch (e) {}
    return '';
  }

  function scanVideos() {
    var out = [];
    try {
      var list = document.querySelectorAll('video');
      var vw = window.innerWidth || 0, vh = window.innerHeight || 0;
      var vArea = vw * vh;
      if (!vArea) return 0;
      for (var i = 0; i < list.length && i < 12; i++) {
        var v = list[i], r = null;
        try { r = v.getBoundingClientRect(); } catch (e) { continue; }
        if (!r || r.width < 80 || r.height < 45) continue;   // 太小的一律不当视频
        var cur = '';
        try { cur = v.currentSrc || v.src || ''; } catch (e) {}
        var playing = false;
        try { playing = !v.paused && !v.ended && v.currentTime > 0; } catch (e) {}
        var dur = 0;
        try { dur = (isFinite(v.duration) && v.duration > 0) ? v.duration : 0; } catch (e) {}
        var muted = false, ctrls = false, ap = false;
        try { muted = !!v.muted; } catch (e) {}
        try { ctrls = !!v.controls; } catch (e) {}
        try { ap = !!v.autoplay; } catch (e) {}
        var isBlob = /^blob:/i.test(cur);
        var cx = r.left + r.width / 2, cy = r.top + r.height / 2;
        // ★ v1.0.226：两条封面的来源，给「视频历史」当缩略图 ——
        //   ① `poster`：页面自己声明的封面图地址（最省事、最准）→ 原生下载它；
        //   ② `shot`：从当前画面上抓的一帧（仅同源抓得到，见 grabShot）。
        //   只有 `src` 为空的那条也不能丢 —— 它就是"没能直接播"的那种，历史里要如实记着。
        // ★ v1.0.228：封面走**多来源**（见 findCover / ogCover），不再只认 video.poster。
        //   抓帧（shot）保留：同源时它是"真实画面"，比 og:image 更贴题。
        var cover = findCover(v);
        if (!cover) cover = ogCover();
        out.push({
          i: i,
          src: isBlob ? '' : cur,                     // blob 不是"能直接播的地址"
          blob: isBlob,
          playing: playing,
          muted: muted,
          autoplay: ap,
          controls: ctrls,
          dur: Math.round(dur),
          w: Math.round(r.width),
          h: Math.round(r.height),
          area: Math.round(r.width * r.height / vArea * 100),   // 占屏百分比
          center: (Math.abs(cx - vw / 2) < vw * 0.25 && Math.abs(cy - vh / 2) < vh * 0.25),
          poster: cover,
          vtitle: videoTitle(v),
          shot: grabShot(v, cur, i)
        });
      }
    } catch (e) {}
    pageVids = out;
    return out.length;
  }

  // ★ v1.0.216：清单没变就**不再重发**。原来每次 DOM 变化都重发一条（节流 400ms），
  //   有两个害处：① 播放器在 <iframe> 里的站（聚合站很常见）—— 主 frame 自己扫不到
  //   <video>，只能报空，这条"空清单"会把子 frame 报上来的视频一遍遍擦掉（按钮闪一下
  //   就没了）；② 页面每 400ms 一条同内容的跨进程消息 + 原生侧一次无谓的界面刷新。
  var vidSig = null;
  function vidSignature(list) {
    var a = [];
    for (var i = 0; i < list.length; i++) {
      var v = list[i];
      // ★ v1.0.228：**封面也算进签名** —— 页面刚加载时 og:image 那个 meta 可能还没解析，
      //   封面会先空后有；不含进签名的话那次变化不触发重发，就永远拿不到封面了。
      a.push(v.i + '|' + v.src + '|' + (v.playing ? 1 : 0) + '|' + v.dur +
             '|' + v.w + 'x' + v.h + '|' + (v.muted ? 1 : 0) + '|' + v.area +
             '|' + (v.poster || ''));
    }
    return a.join(';');
  }

  function flushVideos(force) {
    if (vidTimer) { clearTimeout(vidTimer); vidTimer = null; }
    vidLastAt = nowMs();
    var sig = vidSignature(pageVids);
    if (!force && sig === vidSig) return;    // 没变化 → 不发
    vidSig = sig;
    try {
      window.webkit.messageHandlers.vgVideos.postMessage({
        type: 'videos',
        href: location.href,
        // ★ v1.0.228：页面级标题放这儿（每条视频带一份太浪费带宽）；
        //   原生侧拿它当"视频名"的兜底（og:title > h1 > title，见 pageTitle）。
        ptitle: pageTitle(),
        videos: pageVids
      });
    } catch (e) {}
  }
  // 节流：400ms 内的多次变化合并成一次（跨进程 postMessage 不免费）
  function reportVideos(force) {
    if (force) { scanVideos(); flushVideos(true); return; }
    if (vidTimer) return;
    var wait = 400 - (nowMs() - vidLastAt);
    vidTimer = setTimeout(function () {
      vidTimer = null;
      scanVideos();
      flushVideos(false);
    }, wait > 0 ? wait : 0);
  }

  // ★ v1.0.216：首扫时视频常常还没铺好（懒加载 / 播放器后置 / 尺寸还是 0×0 被上面
  //   那条尺寸过滤挡掉），而 MutationObserver 只看"节点新增"，抓不到"尺寸后置"
  //   （尺寸变化不是属性变化）。所以在还没扫到任何视频之前，每 1.5 秒补扫一次，
  //   最多 20 次（30 秒）；扫到就停。用户后来点播放会触发 play 事件 → 同样会重扫。
  var vidRetry = null, vidRetryLeft = 0;
  function startVideos() {
    if (vidObserver) return;
    reportVideos(true);
    vidRetryLeft = 20;
    vidRetry = setInterval(function () {
      if (vidRetryLeft-- <= 0 || pageVids.length > 0) {
        clearInterval(vidRetry); vidRetry = null; return;
      }
      reportVideos(false);
    }, 1500);
    try {
      // ① 页面新增节点 → 重扫。**只观察 childList**（观察 attributes 是最贵的）
      vidObserver = new MutationObserver(function () { reportVideos(false); });
      vidObserver.observe(document.documentElement || document,
                          { childList: true, subtree: true });
    } catch (e) {}
    try {
      // ② video 自己的状态变化（开播 / 暂停 / 换源）→ 重扫。
      //    用事件委托挂在 document 上（捕获），不逐个元素挂监听。
      var evs = ['play', 'pause', 'loadedmetadata', 'durationchange', 'emptied', 'volumechange'];
      for (var i = 0; i < evs.length; i++) {
        document.addEventListener(evs[i], function (e) {
          var t = e.target;
          if (t && String(t.tagName || '').toLowerCase() === 'video') reportVideos(false);
        }, true);
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
  function payloadItems() {
    var out = [];
    for (var k in found) {
      if (!Object.prototype.hasOwnProperty.call(found, k)) continue;
      out.push(found[k]);
    }
    // 排序：hls > file > dash > blob > other > audio > doc > segment
    // （分片永远垫底；音频/文档排在视频后面）
    var order = { hls: 0, file: 1, dash: 2, blob: 3, other: 4, audio: 5, doc: 6, segment: 9 };
    out.sort(function (a, b) {
      var d = (order[a.kind] || 5) - (order[b.kind] || 5);
      if (d !== 0) return d;
      return (b.last || 0) - (a.last || 0);
    });
    return out.slice(0, 60);
  }

  // ★ v1.0.109：图片走**独立通道**，不进上面那个 60 条池 ——
  //   否则一页几百张图会把视频顶出去（「视频和图片分开」本来就是用户的诉求）。
  //   用户没切到「图片」tab 时返回空数组，一次多余的跨进程开销都不花。
  function payloadImages() {
    if (!wantImages) return [];
    var out = [];
    for (var k in foundImg) {
      if (!Object.prototype.hasOwnProperty.call(foundImg, k)) continue;
      out.push(foundImg[k]);
    }
    // 图片按「最近出现」排 —— 页面上刚显示出来的那张最可能就是要找的
    out.sort(function (a, b) { return (b.last || 0) - (a.last || 0); });
    return out.slice(0, 60);
  }

  function payload() { return payloadItems(); }

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
        items: payloadItems(),
        images: payloadImages()
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

  // ---------- 9b. 扫当前页面的图片（v1.0.109） ----------
  // 只在用户切到「图片」tab 时跑（原生调 __vgSetImages(true)）。
  //
  // 为什么默认不扫：一页几十上百个 img，每次 DOM 扫描都遍历一遍是白花钱；
  // 而 hook 那条路（fetch/xhr/img 请求）本来就在收，用户点了才补扫就够了。
  // 过滤 1×1 追踪像素：naturalWidth/Height ≤ 2 的直接丢（这是免费拿到的，
  // 不用额外发请求 —— 实测体积阈值那条路要先下载才知道大小，成本太高）。
  function scanImages() {
    try {
      var els = document.querySelectorAll('img');
      for (var i = 0; i < els.length; i++) {
        var el = els[i];
        var w = 0, h = 0;
        try { w = el.naturalWidth || 0; h = el.naturalHeight || 0; } catch (e) {}
        if (w > 0 && h > 0 && (w <= 2 || h <= 2)) continue;   // 追踪像素
        // ★ v1.0.110：地址来源分三级，**优先用浏览器解码过的 property**
        //   （`.currentSrc` / `.src`）—— 它们不会带 HTML 实体。
        var u = '';
        try { if (el.currentSrc) u = el.currentSrc; } catch (e) {}
        try { if (!u && el.src) u = el.src; } catch (e) {}
        if (!u) {
          // 懒加载图（property 还没值）：只能读 attribute，交给 add() 里的 cleanURL 兜着
          try {
            u = el.getAttribute('data-src')
             || el.getAttribute('data-original')
             || el.getAttribute('data-lazy-src')
             || el.getAttribute('data-echo') || '';
          } catch (e) {}
        }
        if (u) add(u, 'img');

        // srcset：**只在上面都拿不到时**才用（它以前是 404 的头号来源 ——
        // getAttribute 会带 HTML 实体，而且手工 split 容易把描述符切进 URL）。
        // 用 property `el.srcset`（值同样可能带实体，但 add() 会清洗）。
        if (!u) {
          try {
            var ss = el.srcset || '';
            if (ss) {
              var parts = ss.split(',');
              var last = parts[parts.length - 1].trim().split(/\s+/)[0];
              if (last) add(last, 'img-srcset');
            }
          } catch (e) {}
        }
      }
    } catch (e) {}
  }

  // 原生在切到「图片」tab 时调用：打开图片上报 + 立刻扫一次当前页面。
  window.__vgSetImages = function (on) {
    wantImages = !!on;
    if (wantImages) scanImages();
    report(true);
    var n = 0;
    for (var k in foundImg) { if (Object.prototype.hasOwnProperty.call(foundImg, k)) n++; }
    return n;
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

      // ★ v1.0.105：长按拿到的地址**不一定能下** —— MSE 播放器的 currentSrc 是
      //   `blob:` 临时地址（只在页面里有效，网络层取不到内容，下载必然失败）。
      //   所以顺手从「已经抓到的请求」里挑一个能直接下的（优先 m3u8，其次直链文件）当备选。
      //   注意：这**不依赖自动扫描**（v1.0.104 起默认关了）—— 靠的是 hook，
      //   页面发过的请求一直在记，所以这里挑得到。
      function pickAlt(cur) {
        try {
          if (cur && !/^blob:/i.test(cur) && MEDIA_RE.test(cur)) return '';   // 本身就能下
          var bestHls = '', hlsScore = -1, bestFile = '', fileScore = -1;
          for (var k in found) {
            if (!Object.prototype.hasOwnProperty.call(found, k)) continue;
            var f = found[k];
            if (!f || !f.url) continue;
            // 「正在播的那个」优先，其次「最近出现的」
            var score = (f.last || 0) + (f.playing ? 9e15 : 0);
            if (f.kind === 'hls') {
              if (score > hlsScore) { hlsScore = score; bestHls = f.url; }
            } else if (f.kind === 'file') {
              if (score > fileScore) { fileScore = score; bestFile = f.url; }
            }
          }
          return bestHls || bestFile;
        } catch (e) { return ''; }
      }

      // ★ v1.0.106：长按下载要用的「页面上下文」（Referer / UA / Cookie）
      //   **在这里直接取**，随探测结果一起交回去。
      //   以前是回到原生后再去「嗅探结果」里找同一条 —— 而自动嗅探默认关之后，
      //   那份结果常常是空的 → Referer/Cookie 全空 → 防盗链站必然「拿不到内容」，
      //   而嗅探面板点下载却正常（它用的是自己那条记录的上下文）。
      //   优先用这条请求**真实记录**下来的上下文；没有就用当前页面现取。
      function ctxFor(u) {
        var ref = '', ua = '', ck = '';
        try {
          var f = found[(u || '').split('#')[0]];
          if (f) { ref = f.ref || ''; ua = f.ua || ''; ck = f.ck || ''; }
        } catch (e) {}
        try { if (!ua) ua = navigator.userAgent || ''; } catch (e) {}
        try { if (!ck) ck = document.cookie || ''; } catch (e) {}
        // ★ 兜底的 Referer 用**当前页面地址**，不是 document.referrer：
        //   防盗链校验的就是"这个请求从哪个页面发出来的"——而 document.referrer
        //   是"你从哪一页跳进来的"，站外来源反而会被服务器拒掉。
        try { if (!ref) ref = location.href || ''; } catch (e) {}
        try { if (!ref) ref = document.referrer || ''; } catch (e) {}
        return { ref: ref, ua: ua, ck: ck };
      }

      function mediaInfo(v, doc, via) {
        var r = v.getBoundingClientRect();
        return {
          hit: 'media',
          via: via,
          url: v.currentSrc || v.src || '',
          alt: pickAlt(v.currentSrc || v.src || ''),
          ctx: ctxFor(v.currentSrc || v.src || ''),
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
    if (booted) return;
    booted = true;
    scanLive();
    report(true);
    // DOMContentLoaded 之后有些播放器才把地址注进页面，稍后补一次重活
    setTimeout(function () { scanPageHtml(); report(false); }, 1200);
  }
  if (autoOn) {
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', boot);
    } else {
      boot();
    }
  }

  // ═══ 自动扫描（v1.0.104 起受开关控制、默认关）═══
  var tickTimer = null;    // 每 3 秒的轻活定时器
  var mo = null;           // DOM 变化观察器
  var moTimer = null;      // 变化合并用的定时器

  function startAuto() {
    if (tickTimer) return;   // 已经在跑（重复调用无害）
    // 定时：1.5 秒 → 3 秒，且只做轻活（不再含整页序列化）。
    tickTimer = setInterval(function () {
      if (slowSkips > 0) { slowSkips--; return; }   // 页面太重就先歇一轮（见 scanLive 的自保）
      scanLive();
      report(false);
    }, 3000);

  // DOM 变化：合并 400ms 内的所有变动，只跑一次轻活。
  // 原来是「每变一次就全量扫一次」。另外补上 attributes 过滤：有些播放器用
  // setAttribute('src', ...) 写地址，那条路不经过我们 hook 的 setter，只能靠这里兜。
  try {
    moTimer = null;
    // ★ v1.0.79：原来这里一有 DOM 变化（合并 400ms）就跑 scanLive()，
    //   而 scanLive 里是**全文档** querySelectorAll —— 弹幕、计时器、广告轮播这类
    //   每秒都在改 DOM 的页面会一直重扫，把页面自己的主线程挤住。
    //   改成先做一次**极便宜的判断**：这次变化里有没有跟媒体相关的节点？
    //   没有就直接 return，什么都不做。
    mo = new MutationObserver(function (recs) {
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
  }   // ← startAuto() 到此结束

  function stopAuto() {
    if (tickTimer) { clearInterval(tickTimer); tickTimer = null; }
    if (moTimer) { clearTimeout(moTimer); moTimer = null; }
    if (mo) { try { mo.disconnect(); } catch (e) {} mo = null; }
  }

  // 运行时切换 —— 原生改了开关后立刻调它，不用刷新页面
  window.__vgSetAuto = function (on) {
    autoOn = !!on;
    if (autoOn) startAuto(); else stopAuto();
    return autoOn;
  };

  // ★ 默认关。注意：**长按和抓请求都不依赖这个开关** ——
  //   长按走 __vgHit（第 10 段，独立），抓请求走上面那些 hook（第 1~5 段）。
  if (autoOn) startAuto();

  // ★ v1.0.216：页面视频清单**必须无条件启动** —— 它的条件是「这页有没有 <video>」，
  //   跟「后台自动嗅探」那个开关（默认关）毫无关系。v1.0.214/215 把它挂在 boot() 里，
  //   而 boot() 只在 autoOn 时才跑 → 真机上「窗口」按钮**从来没出现过**（用户实测复现）。
  //   startVideos 自己带 `if (vidObserver) return;`，重复调用无害。
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', startVideos);
  } else {
    startVideos();
  }
})();
