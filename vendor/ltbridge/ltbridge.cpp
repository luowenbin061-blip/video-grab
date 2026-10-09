/* LT Bridge 实现 —— libtorrent 会话 / 磁力 / 文件列表 / 进度，全部以 JSON 出参。
 *
 * ★★ 这个文件是**在云端编出来的**（本机是 Windows，没有 Xcode），
 *   所以每一处用到的 libtorrent API 都尽量挑"稳"的：
 *   · 不用被废弃的 `session::add_torrent`，走 `async_add_torrent`；
 *   · 不去接 alert 队列里的具体类型（只用 `pop_alerts` 把队列排空，防止它无限涨），
 *     错误信息从 `torrent_status` 里读；
 *   · 索引一律用 libtorrent 2.0 的强类型（`file_index_t`），不用 int 硬塞。
 */
#include "ltbridge.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <fstream>
#include <iterator>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/download_priority.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/file_storage.hpp>
#include <libtorrent/info_hash.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>   // read/write_session_params + dht_state
#include <libtorrent/session_status.hpp>   // ses->status().dht_nodes —— 不 include 会报 incomplete type
#include <libtorrent/span.hpp>             // read_session_params 的入参是 span
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/string_view.hpp>
#include <libtorrent/torrent_flags.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/version.hpp>

