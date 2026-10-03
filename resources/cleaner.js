// VideoGrab 网页广告清理脚本
// ---------------------------------------------------------------------------
// WKUserScript 在 document-start 注入，page world，**只在主 frame 干活**。
//
// ★★★ v1.0.211 的统一模型（用户明确要求：几种模式的规则之间不能相互冲突）
//
//   三个"清"的触发源 —— **各自独立，绝不共享"该清的触发理由"**：
//     · 自动：自己打分 ≥ 8，定时器/MutationObserver 触发
//     · A 强力：用户按按钮，**同一套打分把门槛降到 6** + 额外要求"盖住 ≥50% 视口"
//     · B 点选：用户点击命中哪个就清哪个
//
//   三者**只共享**这三样（共享才不会打架）：
//     · 硬排除 `safeToTouch()` · 隐藏/还原 `applyHide()/unhideOne()` · 候选收集 `candidates()`
//
//   优先级（从高到低，命中即停）：
//     ① 硬排除（含 video/audio/canvas、form、main/article、播放器祖先链）
//        → 自动/强力：不清；**点选：不参与高亮**（点不到）→ 天然不冲突
//     ② 本会话"坏元素" `el.__vgBad`（回滚过）
//        → 自动/强力：跳过；**点选：也不高亮**（重载页面可清空这个标记，能再试）
//     ③ 站点「不清理名单」→ 只约束**自动**；用户主动按 A/B 时**一次性放行**（不改名单）
//     ④ 本页 SUSPEND（点过「撤销」）→ 只约束**自动**；手动仍可用
//     ⑤ 门槛：自动 8 分 / 强力 6 分+大面积 / 点选 点击命中
//     ⑥ 清完复核：自动 → 异常就还原 + **自动把该站加进"不清理名单"**；
//                 手动（A/B）→ 异常只还原（**不加名单、不 SUSPEND**），弹条告知
//
//   ★ 为什么"手动的记录"不进自动/强力的判定链：那样手动状态会污染自动 ——
//     用户点错 → 灰屏 → 撤销 → 标记还在 → 自动又清 → **反复灰屏**，安全网失效。
//     所以手动只影响"点选模式下点得到什么"，不影响自动清什么。
//
//   做不到（如实说明）：画在 canvas 里的广告、closed Shadow DOM、子 frame 里的浮层
//   （只主 frame 干活）、站点"反反拦截"。
// ---------------------------------------------------------------------------
(function () {
  'use strict';

  if (window.__vgCleanerInstalled) return;
  window.__vgCleanerInstalled = true;

  // ★ 只在主 frame 干活（比较引用，跨域安全）。子 frame 也上报会造成重复提示/串 host。
  if (window.top !== window.self) return;

  // ★ 注入时由原生替换这两行（同 sniffer.js 的 autoOn 手法）
  var MODE = 'on';
  var SKIP_HOSTS = [];

  var ATTR = 'data-vg-blk';       // 已隐藏标记
  var PICK_ATTR = 'data-vg-pick'; // 点选高亮标记
  var MAX_HIDE = 40;
  var THRESHOLD = 8;              // 自动门槛
  var STRONG_THRESHOLD = 6;       // 强力门槛（同一套打分，只是更低）
  var MAX_PICK = 80;              // 点选最多高亮几个

  var hiddenCount = 0;
  var rolledBack = 0;
  var recent = [];

  var started = false, timer = null, moTimer = null, observer = null, lastSweep = 0;
  var readyAt = 0;
  var SUSPEND = false;            // 本页豁免（自动不再动手）
  var PICK = false;               // 点选模式
  var pickList = [];
  var pickStart = null, lastPickAt = 0;

  function vw() { return window.innerWidth || document.documentElement.clientWidth || 0; }
  function vh() { return window.innerHeight || document.documentElement.clientHeight || 0; }
  function area(r) { return Math.max(0, r.width) * Math.max(0, r.height); }
  function clsOf(el) { var c = el.className; return (typeof c === 'string') ? c : ''; }
  function hostNow() { return location.host || ''; }
  function skipped() { return SKIP_HOSTS.indexOf(hostNow()) >= 0; }

  function desc(el) {
    var t = (el.tagName || '').toLowerCase();
    var id = el.id ? ('#' + el.id) : '';
    var c = clsOf(el).trim().split(/\s+/).slice(0, 3).join('.');
    return t + id + (c ? ('.' + c) : '');
  }

  // ── ① 硬排除：命中任一 → 绝不碰（三个触发源共用同一份）─────────────────────
  function safeToTouch(el) {
    var tag = (el.tagName || '').toLowerCase();
    if (tag === 'html' || tag === 'body' || tag === 'head') return false;
    var id = el.id || '';
    if (id.indexOf('vg-') === 0) return false;
    if (clsOf(el).indexOf('vg-') >= 0) return false;
    if (el.querySelector && el.querySelector('video,audio,canvas')) return false;   // 保播放器
    if (el.querySelector && el.querySelector('form')) return false;                 // 保登录
    if (el.querySelectorAll && el.querySelectorAll('input,select,textarea').length > 2) return false;
    if (el.querySelectorAll) {                                                     // 保正经面板
      if (el.querySelectorAll('a').length >= 6) return false;
      if (el.querySelectorAll('button').length >= 5) return false;
    }
    if (el.querySelector && el.querySelector('main,article,[role="main"]')) return false;  // 保正文
    var v = document.querySelector('video');
    if (v && (el === v || el.contains(v))) return false;
    return true;
  }

  // 自动 / 强力 用的"已排除"判断（②③ 之外的部分）
  function excluded(el) {
    if (el.nodeType !== 1) return true;
    if (el.hasAttribute(ATTR)) return true;      // 已隐藏
    if (el.__vgBad) return true;                 // 本会话坏元素 → 跳过
    return !safeToTouch(el);
  }

  // 点选模式能不能点它（**同样的硬排除 + 坏元素不可点**）
  function pickable(el) {
    if (el.nodeType !== 1) return false;
    if (el.hasAttribute(ATTR)) return false;     // 已经藏起来了
    if (el.__vgBad) return false;                // 曾导致异常 → 不高亮（重载页面可再试）
    return safeToTouch(el);
  }

  function floating(cs) { return cs.position === 'fixed' || cs.position === 'sticky'; }
  function bigEnough(r) { return r.width >= vw() * 0.6 && r.height >= vh() * 0.3; }

  var SHADE_WORDS = ['loading', 'mask', 'skeleton', 'preloader', 'spinner',
                     'waiting', 'placeholder', 'shade', 'cover-bg'];
  function shadePenalty(el) {
    var s = ((el.id || '') + ' ' + clsOf(el)).toLowerCase();
    for (var i = 0; i < SHADE_WORDS.length; i++) {
      if (s.indexOf(SHADE_WORDS[i]) >= 0) return -3;
    }
    return 0;
  }

  // ── 打分（自动与强力**共用这一套**，只是门槛不同）──────────────────────────
  function score(el, cs, r) {
    var W = vw(), H = vh(), vArea = W * H;
    if (vArea <= 0) return 0;
    if (!floating(cs)) return 0;
    var s = 3;
    if (area(r) >= vArea * 0.55) s += 3;
    var zi = parseInt(cs.zIndex, 10);
    if (!isNaN(zi) && zi >= 1000) s += 2;
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

  // ── ⑥ 隐藏 + 复核 ─────────────────────────────────────────────────────────
  // manual = true（A 强力 / B 点选）：异常时**只还原**，不加站点名单、不 SUSPEND 整页。
  // manual = false（自动）：异常时还原 + 上报，由原生把该站加进"不清理名单"。
  function hide(el, why, manual) {
    if (el.hasAttribute(ATTR) || el.__vgBad) return false;
    var beforeSH = sh();
    var c0 = centerEl();
    var centered = !!(c0 && (c0 === el || el.contains(c0)));
    try { applyHide(el); } catch (e) { return false; }

    hiddenCount++;
    if (recent.length > 20) recent.shift();
    recent.push({ sel: desc(el), why: why, t: Date.now() });

    setTimeout(function () {
      try {
        if (!el.hasAttribute(ATTR)) return;
        var c1 = centerEl();
        var blank = (c1 === null || c1 === document.body || c1 === document.documentElement);
        var shrunk = (beforeSH > 400 && sh() < beforeSH * 0.6);
        if ((centered && blank) || shrunk) {
          unhideOne(el);
          el.__vgBad = true;                       // 本会话不再碰它
          rolledBack++;
          hiddenCount = Math.max(0, hiddenCount - 1);
          report(manual ? 'softrollback' : 'rollback');
        }
      } catch (e) {}
    }, 260);
    return true;
  }

  function restoreAll() {
    var els;
    try { els = document.querySelectorAll('[' + ATTR + ']'); } catch (e) { return; }
    for (var i = 0; i < els.length; i++) { unhideOne(els[i]); }
    hiddenCount = 0;
    recent = [];
  }

  // ── 候选收集（三个触发源共用）──────────────────────────────────────────────
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

  function gateOpen() {
    if (document.readyState === 'complete') return true;
    return readyAt > 0 && (Date.now() - readyAt) > 5000;
  }

  // ── 扫描：strong = 用户按了"再清一遍"；force = 跳过 800ms 限流 ──────────────
  function sweep(strong, force) {
    if (MODE === 'off' || PICK) return 0;              // 点选模式下自动一律停手
    if (SUSPEND || skipped()) return 0;
    if (document.visibilityState && document.visibilityState !== 'visible') return 0;
    if (!vw() || !vh()) return 0;
    if (!gateOpen()) return 0;
    var now = Date.now();
    if (!force && now - lastSweep < 800) return 0;
    lastSweep = now;

    var thr = strong ? STRONG_THRESHOLD : THRESHOLD;
    var vArea = vw() * vh();
    var list = candidates(), n = 0;
    for (var i = 0; i < list.length; i++) {
      if (hiddenCount >= MAX_HIDE) break;
      var el = list[i];
      if (excluded(el)) continue;
      var r;
      try { r = el.getBoundingClientRect(); } catch (e) { continue; }
      if (!bigEnough(r)) continue;
      if (strong && area(r) < vArea * 0.5) continue;   // 强力额外要求"盖住 ≥50% 视口"
      var cs;
      try { cs = getComputedStyle(el); } catch (e) { continue; }
      if (cs.display === 'none' || cs.visibility === 'hidden') continue;
      if (parseFloat(cs.opacity) < 0.05) continue;
      if (score(el, cs, r) < thr) continue;
      if (hide(el, strong ? 'strong' : 'score', !!strong)) n++;
    }
    if (n) report(strong ? 'strong' : 'hid');
    return n;
  }

  // ── B 点选：高亮 + 几何命中 ───────────────────────────────────────────────
  function pickCandidates() {
    var list = candidates(), out = [];
    var vArea = vw() * vh();
    for (var i = 0; i < list.length; i++) {
      var el = list[i];
      if (!pickable(el)) continue;
      var cs, r;
      try { cs = getComputedStyle(el); r = el.getBoundingClientRect(); } catch (e) { continue; }
      if (!floating(cs)) continue;
      if (r.bottom < 0 || r.top > vh()) continue;          // 只取视口内的
      var a = area(r);
      if (a < vArea * 0.06) continue;                      // 太小的不算（导航条、按钮）
      if (a > vArea * 1.5) continue;                       // 离谱的大（多半是 body 级容器）
      out.push({ el: el, a: a });
    }
    out.sort(function (x, y) { return y.a - x.a; });
    var res = [];
    for (var j = 0; j < out.length && j < MAX_PICK; j++) res.push(out[j].el);
    return res;
  }

  function paintOutlines() {
    for (var i = 0; i < pickList.length; i++) {
      var el = pickList[i];
      try {
        el.setAttribute(PICK_ATTR, '1');
        el.style.setProperty('outline', '2px solid #ff3b30', 'important');
        el.style.setProperty('outline-offset', '-2px', 'important');
      } catch (e) {}
    }
  }

  function clearOutlines() {
    for (var i = 0; i < pickList.length; i++) {
      var el = pickList[i];
      try {
        el.removeAttribute(PICK_ATTR);
        el.style.removeProperty('outline');
        el.style.removeProperty('outline-offset');
      } catch (e) {}
    }
    pickList = [];
  }

  function repaintPick() {
    clearOutlines();
    pickList = pickCandidates();
    paintOutlines();
  }

  // 几何命中（不靠 elementFromPoint —— 它对 pointer-events:none 的遮罩不靠谱）。
  // 命中多个时**取面积最大的那个**（= 最外层的浮层根，清了整层就干净）。
  function hitTest(x, y) {
    var best = null, bestA = 0;
    for (var i = 0; i < pickList.length; i++) {
      var el = pickList[i];
      if (!el.isConnected) continue;
      var r;
      try { r = el.getBoundingClientRect(); } catch (e) { continue; }
      if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) {
        var a = area(r);
        if (a > bestA) { bestA = a; best = el; }
      }
    }
    return best;
  }

  function pickAct(x, y) {
    lastPickAt = Date.now();
    var el = hitTest(x, y);
    if (!el) return;
    hide(el, 'pick', true);          // 手动：异常只还原，不加站点名单
    repaintPick();
    report('pick');
  }

  // ── 统一的点击入口：**点选优先**，其次点击防护 ─────────────────────────────
  // ★ 顺序很要紧：不先判点选的话，点选的点击会被点击防护先 preventDefault 掉，选不中。
  function onDocClick(e) {
    if (MODE === 'off') return;
    if (PICK) {
      // touchend 已经处理过 → 400ms 内去重
      if (Date.now() - lastPickAt < 400) { swallow(e); return; }
      var x = (e.clientX || 0), y = (e.clientY || 0);
      swallow(e);                    // 点选模式下把所有点击都吞掉（免得误跳转）
      pickAct(x, y);
      return;
    }
    if (SUSPEND || skipped()) return;
    // ── 点击防护：治"点广告的 X 反而跳走" ──
    var t = e.target;
    if (!t || !t.closest) return;
    if (t.closest('[' + ATTR + ']')) { swallow(e); return; }
    var el = t, hops = 0;
    while (el && el !== document.body && hops < 6) {
      if (el.__vgBad) return;
      var r, cs;
      try { r = el.getBoundingClientRect(); cs = getComputedStyle(el); } catch (err) { break; }
      if (floating(cs) && bigEnough(r) && safeToTouch(el)) {
        swallow(e);
        if (hide(el, 'click', false)) report('hid');
        return;
      }
      el = el.parentElement; hops++;
    }
  }

  // 点选模式：iOS 上跳转常常发生在 touchend（不只是 click）
  function onTouchStart(e) {
    if (!PICK) return;
    var t = e.changedTouches && e.changedTouches[0];
    if (t) pickStart = { x: t.clientX, y: t.clientY };
  }
  function onTouchEnd(e) {
    if (!PICK || MODE === 'off') return;
    var t = e.changedTouches && e.changedTouches[0];
    if (!t) return;
    var st = pickStart;
    pickStart = null;
    // 位移 > 10px 当作滚动，放行（不影响滚动）
    if (st && (Math.abs(t.clientX - st.x) > 10 || Math.abs(t.clientY - st.y) > 10)) return;
    swallow(e);
    pickAct(t.clientX, t.clientY);
  }

  function swallow(e) {
    try {
      e.preventDefault();
      e.stopPropagation();
      if (e.stopImmediatePropagation) e.stopImmediatePropagation();
    } catch (err) {}
  }

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
    try {
      document.addEventListener('click', onDocClick, true);
      document.addEventListener('touchstart', onTouchStart, true);
      document.addEventListener('touchend', onTouchEnd, true);
    } catch (e) {}
    try {
      observer = new MutationObserver(function () {
        if (moTimer || PICK) return;
        moTimer = setTimeout(function () { moTimer = null; sweep(false, false); }, 500);
      });
      observer.observe(document.documentElement || document, { childList: true, subtree: true });
    } catch (e) {}
    timer = setInterval(function () { sweep(false, false); }, 3000);
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', function () {
        if (!readyAt) readyAt = Date.now();
        sweep(false, false);
      });
    } else {
      if (!readyAt) readyAt = Date.now();
      setTimeout(function () { sweep(false, false); }, 0);
    }
  }

  function stop() {
    if (timer) { clearInterval(timer); timer = null; }
    if (moTimer) { clearTimeout(moTimer); moTimer = null; }
    if (observer) { try { observer.disconnect(); } catch (e) {} observer = null; }
    try {
      document.removeEventListener('click', onDocClick, true);
      document.removeEventListener('touchstart', onTouchStart, true);
      document.removeEventListener('touchend', onTouchEnd, true);
    } catch (e) {}
    started = false;
  }

  // ── 暴露给原生 ────────────────────────────────────────────────────────────
  window.__vgCleanSet = function (mode) {
    MODE = (mode === 'off') ? 'off' : 'on';
    if (MODE === 'off') { stop(); clearOutlines(); PICK = false; restoreAll(); }
    else { SUSPEND = false; start(); sweep(false, true); }
    return MODE;
  };
  window.__vgCleanNow = function () { return sweep(false, true); };

  /// ★ A 强力：用户按了「再清一遍」。同一套打分，门槛降到 6 + 要求盖住 ≥50% 视口。
  ///   **只本次生效**（不持久）—— 持久会跟"不清理名单"打架（站在名单里自动本来就不跑）。
  window.__vgCleanStrong = function () { return sweep(true, true); };

  /// ★ B 点选：进去之后点哪个清哪个
  window.__vgPickMode = function (on) {
    PICK = !!on;
    if (PICK) {
      repaintPick();
      report('pickstart');
    } else {
      clearOutlines();
      sweep(false, true);
    }
    return PICK;
  };
  window.__vgPickCount = function () { return pickList.length; };

  window.__vgCleanRestore = function () {
    SUSPEND = true;
    restoreAll();
    return 'restored';
  };

  window.__vgCleanSetSkip = function (list) {
    SKIP_HOSTS = (list && list.length) ? list : [];
    if (skipped()) { stop(); restoreAll(); }
    else if (!started && MODE !== 'off') { start(); sweep(false, true); }
    return SKIP_HOSTS.length;
  };

  window.__vgCleanStats = function () {
    return { mode: MODE, suspended: SUSPEND, pick: PICK, pickCount: pickList.length,
             hidden: hiddenCount, rolled: rolledBack, skip: SKIP_HOSTS.length,
             recent: recent.slice(-10) };
  };

  if (document.readyState !== 'loading') readyAt = Date.now();
  if (MODE !== 'off' && !skipped()) start();
})();
