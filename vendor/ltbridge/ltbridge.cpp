/* LT Bridge 实现（当前只有探针函数，见 ltbridge.h 的说明）。 */
#include "ltbridge.h"

#include <cstdio>
#include <string>

#include <libtorrent/version.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/info_hash.hpp>
#include <libtorrent/sha1_hash.hpp>
#include <libtorrent/string_view.hpp>

extern "C" {

const char *lt_bridge_version(void)
{
    static char buf[64];
    std::snprintf(buf, sizeof(buf), "%d.%d.%d.%d",
                  LIBTORRENT_VERSION_MAJOR, LIBTORRENT_VERSION_MINOR,
                  LIBTORRENT_VERSION_TINY, LIBTORRENT_VERSION_NUM);
    return buf;
}

int lt_bridge_probe(const char *uri, char *out, int outLen)
{
    if (uri == nullptr || out == nullptr || outLen < 41) return -2;

    lt::error_code ec;
    lt::add_torrent_params atp = lt::parse_magnet_uri(lt::string_view(uri), ec);
    if (ec) return -1;

    std::string hex = atp.info_hashes.get_best().to_string();
    std::snprintf(out, static_cast<std::size_t>(outLen), "%s", hex.c_str());
    return 0;
}

} /* extern "C" */
