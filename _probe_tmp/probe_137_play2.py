# -*- coding: utf-8 -*-
"""决定性实验：服务端对 .ts 分片的响应，取决于什么？

已确认：清单 200 / 7745B / 合法 UTF-8 / 103 个分片 / 分片名形如
        苍井樱的打手枪2番号HEYZO-2008（口交）0.ts   ← 相对路径 + 原生中文
失败请求（AVPlayer 的错误日志）：同目录下的 xxx.ts → HTTP 400

要分辨的几种可能：
  A. 分片要 Referer，而 AVPlayer 没把 Referer 带到分片请求上 → 400
  B. 地址本身就错（少了个序号）→ 404/400
  C. 服务端对 Range / HEAD 的行为特殊 → 400
只取 1 个字节（-r 0-0），不下载内容。
"""
import subprocess, os, sys
sys.stdout.reconfigure(encoding='utf-8')

CURL = r'C:/Windows/System32/curl.exe'
UA = ('Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 '
      '(KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1')
DIR = ('https://4x1.ekcvn.com/changpian/m3u8/yazhouwuma/202609/'
       '%E8%8B%8D%E4%BA%95%E6%A8%B1%E7%9A%84%E6%89%93%E6%89%8B%E6%9E%AA2'
       '%E7%95%AA%E5%8F%B7HEYZO-2008%EF%BC%88%E5%8F%A3%E4%BA%A4%EF%BC%89/')
NAME = ('%E8%8B%8D%E4%BA%95%E6%A8%B1%E7%9A%84%E6%89%93%E6%89%8B%E6%9E%AA2'
        '%E7%95%AA%E5%8F%B7HEYZO-2008%EF%BC%88%E5%8F%A3%E4%BA%A4%EF%BC%89')
SITE = 'https://4x1.ekcvn.com/'
PAGE = 'https://4x1.ekcvn.com/'          # 页面 Referer 用站点根代替
HDR = r'E:/自用WIN10-最强没有之一/_probe_tmp/_diag_hdr.txt'


def env():
    e = dict(os.environ)
    for k in ('HTTPS_PROXY', 'HTTP_PROXY', 'https_proxy', 'http_proxy', 'ALL_PROXY', 'all_proxy'):
        e.pop(k, None)
    return e


def probe(label, url, extra=None, t=20, dump=False):
    cmd = [CURL, '-sS', '--ssl-no-revoke', '--noproxy', '*', '-A', UA,
           '-o', os.devnull, '-w', '%{http_code} %{size_download}B ct=%{content_type}']
    if dump:
        cmd = [CURL, '-sS', '--ssl-no-revoke', '--noproxy', '*', '-A', UA,
               '-D', HDR, '-o', os.devnull, '-w', '%{http_code} %{size_download}B']
    cmd += (extra or []) + ['--max-time', str(t), url]
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=t + 8, env=env())
        out = r.stdout.decode('utf-8', 'ignore').strip()
        if dump and os.path.exists(HDR):
            out += '\n      ' + ' | '.join(
                l.strip() for l in open(HDR, encoding='utf-8', errors='ignore')
                if ':' in l and not l.startswith('HTTP/'))
        return out
    except subprocess.TimeoutExpired:
        return 'TIMEOUT'


SEG0 = DIR + NAME + '0.ts'      # 清单里的第一个分片（带序号）
SEGBARE = DIR + NAME + '.ts'    # 截图里那条"失败请求"（不带序号）

print('=== 1) 带序号的分片（清单里真实存在的）===')
print('  无 Referer + Range 0-0  ->', probe('a', SEG0, ['-r', '0-0']))
print('  带 Referer + Range 0-0  ->', probe('b', SEG0, ['-r', '0-0', '-H', 'Referer: ' + PAGE]))
print('  无 Referer 无 Range     ->', probe('c', SEG0, ['-I']))

print('\n=== 2) 不带序号的那条（截图里的失败请求）===')
print('  无 Referer + Range 0-0  ->', probe('d', SEGBARE, ['-r', '0-0']))
print('  带 Referer + Range 0-0  ->', probe('e', SEGBARE, ['-r', '0-0', '-H', 'Referer: ' + PAGE]))

print('\n=== 3) 带 Referer 时的完整响应头（看服务端是谁、有没有防盗链线索）===')
print('  分片带序号 ->', probe('f', SEG0, ['-r', '0-0', '-H', 'Referer: ' + PAGE], dump=True))
print('  分片不带序号 ->', probe('g', SEGBARE, ['-r', '0-0', '-H', 'Referer: ' + PAGE], dump=True))

print('\n=== 4) 清单本身：带/不带 Referer、HEAD ===')
print('  HEAD 无 Referer ->', probe('h', DIR + NAME + '.m3u8', ['-I']))
print('  Range 0-0 无 Referer ->', probe('i', DIR + NAME + '.m3u8', ['-r', '0-0']))