namespace {

/* ── JSON 里字符串的转义（名字和路径里真的会有引号/反斜杠） ── */
void jsonEsc(std::string &out, const std::string &s) {
    for (unsigned char c : s) {
        switch (c) {
        case '"':  out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n";  break;
        case '\r': out += "\\r";  break;
        case '\t': out += "\\t";  break;
        default:
            if (c < 0x20) {
                char buf[8];
                std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                out += buf;
            } else {
                out += static_cast<char>(c);   // UTF-8 原样透传
            }
        }
    }
}

struct Entry {
    int id = 0;
    lt::info_hash_t ih;
    std::string name;       // 磁力里的 dn=（元数据到手后会换成真名）
    bool added = false;     // 会话里登记成功没有（靠 add_torrent_alert 判定）
    std::string err;        // 引擎报的错（add 失败 / torrent_error_alert）
};

/// 磁力链接里自带的 tracker 经常全是死的 —— 再补一份公共 tracker。
/// ★ v1.0.249：从 11 条扩到 27 条（新增的来自社区维护的活跃列表 ngosang/trackerslist）。
///   重复 announce 没坏处，死掉的会被自动淘汰；多条并发的意义是"广撒网捞 peer"。
/// ★ 里面 https 的两条要靠协议加密支持（v1.0.249 起 libtorrent 按加密支持编译）。
const char *kPublicTrackers[] = {
    // —— 老一批（v1.0.248 就有，保留）——
    "udp://tracker.opentrackr.org:1337/announce",
    "udp://open.tracker.cl:1337/announce",
    "udp://open.demonii.com:1337/announce",
    "udp://tracker.openbittorrent.com:6969/announce",
    "udp://exodus.desync.com:6969/announce",
    "udp://tracker.torrent.eu.org:451/announce",
    "udp://open.stealth.si:80/announce",
    "udp://tracker.moeking.me:6969/announce",
    "udp://explodie.org:6969/announce",
    "udp://tracker1.bt.moack.co.kr:80/announce",
    "http://tracker.openbittorrent.com:80/announce",
    // —— v1.0.249 新增（ngosang/trackerslist 的 best 榜）——
    "udp://tracker.skynetcloud.site:6969/announce",
    "udp://tracker.qu.ax:6969/announce",
    "udp://tracker.corpscorp.online:80/announce",
    "udp://tracker.bittor.pw:1337/announce",
    "udp://tracker-udp.gbitt.info:80/announce",
    "udp://tracker.nyaa.vc:6969/announce",
    "udp://tracker.ducks.party:1984/announce",
    "udp://tracker2.dler.org:80/announce",
    "udp://tracker.gmi.gd:6969/announce",
    "udp://tracker.dler.org:6969/announce",
    "http://tracker.dler.com:6969/announce",
    "udp://retracker01-msk-virt.corbina.net:80/announce",
    "http://tracker.renfei.net:8080/announce",
    "udp://tracker.farted.net:6969/announce",
    // —— https（协议加密开回来之后才用得上 TLS tracker）——
    "https://tracker.tamersunion.org:443/announce",
    "https://tracker.gbitt.info:443/announce",
};

struct EngineImpl {
    std::unique_ptr<lt::session> ses;
    std::string savePath;
    std::vector<Entry> entries;
    int nextId = 1;
    std::mutex mu;
    /// ★ v1.0.249：上次把 DHT 状态存盘的时刻（poll 里节流用）。
    std::time_t lastStateSave = 0;
};

EngineImpl *asImpl(LTEngine e) { return static_cast<EngineImpl *>(e); }

/// ★ v1.0.249：把 DHT 路由表存盘（原子写：先 .tmp、成功改名才算数）。
///   目的：下次启动**热启动** —— 直接回到上次的网络位置，而不是从 5 个引导节点从零爬
///   （那几十秒到几分钟里基本找不到任何 peer，是「找不到资源」的一大来源）。
///   · 调用方必须已持 e->mu（poll / free 两处都在锁内调）；
///   · dht_nodes <= 0 时不存 —— 免得拿一份「空路由表」把磁盘上的好状态覆盖掉；
///   · 默认节流 120 秒一次；force=true（关闭引擎前）跳过节流。
void saveDhtStateLocked(EngineImpl *e, bool force) {
    if (e == nullptr || !e->ses || e->savePath.empty()) return;
    if (e->ses->status().dht_nodes <= 0) return;
    const std::time_t now = std::time(nullptr);
    if (!force && now - e->lastStateSave < 120) return;

    const lt::session_params st = e->ses->session_state();
    const std::vector<char> buf = lt::write_session_params_buf(st);
    if (buf.empty()) return;

    const std::string tmpPath = e->savePath + "/dht_state.bin.tmp";
    const std::string finPath = e->savePath + "/dht_state.bin";
    std::ofstream out(tmpPath, std::ios::binary | std::ios::trunc);
    if (!out) return;
    out.write(buf.data(), static_cast<std::streamsize>(buf.size()));
    out.close();
    if (!out.good()) return;                 // 写坏了就不改名 —— 磁盘上旧的还在
    std::rename(tmpPath.c_str(), finPath.c_str());
    e->lastStateSave = now;
}

/* ★ `session::find_torrent` 只认老的 `sha1_hash`（v1 哈希），
 *   2.0.10 里**没有** `info_hash_t` 的重载 —— 实测编译报
 *   「no viable conversion from 'lt::info_hash_t' to 'const sha1_hash'」。
 *   磁力链接绝大多数是 v1（btih），`get_best()` 正好给出 v1 那一个。
 */
lt::sha1_hash ih1(const lt::info_hash_t &ih) { return ih.get_best(); }

const Entry *findEntry(const EngineImpl *e, int id) {
    for (const auto &x : e->entries) {
        if (x.id == id) return &x;
    }
    return nullptr;
}

/// ★ v1.0.250 边下边播：把「文件内的字节区间」映射成「整个种子里的 piece 区间」。
///   返回 false = 参数越界 / 没元数据。first/last 是**含端**下标，已夹到合法范围。
bool pieceRangeFor(const lt::torrent_info &ti, int fileIndex,
                   long long off, long long len, int &first, int &last) {
    const lt::file_storage &fs = ti.files();
    if (fileIndex < 0 || fileIndex >= fs.num_files()) return false;
    const lt::file_index_t fi(fileIndex);
    const std::int64_t fsize = fs.file_size(fi);
    if (off < 0 || len <= 0 || off >= fsize) return false;
    const std::int64_t foff = fs.file_offset(fi);
    const std::int64_t b0 = foff + off;
    const std::int64_t b1 = foff + std::min<std::int64_t>(off + len, fsize) - 1;
    const int pieceLen = ti.piece_length();
    if (pieceLen <= 0) return false;
    first = static_cast<int>(b0 / pieceLen);
    last = static_cast<int>(b1 / pieceLen);
    const int np = ti.num_pieces();
    if (first < 0) first = 0;
    if (last >= np) last = np - 1;
    return first <= last;
}

}  // namespace

