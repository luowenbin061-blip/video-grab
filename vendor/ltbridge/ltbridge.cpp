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
    // ★★ alert 队列**必须有人排空**，否则会一直涨到把内存吃光。
    //   我们不去处理具体 alert（错误从 torrent_status 读），这里只把掩码压到最小，
    //   然后在 poll 里 pop_alerts 排空。
    sp.set_int(lt::settings_pack::alert_mask,
               static_cast<int>(lt::alert_category::error));

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
    // ★ 排空 alert 队列（不排会无限涨）。具体内容我们不看。
    if (e->ses) {
        std::vector<lt::alert *> alerts;
        e->ses->pop_alerts(&alerts);
    }

    const Entry *en = findEntry(e, id);
    if (en == nullptr) return -2;

    lt::torrent_handle th;
    if (e->ses) th = e->ses->find_torrent(ih1(en->ih));

    std::string js = "{";
    if (!th.is_valid()) {
        // 刚 add 完还没登记进会话
        js += "\"state\":\"metadata\",\"name\":\"";
        jsonEsc(js, en->name);
        js += "\",\"totalBytes\":0,\"doneBytes\":0,\"rateBytes\":0,\"peers\":0,"
              "\"progress\":0,\"files\":[]}";
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

        char buf[512];
        js += "\"state\":\"";
        js += state;
        js += "\",\"name\":\"";
        jsonEsc(js, st.name.empty() ? en->name : st.name);
        js += "\",\"meta\":" + std::string(hasMeta ? "true" : "false");

        std::snprintf(buf, sizeof(buf),
                      ",\"totalBytes\":%lld,\"doneBytes\":%lld,\"rateBytes\":%lld,"
                      "\"peers\":%d,\"progress\":%.4f",
                      static_cast<long long>(st.total_wanted),
                      static_cast<long long>(st.total_wanted_done),
                      static_cast<long long>(st.download_payload_rate),
                      st.num_peers,
                      static_cast<double>(st.progress));
        js += buf;

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
