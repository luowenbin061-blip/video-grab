import Foundation

/// 电脑端「文件」页 —— 手机共享出来的下载目录，在电脑浏览器里长什么样。
///
/// ★ v1.0.169：从「一行一个文件名」改成**卡片网格**。
///   动因：`records.json` 里本来就存着 时长 / 分辨率 / 下载时间 / 缩略图，
///   这一页以前一个都没用上 —— 在电脑上挑文件只能靠文件名猜。
///   现在：缩略图 + 三行信息 + 搜索 / 排序 / 类型筛选 + 点缩略图直接播。
///
/// ★ 分工（改的时候别搞混）：
///   · **服务端**（本文件）只做一件事：把「一张卡要的全部字段」算好，编成 JSON 注入页面；
///   · **前端**（页面里那一小段 JS）负责排序 / 筛选 / 搜索 / 播放 / 选中 / 下载。
///   所以加字段只需改两处：`Item` + 页面 JS 里对应的键名。
///
/// ★★ 线程约束：本文件**可能跑在后台线程**（HTTP 服务用的是并发队列，不是主线程）。
///   所以这里只许用 `JobStore` / `JobRecord` 这类非隔离的东西，
///   **不许碰 `DownloadJob`** —— 它是 `@MainActor` 的（v1.0.168 那次就是栽在这类写法上）。
enum LanPage {

    /// 一张卡要的全部字段。键名直接对应注入页面里的 JSON。
    struct Item {
        var name: String      // 显示名
        var url: String       // 下载 / 播放地址（已含口令前缀、已 URL 编码）
        var kind: String      // video / image / audio / doc / dir
        var dur: Double       // 秒（0 = 不知道 → 不显示时长角标）
        var dim: String       // "1280×720"（空 = 不显示）
        var bytes: Int64      // 字节数（前端换算成 MB/GB）
        var time: Double      // unix 秒（0 = 不知道）
        var thumb: String     // 缩略图地址（空 = 用占位图标）
    }

    /// 页面里那 5 个类型图标（缩略图缺失时顶上）
    private static let icons: [String: String] = [
        "video": "<svg viewBox=\"0 0 24 24\" width=\"30\" height=\"30\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.4\"><rect x=\"3\" y=\"5\" width=\"18\" height=\"14\" rx=\"2\"/><path d=\"M10 9.5l5 2.5-5 2.5z\" fill=\"currentColor\" stroke=\"none\"/></svg>",
        "image": "<svg viewBox=\"0 0 24 24\" width=\"30\" height=\"30\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.4\"><rect x=\"3\" y=\"5\" width=\"18\" height=\"14\" rx=\"2\"/><circle cx=\"8.5\" cy=\"10\" r=\"1.4\"/><path d=\"M4 17.5l5-4.2 3.6 2.9 2.8-2.1L20 17\"/></svg>",
        "audio": "<svg viewBox=\"0 0 24 24\" width=\"30\" height=\"30\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.9\" stroke-linecap=\"round\"><path d=\"M4 11v2M8 7.5v9M12 4.5v15M16 7.5v9M20 11v2\"/></svg>",
        "doc": "<svg viewBox=\"0 0 24 24\" width=\"30\" height=\"30\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.4\"><path d=\"M6.5 3h7l5 5v13h-12z\"/><path d=\"M13.5 3v5h5\"/></svg>",
        "dir": "<svg viewBox=\"0 0 24 24\" width=\"30\" height=\"30\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.4\"><path d=\"M3 7.5A1.5 1.5 0 0 1 4.5 6h4l2 2.2h8A1.5 1.5 0 0 1 20 9.7v8.3A1.5 1.5 0 0 1 18.5 19.5h-14A1.5 1.5 0 0 1 3 18z\"/></svg>"
    ]

