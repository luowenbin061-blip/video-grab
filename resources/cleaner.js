// VideoGrab 网页广告清理脚本
// ---------------------------------------------------------------------------
// 由 WKUserScript 在 document-start 注入，page world。与 sniffer.js **并列但各管各的**：
//   · sniffer.js 管「找视频地址」，它的定时器只在「后台自动嗅探」开着时才跑；
//   · 本脚本管「把盖住内容的浮层广告清掉」，**默认常开**。
//     两者**不能合并** —— 否则关掉自动嗅探会把广告清理也一起关了。
//
// 治的是什么（按用户 6 张真机截图核实）：
//   小聚合站/资源站在页面上**自己画的一层浮层**（全屏插屏图、赌博浮层、居中模态）。
//   它们**没有独立的网络请求** → 域名黑名单/规则库在原理上拦不到，只能运行时清。
//
// ★★ v1.0.210 这轮修的（真机实测「有误杀 → 整页灰掉」之后的改动）：
//   1. **只在主 frame 干活**。原来注入覆盖 iframe（跟 sniffer 一致），但广告浮层几乎都
//      在主 frame；而子 frame 也上报会**重复弹提示 / 把 host 记错**。（这是 209 的实 bug）
//   2. **自动回滚**（最有价值的一条）：隐藏后 260ms 复核 —— 如果**视口中心点变成了空白**
//      或者**页面高度骤降**，说明刚才藏的是正文/主容器 → **立刻原样还原**，并把该元素
//      记进本页"坏元素"集合（不再碰它）、同时上报让原生把**这个站**加进例外。
//      「隐藏」这个动作本身就可能出错，所以必须能自己发现并纠正。
//   3. **本页豁免（SUSPEND）**：还原之后本页不再动手 —— 否则 3 秒定时器又把它藏回去。
//   4. **等页面稳了再动手**：`readyState === 'complete'`，或者就绪满 5 秒（**必须有这条兜底**：
//      长轮询/常驻 iframe 的站可能永远到不了 complete）。
//   5. 新增排除：含 `main` / `article` / `[role=main]` 的判为**正文**，不动。
//   6. 加载/遮罩类关键词（loading/mask/skeleton/preloader…）改**扣分**（不做绝对排除）。
//
// 设计取舍（沿用 209，经 DeepSeek 复核）：
//   · **只隐藏、不移除**：remove() 会被站点自己的 MutationObserver 发现并重新插回来；
//     这里用 display/visibility/pointer-events 三件套 + !important。
//   · 判据**不用单一条件**（"fixed + 面积大"会大量误杀），用**多信号累计打分**。
//
// 本脚本**做不到**的事（如实说明，别指望它）：
//   · 画在 <canvas> 里的广告 → 无解（拿不到像素里的语义）
//   · closed 模式的 Shadow DOM → 页面世界里够不到
//   · 子 frame 里的浮层 → 现在只在主 frame 干活，管不到（换来的是"不会误报/误记"）
//   · 「反反拦截」（站点检测到被隐藏就黑屏）→ 靠自动回滚 + 关总开关
// ---------------------------------------------------------------------------
(function () {
  'use strict';

  if (window.__vgCleanerInstalled) return;
  window.__vgCleanerInstalled = true;

  // ★★ 只在主 frame 干活（见文件头第 1 条）。比较 window.top/window.self 跨域也安全
  //   —— 只是比较引用，不读对方任何属性。
  if (window.top !== window.self) return;

  // ★ 注入时由原生替换这两行（同 sniffer.js 的 autoOn 手法）
  var MODE = 'on';
  var SKIP_HOSTS = [];

  var ATTR = 'data-vg-blk';       // 打过这个标记 = 已被我们处理过
  var MAX_HIDE = 40;              // 单页最多隐藏几个（防某条判据失灵时雪崩）
  var hiddenCount = 0;
  var rolledBack = 0;
  var recent = [];                // 最近隐藏记录（纯数据，只给诊断回传）

  var started = false, timer = null, moTimer = null, observer = null, lastSweep = 0;
  var readyAt = 0;                // DOM 就绪的时刻（超时兜底用）
  var SUSPEND = false;            // 本页豁免：点了「撤销」/发生过回滚 → 本页不再动手

  function vw() { return window.innerWidth || document.documentElement.clientWidth || 0; }
  function vh() { return window.innerHeight || document.documentElement.clientHeight || 0; }
  function area(r) { return Math.max(0, r.width) * Math.max(0, r.height); }
  function clsOf(el) { var c = el.className; return (typeof c === 'string') ? c : ''; }
  function hostNow() { return location.host || ''; }

  function skipped() { return SKIP_HOSTS.indexOf(hostNow()) >= 0; }

  // 给诊断用的短描述（**不含 DOM 引用**，必须能 JSON 序列化）
  function desc(el) {
    var t = (el.tagName || '').toLowerCase();
    var id = el.id ? ('#' + el.id) : '';
    var c = clsOf(el).trim().split(/\s+/).slice(0, 3).join('.');
    return t + id + (c ? ('.' + c) : '');
  }

  // ── 硬性排除：命中任一 → 绝不碰 ────────────────────────────────────────────
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
    // ★ 4) v1.0.210：含正文语义标签的 → 这是页面正文，不是浮层广告
    if (el.querySelector && el.querySelector('main,article,[role="main"]')) return false;
    // ★ 5) 正在播放的那个 video 的祖先链 → 不动（再保一层）
    var v = document.querySelector('video');
    if (v && (el === v || el.contains(v))) return false;
    return true;
  }

  function excluded(el) {
    if (el.nodeType !== 1) return true;
    if (el.hasAttribute && el.hasAttribute(ATTR)) return true;   // 已处理过
    if (el.__vgBad) return true;                                 // 本页被判为"坏元素"
    return !safeToTouch(el);
  }

  // 是不是"浮"在内容上的定位
  function floating(cs) { return cs.position === 'fixed' || cs.position === 'sticky'; }

  // 尺寸是否够大（粗筛）
  function bigEnough(r) { return r.width >= vw() * 0.6 && r.height >= vh() * 0.3; }

  // 加载/遮罩类关键词 → **扣分**（不做绝对排除：这类词也可能出现在广告上）
  var SHADE_WORDS = ['loading', 'mask', 'skeleton', 'preloader', 'spinner',
                     'waiting', 'placeholder', 'shade', 'cover-bg'];
  function shadePenalty(el) {
    var s = ((el.id || '') + ' ' + clsOf(el)).toLowerCase();
    for (var i = 0; i < SHADE_WORDS.length; i++) {
      if (s.indexOf(SHADE_WORDS[i]) >= 0) return -3;
    }
    return 0;
  }

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
    s += shadePenalty(el);
    return s;
  }

  var THRESHOLD = 8;     // 满分 11（减去遮罩扣分）；8 分 = 至少"盖大半屏 + （高 z-index 或 大图）"

  function applyHide(el) {
    el.style.setProperty('display', 'none', 'important');
    el.style.setProperty('visibility', 'hidden', 'important');
    el.style.setProperty('pointer-events', 'none', 'important');
    el.setAttribute(ATTR, '1');
    el.setAttribute('aria-hidden', 'true');
  }

  function unhideOne(el) {
    try {
      el.style.removeProperty('display');
      el.style.removeProperty('visibility');
      el.style.removeProperty('pointer-events');
      el.removeAttribute(ATTR);
      el.removeAttribute('aria-hidden');
    } catch (e) {}
  }

  function sh() { return document.documentElement ? document.documentElement.scrollHeight : 0; }
  function centerEl() {
    try { return document.elementFromPoint(vw() / 2, vh() / 2); } catch (e) { return null; }
  }

  // ── 隐藏 + **自动回滚复核**（v1.0.210 的核心安全网）───────────────────────
  function hide(el, why) {
    if (el.hasAttribute(ATTR) || el.__vgBad) return false;
    var beforeSH = sh();
    var c0 = centerEl();
    var centered = !!(c0 && (c0 === el || el.contains(c0)));   // 它盖着视口中心吗
    try { applyHide(el); } catch (e) { return false; }

    hiddenCount++;
    if (recent.length > 20) recent.shift();
    recent.push({ sel: desc(el), why: why, t: Date.now() });

    setTimeout(function () {
      try {
        if (!el.hasAttribute(ATTR)) return;                  // 已被还原/被页面移走
        var c1 = centerEl();
        var blank = (c1 === null || c1 === document.body || c1 === document.documentElement);
        var shrunk = (beforeSH > 400 && sh() < beforeSH * 0.6);
        // 藏之前它盖着中心点，藏完中心点成了空白 → 它就是页面本身（或主容器）
        if ((centered && blank) || shrunk) {
          unhideOne(el);
          el.__vgBad = true;                                 // 本页不再碰它
          rolledBack++;
          hiddenCount = Math.max(0, hiddenCount - 1);
          report('rollback');
        }
      } catch (e) {}
    }, 260);
    return true;
  }

  // 还原本页所有被隐藏的层（点「撤销」/ 关开关 都走它）
  function restoreAll() {
    var els;
    try { els = document.querySelectorAll('[' + ATTR + ']'); } catch (e) { return; }
    for (var i = 0; i < els.length; i++) { unhideOne(els[i]); }
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

  // ★ 动手的门槛：页面加载完，或者"就绪满 5 秒"（兜底 —— 有些站永远到不了 complete）
  function gateOpen() {
    if (document.readyState === 'complete') return true;
    return readyAt > 0 && (Date.now() - readyAt) > 5000;
  }

  function sweep() {
    if (MODE === 'off' || SUSPEND || skipped()) return 0;
    if (document.visibilityState && document.visibilityState !== 'visible') return 0;
    if (!vw() || !vh()) return 0;
    if (!gateOpen()) return 0;
    // ★ 最小间隔：整轮扫要调几百次 getBoundingClientRect（会触发布局），
    //   DOM 抖得厉害时（MutationObserver 反复触发）必须限流。
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
    if (n) report('hid');
    return n;
  }

  // ── 点击防护（**独立于上面的清理**，不依赖"已标记"）────────────────────────
  // 治的是：「广告上的 X 点一下就跳走」。click 的 capture 阶段现场判断落点是否在
  // 广告浮层里 → 是就把这次点击整个掐掉（站点的 click 处理不跑，跳转就不会执行）。
  // ★ 只掐"落在浮层里的点击"，**不碰普通链接**（那种是正常导航）。
  function onDocClick(e) {
    if (MODE === 'off' || SUSPEND || skipped()) return;
    var t = e.target;
    if (!t || !t.closest) return;
    if (t.closest('[' + ATTR + ']')) { swallow(e); return; }   // 已隐藏的（理论上点不到）
    var el = t, hops = 0;
    while (el && el !== document.body && hops < 6) {
      if (el.__vgBad) return;                                  // 判定过是正文 → 放行
      var r, cs;
      try { r = el.getBoundingClientRect(); cs = getComputedStyle(el); } catch (err) { break; }
      if (floating(cs) && bigEnough(r) && safeToTouch(el)) {
        swallow(e);
        if (hide(el, 'click')) report('hid');     // 顺手清掉，下次不用再拦
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

  // ── 回传原生（逃生门 + 诊断）──────────────────────────────────────────────
  function report(type) {
    try {
      var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.vgClean;
      if (!h) return;
      h.postMessage({
        type: type,
        host: hostNow(),
        url: String(location.href || '').slice(0, 300),
        n: hiddenCount,
        rolled: rolledBack,
        items: recent.slice(-5)
      });
    } catch (e) {}
  }

  function start() {
    if (started || skipped() || MODE === 'off') return;
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
      document.addEventListener('DOMContentLoaded', function () {
        if (!readyAt) readyAt = Date.now();
        sweep();
      });
    } else {
      if (!readyAt) readyAt = Date.now();
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
    if (MODE === 'off') { stop(); restoreAll(); } else { SUSPEND = false; start(); sweep(); }
    return MODE;
  };
  window.__vgCleanNow = function () { return sweep(); };

  /// ★ 本页豁免：还原本页 + 本页不再动手（否则 3 秒后又藏回去）
  window.__vgCleanRestore = function () {
    SUSPEND = true;
    restoreAll();
    return 'restored';
  };

  /// ★ 例外名单（原生改了名单后调它，不用刷新）
  window.__vgCleanSetSkip = function (list) {
    SKIP_HOSTS = (list && list.length) ? list : [];
    if (skipped()) { stop(); restoreAll(); }
    else if (!started && MODE !== 'off') { start(); sweep(); }
    return SKIP_HOSTS.length;
  };

  window.__vgCleanStats = function () {
    return { mode: MODE, suspended: SUSPEND, hidden: hiddenCount,
             rolled: rolledBack, skip: SKIP_HOSTS.length, recent: recent.slice(-10) };
  };

  if (document.readyState !== 'loading') readyAt = Date.now();
  if (MODE !== 'off' && !skipped()) start();
})();