extern "C" {

const char *lt_bridge_version(void) {
    static char buf[64];
    std::snprintf(buf, sizeof(buf), "%d.%d.%d.%d",
                  LIBTORRENT_VERSION_MAJOR, LIBTORRENT_VERSION_MINOR,
                  LIBTORRENT_VERSION_TINY, LIBTORRENT_VERSION_NUM);
    return buf;
}

int lt_bridge_probe(const char *uri, char *out, int outLen) {
    if (uri == nullptr || out == nullptr || outLen < 41) return -2;
    lt::error_code ec;
    lt::add_torrent_params atp = lt::parse_magnet_uri(lt::string_view(uri), ec);
    if (ec) return -1;
    std::string hex = atp.info_hashes.get_best().to_string();
    std::snprintf(out, static_cast<std::size_t>(outLen), "%s", hex.c_str());
    return 0;
}

LTEngine lt_engine_new(const char *saveDir) {
    auto *e = new (std::nothrow) EngineImpl();
    if (e == nullptr) return nullptr;
    if (saveDir != nullptr) e->savePath = saveDir;

    lt::settings_pack sp;
    sp.set_bool(lt::settings_pack::enable_dht, true);
    sp.set_bool(lt::settings_pack::enable_lsd, true);
    sp.set_bool(lt::settings_pack::enable_upnp, true);
    sp.set_bool(lt::settings_pack::enable_natpmp, true);
    sp.set_str(lt::settings_pack::user_agent, "VideoGrab/1.0");

    // ★★ v1.0.249：**协议加密开满**（pe_enabled = 优先加密、也接受明文）。
    //   相当一部分做种服务器（seedbox / PT 圈）只接受加密握手 ——
    //   以前库是按 encryption=OFF 编的，这批 peer 直接就握不上手，
    //   同伴池少掉一块（表现为「找不到资源 / 拿不到文件列表」）。
    //   pe_enabled 的语义：能加密就加密，对方不支持就回退明文 —— 最兼容的一档。
    sp.set_int(lt::settings_pack::out_enc_policy,
               static_cast<int>(lt::settings_pack::pe_enabled));
    sp.set_int(lt::settings_pack::in_enc_policy,
               static_cast<int>(lt::settings_pack::pe_enabled));
    // ★ 监听端口用 2.0 的写法（listen_interfaces）。原来那个 listen_on() 已经废弃。
    sp.set_str(lt::settings_pack::listen_interfaces, "0.0.0.0:6881,[::]:6881");

    // ★★ v1.0.248：**显式给 DHT 引导节点**。
    //   实测（用户真机）：磁力加进去以后一直「已连上 0 个」，几十秒都不变 ——
    //   那不是"没人做种"，是**引擎根本没接进 DHT 网络**。
    //   只把 enable_dht 打开并不保证有引导节点（拿不到 DHT 路由表 = 找不到任何 peer）。
    //   这几个是各客户端通用的公共引导节点，写死在这儿最稳。
    sp.set_str(lt::settings_pack::dht_bootstrap_nodes,
               "router.bittorrent.com:6881,router.utorrent.com:6881,"
               "dht.libtorrent.org:25401,dht.transmissionbt.com:6881,"
               "dht.aelitis.com:6881");

    // ★★ 磁力链接里带的 tracker 经常全是死的。客户端通行的做法是**再补一份公共 tracker**，
    //   并且**一次向所有 tracker / 所有 tier 同时 announce**（不然要等前一个超时才轮到下一个，
    //   表现为"几十秒一个 peer 都没有"）。
    sp.set_bool(lt::settings_pack::announce_to_all_trackers, true);
    sp.set_bool(lt::settings_pack::announce_to_all_tiers, true);
    // 主动外连的速度上限（默认偏保守，冷门种子要等很久才凑够 peer）
    sp.set_int(lt::settings_pack::connection_speed, 100);

    // ★★ alert 队列**必须有人排空**，否则会一直涨到把内存吃光。
    //   v1.0.248：掩码放宽到 error + status —— 我们要从 `add_torrent_alert` /
    //   `torrent_error_alert` 里读「这条任务到底登记上没有 / 报没报错」。
    sp.set_int(lt::settings_pack::alert_mask,
               static_cast<int>(lt::alert_category::error)
               | static_cast<int>(lt::alert_category::status));

    lt::session_params params;
    params.settings = sp;

    // ★★ v1.0.249：把上次存下来的 **DHT 路由表**捞回来（有的话）。
    //   没有它：每次冷启动都要从 5 个引导节点从零爬，头一两分钟基本「一个节点都连不上」；
    //   有它：直接回到上次的网络位置 = 热启动。
    //   （文件坏了 / 版本不兼容 → 当没有，照常冷启动，不报错。）
    if (!e->savePath.empty()) {
        std::ifstream f(e->savePath + "/dht_state.bin", std::ios::binary);
        if (f) {
            std::vector<char> buf((std::istreambuf_iterator<char>(f)),
                                  std::istreambuf_iterator<char>());
            if (!buf.empty()) {
                try {
                    lt::session_params loaded =
                        lt::read_session_params(lt::span<char const>(buf));
                    params.dht_state = std::move(loaded.dht_state);
                } catch (...) {
                    // 文件坏了 → 照常冷启动
                }
            }
        }
    }

    e->ses.reset(new (std::nothrow) lt::session(params));
    if (!e->ses) {
        delete e;
        return nullptr;
    }
    return static_cast<LTEngine>(e);
}

void lt_engine_free(LTEngine h) {
    EngineImpl *e = asImpl(h);
    if (e == nullptr) return;
    {
        std::lock_guard<std::mutex> lock(e->mu);
        if (e->ses) {
            saveDhtStateLocked(e, true); // 关闭前最后存一次 DHT 状态（force）
            e->ses->pause();             // 先把会话停掉，再析构（析构会等线程收尾）
        }
    }
    delete e;
}

int lt_engine_add_magnet(LTEngine h, const char *uri) {
    EngineImpl *e = asImpl(h);
    if (e == nullptr || uri == nullptr || !e->ses) return -1;

    lt::error_code ec;
    lt::add_torrent_params atp = lt::parse_magnet_uri(lt::string_view(uri), ec);
    if (ec) return -1;
    atp.save_path = e->savePath;
    // ★ 补公共 tracker：磁力里自带的那些经常整批都是死的，光靠 DHT 有时候会很慢。
    for (const char *t : kPublicTrackers) atp.trackers.emplace_back(t);

    std::lock_guard<std::mutex> lock(e->mu);
    // ★ v1.0.249：同一个 info-hash 已经在会话里（比如又粘了一次同一条链接）→
    //   先把旧的移掉。不然 libtorrent 会把重复添加**静默忽略**，
    //   界面看起来像「卡住不动」。
    {
        lt::torrent_handle old = e->ses->find_torrent(ih1(atp.info_hashes));
        if (old.is_valid()) e->ses->remove_torrent(old);
    }
    int id = e->nextId++;
    Entry en;
    en.id = id;
    en.ih = atp.info_hashes;
    en.name = atp.name;
    e->entries.push_back(en);
    e->ses->async_add_torrent(std::move(atp));
    return id;
}

void lt_engine_remove(LTEngine h, int id) {
    EngineImpl *e = asImpl(h);
    if (e == nullptr || !e->ses) return;
    std::lock_guard<std::mutex> lock(e->mu);
    for (std::size_t i = 0; i < e->entries.size(); ++i) {
        if (e->entries[i].id == id) {
            lt::torrent_handle th = e->ses->find_torrent(ih1(e->entries[i].ih));
            if (th.is_valid()) {
                // ★ 不删文件（`delete_files` 保持默认 false）—— 删不删由上层说了算
                e->ses->remove_torrent(th);
            }
            e->entries.erase(e->entries.begin() + static_cast<long>(i));
            return;
        }
    }
}

void lt_engine_pause(LTEngine h, int id, int paused) {
    EngineImpl *e = asImpl(h);
    if (e == nullptr || !e->ses) return;
    std::lock_guard<std::mutex> lock(e->mu);
    const Entry *en = findEntry(e, id);
    if (en == nullptr) return;
    lt::torrent_handle th = e->ses->find_torrent(ih1(en->ih));
    if (!th.is_valid()) return;
    if (paused) {
        th.unset_flags(lt::torrent_flags::auto_managed);
        th.pause();
    } else {
        th.set_flags(lt::torrent_flags::auto_managed);
        th.resume();
    }
}

void lt_engine_select_files(LTEngine h, int id, const int *idx, int n) {
    EngineImpl *e = asImpl(h);
    if (e == nullptr || !e->ses) return;
    std::lock_guard<std::mutex> lock(e->mu);
    const Entry *en = findEntry(e, id);
    if (en == nullptr) return;
    lt::torrent_handle th = e->ses->find_torrent(ih1(en->ih));
    if (!th.is_valid()) return;
    auto ti = th.torrent_file();
    if (!ti) return;                       // 元数据还没到手，选不了

    const int total = ti->files().num_files();
    std::vector<lt::download_priority_t> pri(
        static_cast<std::size_t>(total), lt::dont_download);
    if (n <= 0) {
        // 全下
        for (int i = 0; i < total; ++i) {
            pri[static_cast<std::size_t>(i)] = lt::default_priority;
        }
    } else {
        for (int k = 0; k < n; ++k) {
            const int i = idx[k];
            if (i >= 0 && i < total) {
                pri[static_cast<std::size_t>(i)] = lt::default_priority;
            }
        }
    }
    th.prioritize_files(pri);
}

void lt_engine_select_none(LTEngine h, int id) {
    EngineImpl *e = asImpl(h);
    if (e == nullptr || !e->ses) return;
    std::lock_guard<std::mutex> lock(e->mu);
    const Entry *en = findEntry(e, id);
    if (en == nullptr) return;
    lt::torrent_handle th = e->ses->find_torrent(ih1(en->ih));
    if (!th.is_valid()) return;
    auto ti = th.torrent_file();
    if (!ti) return;                       // 元数据还没到手，没得选
    const int total = ti->files().num_files();
    const std::vector<lt::download_priority_t> pri(
        static_cast<std::size_t>(total), lt::dont_download);
    th.prioritize_files(pri);
}

/* ── v1.0.250 边下边播 ── */

int lt_engine_stream_prefer(LTEngine h, int id, int fileIndex, long long off, long long len) {
    EngineImpl *e = asImpl(h);
    if (e == nullptr || !e->ses) return -1;
    std::lock_guard<std::mutex> lock(e->mu);
    const Entry *en = findEntry(e, id);
    if (en == nullptr) return -1;
    lt::torrent_handle th = e->ses->find_torrent(ih1(en->ih));
    if (!th.is_valid()) return -1;
    auto ti = th.torrent_file();
    if (!ti) return -1;

    int first = 0, last = 0;
    if (!pieceRangeFor(*ti, fileIndex, off, len, first, last)) return -2;

    int n = 0;
    for (int p = first; p <= last; ++p) {
        const lt::piece_index_t pi(p);
        // 保险：这个 piece 若被设成「不下」（文件没勾选），先提回默认 —— 不然 deadline 也没用
        if (th.piece_priority(pi) == lt::dont_download) {
            th.piece_priority(pi, lt::default_priority);
        }
        // 3 秒内希望到手；到期后自动回落普通优先级（不用事后清理）
        th.set_piece_deadline(pi, 3000);
        ++n;
    }
    return n;
}

long long lt_engine_stream_prefix(LTEngine h, int id, int fileIndex, long long off, long long want) {
    EngineImpl *e = asImpl(h);
    if (e == nullptr || !e->ses) return -1;
    std::lock_guard<std::mutex> lock(e->mu);
    const Entry *en = findEntry(e, id);
    if (en == nullptr) return -1;
    lt::torrent_handle th = e->ses->find_torrent(ih1(en->ih));
    if (!th.is_valid()) return -1;
    auto ti = th.torrent_file();
    if (!ti) return -1;
    if (want <= 0) return 0;

    const lt::file_storage &fs = ti->files();
    if (fileIndex < 0 || fileIndex >= fs.num_files()) return -1;
    const lt::file_index_t fi(fileIndex);
    const std::int64_t fsize = fs.file_size(fi);
    if (off < 0 || off >= fsize) return -1;

    const std::int64_t foff = fs.file_offset(fi);
    const std::int64_t from = foff + off;
    const std::int64_t to = foff + std::min<std::int64_t>(off + want, fsize);  // 不含端
    const int pieceLen = ti->piece_length();
    if (pieceLen <= 0) return -1;
    const int np = ti->num_pieces();

    std::int64_t covered = 0;
    int p = static_cast<int>(from / pieceLen);
    while (p < np) {
        if (!th.have_piece(lt::piece_index_t(p))) break;
        const std::int64_t pEnd = static_cast<std::int64_t>(p + 1) * pieceLen;
        const std::int64_t segEnd = std::min(pEnd, to);
        if (segEnd <= from) { ++p; continue; }
        covered = segEnd - from;
        if (segEnd >= to) break;           // 想要的都齐了
        ++p;
    }
    return covered < 0 ? 0 : covered;
}

int lt_engine_poll(LTEngine h, int id, char *out, int outLen) {
    EngineImpl *e = asImpl(h);
    if (e == nullptr || out == nullptr || outLen < 64) return -1;

    std::lock_guard<std::mutex> lock(e->mu);
    // ★ 排空 alert 队列（不排会无限涨），顺便把「登记成功没有 / 报错没有」记到任务上。
    //   ★★ v1.0.248：以前只排空、不看内容 → 任务要是压根没登记上，
    //   界面就只会一直显示"正在找资源…0 个"，完全看不出是引擎的问题。
    if (e->ses) {
        std::vector<lt::alert *> alerts;
        e->ses->pop_alerts(&alerts);
        for (lt::alert *a : alerts) {
            if (auto *at = lt::alert_cast<lt::add_torrent_alert>(a)) {
                const lt::sha1_hash h = ih1(at->params.info_hashes);
                for (auto &en : e->entries) {
                    if (ih1(en.ih) == h) {
                        if (at->error) {
                            en.err = std::string("加入任务失败：") + at->error.message();
                        } else {
                            en.added = true;
                        }
                    }
                }
            } else if (auto *te = lt::alert_cast<lt::torrent_error_alert>(a)) {
                const lt::sha1_hash h = ih1(te->handle.info_hashes());
                for (auto &en : e->entries) {
                    if (ih1(en.ih) == h) en.err = te->error.message();
                }
            }
        }
    }

    const Entry *en = findEntry(e, id);
    if (en == nullptr) return -2;

    lt::torrent_handle th;
    if (e->ses) th = e->ses->find_torrent(ih1(en->ih));

    // ★★ v1.0.248：把「引擎接受这条任务没有 / 有没有报错 / DHT 连上几个节点」
    //   一起报上去。用户实测那次"一直已连上 0 个"，界面上分不出是
    //   "引擎没接进网络" 还是 "这个种没人做种" —— 有这几个字段就能分辨。
    char buf[512];
    const int dhtNodes = e->ses ? e->ses->status().dht_nodes : 0;

    // ★★ v1.0.249：每 120 秒把 DHT 状态存一次盘（让下次启动热启动）。
    //   放在 poll 里做是图省事：这里每 0.5 秒被叫一次，又不依赖 Swift 的时机
    //   （App 随时可能被系统挂起/杀掉，靠「退出时保存」根本不可靠）。
    saveDhtStateLocked(e, false);

    std::string js = "{";
    js += "\"hasHandle\":";
    js += th.is_valid() ? "true" : "false";
    js += ",\"added\":";
    js += en->added ? "true" : "false";
    js += ",\"dhtNodes\":";
    std::snprintf(buf, sizeof(buf), "%d,\"err\":\"", dhtNodes);
    js += buf;
    jsonEsc(js, en->err);
    js += "\"";

    if (!th.is_valid()) {
        // 还没在会话里找到（刚 add 完的瞬间，或者压根没登记上 —— 看 added 字段）
        js += ",\"state\":\"metadata\",\"name\":\"";
        jsonEsc(js, en->name);
        js += "\",\"meta\":false,\"totalBytes\":0,\"doneBytes\":0,\"rateBytes\":0,"
              "\"peers\":0,\"progress\":0,\"trackers\":0,\"files\":[]}";
    } else {
        const lt::torrent_status st = th.status();
        const bool hasMeta = st.has_metadata;

        const char *state = "downloading";
        switch (st.state) {
        case lt::torrent_status::queued_for_checking:
        case lt::torrent_status::checking_files:
        case lt::torrent_status::checking_resume_data:
        case lt::torrent_status::allocating:
            state = "checking";
            break;
        case lt::torrent_status::downloading_metadata:
            state = "metadata";
            break;
        case lt::torrent_status::downloading:
            state = "downloading";
            break;
        case lt::torrent_status::finished:
        case lt::torrent_status::seeding:
            state = "finished";
            break;
        default:
            state = "downloading";
            break;
        }

        char buf2[512];
        js += ",\"state\":\"";
        js += state;
        js += "\",\"name\":\"";
        jsonEsc(js, st.name.empty() ? en->name : st.name);
        js += "\",\"meta\":" + std::string(hasMeta ? "true" : "false");

        std::snprintf(buf2, sizeof(buf2),
                      ",\"totalBytes\":%lld,\"doneBytes\":%lld,\"rateBytes\":%lld,"
                      "\"peers\":%d,\"progress\":%.4f,\"trackers\":%d",
                      static_cast<long long>(st.total_wanted),
                      static_cast<long long>(st.total_wanted_done),
                      static_cast<long long>(st.download_payload_rate),
                      st.num_peers,
                      static_cast<double>(st.progress),
                      static_cast<int>(th.trackers().size()));
        js += buf2;

        // ★ v1.0.250：把「暂停没有」报上来 —— 界面按钮要跟着它切「暂停 / 继续」。
        if (th.flags() & lt::torrent_flags::paused) {
            js += ",\"paused\":true";
        } else {
            js += ",\"paused\":false";
        }

        js += ",\"files\":[";
        if (hasMeta) {
            auto ti = th.torrent_file();
            if (ti) {
                const lt::file_storage &fs = ti->files();
                const int total = fs.num_files();
                std::vector<std::int64_t> fp;
                if (total > 0) fp = th.file_progress();
                for (int i = 0; i < total; ++i) {
                    const lt::file_index_t fi(i);
                    const std::int64_t sz = fs.file_size(fi);
                    std::int64_t done = 0;
                    if (static_cast<std::size_t>(i) < fp.size()) {
                        done = fp[static_cast<std::size_t>(i)];
                    }
                    if (i > 0) js += ",";
                    js += "{\"index\":";
                    std::snprintf(buf, sizeof(buf), "%d", i);
                    js += buf;
                    js += ",\"path\":\"";
                    jsonEsc(js, fs.file_path(fi));
                    js += "\",\"size\":";
                    std::snprintf(buf, sizeof(buf), "%lld", static_cast<long long>(sz));
                    js += buf;
                    js += ",\"done\":";
                    std::snprintf(buf, sizeof(buf), "%lld", static_cast<long long>(done));
                    js += buf;
                    js += "}";
                }
            }
        }
        js += "]}";
    }

    // 写进调用方的缓冲区（截断也要保证 '\0' 结尾）
    const std::size_t cap = static_cast<std::size_t>(outLen);
    const std::size_t n = js.size() < cap - 1 ? js.size() : cap - 1;
    std::memcpy(out, js.data(), n);
    out[n] = '\0';
    return static_cast<int>(n);
}

}  /* extern "C" */
