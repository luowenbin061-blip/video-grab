/* LT Bridge —— 我们自己写的 libtorrent 桥接层（C 接口，给 Swift 调）。
 *
 * ★ 为什么自己写、不用现成封装：
 *   现成的 iOS 封装（LibTorrent-swift 要 iOS 17 用不了；SwiftyTorrent 没做边下边播）
 *   要么不能用、要么带 GPL v3 授权（会传染到整个 App）。
 *   libtorrent 本体是 BSD-3-Clause，自己写桥接层授权干净。
 *
 * ★ 本文件目前只有两个"探针"函数 —— 目的是证明「我们自己写的桥接层能真的编进
 *   libtorrent 静态库并链上」。功能（session / 添加磁力 / 文件列表 / 下载）后续再加。
 */
#ifndef LTBRIDGE_H
#define LTBRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/* libtorrent 版本号，例 "2.0.10.0" —— 编译期宏，证明头文件可用。 */
const char *lt_bridge_version(void);

/* 干跑一次磁力解析（真调用 libtorrent 的 parse_magnet_uri）。
 * 成功返回 0，并把 v1 info-hash 的十六进制写进 out（需 >= 41 字节）；
 * 解析失败返回 -1；入参不合法返回 -2。 —— 用来证明「库真的链上了」。 */
int lt_bridge_probe(const char *uri, char *out, int outLen);

#ifdef __cplusplus
}
#endif

#endif /* LTBRIDGE_H */
