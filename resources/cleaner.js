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

  // ★★ v1.0.213：内容判据用的词表。
  //   借鉴开源规则库的思路（「不是看它长什么样，是看它指向哪」），但**词表只当加分项、不当判据**。
  //   ★ 纪律（DeepSeek 复核后定的）：**不收短词、不收纯数字** ——
  //     像 ag / 188 / 668 / 918 这种，当域名片段判会撞一大片正常站，误伤极大。
  //     匹配一律**按域名 label 精确比对**（绝不 indexOf 子串），否则 alphabet / bethesda 会被误伤。
  var SUSPECT_LABELS = [
    // 博彩/赌场（词都够长，安全）
    'casino', 'gambling', 'betting', 'poker', 'jackpot', 'lottery', 'roulette', 'baccarat',
    // 常见平台牌子（label 精确匹配）
    'pgsoft', 'jdb', 'bbin', 'playtech', 'microgaming', 'netent', 'pragmatic',
    // 广告联盟 / 广告服务（长词）
    'doubleclick', 'googlesyndication', 'popads', 'popcash', 'adsterra', 'propellerads',
    'revcontent', 'taboola', 'outbrain', 'pubmatic', 'adnxs', 'adservice', 'adserver',
    'adnetwork', 'bannerconnect',
    // ★ 高风险短词：只认「整体就是它」或「它 + 数字/下划线/横线」——
    //   这样 bet365 / bet-88 / slot888 能命中，而 bethesda / alphabet / slotted 不会。
    'bet', 'slot'
  ];

  // 可信 iframe 源：这些即使出现在浮层里也不当广告（视频/支付/验证码/地图/评论/统计）
  var TRUSTED_HOSTS = [
    'youtube.com', 'youtube-nocookie.com', 'ytimg.com', 'vimeo.com', 'dailymotion.com',
    'stripe.com', 'paypal.com', 'alipay.com', 'alipayobjects.com',
    'recaptcha.net', 'hcaptcha.com', 'cloudflare.com',
    'google.com', 'gstatic.com', 'googleapis.com',
    'openstreetmap.org', 'amap.com', 'map.baidu.com',
    'disqus.com', 'facebook.com', 'twitter.com', 'x.com'
  ];

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

  // ── v1.0.213：域名工具（内容判据的地基）────────────────────────────────────
  //   一律用 new URL 取 hostname（自动处理相对路径、协议、端口、URL 编码），
  //   绝不自己写正则去抠字符串 —— 那是误伤的主要来源。
  function hostOf(u) {
    try {
      if (!u) return '';
      var h = new URL(u, location.href).hostname.toLowerCase();
      return h.replace(/\.$/, '');            // 去掉结尾的点（evil.com. 这种）
    } catch (e) { return ''; }
  }
  // 本站 / 本站子域 / 本站父域 → 都算「自家」，不算外链
  function isSelfHost(h) {
    var me = (location.hostname || '').toLowerCase();
    if (!h || !me) return true;
    if (h === me) return true;
    if (h.slice(-(me.length + 1)) === '.' + me) return true;   // h 是 me 的子域
    if (me.slice(-(h.length + 1)) === '.' + h) return true;    // h 是 me 的父域
    return false;
  }
  function isTrustedHost(h) {
    for (var i = 0; i < TRUSTED_HOSTS.length; i++) {
      var t = TRUSTED_HOSTS[i];
      if (h === t || h.slice(-(t.length + 1)) === '.' + t) return true;
    }
    return false;
  }
  // 单个 label 是否命中可疑词：**精确等于**，或「词 + 数字/下划线/横线」开头那一段。
  // ★ 绝不做无边界的子串包含 —— 那是 alphabet / bethesda 被误伤的根源。
  function labelHit(label) {
    if (!label) return false;
    for (var i = 0; i < SUSPECT_LABELS.length; i++) {
      var w = SUSPECT_LABELS[i];
      if (label === w) return true;
      if (label.length > w.length && label.slice(0, w.length) === w &&
          /^[0-9_-]/.test(label.charAt(w.length))) return true;
    }
    return false;
  }
  function isSuspectHost(h) {
    if (!h || isSelfHost(h) || isTrustedHost(h)) return false;
    var parts = h.split('.');
    for (var i = 0; i < parts.length; i++) {
      if (labelHit(parts[i])) return true;
    }
    return false;
  }
  // 「不算跳转」的 href：同页锚点 / javascript: / 空 —— 正常站的关闭按钮就长这样
  function isSafeHref(u) {
    if (!u) return true;
    var s = String(u).trim().toLowerCase();
    if (!s || s === '#' || s.charAt(0) === '#') return true;
    if (s.indexOf('javascript:') === 0) return true;
    if (s.indexOf('mailto:') === 0 || s.indexOf('tel:') === 0) return true;
    return false;
  }
  // 这个元素是不是「指向站外」的链接
  function outLinkHost(el) {
    var h = hostOf(el.getAttribute ? el.getAttribute('href') : '');
    if (!h || isSelfHost(h) || isSafeHref(el.getAttribute ? el.getAttribute('href') : '')) return '';
    return h;
  }

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
  // ★★ v1.0.213 核心：**内容信号**（借鉴乘风「用链接目标认广告」的思路）。
  //   它只**加分**，绝不单独决定"是不是广告" —— 这是 DeepSeek 复核时纠正的关键点：
  //   让任一条内容特征「命中即清」，等于把"漏"换成更严重的"误杀"。
  //   所以：内容信号 + 形状分**一起够阈值**才动手。
  function contentSignal(el) {
    var s = 0, i, h;
    try {
      // (a) 层里含指向「站外可疑域」的链接（+3）
      var as = el.querySelectorAll ? el.querySelectorAll('a[href]') : null;
      if (as) {
        var n = Math.min(as.length, 24);
        for (i = 0; i < n; i++) {
          h = outLinkHost(as[i]);
          if (h && isSuspectHost(h)) { s += 3; break; }
        }
      }
      // (b) 整层本身就是一个指向站外的 <a>（点哪都跳走 —— 典型插屏）（+2）
      if ((el.tagName || '').toLowerCase() === 'a' && outLinkHost(el)) s += 2;
      // (c) 层里含指向「可疑域」的 iframe（可信源如视频/支付/验证码已排除）（+2）
      var ifs = el.querySelectorAll ? el.querySelectorAll('iframe[src]') : null;
      if (ifs) {
        var m = Math.min(ifs.length, 6);
        for (i = 0; i < m; i++) {
          h = hostOf(ifs[i].getAttribute('src'));
          if (h && isSuspectHost(h)) { s += 2; break; }
        }
      }
      // (d) **假关闭按钮**：看着像关闭，点下去却跳到站外（+3）
      //     —— 这条直击「点它的 X 反而跳走」那个痛点，完全不依赖词表。
      var cc = el.querySelectorAll
        ? el.querySelectorAll('[class*="close"],[class*="dismiss"],[id*="close"],[aria-label*="关闭"]')
        : null;
      if (cc) {
        var k = Math.min(cc.length, 8);
        for (i = 0; i < k; i++) {
          var c = cc[i];
          if (!looksLikeClose(c)) continue;
          h = outLinkHost(c);
          if (h) { s += 3; break; }
        }
      }
    } catch (e) {}
    return s;
  }

  function score(el, cs, r, sig) {
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
    return s + shadePenalty(el) + (sig || 0);
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
    var eh = 0;
    try { eh = el.getBoundingClientRect().height || 0; } catch (e0) {}   // ★ 隐藏前先量它多高
    try { el.setAttribute(AD_ATTR, '1'); applyHide(el); } catch (e) { return false; }
    hiddenCount++;
    if (recent.length > 20) recent.shift();
    recent.push({ sel: desc(el), why: why, t: Date.now() });

    // ★ 自检回滚**只对"机器自己判的"**做 —— 用户亲手选的绝不回滚（那是他的意图），
    //   而且回滚**只还原这一个元素**：这一版**彻底删掉了**"拉黑整个网站 + 把当页全放回来"。
    if (!fromUser) scheduleRollback(el, why, eh);
    return true;
  }

  function scheduleRollback(el, why, eh) {
    var beforeSH = sh();
    setTimeout(function () {
      try {
        if (!el.hasAttribute(ATTR)) return;
        // ★ v1.0.213：判据加**第二道** —— 降幅要跟「我刚藏的这个元素」相称。
        //   只按"页面高度骤降"判，SPA 切页 / 懒加载 / 无限滚动都会误判（DeepSeek 指出，已采纳）。
        //   而且这道判据天然成立：fixed 浮层不占文档流，藏它本来就不会让高度掉 ——
        //   会掉高度的，几乎只有"藏在正常文档流里的大容器"（那多半是正文）。
        var drop = beforeSH - sh();
        if (beforeSH > ROLLBACK_MIN_SH && drop > beforeSH * ROLLBACK_DROP &&
            (eh <= 0 || drop >= eh * 0.5)) {
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
      // ★ v1.0.213：内容信号**只算一次**（既避免重复开销，也是"面积门槛的替代入场券"）。
      var sig = contentSignal(el);
      if (area(r) < vArea * 0.02) continue;                 // 任何情况都要求 ≥2% 屏
      // 自动：要么"够大"（老门槛 60%宽×30%高），要么"有内容信号"（贴边小广告由此进场）；
      // 强力：只要 ≥2%
      if (!strong && !bigEnough(r) && sig <= 0) continue;
      if (score(el, cs, r, sig) < thr) continue;
      if (markAndHide(el, strong ? 'strong' : 'score', false)) n++;
    }
    // ★ v1.0.213：自动那趟再认一遍「假关闭按钮」——
    //   那个 X 常常和浮层不在同一层级（是兄弟节点），打分扫不到，得单独顺一遍。
    if (!strong) n += autoByFakeClose();
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
  // ★ v1.0.213：自动模式也认「假关闭按钮」（原来只有强力才认）。
  //   判据收紧为「看着像关闭 **且点了会跳到站外**」——
  //   正常站的关闭按钮是 <a href="#"> / javascript:void(0)，被 isSafeHref 排除在外，不会误伤。
  function autoByFakeClose() {
    var n = 0, list = [];
    try {
      list = document.querySelectorAll('[class*="close"],[class*="dismiss"],[id*="close"],[aria-label*="关闭"]');
    } catch (e) { return 0; }
    for (var i = 0; i < list.length && n < MAX_HIDE; i++) {
      var c = list[i];
      if (!looksLikeClose(c)) continue;
      if (!outLinkHost(c)) continue;             // 只认"点了会跳站外"的假关闭
      var host = nearestOverlay(c);
      if (!host || host.hasAttribute(ATTR) || host.__vgBad) continue;
      if (!safeToTouch(host)) continue;
      if (markAndHide(host, 'fakeclose', false)) n++;
    }
    return n;
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
      // ★ v1.0.213：与 sweep 用同一套门槛（内容信号可替代"够大"）
      var sig = contentSignal(el);
      if (area(r) < vArea * 0.02) continue;
      if (!bigEnough(r) && sig <= 0) continue;
      if (score(el, cs, r, sig) < THRESHOLD) continue;
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
