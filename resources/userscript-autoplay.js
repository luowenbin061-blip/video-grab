// ==UserScript==
// @name         自动播放网页视频
// @match        *://*/*
// @description  整页只有一个可见视频时帮你播起来（催不动就替你点一下播放按钮）
// ==/UserScript==
//
// ★ 这是「用户脚本」体系里的**第一个内置脚本**（用户 2026-10-07 要的功能）。
//   它自己也是这个体系的样板：头部照油猴那套写，正文就是一个立即执行的函数。
//
// ★ 他定的判据：**当前页面只有唯一一个视频时才自动播，否则会乱套** ——
//   所以下面要跨 frame 汇总（视频常常在播放器 iframe 里）：
//     子 frame 上报"我这有几个" → 主 frame 汇总 → 总数恰好 1 才催。
//   页面里有 1 个正片 + 1 个广告位小视频（总数 2）→ 谁都不催。
//
// ★ 体积/时机都刻意克制：不做 MutationObserver，只在头 12 秒里补扫几次。

(function () {
  if (window.__vgAutoPlayLoaded) return;        // 同一个 frame 只装一次

  // ★ 原生侧在注入前按「网页媒体自动播放」四档替换这一行：
  //   用户明确选了"禁止视频自动播放"之类 → 用户说了算，这个脚本整段不干活。
  var VG_AUTOPLAY_BLOCKED = false;
  if (VG_AUTOPLAY_BLOCKED) return;

  var MAX_TRY = 3;
  var DELAYS = [0, 600, 1800];                  // 递进间隔：立刻重试大概率还是被拒
  // ★ v1.0.234：阈值放宽（48→32 / 15%→8%）。原来那套真机偏严：
  //   播放器嵌在 iframe 里时，"占屏面积"是相对 **iframe 自己** 算的，
  //   小一点的播放器会被误判成"不算一个视频" → 一条都不催。
  var MIN_PX = 32;
  var MIN_RATIO = 0.08;
  // 补扫拉到 20 秒 —— 有的站播放器是后来才塞进来的
  var SCAN_TIMES = [0, 800, 1800, 3000, 5000, 8000, 12000, 16000, 20000];

  var isTop = false;
  try { isTop = (window === window.top); } catch (e) { isTop = false; }

  var done = false;         // 已经成功播起来了（这个 frame）
  var attempt = 0;          // 催播次数
  var mutedByUs = false;    // 是我们把它静音才播起来的（之后要帮它把声音打开）
  var lastTotal = -1;

  // ── ① 数一数：这个 frame 里"像样的可见视频"有几个 ──
  function visibleVideos() {
    var out = [];
    try {
      var list = document.querySelectorAll('video');
      var vw = window.innerWidth || 1, vh = window.innerHeight || 1;
      for (var i = 0; i < list.length; i++) {
        var v = list[i], r = null;
        try { r = v.getBoundingClientRect(); } catch (e) { continue; }
        if (!r || r.width < MIN_PX || r.height < MIN_PX) continue;
        // 不在视口里的直接排掉 —— 这一条同时挡住了网站常用的
        // 「position:absolute; left:-9999px」那种隐藏预加载 video。
        if (r.bottom <= 0 || r.top >= vh || r.right <= 0 || r.left >= vw) continue;
        var w = Math.min(r.right, vw) - Math.max(r.left, 0);
        var h = Math.min(r.bottom, vh) - Math.max(r.top, 0);
        if (w <= 0 || h <= 0) continue;
        if ((w * h) / (vw * vh) < MIN_RATIO) continue;
        try {
          var cs = window.getComputedStyle(v);
          if (cs.display === 'none' || cs.visibility === 'hidden') continue;
          if (parseFloat(cs.opacity || '1') < 0.05) continue;
        } catch (e) {}
        out.push(v);
      }
    } catch (e) {}
    return out;
  }

  // ── ② 跨 frame 汇总：子 frame 上报数量，主 frame 汇总后广播"全页总数" ──
  var others = [];          // 主 frame 记的：每个子 frame 的最新数量
  var srcKeys = [];         // 跟 others 一一对应的窗口引用

  function sendUp(n) {
    if (isTop) return;
    try { window.top.postMessage({ __vgAutoPlay: 'count', n: n }, '*'); } catch (e) {}
  }

  /// 把这个 frame 的**直接子 frame** 都通知一遍。
  /// ★ v1.0.234：不再限制"只有主 frame 能广播" —— 中间层的 frame 也要往下转发，
  ///   否则**孙 frame**（iframe 里的 iframe）永远收不到"全页总数"，于是不催。
  function tellKids(msg) {
    try {
      var fs = window.frames;
      for (var i = 0; i < fs.length; i++) {
        try { fs[i].postMessage(msg, '*'); } catch (e) {}
      }
    } catch (e) {}
  }

  function broadcast(total) {
    tellKids({ __vgAutoPlay: 'total', n: total });
  }

  function noteFrom(e) {
    var d = e && e.data;
    if (!d || d.__vgAutoPlay !== 'count') return false;
    var n = (typeof d.n === 'number' && d.n >= 0) ? d.n : 0;
    var key = e.source;
    var at = -1;
    for (var i = 0; i < srcKeys.length; i++) { if (srcKeys[i] === key) { at = i; break; } }
    if (at >= 0) { others[at] = n; } else { srcKeys.push(key); others.push(n); }
    return true;
  }

  if (isTop) {
    window.addEventListener('message', function (e) {
      if (noteFrom(e)) { scan(); }
    }, false);
  } else {
    window.addEventListener('message', function (e) {
      var d = e && e.data;
      if (!d || !d.__vgAutoPlay) return;
      // ★ 主 frame 主动来问 → 立刻上报（有的子 frame 比主 frame 晚 ready，光等它可能等不到）
      if (d.__vgAutoPlay === 'hello') { scan(); return; }
      if (d.__vgAutoPlay !== 'total') return;
      if (typeof d.n === 'number') {
        broadcast(d.n);            // ★ 往下转发给孙 frame（不然它们收不到总数）
        handleTotal(d.n);
      }
    }, false);
  }

  // ── ③ 扫描 → 上报 → （主 frame）汇总广播 / （子 frame）等广播 ──
  function scan() {
    // ★ 这里**不按 done 提前返回**：主 frame 的"汇总 + 广播"要一直有效
    //   （子 frame 可能比我们晚才上报）。重复催播由 handleTotal 里的 done 挡。
    var mine = visibleVideos().length;
    if (isTop) {
      // ★ v1.0.234：还没收到任何子 frame 上报、但页面上确实有 iframe → 主动去问一遍。
      //   不然会因为"子 frame 比我们晚 ready"而一直算不出正确总数。
      try {
        if (others.length === 0 && window.frames.length > 0) {
          tellKids({ __vgAutoPlay: 'hello' });
        }
      } catch (e) {}
      var total = mine;
      for (var i = 0; i < others.length; i++) total += others[i];
      if (total !== lastTotal) {
        lastTotal = total;
        broadcast(total);
      }
      handleTotal(total);
    } else {
      sendUp(mine);
    }
  }

  // ── ④ 总数恰好 1 才动手 ──
  function handleTotal(total) {
    if (done || total !== 1) return;
    var vs = visibleVideos();
    if (vs.length !== 1) return;                // 这个 frame 里得有且只有那一个
    var v = vs[0];
    if (!v.paused) { done = true; return; }     // 页面自己已经播起来了 → 不插手
    tryPlay(v);

    // ★★ v1.0.235：催不动就**帮你点一下播放按钮**。
    //   为什么必须补这一步：有一类播放器（很常见）是"**点按钮才开始加载视频**"——
    //   在它加载之前调 play()，Promise 会**一直挂着**（不报错也不播），
    //   所以光靠 play() 这类站永远起不来。用户实测反馈的就是这种：
    //   "页面自带播放按钮的视频，还是得我手动点一下"。
    //   ★ 时机：先给 play() 一点时间（1.2 秒），没起来再点；再等 2 秒还没有就最后点一次收手。
    setTimeout(function () {
      if (done) return;
      if (!v.paused) { done = true; return; }
      tapPlay(v);
    }, 1200);
    setTimeout(function () {
      if (done) return;
      if (!v.paused) { done = true; return; }
      tapPlay(v);
      done = true;      // ★ 收手：绝不再多点（反复点最容易点到广告）
    }, 3600);
  }

  // ── ⑥ "帮你点一下播放按钮" ──
  //   两条路：① 先找**看起来就是播放按钮**的元素（常见类名 / 中文标题）；
  //          ② 找不到就点视频中心最上层的那个元素（播放遮罩通常就盖在中心）。
  //   ★ 安全线：链接 / iframe / 往上三层里有 <a> 的，一律**不点**（那可能是广告）。
  //   ★ 全程最多 2 次（`tapped`）——点到广告比不播更糟。

  var tapped = 0;
  var PLAY_SEL = [
    '.vjs-big-play-button', '.dplay-icon', '.dplayer-play-icon', '.xgplayer-play',
    '.prism-play-btn', '.player-play', '.play-btn', '.play-button', '.big-play',
    '[class*="bigplay"]', '[class*="play-btn"]', '[class*="playbutton"]',
    '[aria-label*="播放"]', '[title*="播放"]'
  ];

  function tapPlay(v) {
    if (tapped >= 2) return;
    tapped++;
    try {
      var r = v.getBoundingClientRect();
      var cx = r.left + r.width / 2, cy = r.top + r.height / 2;
      var btn = findPlayButton(v, r);
      if (btn) { tap(btn, cx, cy); return; }
      var el = null;
      try { el = document.elementFromPoint(cx, cy); } catch (e2) {}
      if (!el || !safeToTap(el, v)) return;
      tap(el, cx, cy);
    } catch (e) {}
  }

  function findPlayButton(v, r) {
    for (var i = 0; i < PLAY_SEL.length; i++) {
      var list = null;
      try { list = document.querySelectorAll(PLAY_SEL[i]); } catch (e) { continue; }
      for (var j = 0; j < list.length; j++) {
        var e = list[j], b = null;
        try { b = e.getBoundingClientRect(); } catch (e2) { continue; }
        if (!b || b.width < 8 || b.height < 8) continue;
        // 必须在**这个视频的框里** —— 页面别处的按钮不算
        if (b.left >= r.left - 4 && b.right <= r.right + 4 &&
            b.top >= r.top - 4 && b.bottom <= r.bottom + 4) return e;
      }
    }
    return null;
  }

  function safeToTap(el, v) {
    try {
      if (el === v) return true;                 // 就是视频本身 → 安全
      var t = String(el.tagName || '').toLowerCase();
      if (t === 'a' || t === 'iframe') return false;
      var p = el.parentElement, k = 0;
      for (; p && k < 3; k++, p = p.parentElement) {
        if (String(p.tagName || '').toLowerCase() === 'a') return false;
      }
      return true;
    } catch (e) { return false; }
  }

  /// 派发一整套"手指点上去"的事件。
  /// ★ 光调 `el.click()` 不够 —— 很多播放器监听的是 pointer / touch 系列。
  function tap(el, x, y) {
    var base = { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y };
    var kinds = ['pointerdown', 'touchstart', 'pointerup', 'touchend', 'mouseup', 'click'];
    for (var i = 0; i < kinds.length; i++) {
      var ev = null;
      try {
        if (kinds[i].indexOf('touch') === 0) {
          ev = new TouchEvent(kinds[i], { bubbles: true, cancelable: true });
        } else if (kinds[i].indexOf('pointer') === 0) {
          ev = new PointerEvent(kinds[i], base);
        } else {
          ev = new MouseEvent(kinds[i], base);
        }
      } catch (e) { ev = null; }
      if (ev) { try { el.dispatchEvent(ev); } catch (e2) {} }
    }
    try { el.click(); } catch (e3) {}
  }

  // ── ⑤ 催播：先直接来；被拒就先静音播（iOS 上静音自动播是放行的） ──
  function tryPlay(v) {
    if (done || attempt >= MAX_TRY) return;
    var wait = DELAYS[Math.min(attempt, DELAYS.length - 1)];
    attempt++;
    if (wait > 0) { setTimeout(function () { fire(v); }, wait); return; }
    fire(v);
  }

  function fire(v) {
    if (done) return;
    var p = null;
    try { p = v.play(); } catch (e) { p = null; }
    if (p && p.then) {
      p.then(function () { ok(v); }).catch(function () { quietTry(v); });
    } else {
      quietTry(v);
    }
  }

  function quietTry(v) {
    // 被拒了 → 静音再试一次（这一条在 iOS 上几乎总能过）
    try {
      if (!v.muted) { v.muted = true; mutedByUs = true; }
      var q = v.play();
      if (q && q.then) {
        q.then(function () { ok(v); }).catch(function () { retry(v); });
      } else {
        retry(v);
      }
    } catch (e) { retry(v); }
  }

  function retry(v) {
    if (done || attempt >= MAX_TRY) return;
    tryPlay(v);
  }

  function ok(v) {
    done = true;
    armUnmute(v);
  }

  /// 静音播起来之后：**你第一次碰屏幕时把声音打开**。
  /// ★ 必须在手势回调里**同步**执行 —— 放进 setTimeout / Promise 里，用户手势就失效了。
  /// ★ 视频在 iframe 里时，这一下要**点在那个 iframe 的画面里**才算数（iOS 的手势
  ///   是每个网页自己算的，主页面上的点击传不进去）。
  function armUnmute(v) {
    if (!mutedByUs) return;
    var evs = ['pointerdown', 'touchstart', 'click', 'keydown'];
    function once() {
      for (var i = 0; i < evs.length; i++) document.removeEventListener(evs[i], once, true);
      try {
        v.muted = false;
        if (v.paused) { var r = v.play(); if (r && r.catch) r.catch(function () {}); }
      } catch (e) {}
    }
    for (var i = 0; i < evs.length; i++) document.addEventListener(evs[i], once, true);
  }

  // ── ⑥ 起跑：DOM 还没好的时候扫不到东西，前 12 秒补扫几次 ──
  function boot() {
    for (var i = 0; i < SCAN_TIMES.length; i++) {
      (function (t) { setTimeout(scan, t); })(SCAN_TIMES[i]);
    }
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }

  window.__vgAutoPlayLoaded = 1;
})();
