// VideoGrab 网页广告清理脚本
// ---------------------------------------------------------------------------
// WKUserScript 在 document-start 注入，page world，**覆盖所有 frame**。
//
// ★★★ v1.0.212 是一次重构。前几版"越改越差"的根因已查实（两个版本脚本逐行 diff，
//     判据与门槛完全一致）—— 不是判据问题，是**安全网在自伤**：
//       自检太松 → 误判"藏错了" → 不只是还原，还把**整个网站永久拉黑**，
//       并在拉黑瞬间 `restoreAll()` 把当页已藏的**全部放回来** → 一个个站永久失去清理能力。
//     所以这一版的核心改动是「**只做可撤销的动作，不做有记忆的惩罚**」。
//
// ── 三层分工（谁负责什么）──────────────────────────────────────────────────
//   ① 全 frame 注入：**每个 frame 都清**（iframe 里的浮层是大头），
//      但**只有主 frame 上报**（子 frame 静默）—— 这样既不漏，也不会重复弹提示/串 host。
//   ② 自动清理：多信号打分，**保守**（阈值 8），只隐藏、可随时撤销。
//   ③ 用户规则（点选保存）：**优先级最高**，按 host 存下来，刷新后**在渲染前就隐藏**。
//
// ── 优先级（从高到低，命中即停）────────────────────────────────────────────
//   1. 硬排除（含 video/audio/canvas、form、main/article、当前播放器祖先链）—— 三层都遵守
//   2. 用户保存的规则 → 清（且**不做自检回滚**：那是你亲手选的）
//   3. 本会话"坏元素"（自检回滚过）→ 自动跳过；点选仍可再选
//   4. 站点「不清理名单」→ **只约束自动**；用户主动操作时一次性放行
//   5. 本页 SUSPEND（点过撤销）→ 只约束自动
//   6. 门槛：自动 8 分 / 强力 4 分 / 点选 点击为准
//
// ── 做不到的（如实说）──────────────────────────────────────────────────────
//   · 画在 canvas 里的广告；closed Shadow DOM；跨域 frame 里"父页面那层"（只能清它自己那层）；
//     站点"反反拦截"（靠"只隐藏 + 一键撤销"兜）
// ---------------------------------------------------------------------------
(function () {
  'use strict';

  if (window.__vgCleanerInstalled) return;
  window.__vgCleanerInstalled = true;

  var IS_TOP = (window.top === window.self);   // 比较引用，跨域安全

  // ★ 注入时由原生替换这几行
  var MODE = 'on';
  var SKIP_HOSTS = [];
  var SAVED = {};
  var RULES_V = 1;

  var ATTR = 'data-vg-blk';        // 已隐藏
  var AD_ATTR = 'data-vg-ad';      // 已认定为广告（点击防护只认它，不再"现场猜"）
  var PICK_TMP = 'data-vg-picksel';// 点选时的临时描边

  var THRESHOLD = 8;               // 自动
  var STRONG_THRESHOLD = 4;        // 强力（同一套打分，只是更低）
  var MAX_HIDE = 60;
  var BATCH = 40;                  // 每次处理多少新增节点
  var ROLLBACK_DROP = 0.4;         // 页面高度掉这么多才算"藏错了"
  var ROLLBACK_MIN_SH = 800;

  var hiddenCount = 0, rolledBack = 0, savedApplied = 0;
  var recent = [];

  var started = false, timer = null, observer = null, lastSweep = 0;
  var readyAt = 0;
  var SUSPEND = false;
  var PICK = false;
  var pickAt = null, pickStart = null, lastPickAt = 0;
  var queue = [], flushing = false;

  function vw() { return window.innerWidth || document.documentElement.clientWidth || 0; }
  function vh() { return window.innerHeight || document.documentElement.clientHeight || 0; }
  function area(r) { return Math.max(0, r.width) * Math.max(0, r.height); }
  function clsOf(el) { var c = el.className; return (typeof c === 'string') ? c : ''; }
  function hostNow() { return location.host || ''; }
  function skipped() { return SKIP_HOSTS.indexOf(hostNow()) >= 0; }
  function floating(cs) { return cs.position === 'fixed' || cs.position === 'sticky'; }
  function sh() { return document.documentElement ? document.documentElement.scrollHeight : 0; }

  function desc(el) {
    var t = (el.tagName || '').toLowerCase();
    var id = el.id ? ('#' + el.id) : '';
    var c = clsOf(el).trim().split(/\s+/).slice(0, 3).join('.');
    return t + id + (c ? ('.' + c) : '');
  }

  // ── 1) 硬排除：三层共用，命中即绝不碰 ──────────────────────────────────────
  function safeToTouch(el) {
    if (!el || el.nodeType !== 1) return false;
    var tag = (el.tagName || '').toLowerCase();
    if (tag === 'html' || tag === 'body' || tag === 'head') return false;
    var id = el.id || '';
    if (id.indexOf('vg-') === 0) return false;
    if (clsOf(el).indexOf('vg-') >= 0) return false;
    // 保播放器：含媒体/画布的一律不动（误杀代价最高）
    if (el.querySelector && el.querySelector('video,audio,canvas')) return false;
    // 保登录/表单
    if (el.querySelector && el.querySelector('form')) return false;
    if (el.querySelectorAll && el.querySelectorAll('input,select,textarea').length > 2) return false;
    // 保"正经面板"：链接/按钮**特别多**才算（原阈值 6/5 太严 —— 广告容器也常常好几个链接，
    // 那正是"漏网"的原因之一。放宽到 10/8，既救回广告容器，也不至于把导航面板当广告）
    if (el.querySelectorAll) {
      if (el.querySelectorAll('a').length >= 10) return false;
      if (el.querySelectorAll('button').length >= 8) return false;
    }
    // 保正文
    if (el.querySelector && el.querySelector('main,article,[role="main"]')) return false;
    // 当前播放的那个 video 的祖先链
    var v = document.querySelector('video');
    if (v && (el === v || el.contains(v))) return false;
    return true;
  }

  // ── 打分（自动与强力共用同一套）─────────────────────────────────────────────
  var SHADE_WORDS = ['loading', 'mask', 'skeleton', 'preloader', 'spinner',
                     'waiting', 'placeholder', 'shade'];
  function shadePenalty(el) {
    var s = ((el.id || '') + ' ' + clsOf(el)).toLowerCase();
    for (var i = 0; i < SHADE_WORDS.length; i++) {
      if (s.indexOf(SHADE_WORDS[i]) >= 0) return -3;
    }
    return 0;
  }
  function score(el, cs, r) {
    if (!floating(cs)) return 0;
    var vArea = vw() * vh();
    if (vArea <= 0) return 0;
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
    return s + shadePenalty(el);
  }
  function bigEnough(r) { return r.width >= vw() * 0.6 && r.height >= vh() * 0.3; }

  // ── 2) 隐藏 / 标记 / 还原（全脚本只有这一处改样式）────────────────────────
  function applyHide(el) {
    try { el.removeAttribute('data-vg-show'); } catch (e) {}
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
      el.setAttribute('data-vg-show', '1');   // 让"保存规则"注入的那段 CSS 也不再管它
      el.setAttribute(AD_ATTR, '1');          // 记住"它被我们判过是广告"→ 点击防护仍拦它
    } catch (e) {}
  }

  // 标记 + 隐藏。manual 用来说明"是不是用户亲手选的"
  function markAndHide(el, why, fromUser) {
    if (!safeToTouch(el) || el.hasAttribute(ATTR)) return false;
    try { el.setAttribute(AD_ATTR, '1'); applyHide(el); } catch (e) { return false; }
    hiddenCount++;
    if (recent.length > 20) recent.shift();
    recent.push({ sel: desc(el), why: why, t: Date.now() });

    // ★ 自检回滚**只对"机器自己判的"**做 —— 用户亲手选的绝不回滚（那是他的意图），
    //   而且回滚**只还原这一个元素**：这一版**彻底删掉了**"拉黑整个网站 + 把当页全放回来"。
    if (!fromUser) scheduleRollback(el, why);
    return true;
  }

  function scheduleRollback(el, why) {
    var beforeSH = sh();
    setTimeout(function () {
      try {
        if (!el.hasAttribute(ATTR)) return;
        // ★ 判据只留**最硬的一条**：页面高度骤降。
        //   删掉了 elementFromPoint / 元素数占比那两条 —— 全屏广告被藏掉时
        //   "视口中心是 body"极其常见，正是上一版误判的源头。
        if (beforeSH > ROLLBACK_MIN_SH && sh() < beforeSH * (1 - ROLLBACK_DROP)) {
          unhideOne(el);
          el.__vgBad = true;
          rolledBack++;
          hiddenCount = Math.max(0, hiddenCount - 1);
          report('rollback');
        }
      } catch (e) {}
    }, 300);
  }

  // 还原本页（只给"撤销"用；**回滚不再调用它**）
  function restoreAll() {
    var els;
    try { els = document.querySelectorAll('[' + ATTR + ']'); } catch (e) { return 0; }
    for (var i = 0; i < els.length; i++) { unhideOne(els[i]); }
    var n = els.length;
    hiddenCount = 0;
    recent = [];
    return n;
  }

  // ── 3) 用户保存的规则（优先级最高；刷新后**渲染前**就隐藏）──────────────────
  function savedRules() {
    var h = hostNow();
    var list = (SAVED && SAVED[h]) || [];
    var out = [];
    for (var i = 0; i < list.length; i++) { if (list[i] && list[i].on !== false) out.push(list[i]); }
    return out;
  }

  // ★ 这一条是"刷新后不再出现"的关键：把保存过的选择器做成 <style> 塞进 <head>，
  //   **CSS 生效在渲染之前** —— 广告根本不会画出来（而不是画出来再藏）。
  //   `:not([data-vg-show])` 是留给"本页撤销"的：撤销时给元素打上那个属性，CSS 就不再管它
  //   （不然 CSS 里的 !important 会压过内联还原，撤销就失效了）。
  function savedCSS() {
    var rules = savedRules(), css = '';
    for (var i = 0; i < rules.length; i++) {
      var sels = rules[i].sels || [];
      for (var k = 0; k < sels.length; k++) {
        css += sels[k] + ':not([data-vg-show])'
             + '{display:none !important;visibility:hidden !important}\n';
      }
    }
    return css;
  }

  function injectSavedCSS() {
    var css = savedCSS();
    try {
      var st = document.querySelector('style[data-vg-saved]');
      if (!css) { if (st) st.textContent = ''; return; }   // 规则被清空 → 也要把旧样式清掉
      if (st) { st.textContent = css; return; }            // 复用同一个，不删元素
      st = document.createElement('style');
      st.setAttribute('data-vg-saved', '1');
      st.textContent = css;
      var put = function () {
        try {
          if (document.documentElement && !document.querySelector('style[data-vg-saved]')) {
            document.documentElement.appendChild(st);
          }
        } catch (e) {}
      };
      put();
      if (!document.documentElement) document.addEventListener('readystatechange', put);
    } catch (e) {}
  }

  function matchFingerprint(fp, max) {
    var out = [];
    var all;
    try { all = document.querySelectorAll(fp.tag || '*'); } catch (e) { return out; }
    for (var i = 0; i < all.length && out.length < max; i++) {
      var el = all[i];
      if (el.hasAttribute(ATTR) || el.__vgBad) continue;
      if (!safeToTouch(el)) continue;
      var cs, r;
      try { cs = getComputedStyle(el); r = el.getBoundingClientRect(); } catch (e) { continue; }
      if (!floating(cs)) continue;
      var aw = Math.round(r.width / Math.max(1, vw()) * 100);
      var ah = Math.round(r.height / Math.max(1, vh()) * 100);
      if (Math.abs(aw - fp.aw) > 20 || Math.abs(ah - fp.ah) > 20) continue;
      if (posBucket(r) !== fp.pos) continue;
      if (fp.img && !(el.querySelector && el.querySelector('img'))) continue;
      var cls = stableClasses(el).join(' ');
      if (fp.cls && cls && cls !== fp.cls) continue;
      out.push(el);
    }
    return out;
  }

  function applySavedRules() {
    var rules = savedRules();
    if (!rules.length) return 0;
    var n = 0;
    for (var i = 0; i < rules.length; i++) {
      var rule = rules[i];
      var max = rule.max || 3;
      var els = [];
      var sels = rule.sels || [];
      for (var k = 0; k < sels.length && !els.length; k++) {
        try {
          var found = document.querySelectorAll(sels[k]);
          // 唯一性校验：匹配**太多**说明这条选择器太泛 → 不用它（免得连正常内容一起藏）
          if (found.length >= 1 && found.length <= max) els = [].slice.call(found);
        } catch (e) {}
      }
      if (!els.length && rule.fp) els = matchFingerprint(rule.fp, max);
      for (var j = 0; j < els.length; j++) {
        if (markAndHide(els[j], 'saved', true)) n++;
      }
    }
    savedApplied = n;
    return n;
  }

  // ── 4) 选择器 / 指纹（给"点选保存"用）─────────────────────────────────────
  var RANDOM_RE = /^css-|^sc-|^jsx-|^emotion-|^style-|^svelte-|^_[0-9a-z]{5,}|^-?[a-z]{0,3}[-_]?[0-9a-f]{6,}$/;
  function stableClasses(el) {
    var raw = clsOf(el).split(/\s+/), out = [];
    for (var i = 0; i < raw.length && out.length < 3; i++) {
      var c = raw[i];
      if (!c || c.length > 30) continue;
      if (RANDOM_RE.test(c)) continue;
      if (/[0-9]{4,}/.test(c)) continue;
      if (out.indexOf(c) >= 0) continue;
      out.push(c);
    }
    return out;
  }
  function nthOf(el) {
    var p = el.parentElement;
    if (!p) return '';
    var same = [];
    for (var i = 0; i < p.children.length; i++) {
      if (p.children[i].tagName === el.tagName) same.push(p.children[i]);
    }
    if (same.length <= 1) return '';
    return ':nth-of-type(' + (same.indexOf(el) + 1) + ')';
  }
  function pathSelector(el, depth) {
    var parts = [], cur = el, d = 0;
    while (cur && cur.nodeType === 1 && d < depth && cur !== document.body) {
      var seg = (cur.tagName || '').toLowerCase();
      var cls = stableClasses(cur);
      if (!cur.id && cls.length) seg += '.' + cls.join('.');
      if (cur.id && /^[A-Za-z][\w-]*$/.test(cur.id)) { parts.unshift('#' + cur.id); break; }
      seg += nthOf(cur);
      parts.unshift(seg);
      cur = cur.parentElement; d++;
    }
    return parts.join(' > ');
  }
  function selectorCandidates(el) {
    var raw = [];
    if (el.id && /^[A-Za-z][\w-]*$/.test(el.id)) raw.push('#' + el.id);
    var cls = stableClasses(el);
    if (cls.length) raw.push((el.tagName || '').toLowerCase() + '.' + cls.join('.'));
    var p = pathSelector(el, 3);
    if (p) raw.push(p);
    var out = [];
    for (var i = 0; i < raw.length; i++) {
      if (out.indexOf(raw[i]) >= 0) continue;
      var n = -1;
      try { n = document.querySelectorAll(raw[i]).length; } catch (e) { continue; }
      if (n >= 1 && n <= 3) out.push(raw[i]);      // 唯一性校验
    }
    return out;
  }
  function posBucket(r) {
    var cy = (r.top + r.height / 2) / Math.max(1, vh());
    var cx = (r.left + r.width / 2) / Math.max(1, vw());
    return (cy < 0.33 ? 't' : (cy > 0.66 ? 'b' : 'm')) + (cx < 0.33 ? 'l' : (cx > 0.66 ? 'r' : 'c'));
  }
  function fingerprint(el) {
    var r = el.getBoundingClientRect();
    return {
      tag: (el.tagName || '').toLowerCase(),
      cls: stableClasses(el).join(' '),
      aw: Math.round(r.width / Math.max(1, vw()) * 100),
      ah: Math.round(r.height / Math.max(1, vh()) * 100),
      pos: posBucket(r),
      img: !!(el.querySelector && el.querySelector('img'))
    };
  }

  // ── 5) 候选收集 + 扫描 ───────────────────────────────────────────────────
  // 深度不再限制在 4 层：浮层常常被塞在很深的包装里。上限靠数量兜住。
  function candidates(limit) {
    var out = [], body = document.body;
    if (!body) return out;
    var q = [body], guard = 0;
    while (q.length && out.length < (limit || 900) && guard < 5000) {
      var el = q.shift(); guard++;
      var kids = el.children;
      if (!kids) continue;
      for (var i = 0; i < kids.length; i++) {
        var c = kids[i];
        out.push(c);
        q.push(c);
      }
    }
    return out;
  }

  function gateOpen() {
    if (document.readyState === 'complete') return true;
    return readyAt > 0 && (Date.now() - readyAt) > 5000;
  }

  function sweep(strong, force) {
    if (MODE === 'off' || PICK) return 0;
    if (SUSPEND || skipped()) return 0;
    if (document.visibilityState && document.visibilityState !== 'visible') return 0;
    if (!vw() || !vh() || !gateOpen()) return 0;
    var now = Date.now();
    if (!force && now - lastSweep < 700) return 0;
    lastSweep = now;

    var thr = strong ? STRONG_THRESHOLD : THRESHOLD;
    var vArea = vw() * vh(), list = candidates(), n = 0;
    for (var i = 0; i < list.length; i++) {
      if (hiddenCount >= MAX_HIDE) break;
      var el = list[i];
      if (el.nodeType !== 1 || el.hasAttribute(ATTR) || el.__vgBad) continue;
      if (!safeToTouch(el)) continue;
      var cs = getComputedStyleSafe(el);
      if (!cs || !floating(cs)) continue;
      if (cs.display === 'none' || cs.visibility === 'hidden') continue;
      if (parseFloat(cs.opacity) < 0.05) continue;
      var r;
      try { r = el.getBoundingClientRect(); } catch (e) { continue; }
      // 自动：要求"够大"；强力：只要占屏 ≥2%（小的悬浮按钮也算）
      if (strong) { if (area(r) < vArea * 0.02) continue; }
      else if (!bigEnough(r)) continue;
      if (score(el, cs, r) < thr) continue;
      if (markAndHide(el, strong ? 'strong' : 'score', false)) n++;
    }
    if (n) report(strong ? 'strong' : 'hid');
    return n;
  }

  function getComputedStyleSafe(el) {
    try { return getComputedStyle(el); } catch (e) { return null; }
  }

  // ── 6) 强力：顺着"关闭控件"找它所在的浮层，清那一层 ────────────────────────
  // ★ 不是"把关闭按钮都清掉" —— 那样会连播放器的关闭/全屏/弹幕/选集按钮一起清。
  function looksLikeClose(c) {
    var t = (c.textContent || '').trim();
    if (t && t.length <= 2 && /[×✕✖╳xX]/.test(t)) return true;
    var s = ((c.id || '') + ' ' + clsOf(c) + ' ' + (c.getAttribute('aria-label') || '')).toLowerCase();
    return /close|dismiss|关闭/.test(s);
  }
  function nearestOverlay(el) {
    var cur = el, hops = 0;
    while (cur && cur !== document.body && hops < 8) {
      var cs = getComputedStyleSafe(cur);
      if (cs && floating(cs)) {
        var r = cur.getBoundingClientRect();
        if (area(r) >= vw() * vh() * 0.05) return cur;
      }
      cur = cur.parentElement; hops++;
    }
    return null;
  }
  function strongByCloseControl() {
    var n = 0;
    var list = [];
    try {
      list = document.querySelectorAll('[class*="close"],[class*="dismiss"],[id*="close"],[aria-label*="关闭"]');
    } catch (e) { return 0; }
    for (var i = 0; i < list.length && n < MAX_HIDE; i++) {
      var c = list[i];
      if (!looksLikeClose(c)) continue;
      var host = nearestOverlay(c);
      // 找不到浮层祖先 → 不动（这条保护了"播放器里那个关闭按钮"）
      if (!host || host.hasAttribute(ATTR) || host.__vgBad) continue;
      if (markAndHide(host, 'strong-close', false)) n++;
    }
    return n;
  }
  function strongPass() {
    if (MODE === 'off' || PICK) return 0;
    if (SUSPEND || skipped()) return 0;
    var n = strongByCloseControl();
    n += sweep(true, true);
    return n;
  }

  // ── 7) 点选：任意元素、逐层外扩、选中即保存 ────────────────────────────────
  function elementChain(x, y) {
    var list = null;
    try { if (document.elementsFromPoint) list = document.elementsFromPoint(x, y); } catch (e) {}
    if (!list || !list.length) {
      var e = null;
      try { e = document.elementFromPoint(x, y); } catch (e2) {}
      list = [];
      while (e && e !== document.body) { list.push(e); e = e.parentElement; }
    }
    var out = [];
    for (var i = 0; i < list.length; i++) {
      var el = list[i];
      if (!el || el.nodeType !== 1) continue;
      if (el === document.body || el === document.documentElement) continue;
      if (el.hasAttribute(ATTR)) continue;
      if (!safeToTouch(el)) continue;
      out.push(el);
    }
    return out;
  }
  function outlineOnce(el) {
    try {
      var old = document.querySelectorAll('[' + PICK_TMP + ']');
      for (var i = 0; i < old.length; i++) {
        old[i].removeAttribute(PICK_TMP);
        old[i].style.removeProperty('outline');
        old[i].style.removeProperty('outline-offset');
      }
      el.setAttribute(PICK_TMP, '1');
      el.style.setProperty('outline', '2px solid #ff3b30', 'important');
      el.style.setProperty('outline-offset', '-2px', 'important');
    } catch (e) {}
  }
  function pickAct(x, y) {
    lastPickAt = Date.now();
    var chain = elementChain(x, y);
    if (!chain.length) { report('pickmiss'); return; }
    var same = pickAt && Math.abs(pickAt.x - x) < 14 && Math.abs(pickAt.y - y) < 14;
    var idx = same ? Math.min(pickAt.depth + 1, chain.length - 1) : 0;
    pickAt = { x: x, y: y, depth: idx };
    var el = chain[idx];
    outlineOnce(el);
    var rule = { sels: selectorCandidates(el), fp: fingerprint(el), max: 3, on: true };
    if (markAndHide(el, 'pick', true)) {
      var h = hostNow();
      if (!SAVED[h]) SAVED[h] = [];
      if (SAVED[h].length < 40) SAVED[h].push(rule);
      sendSave(rule);
    }
    // 告诉原生"选中了第几层 / 共几层"，好让顶部提示条显示
    report('pick', { depth: idx, total: chain.length });
  }
  function sendSave(rule) {
    post({ type: 'save', host: hostNow(),
           path: (location.pathname || '/').slice(0, 120),
           rule: rule });
  }

  // ── 8) 点击入口：点选优先，其次点击防护（只认我们标过的广告）───────────────
  function onDocClick(e) {
    if (MODE === 'off') return;
    if (PICK) {
      if (Date.now() - lastPickAt < 400) { swallow(e); return; }
      var x = (e.clientX || 0), y = (e.clientY || 0);
      swallow(e);
      pickAct(x, y);
      return;
    }
    if (SUSPEND) return;
    var t = e.target;
    if (!t || !t.closest) return;
    // ★ 只拦"被我们标为广告"的东西。不再"现场判断浮层形状"——
    //   那是在猜，会误拦正常控件。
    if (t.closest('[' + AD_ATTR + ']')) swallow(e);
  }
  function onTouchStart(e) {
    if (!PICK) return;
    var t = e.changedTouches && e.changedTouches[0];
    if (t) pickStart = { x: t.clientX, y: t.clientY };
  }
  function onTouchEnd(e) {
    if (!PICK || MODE === 'off') return;
    var t = e.changedTouches && e.changedTouches[0];
    if (!t) return;
    var st = pickStart; pickStart = null;
    // 位移 > 10px 当滚动 → 放行（滚动永不受影响）
    if (st && (Math.abs(t.clientX - st.x) > 10 || Math.abs(t.clientY - st.y) > 10)) return;
    swallow(e);
    pickAct(t.clientX, t.clientY);
  }
  function swallow(e) {
    try {
      e.preventDefault(); e.stopPropagation();
      if (e.stopImmediatePropagation) e.stopImmediatePropagation();
    } catch (err) {}
  }

  function post(msg) {
    if (!IS_TOP) return;          // ★ 只有主 frame 上报（子 frame 静默清理）
    try {
      var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.vgClean;
      if (h) h.postMessage(msg);
    } catch (e) {}
  }
  function report(type, extra) {
    var m = { type: type, host: hostNow(),
              url: String(location.href || '').slice(0, 300),
              n: hiddenCount, rolled: rolledBack, saved: savedApplied,
              items: recent.slice(-5) };
    if (extra) { for (var k in extra) { if (extra.hasOwnProperty(k)) m[k] = extra[k]; } }
    post(m);
  }

  // ── 9) 变化驱动（新增节点**立即入队**，不分批去抖；每批少量处理）───────────
  function enqueue(node) {
    if (!node || node.nodeType !== 1) return;
    if (queue.length < 800) queue.push(node);
    flushSoon();
  }
  function flushSoon() {
    if (flushing) return;
    flushing = true;
    setTimeout(flushQueue, 0);
  }
  function flushQueue() {
    flushing = false;
    if (MODE === 'off' || PICK || SUSPEND || skipped()) { queue = []; return; }
    var n = 0, vArea = vw() * vh();
    while (queue.length && n < BATCH) {
      var el = queue.shift(); n++;
      if (el.nodeType !== 1 || el.hasAttribute(ATTR) || el.__vgBad) continue;
      if (!safeToTouch(el)) continue;
      var cs = getComputedStyleSafe(el), r;
      try { r = el.getBoundingClientRect(); } catch (e) { continue; }
      if (!cs || !floating(cs)) continue;
      if (cs.display === 'none' || cs.visibility === 'hidden') continue;
      if (parseFloat(cs.opacity) < 0.05) continue;
      if (!bigEnough(r)) continue;
      if (score(el, cs, r) < THRESHOLD) continue;
      if (markAndHide(el, 'mutation', false)) report('hid');
    }
    if (queue.length) flushSoon();
  }

  function start() {
    if (started || skipped() || MODE === 'off') return;
    started = true;
    try {
      document.addEventListener('click', onDocClick, true);
      document.addEventListener('touchstart', onTouchStart, true);
      document.addEventListener('touchend', onTouchEnd, true);
    } catch (e) {}
    injectSavedCSS();
    applySavedRules();
    try {
      observer = new MutationObserver(function (recs) {
        for (var i = 0; i < recs.length; i++) {
          var added = recs[i].addedNodes;
          for (var k = 0; k < added.length; k++) enqueue(added[k]);
        }
      });
      observer.observe(document.documentElement || document,
                       { childList: true, subtree: true });
    } catch (e) {}
    timer = setInterval(function () { sweep(false, false); applySavedRules(); }, 3000);
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', function () {
        if (!readyAt) readyAt = Date.now();
        sweep(false, false); applySavedRules();
      });
    } else {
      if (!readyAt) readyAt = Date.now();
      setTimeout(function () { sweep(false, false); applySavedRules(); }, 0);
    }
  }

  function stop() {
    if (timer) { clearInterval(timer); timer = null; }
    if (observer) { try { observer.disconnect(); } catch (e) {} observer = null; }
    try {
      document.removeEventListener('click', onDocClick, true);
      document.removeEventListener('touchstart', onTouchStart, true);
      document.removeEventListener('touchend', onTouchEnd, true);
    } catch (e) {}
    queue = [];
    started = false;
  }

  // ── 10) 暴露给原生 ────────────────────────────────────────────────────────
  window.__vgCleanSet = function (mode) {
    MODE = (mode === 'off') ? 'off' : 'on';
    if (MODE === 'off') { stop(); PICK = false; restoreAll(); }
    else { SUSPEND = false; start(); sweep(false, true); }
    return MODE;
  };
  window.__vgCleanNow = function () { return sweep(false, true); };
  window.__vgCleanStrong = function () { return strongPass(); };
  window.__vgPickMode = function (on) {
    PICK = !!on;
    pickAt = null;
    if (PICK) { report('pickstart'); }
    else {
      var old = document.querySelectorAll('[' + PICK_TMP + ']');
      for (var i = 0; i < old.length; i++) {
        old[i].removeAttribute(PICK_TMP);
        old[i].style.removeProperty('outline');
        old[i].style.removeProperty('outline-offset');
      }
      sweep(false, true);
    }
    return PICK;
  };
  window.__vgCleanRestore = function () { SUSPEND = true; return restoreAll(); };
  window.__vgCleanSetSkip = function (list) {
    SKIP_HOSTS = (list && list.length) ? list : [];
    if (skipped()) { stop(); restoreAll(); }
    else if (!started && MODE !== 'off') { start(); sweep(false, true); }
    return SKIP_HOSTS.length;
  };
  // 原生把"这个站保存过的规则"下发进来（改完立刻生效，不用刷新）
  window.__vgSetSaved = function (all) {
    SAVED = (all && typeof all === 'object') ? all : {};
    injectSavedCSS();                    // 复用同一个 <style>，只换内容
    return applySavedRules();
  };
  window.__vgCleanStats = function () {
    return { mode: MODE, top: IS_TOP, suspended: SUSPEND, pick: PICK,
             hidden: hiddenCount, rolled: rolledBack, saved: savedApplied,
             skip: SKIP_HOSTS.length, rules: savedRules().length,
             recent: recent.slice(-10) };
  };

  if (document.readyState !== 'loading') readyAt = Date.now();
  if (MODE !== 'off' && !skipped()) start();
})();
