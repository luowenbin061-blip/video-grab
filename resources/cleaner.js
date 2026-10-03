// VideoGrab 网页广告清理脚本
// ---------------------------------------------------------------------------
// 由 WKUserScript 在 document-start 注入到【每一个 frame】（forMainFrameOnly=false），
// page world。与 sniffer.js **并列但各管各的**：
//   · sniffer.js 管「找视频地址」，它的定时器只在「后台自动嗅探」开着时才跑；
//   · 本脚本管「把盖住内容的浮层广告清掉」，**默认常开**。
//     两者**不能合并** —— 否则关掉自动嗅探会把广告清理也一起关掉。
//
// 治的是什么（已按用户 6 张真机截图核实）：
//   小聚合站/资源站在页面上**自己画的一层浮层**（全屏插屏图、赌博浮层、居中模态）。
//   它们**没有独立的网络请求** → 域名黑名单/规则库在原理上拦不到，只能运行时清。
//
// 设计取舍（经 DeepSeek 复核后修正，两个关键点）：
//   1. **只隐藏、不移除**：remove() 会被站点自己的 MutationObserver 发现并重新插回来；
//      这里改成 display/visibility/pointer-events 三件套 + !important 同时设，
//      站点要检测的成本更高。（但**关掉开关时会还原**，见 restoreAll）
//   2. 判据**不用单一条件**（"fixed + 面积大"会大量误杀播放器/选集抽屉），
//      改成**多信号累计打分**，且先过一道**硬性排除**（含 video/audio/canvas、含 form、
//      含大量链接/按钮的"正经面板"）。
//
// 本脚本**做不到**的事（如实说明，别指望它）：
//   · 画在 <canvas> 里的广告 → 无解（拿不到像素里的语义）
//   · closed 模式的 Shadow DOM → 页面世界里够不到
//   · 跨域 iframe 里的浮层 → 只能清它自己那一层，清不到父页面
//   · 「反反拦截」（站点检测到被隐藏就黑屏）→ 只能靠用户关掉总开关
// ---------------------------------------------------------------------------
(function () {
  'use strict';

  if (window.__vgCleanerInstalled) return;
  window.__vgCleanerInstalled = true;

  // ★ 注入时由原生替换这一行（同 sniffer.js 的 autoOn 手法）：'on' / 'off'
  var MODE = 'on';

  var ATTR = 'data-vg-blk';       // 打过这个标记 = 已被我们处理过
  var MAX_HIDE = 40;              // 单页最多隐藏几个（防某条判据失灵时雪崩）
  var hiddenCount = 0;
  var recent = [];                // 最近隐藏记录（纯数据，只给诊断回传）

  var started = false, timer = null, moTimer = null, observer = null, lastSweep = 0;

  function vw() { return window.innerWidth || document.documentElement.clientWidth || 0; }
  function vh() { return window.innerHeight || document.documentElement.clientHeight || 0; }
  function area(r) { return Math.max(0, r.width) * Math.max(0, r.height); }
  function clsOf(el) { var c = el.className; return (typeof c === 'string') ? c : ''; }

  // 给诊断用的短描述（**不含 DOM 引用**，必须能 JSON 序列化）
  function desc(el) {
    var t = (el.tagName || '').toLowerCase();
    var id = el.id ? ('#' + el.id) : '';
    var c = clsOf(el).trim().split(/\s+/).slice(0, 3).join('.');
    return t + id + (c ? ('.' + c) : '');
  }

  // ── 硬性排除：命中任一 → 绝不碰 ────────────────────────────────────────────
  // （"已处理过"的判断不在这里，见 excluded()）
  function safeToTouch(el) {
    var tag = (el.tagName || '').toLowerCase();
    if (tag === 'html' || tag === 'body' || tag === 'head') return false;
    var id = el.id || '';
    if (id.indexOf('vg-') === 0) return false;               // 我们自己的浮层
    if (clsOf(el).indexOf('vg-') >= 0) return false;

    // ★ 1) 保播放器：含媒体/画布的一律不动（误杀代价最高的一类）
    if (el.querySelector && el.querySelector('video,audio,canvas')) return false;
    // ★ 2) 保登录/表单：含 form 或超过 2 个输入控件（登录框、搜索面板）
    if (el.querySelector && el.querySelector('form')) return false;
    if (el.querySelectorAll && el.querySelectorAll('input,select,textarea').length > 2) return false;
    // ★ 3) 保"正经面板"：链接/按钮很多的（选集抽屉、菜单、导航）不是广告浮层
    if (el.querySelectorAll) {
      if (el.querySelectorAll('a').length >= 6) return false;
      if (el.querySelectorAll('button').length >= 5) return false;
    }
    // ★ 4) 正在播放的那个 video 的祖先链 → 不动（再保一层）
    var v = document.querySelector('video');
    if (v && (el === v || el.contains(v))) return false;
    return true;
  }

  function excluded(el) {
    if (el.nodeType !== 1) return true;
    if (el.hasAttribute && el.hasAttribute(ATTR)) return true;   // 已处理过
    return !safeToTouch(el);
  }

  // 是不是"浮"在内容上的定位
  function floating(cs) { return cs.position === 'fixed' || cs.position === 'sticky'; }

  // 尺寸是否够大（粗筛，调用前可先做更便宜的判断）
  function bigEnough(r) { return r.width >= vw() * 0.6 && r.height >= vh() * 0.3; }

  // ── 打分：只有累计够高才认作广告浮层 ──────────────────────────────────────
  function score(el, cs, r) {
    var W = vw(), H = vh(), vArea = W * H;
    if (vArea <= 0) return 0;
    if (!floating(cs)) return 0;
    var s = 3;
    if (area(r) >= vArea * 0.55) s += 3;                      // 盖住大半屏
    var zi = parseInt(cs.zIndex, 10);
    if (!isNaN(zi) && zi >= 1000) s += 2;                     // 广告层通常 z-index 极高
    // 含一张"大图"（插屏广告基本都是图）
    if (el.querySelectorAll) {
      var imgs = el.querySelectorAll('img');
      for (var i = 0; i < imgs.length && i < 12; i++) {
        if (area(imgs[i].getBoundingClientRect()) >= vArea * 0.12) { s += 2; break; }
      }
    }
    if (el.querySelector && el.querySelector('a[href]')) s += 1;
    return s;
  }

  var THRESHOLD = 8;     // 满分 11；8 分 = 至少"盖大半屏 + （高 z-index 或 大图）"

  function hide(el, why) {
    try {
      el.style.setProperty('display', 'none', 'important');
      el.style.setProperty('visibility', 'hidden', 'important');
      el.style.setProperty('pointer-events', 'none', 'important');
      el.setAttribute(ATTR, '1');
      el.setAttribute('aria-hidden', 'true');
    } catch (e) { return false; }
    hiddenCount++;
    if (recent.length > 20) recent.shift();
    recent.push({ sel: desc(el), why: why, t: Date.now() });
    return true;
  }

  // 关掉开关 / 需要还原时：把隐藏过的**原样恢复**
  // （比 remove() 好在：站点从没察觉元素消失过，恢复也不留痕）
  function restoreAll() {
    var els;
    try { els = document.querySelectorAll('[' + ATTR + ']'); } catch (e) { return; }
    for (var i = 0; i < els.length; i++) {
      try {
        els[i].style.removeProperty('display');
        els[i].style.removeProperty('visibility');
        els[i].style.removeProperty('pointer-events');
        els[i].removeAttribute(ATTR);
        els[i].removeAttribute('aria-hidden');
      } catch (e) {}
    }
    hiddenCount = 0;
    recent = [];
  }

  // ── 候选收集：只走到第 4 层（浮层基本都在这个范围），避免遍历整页 ──────────
  function candidates() {
    var out = [];
    var body = document.body;
    if (!body) return out;
    var q = [{ el: body, d: 0 }];
    while (q.length && out.length < 400) {
      var it = q.shift();
      if (it.d > 3) continue;
      var kids = it.el.children;
      if (!kids) continue;
      for (var k = 0; k < kids.length; k++) {
        var e = kids[k];
        out.push(e);
        if (e.children && e.children.length) q.push({ el: e, d: it.d + 1 });
      }
    }
    return out;
  }

  function sweep() {
    if (MODE === 'off') return 0;
    if (document.visibilityState && document.visibilityState !== 'visible') return 0;
    if (!vw() || !vh()) return 0;
    // ★ 最小间隔：整轮扫要调几百次 getBoundingClientRect（会触发布局），
    //   页面上 DOM 抖得厉害时（MutationObserver 反复触发）必须限流，
    //   否则低端机上会明显发涩。800ms 足够快，又不至于互相叠加。
    var now = Date.now();
    if (now - lastSweep < 800) return 0;
    lastSweep = now;
    var list = candidates(), n = 0;
    for (var i = 0; i < list.length; i++) {
      if (hiddenCount >= MAX_HIDE) break;
      var el = list[i];
      if (excluded(el)) continue;
      var r;
      try { r = el.getBoundingClientRect(); } catch (e) { continue; }
      if (!bigEnough(r)) continue;                             // 便宜的先判：不够大就跳
      var cs;
      try { cs = getComputedStyle(el); } catch (e) { continue; }
      if (cs.display === 'none' || cs.visibility === 'hidden') continue;
      if (parseFloat(cs.opacity) < 0.05) continue;
      if (score(el, cs, r) < THRESHOLD) continue;
      if (hide(el, 'score')) n++;
    }
    if (n) report();
    return n;
  }

  // ── 点击防护（**独立于上面的清理**，不依赖"已标记"）────────────────────────
  // 治的是：「广告上的 X 点一下就跳走」。做法：click 进入 capture 阶段时，
  // **现场判断**这一点是否落在一个广告浮层里 —— 是就把这次点击整个掐掉
  // （掐掉后站点的 click 处理不会跑 → 它那条跳转也就不会执行）。
  // ★ 只掐"落在浮层里的点击"，**不碰普通链接**（那种是正常导航）。
  function onDocClick(e) {
    if (MODE === 'off') return;
    var t = e.target;
    if (!t || !t.closest) return;
    if (t.closest('[' + ATTR + ']')) { swallow(e); return; }   // 已隐藏的（理论上点不到）
    var el = t, hops = 0;
    while (el && el !== document.body && hops < 6) {
      var r, cs;
      try { r = el.getBoundingClientRect(); cs = getComputedStyle(el); } catch (err) { break; }
      if (floating(cs) && bigEnough(r) && safeToTouch(el)) {
        swallow(e);
        if (hide(el, 'click')) report();     // 顺手清掉，下次不用再拦
        return;
      }
      el = el.parentElement; hops++;
    }
  }

  function swallow(e) {
    try {
      e.preventDefault();
      e.stopPropagation();
      if (e.stopImmediatePropagation) e.stopImmediatePropagation();
    } catch (err) {}
  }

  // ── 回传原生（诊断用；原生写到受限日志文件里）──────────────────────────────
  function report() {
    try {
      var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.vgClean;
      if (!h) return;
      h.postMessage({
        host: location.host || '',
        url: String(location.href || '').slice(0, 300),
        n: hiddenCount,
        items: recent.slice(-5)
      });
    } catch (e) {}
  }

  function start() {
    if (started) return;
    started = true;
    try { document.addEventListener('click', onDocClick, true); } catch (e) {}
    try {
      observer = new MutationObserver(function () {
        if (moTimer) return;
        moTimer = setTimeout(function () { moTimer = null; sweep(); }, 500);
      });
      observer.observe(document.documentElement || document, { childList: true, subtree: true });
    } catch (e) {}
    timer = setInterval(sweep, 3000);
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', function () { sweep(); });
    } else {
      setTimeout(sweep, 0);
    }
  }

  function stop() {
    if (timer) { clearInterval(timer); timer = null; }
    if (moTimer) { clearTimeout(moTimer); moTimer = null; }
    if (observer) { try { observer.disconnect(); } catch (e) {} observer = null; }
    try { document.removeEventListener('click', onDocClick, true); } catch (e) {}
    started = false;
  }

  // ── 暴露给原生 ────────────────────────────────────────────────────────────
  window.__vgCleanSet = function (mode) {
    MODE = (mode === 'off') ? 'off' : 'on';
    if (MODE === 'off') { stop(); restoreAll(); } else { start(); sweep(); }
    return MODE;
  };
  window.__vgCleanNow = function () { return sweep(); };
  window.__vgCleanStats = function () {
    return { mode: MODE, hidden: hiddenCount, recent: recent.slice(-10) };
  };

  if (MODE !== 'off') start();
})();
