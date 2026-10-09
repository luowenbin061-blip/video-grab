#ifndef VideoGrab_Bridging_Header_h
#define VideoGrab_Bridging_Header_h

// FFmpeg 进程内入口（实现在 app/Hook.m，FFmpeg_main 符号由
// FFmpeg-iOS 包的 fftools 静态库提供）。返回 0 = 成功。
int HookFFmpeg(int argc, char **argv);

// ★ v1.0.247 磁力（BT）引擎：自研的 libtorrent 桥接层。
// 实现在 vendor/ltbridge/ltbridge.cpp，编进 vendor/libtorrent/lib/libvideoGrabLT.a
// （那条流水线见 .github/workflows/build-libtorrent.yml）。
// ★ 这个头是**纯 C**，不含任何 libtorrent / boost 内容 —— 故意如此，
//   这样 App 侧编译完全不需要 libtorrent 那套头文件。
#include "ltbridge.h"

#endif /* VideoGrab_Bridging_Header_h */
