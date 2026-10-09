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

#include <cstdint>
#include <cstdio>
#include <cstring>
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
#include <libtorrent/session_params.hpp>
#include <libtorrent/session_status.hpp>   // ses->status().dht_nodes —— 不 include 会报 incomplete type
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
/// ★ 这份单子是各客户端通用的那几条；重复 announce 没坏处，死掉的会被自动淘汰。
const char *kPublicTrackers[] = {
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
};

struct EngineImpl {
    std::unique_ptr<lt::session> ses;
    std::string savePath;
    std::vector<Entry> entries;
    int nextId = 1;
    std::mutex mu;
};

EngineImpl *asImpl(LTEngine e) { return static_cast<EngineImpl *>(e); }

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
        if (e->ses) e->ses->pause();     // 先把会话停掉，再析构（析构会等线程收尾）
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
