// ==UserScript==
// @name         自动播放网页视频
// @match        *://*/*
// @description  整页只有一个可见视频时，帮你把它播起来
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
  var MIN_PX = 48;                              // 小于这个尺寸的不算一个"视频"
  var MIN_RATIO = 0.15;                         // 占视口面积不到 15% 的不算（挡小广告位）
  var SCAN_TIMES = [0, 800, 1800, 3000, 5000, 8000, 12000];

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

  function broadcast(total) {
    if (!isTop) return;
    try {
      var fs = window.frames;
      for (var i = 0; i < fs.length; i++) {
        try { fs[i].postMessage({ __vgAutoPlay: 'total', n: total }, '*'); } catch (e) {}
      }
    } catch (e) {}
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
      if (!d || d.__vgAutoPlay !== 'total') return;
      if (typeof d.n === 'number') handleTotal(d.n);
    }, false);
  }

  // ── ③ 扫描 → 上报 → （主 frame）汇总广播 / （子 frame）等广播 ──
  function scan() {
    // ★ 这里**不按 done 提前返回**：主 frame 的"汇总 + 广播"要一直有效
    //   （子 frame 可能比我们晚才上报）。重复催播由 handleTotal 里的 done 挡。
    var mine = visibleVideos().length;
    if (isTop) {
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
