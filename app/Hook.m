// Hook.m —— FFmpeg 的进程内入口适配层。
//
// 改编自 kewlbear/FFmpeg-iOS-Support 的 Hook.m（LGPL-2.1）。
// 作用：ffmpeg CLI 的 main 在结束时（甚至中途出错时）会调用 exit()
// 直接杀掉整个进程 —— 在 App 里跑等于自杀。这里用 setjmp/longjmp
// 把 exit 拦下来：FFmpeg_exit 被 ffmpeg 内部调用时，longjmp 回到
// HookMain 的 setjmp 点，把退出码当返回值交还给 Swift。
//
// FFmpeg_main / FFprobe_main / nb_input_files 等符号由
// FFmpeg-iOS 包提供的 fftools 静态库给出（链接期解析）。

#import <Foundation/Foundation.h>
#import <setjmp.h>

#define HOOK0 1973

static jmp_buf j;

// ★ v1.0.195（AI 审查 P0）：**全局串行锁** ——
//   合并（MergeQueue）和压缩（CompressQueue）是两条互不知晓的后台队列，
//   以前能同时进 FFmpeg_main：jmp_buf 是全局唯一的，两路一起 setjmp/longjmp
//   全局状态（nb_input_files 等）必互踩 → 轻则输出错乱，重则闪退。
//   有这把锁，谁先拿到谁跑，另一个排队 —— 一把锁堵死整类问题。
static NSLock *hookLock = nil;
static dispatch_once_t hookOnce;
static NSLock *hookLockGet(void) {
    dispatch_once(&hookOnce, ^{ hookLock = [[NSLock alloc] init]; });
    return hookLock;
}

static void resetFFmpeg(void) {
    // ffmpeg 多次运行之间要清掉全局状态，否则第二次跑会带着上一次的文件列表
    extern int nb_input_files;
    extern int nb_output_files;
    extern int nb_filtergraphs;

    nb_input_files = 0;
    nb_output_files = 0;
    nb_filtergraphs = 0;
}

static void resetFFprobe(void) {
    // ★ v1.0.204（代码体检 P3）：这里原来只写着 `FIXME: ...`，看着像"忘了补"。
    //   实测确认：**全工程没有任何地方调用 HookFFprobe**（探参数一律走 AVFoundation，
    //   因为进程内 ffmpeg 拿不到 stdout）—— 所以留空是安全的，不是遗留 bug。
    //   ★ 哪天要启用 HookFFprobe：**先补上 ffprobe 侧需要复位的全局量**，
    //     否则第二次调用可能带着上一次的残留状态（ffmpeg 侧的 nb_input_files 等
    //     就是必须复位的那种，见上面 resetFFmpeg）。
}

void FFmpeg_exit(int code) {
    NSLog(@"%s=%d, will longjmp", __func__, code);
    longjmp(j, code ?: HOOK0);
}

int HookMain(int argc, char **argv, int (*realMain)(int, char **), void (*reset)()) {
    int ret = setjmp(j);
    if (ret) {
        reset();
        return ret == HOOK0 ? 0 : ret;
    }

    ret = realMain(argc, argv);

    reset();

    return ret;
}

int HookFFmpeg(int argc, char **argv) {
    extern int FFmpeg_main(int, char **);
    NSLock *lk = hookLockGet();
    [lk lock];
    int r = HookMain(argc, argv, FFmpeg_main, resetFFmpeg);
    [lk unlock];
    return r;
}

int HookFFprobe(int argc, char **argv) {
    extern int FFprobe_main(int, char **);
    NSLock *lk = hookLockGet();
    [lk lock];
    int r = HookMain(argc, argv, FFprobe_main, resetFFprobe);
    [lk unlock];
    return r;
}