    /// 组装整页 HTML。
    /// - Parameters:
    ///   - heading: 标题（根目录 = "我的下载"；子目录 = 目录名）
    ///   - sub: 标题下那行小字
    ///   - backURL: 有值就显示「返回上一层」
    ///   - note: 页脚那句说明
    static func html(items: [Item], heading: String, sub: String,
                     backURL: String?, note: String) -> String {
        let back = backURL.map {
            "<a class=\"back\" href=\"\(esc($0))\">← 返回上一层</a>"
        } ?? ""

        return #"""
        <!doctype html>
        <html lang="zh-CN">
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="color-scheme" content="dark light">
        <title>视频抓取 · 文件</title>
        <style>
        :root{
          /* ① 原始值 */
          --blue-500:#4c8dff; --blue-400:#6ba1ff;
          --n-0:#0e1014; --n-1:#161920; --n-2:#1e222b; --n-3:#272c37;
          --t-1:#eef1f6; --t-2:#9aa3b2; --t-3:#6b7382;
          --line:rgba(255,255,255,.09); --line-2:rgba(255,255,255,.18);
          --space-1:.25rem; --space-2:.5rem; --space-3:.75rem; --space-4:1rem;
          --space-6:1.5rem; --space-8:2rem;
          --r-md:8px; --r-lg:12px; --r-xl:16px;
          --fs-xs:.75rem; --fs-sm:.875rem; --fs-base:1rem; --fs-lg:1.25rem;
          --dur-fast:150ms; --ease-out:cubic-bezier(.22,.61,.36,1);
          /* ② 语义层：换主题只动这一段 */
          --color-primary:var(--blue-500);
          --page-bg:var(--n-0); --text-1:var(--t-1); --text-2:var(--t-2); --text-3:var(--t-3);
          --line-1:var(--line); --line-3:var(--line-2);
          /* ③ 组件层 */
          --card-bg:var(--n-1); --card-line:var(--line-1); --card-radius:var(--r-lg);
        }
        @media (prefers-color-scheme:light){
          :root{
            --n-0:#f6f7f9; --n-1:#ffffff; --n-2:#f0f2f5; --n-3:#e4e7ec;
            --t-1:#12161d; --t-2:#5b6472; --t-3:#8a92a0;
            --line:rgba(0,0,0,.09); --line-2:rgba(0,0,0,.2);
          }
        }
        *,*::before,*::after{box-sizing:border-box}
        body{
          margin:0;background:var(--page-bg);color:var(--text-1);
          font:400 var(--fs-base)/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei",system-ui,sans-serif;
          -webkit-font-smoothing:antialiased;
        }
        body.lock{overflow:hidden}
        .sr-only{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap}
        main{max-width:1180px;margin:0 auto;padding:var(--space-8) var(--space-6) var(--space-8)}

        .back{display:inline-block;margin-bottom:var(--space-4);font-size:var(--fs-sm);
          color:var(--text-2);text-decoration:none;transition:color var(--dur-fast) var(--ease-out)}
        .back:hover{color:var(--text-1)}
        .back:focus-visible{outline:2px solid var(--color-primary);outline-offset:3px;border-radius:4px}

        header{display:flex;flex-wrap:wrap;align-items:center;gap:var(--space-3);margin-bottom:var(--space-6)}
        h1{font-size:var(--fs-lg);font-weight:500;letter-spacing:-.01em;margin:0;flex:1 1 12rem;min-width:0}
        h1 small{display:block;font-size:var(--fs-xs);font-weight:400;color:var(--text-3);letter-spacing:0;margin-top:2px;
          white-space:nowrap;overflow:hidden;text-overflow:ellipsis}

        .search{flex:1 1 15rem;max-width:22rem;position:relative}
        .search input{
          width:100%;padding:.5rem .75rem .5rem 2.1rem;font:inherit;font-size:var(--fs-sm);
          background:var(--n-2);color:var(--text-1);border:1px solid var(--line-1);border-radius:var(--r-md);
          transition:border-color var(--dur-fast) var(--ease-out),background var(--dur-fast) var(--ease-out);
        }
        .search input::placeholder{color:var(--text-3)}
        .search input:hover{border-color:var(--line-3)}
        .search input:focus{outline:none;border-color:var(--color-primary);background:var(--n-1)}
        .search svg{position:absolute;left:.7rem;top:50%;transform:translateY(-50%);color:var(--text-3);pointer-events:none}

        .seg{display:flex;gap:2px;padding:3px;background:var(--n-2);border-radius:var(--r-md);border:1px solid var(--line-1);flex-wrap:wrap}
        .seg button{
          font:inherit;font-size:var(--fs-xs);padding:.35rem .7rem;border:0;border-radius:6px;
          background:transparent;color:var(--text-2);cursor:pointer;white-space:nowrap;
          transition:background var(--dur-fast) var(--ease-out),color var(--dur-fast) var(--ease-out);
        }
        .seg button:hover{color:var(--text-1);background:var(--n-3)}
        .seg button[aria-pressed="true"]{background:var(--color-primary);color:#fff}
        .seg button:active{transform:scale(.97)}
        .seg button:focus-visible{outline:2px solid var(--color-primary);outline-offset:2px}
        .seg .n{opacity:.6;font-variant-numeric:tabular-nums;margin-left:.15rem}
        .seg button[aria-pressed="true"] .n{opacity:.75}

        .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(100%,15rem),1fr));gap:var(--space-4)}

        .card{
          background:var(--card-bg);border:1px solid var(--card-line);border-radius:var(--card-radius);
          overflow:hidden;cursor:pointer;position:relative;
          opacity:0;transform:translateY(10px);animation:reveal .45s var(--ease-out) forwards;
          transition:border-color var(--dur-fast) var(--ease-out),
                     translate var(--dur-fast) var(--ease-out),
                     background var(--dur-fast) var(--ease-out);
        }
        @keyframes reveal{to{opacity:1;transform:none}}
        .card:hover{border-color:var(--line-3);translate:0 -2px;background:var(--n-2)}
        .card:active{translate:0 0}
        .card:focus-visible{outline:2px solid var(--color-primary);outline-offset:2px}
        .card[aria-selected="true"]{border-color:var(--color-primary);background:var(--n-2)}

        .thumb{
          position:relative;aspect-ratio:16/9;display:flex;align-items:center;justify-content:center;
          background:var(--n-3);overflow:hidden;
        }
        .thumb img{width:100%;height:100%;object-fit:cover;display:block}
        .thumb .ph{color:var(--text-3)}
        .play{
          position:absolute;left:50%;top:50%;width:2.4rem;height:2.4rem;border-radius:50%;
          background:rgba(0,0,0,.58);display:flex;align-items:center;justify-content:center;
          opacity:0;transform:translate(-50%,-50%) scale(.9);
          transition:opacity var(--dur-fast) var(--ease-out),transform var(--dur-fast) var(--ease-out);
        }
        .card:hover .play,.card:focus-visible .play,.card:focus-within .play{opacity:1;transform:translate(-50%,-50%) scale(1)}
        .dur{position:absolute;right:.4rem;bottom:.4rem;font-size:var(--fs-xs);line-height:1.35;
          padding:0 .35rem;border-radius:4px;background:rgba(0,0,0,.74);color:#fff;
          font-variant-numeric:tabular-nums}
        .tick{position:absolute;left:.4rem;top:.4rem;width:1.15rem;height:1.15rem;border-radius:50%;
          background:var(--color-primary);display:none;align-items:center;justify-content:center}
        .card[aria-selected="true"] .tick{display:flex}
        .dl{position:absolute;right:.4rem;top:.4rem;width:1.65rem;height:1.65rem;border-radius:6px;
          display:flex;align-items:center;justify-content:center;text-decoration:none;
          background:rgba(0,0,0,.58);color:#fff;opacity:0;
          transition:opacity var(--dur-fast) var(--ease-out),background var(--dur-fast) var(--ease-out)}
        .card:hover .dl,.dl:focus-visible{opacity:1}
        .dl:hover{background:var(--color-primary)}
        .dl:focus-visible{outline:2px solid #fff;outline-offset:2px}

        .body{padding:var(--space-3) var(--space-3) var(--space-4)}
        .name{font-size:var(--fs-sm);font-weight:500;margin:0 0 .15rem;
          white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        .meta{font-size:var(--fs-xs);color:var(--text-2);margin:0;font-variant-numeric:tabular-nums}
        .time{font-size:var(--fs-xs);color:var(--text-3);margin:.2rem 0 0;font-variant-numeric:tabular-nums}

        footer{
          position:sticky;bottom:0;margin-top:var(--space-6);padding:var(--space-3) 0;
          display:flex;align-items:center;gap:var(--space-3);flex-wrap:wrap;
          font-size:var(--fs-sm);color:var(--text-2);
          background:linear-gradient(to top,var(--page-bg) 62%,transparent);
        }
        .btn{
          font:inherit;font-size:var(--fs-sm);padding:.45rem .9rem;border-radius:var(--r-md);
          border:1px solid var(--line-3);background:transparent;color:var(--text-1);cursor:pointer;
          transition:background var(--dur-fast) var(--ease-out),border-color var(--dur-fast) var(--ease-out),opacity var(--dur-fast) var(--ease-out);
        }
        .btn:hover:not(:disabled){background:var(--n-2);border-color:var(--text-3)}
        .btn:active:not(:disabled){transform:scale(.98)}
        .btn:focus-visible{outline:2px solid var(--color-primary);outline-offset:2px}
        .btn:disabled{opacity:.4;cursor:not-allowed}
        .btn.primary{background:var(--color-primary);border-color:var(--color-primary);color:#fff}
        .btn.primary:hover:not(:disabled){background:var(--blue-400);border-color:var(--blue-400)}
        .hint{margin-left:auto;font-size:var(--fs-xs);color:var(--text-3)}
        .empty{grid-column:1/-1;padding:var(--space-8) 0;text-align:center;color:var(--text-3);font-size:var(--fs-sm)}
        .legend{margin-top:var(--space-6);font-size:var(--fs-xs);color:var(--text-3);line-height:1.7;max-width:46rem}

        .ovl{position:fixed;inset:0;background:rgba(0,0,0,.9);display:flex;align-items:center;justify-content:center;
          z-index:50;padding:var(--space-4)}
        .ovl[hidden]{display:none}
        .ovl .box{max-width:min(96vw,1100px);max-height:86vh;display:flex}
        .ovl video,.ovl img{max-width:min(96vw,1100px);max-height:86vh;display:block;border-radius:var(--r-md);background:#000}
        .ovl .x{position:absolute;right:var(--space-4);top:var(--space-4);width:2.6rem;height:2.6rem;
          border-radius:50%;border:0;background:rgba(255,255,255,.14);color:#fff;cursor:pointer;
          display:flex;align-items:center;justify-content:center;
          transition:background var(--dur-fast) var(--ease-out)}
        .ovl .x:hover{background:rgba(255,255,255,.28)}
        .ovl .x:focus-visible{outline:2px solid #fff;outline-offset:2px}
        .ovl .nm{position:absolute;left:var(--space-4);bottom:var(--space-4);right:var(--space-4);
          color:#fff;font-size:var(--fs-sm);text-align:center;opacity:.8}

        @media (prefers-reduced-motion:reduce){
          *,*::before,*::after{animation-duration:.01ms!important;transition-duration:.01ms!important}
        }
        @media (max-width:640px){
          main{padding:var(--space-4) var(--space-3)}
          .hint{display:none}
        }
        </style>

        <main>
          <h2 class="sr-only">手机共享出来的文件列表：可搜索、排序、按类型筛选；点缩略图在线播放，点卡片选中后可批量下载。</h2>

          \#(back)

          <header>
            <h1>\#(esc(heading))<small>\#(esc(sub))</small></h1>
            <div class="search">
              <svg width="15" height="15" viewBox="0 0 24 24" fill="none" aria-hidden="true"><circle cx="11" cy="11" r="7" stroke="currentColor" stroke-width="1.8"/><path d="M16.5 16.5L21 21" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>
              <input id="q" type="search" placeholder="搜索文件名" aria-label="搜索文件名">
            </div>
            <div class="seg" id="sort" role="group" aria-label="排序方式">
              <button type="button" data-k="time" aria-pressed="true">最新</button>
              <button type="button" data-k="size" aria-pressed="false">最大</button>
              <button type="button" data-k="name" aria-pressed="false">名称</button>
            </div>
            <div class="seg" id="kind" role="group" aria-label="类型筛选"></div>
          </header>

          <div class="grid" id="grid" role="listbox" aria-label="文件列表" aria-multiselectable="true"></div>

          <footer>
            <span id="cnt">0 个文件</span>
            <button type="button" class="btn primary" id="dl" disabled>下载选中</button>
            <button type="button" class="btn" id="clr" disabled>取消选择</button>
            <span class="hint">点缩略图在线播放 · 点卡片选中</span>
          </footer>

          <p class="legend">\#(esc(note))</p>
        </main>

        <div class="ovl" id="ovl" hidden>
          <button type="button" class="x" id="ovlX" aria-label="关闭">✕</button>
          <div class="box" id="ovlBox"></div>
          <p class="nm" id="ovlNm"></p>
        </div>

        <script>
        var D = \#(json(items));
        // ★ 每张卡记住自己在 D 里的**原始下标** —— 排序/筛选后列表下标会变，
        //   而选中集合和批量下载都按原始下标索引，两套下标混用必然错位。
        D.forEach(function(x, k){ x.i = k; });
        var ICON = {
          video:'\#(icons["video"] ?? "")',
          image:'\#(icons["image"] ?? "")',
          audio:'\#(icons["audio"] ?? "")',
          doc:'\#(icons["doc"] ?? "")',
          dir:'\#(icons["dir"] ?? "")'
        };
        var PLAY = '<svg width="14" height="14" viewBox="0 0 24 24" aria-hidden="true"><path d="M9 7l9 5-9 5z" fill="#fff"/></svg>';
        var TICK = '<svg width="9" height="9" viewBox="0 0 24 24" aria-hidden="true"><path d="M5 13l4 4L19 7" stroke="#fff" stroke-width="3" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>';
        var DL = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M12 4v11m0 0l-4-4m4 4l4-4M5 19h14" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>';

        var KINDNAME = {video:"视频", image:"图片", audio:"音频", doc:"文件", dir:"文件夹"};
        var sort = "time", kind = "all", q = "", sel = {};

        function esc(s){
          return String(s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;");
        }
        function pad(n){ return n < 10 ? "0" + n : "" + n; }
        function fmtDur(s){
          if(!s) return "";
          s = Math.round(s);
          var h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), x = s % 60;
          return h ? (h + ":" + pad(m) + ":" + pad(x)) : (m + ":" + pad(x));
        }
        function fmtSize(b){
          if(b >= 1073741824) return (b / 1073741824).toFixed(2) + " GB";
          if(b >= 1048576) return (b / 1048576).toFixed(1) + " MB";
          if(b > 0) return Math.max(1, Math.round(b / 1024)) + " KB";
          return "";
        }
        function fmtAgo(t){
          if(!t) return "";
          var d = new Date(t * 1000), n = new Date();
          var d0 = new Date(n.getFullYear(), n.getMonth(), n.getDate());
          var dd = new Date(d.getFullYear(), d.getMonth(), d.getDate());
          var diff = Math.round((d0 - dd) / 86400000);
          var hm = pad(d.getHours()) + ":" + pad(d.getMinutes());
          if(diff === 0) return "今天 " + hm;
          if(diff === 1) return "昨天 " + hm;
          if(diff > 1 && diff < 7) return diff + " 天前";
          return (d.getMonth() + 1) + "月" + d.getDate() + "日";
        }

        function visible(){
          return D.filter(function(x){
            if(kind !== "all" && x.kind !== kind) return false;
            if(q && x.name.toLowerCase().indexOf(q.toLowerCase()) < 0) return false;
            return true;
          });
        }

        function sortList(list){
          list.sort(function(a, b){
            if(sort === "name") return a.name.localeCompare(b.name, "zh");
            if(sort === "size") return b.bytes - a.bytes;
            return b.time - a.time;
          });
          return list;
        }

        function card(x, i){
          var on = sel[x.i] ? "true" : "false";
          var canPlay = x.kind !== "doc";
          var html = '<article class="card" tabindex="0" role="option" aria-selected="' + on + '"'
                   + ' data-i="' + x.i + '" style="animation-delay:' + Math.min(i, 9) * 45 + 'ms">'
                   + '<div class="thumb">';
          if(x.thumb){
            html += '<img src="' + esc(x.thumb) + '" alt="" loading="lazy" decoding="async">';
          } else {
            html += '<span class="ph">' + (ICON[x.kind] || ICON.doc) + '</span>';
          }
          if(canPlay) html += '<span class="play">' + PLAY + '</span>';
          var d = fmtDur(x.dur);
          if(d && x.kind !== "image") html += '<span class="dur">' + d + '</span>';
          html += '<span class="tick">' + TICK + '</span>'
                + '<a class="dl" href="' + esc(x.url) + '" download="' + esc(x.name) + '" title="下载" aria-label="下载 ' + esc(x.name) + '">' + DL + '</a>'
                + '</div><div class="body">'
                + '<p class="name" title="' + esc(x.name) + '">' + esc(x.name) + '</p>'
                + '<p class="meta">' + esc([x.dim, fmtSize(x.bytes)].filter(Boolean).join(" · ")) + '</p>'
                + '<p class="time">' + esc(fmtAgo(x.time)) + '</p>'
                + '</div></article>';
          return html;
        }

        function render(){
          var list = sortList(visible());
          var g = document.getElementById("grid");
          if(!list.length){
            g.innerHTML = '<p class="empty">' + (D.length ? "没有匹配的文件" : "这个目录里还没有文件") + '</p>';
          } else {
            g.innerHTML = list.map(card).join("");
          }
          var n = Object.keys(sel).length;
          document.getElementById("cnt").textContent =
            n ? ("已选 " + n + " 个 · 共 " + list.length + " 个") : (list.length + " 个文件");
          document.getElementById("dl").disabled = !n;
          document.getElementById("clr").disabled = !n;
        }

        function chipRow(){
          var counts = {all: D.length};
          D.forEach(function(x){ counts[x.kind] = (counts[x.kind] || 0) + 1; });
          var order = ["all", "video", "image", "audio", "doc", "dir"];
          var row = document.getElementById("kind");
          row.innerHTML = order.filter(function(k){ return counts[k]; }).map(function(k){
            var on = k === kind ? "true" : "false";
            var label = k === "all" ? "全部" : (KINDNAME[k] || k);
            return '<button type="button" data-k="' + k + '" aria-pressed="' + on + '">'
                 + label + '<span class="n">' + counts[k] + '</span></button>';
          }).join("");
        }

        function toggle(i){
          if(sel[i]) delete sel[i]; else sel[i] = 1;
          render();
        }

        // ── 播放浮层 ──
        function open(i){
          var x = D[i];
          if(x.kind === "dir"){ location.href = x.url; return; }
          var box = document.getElementById("ovlBox");
          box.innerHTML = x.kind === "image"
            ? '<img src="' + esc(x.url) + '" alt="">'
            : '<video src="' + esc(x.url) + '" controls autoplay playsinline></video>';
          document.getElementById("ovlNm").textContent = x.name;
          document.getElementById("ovl").hidden = false;
          document.body.classList.add("lock");
          document.getElementById("ovlX").focus();
        }
        function close(){
          var o = document.getElementById("ovl");
          if(o.hidden) return;
          o.hidden = true;
          document.getElementById("ovlBox").innerHTML = "";   // 停掉播放
          document.body.classList.remove("lock");
        }

        document.getElementById("grid").addEventListener("click", function(e){
          var c = e.target.closest(".card"); if(!c) return;
          if(e.target.closest(".dl")) return;                  // 点下载按钮不选中
          if(e.target.closest(".thumb")){ open(+c.dataset.i); return; }
          toggle(+c.dataset.i);
        });
        document.getElementById("grid").addEventListener("keydown", function(e){
          var c = e.target.closest(".card"); if(!c) return;
          if(e.key === " " || e.key === "Enter"){ e.preventDefault(); toggle(+c.dataset.i); }
        });
        document.getElementById("q").addEventListener("input", function(){ q = this.value; render(); });
        ["sort", "kind"].forEach(function(id){
          var g = document.getElementById(id);
          g.addEventListener("click", function(e){
            var b = e.target.closest("button"); if(!b) return;
            var on = b.getAttribute("aria-pressed") === "true";
            if(id === "sort" && on) return;
            g.querySelectorAll("button").forEach(function(o){ o.setAttribute("aria-pressed", "false"); });
            b.setAttribute("aria-pressed", "true");
            if(id === "sort") sort = b.dataset.k; else { kind = b.dataset.k; }
            render();
          });
        });
        document.getElementById("clr").addEventListener("click", function(){ sel = {}; render(); });
        document.getElementById("dl").addEventListener("click", function(){
          var keys = Object.keys(sel);
          if(!keys.length) return;
          // 浏览器对"一次点击触发多个下载"敏感 —— 间隔开，别被拦
          keys.forEach(function(k, i){
            setTimeout(function(){
              var a = document.createElement("a");
              a.href = D[k].url; a.download = D[k].name;
              document.body.appendChild(a); a.click(); a.remove();
            }, i * 400);
          });
        });
        document.getElementById("ovlX").addEventListener("click", close);
        document.getElementById("ovl").addEventListener("click", function(e){
          if(e.target === this) close();
        });
        document.addEventListener("keydown", function(e){
          if(e.key === "Escape") close();
        });

        chipRow();
        render();
        </script>
        </html>
        """#
    }

    // MARK: - 小工具

    /// HTML 转义（标题、名字这类要进标签内容的）
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 把卡片数据编成 JSON 字面量。
    ///
    /// ★ 必须把 `<` 写成 `\u003c` —— 文件名里万一带上 `</script>`，
    ///   页面里的脚本块会被提前截断，整页 JS 直接全废（文件名是用户/站点给的，不能假设干净）。
    static func json(_ items: [Item]) -> String {
        var out = "["
        for (i, it) in items.enumerated() {
            if i > 0 { out += "," }
            out += "{\"name\":\(q(it.name)),"
            out += "\"url\":\(q(it.url)),"
            out += "\"kind\":\(q(it.kind)),"
            out += "\"dur\":\(num(it.dur)),"
            out += "\"dim\":\(q(it.dim)),"
            out += "\"bytes\":\(it.bytes),"
            out += "\"time\":\(num(it.time)),"
            out += "\"thumb\":\(q(it.thumb))}"
        }
        return out + "]"
    }

    private static func num(_ d: Double) -> String {
        guard d.isFinite else { return "0" }
        return d == d.rounded() ? String(Int64(d)) : String(format: "%.3f", d)
    }

    private static func q(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 || u == "<" {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }
}
