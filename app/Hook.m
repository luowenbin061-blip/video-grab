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
    // FIXME: ...
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
    return HookMain(argc, argv, FFmpeg_main, resetFFmpeg);
}

int HookFFprobe(int argc, char **argv) {
    extern int FFprobe_main(int, char **);
    return HookMain(argc, argv, FFprobe_main, resetFFprobe);
}
