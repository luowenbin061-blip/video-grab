/* LT Bridge —— 自研 libtorrent 桥接层（C 接口，给 Swift 调）。
 *
 * ★ 为什么自己写、不用现成封装：
 *   现成的 iOS 封装要么用不了（LibTorrent-swift 要 iOS 17），
 *   要么带 GPL v3 授权（会传染到整个 App）。
 *   libtorrent 本体是 BSD-3-Clause，自己写桥接层授权干净。
 *
 * ★ 接口为什么长这样：
 *   · 引擎（session）用不透明指针 `LTEngine` 传，Swift 侧只当一个句柄用；
 *   · 查询状态一律走 **JSON 出参**（`lt_engine_poll` 往调用方给的缓冲区里写一段 JSON）——
 *     这样不用为"文件列表 / 进度 / 名字"各设计一套结构体，加字段也不用改 C 接口；
 *   · Swift 侧每 ~0.5 秒轮询一次 poll，拿到的 JSON 直接解析。
 *
 * ★ 线程：引擎内部有锁，`poll` / `add` / `select` 可以从任意线程调，
 *   但**同一个引擎不要并发调**（Swift 侧串行轮询即可）。
 */
#ifndef LTBRIDGE_H
#define LTBRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/* 引擎句柄（不透明）。 */
typedef void *LTEngine;

/* libtorrent 版本号，例 "2.0.10.0" —— 编译期宏，用来确认库真的链上了。 */
const char *lt_bridge_version(void);

/* 干跑一次磁力解析。成功返回 0 并把 v1 info-hash 的十六进制写进 out（需 >= 41 字节）；
 * 解析失败返回 -1；入参不合法返回 -2。 */
int lt_bridge_probe(const char *uri, char *out, int outLen);

/* ── 引擎生命周期 ── */

/* 建引擎。saveDir 是文件落盘的目录（UTF-8）。返回 NULL = 失败。 */
LTEngine lt_engine_new(const char *saveDir);

/* 销毁引擎（会停掉会话；已下载的文件**不动**）。传 NULL 安全。 */
void lt_engine_free(LTEngine e);

/* ── 任务 ── */

/* 加一条磁力链接，返回 >=0 的任务 id；-1 = 失败（链接不合法/引擎没建起来）。 */
int lt_engine_add_magnet(LTEngine e, const char *uri);

/* 移除一条任务。★ 只从会话里摘掉，**不删已下载的文件**（删文件交给上层决定）。 */
void lt_engine_remove(LTEngine e, int id);

/* 暂停 / 继续。paused 非 0 = 暂停。 */
void lt_engine_pause(LTEngine e, int id, int paused);

/* 只下指定的这些文件（idx = 文件下标数组，从 0 开始）。
 * n <= 0 表示"全都下"。 */
void lt_engine_select_files(LTEngine e, int id, const int *idx, int n);

/* ── 轮询 ── */

/* 把这条任务当前的状态写成一段 JSON，塞进 out（UTF-8，带结尾 '\0'）。
 * outLen 建议 >= 4096（文件多时会更大；写不下会被截断，仍保证以 '\0' 结尾）。
 * 返回写进去的字节数（不含 '\0'）；-1 = 参数不合法；-2 = 找不到这条任务。
 *
 * JSON 形状：
 * {
 *   "hasHandle": true|false,   // 会话里找到这条任务没有（false 且 added=false → 引擎没接受它）
 *   "added": true|false,       // 会话登记成功了没有（靠 add_torrent_alert 判定）
 *   "dhtNodes": 123,           // ★ DHT 路由表里有几个节点 —— 用来区分
 *                              //   "引擎没接进网络"（恒为 0）和"这个种没人做种"（有节点但没 peer）
 *   "err": "",                 // 引擎报的错（加入失败 / torrent_error_alert）
 *   "state": "metadata" | "downloading" | "checking" | "finished" | "error",
 *   "name": "种子名",
 *   "meta": true|false,        // 元数据（文件列表）到手没有
 *   "totalBytes": 123456, "doneBytes": 4567, "rateBytes": 1024,
 *   "peers": 3, "progress": 0.37, "trackers": 11,
 *   "files": [ {"index":0,"path":"a/b.mp4","size":123,"done":0} ]
 * }
 */
int lt_engine_poll(LTEngine e, int id, char *out, int outLen);

#ifdef __cplusplus
}
#endif

#endif /* LTBRIDGE_H */
