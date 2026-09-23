#ifndef VideoGrab_Bridging_Header_h
#define VideoGrab_Bridging_Header_h

// FFmpeg 进程内入口（实现在 app/Hook.m，FFmpeg_main 符号由
// FFmpeg-iOS 包的 fftools 静态库提供）。返回 0 = 成功。
int HookFFmpeg(int argc, char **argv);

#endif /* VideoGrab_Bridging_Header_h */
