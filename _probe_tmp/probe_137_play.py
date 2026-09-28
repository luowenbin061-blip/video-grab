# -*- coding: utf-8 -*-
"""实测那个"播放 400"的地址：清单里到底写了什么、服务端对分片怎么答。

用户给的清单地址（2026-09-28）：
  https://4x1.ekcvn.com/changpian/m3u8/yazhouwuma/202609/<中文>/<中文>.m3u8
失败请求（截图里 AVPlayer 写的）是一个**分片**：
  ...同目录.../<中文>.ts  → HTTP 400

只做只读探测：清单是文本（小），分片只取 1 个字节看状态码。
"""
import subprocess, os, sys
sys.stdout.reconfigure(encoding='utf-8')

CURL = r'C:/Windows/System32/curl.exe'
PROXY = 'http://127.0.0.1:7897'
UA = ('Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 '
      '(KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1')

DIR = ('https://4x1.ekcvn.com/changpian/m3u8/yazhouwuma/202609/'
       '%E8%8B%8D%E4%BA%95%E6%A8%B1%E7%9A%84%E6%89%93%E6%89%8B%E6%9E%AA2'
       '%E7%95%AA%E5%8F%B7HEYZO-2008%EF%BC%88%E5%8F%A3%E4%BA%A4%EF%BC%89/')
NAME = ('%E8%8B%8D%E4%BA%95%E6%A8%B1%E7%9A%84%E6%89%93%E6%89%8B%E6%9E%AA2'
        '%E7%95%AA%E5%8F%B7HEYZO-2008%EF%BC%88%E5%8F%A3%E4%BA%A4%EF%BC%89')
M3U8 = DIR + NAME + '.m3u8'
TS = DIR + NAME + '.ts'
SITE = 'https://4x1.ekcvn.com/'


def env():
    e = dict(os.environ)
    for k in ('HTTPS_PROXY', 'HTTP_PROXY', 'https_proxy', 'http_proxy', 'ALL_PROXY', 'all_proxy'):
        e.pop(k, None)
    e['HTTPS_PROXY'] = PROXY
    e['HTTP_PROXY'] = PROXY
    return e


def curl(url, extra=None, out=None, timeout='25'):
    cmd = [CURL, '-sS', '-L', '--ssl-no-revoke', '-A', UA, '--max-time', timeout]
    cmd += extra or []
    if out:
        cmd += ['-o', out, '-w', '%{http_code} %{size_download}B ct=%{content_type}']
    else:
        cmd += ['-o', os.devnull, '-w', '%{http_code} %{size_download}B ct=%{content_type}']
    cmd.append(url)
    r = subprocess.run(cmd, capture_output=True, timeout=int(timeout) + 10, env=env())
    return (r.stdout.decode('utf-8', 'ignore').strip(), r.stderr.decode('utf-8', 'ignore')[:120])


print('=== 1) 取清单（带 Referer = 站点根）===')
tmp = r'E:/自用WIN10-最强没有之一/_probe_tmp/_diag_playlist.bin'
code, err = curl(M3U8, ['-H', 'Referer: ' + SITE, '-o', tmp,
                        '-w', '%{http_code} %{size_download}B ct=%{content_type}'])
# 上面 out 参数没用上，重来一次拿状态码
print('  ->', curl(M3U8, ['-H', 'Referer: ' + SITE]), err)

raw = io = None
try:
    with open(tmp, 'rb') as f:
        raw = f.read()
except Exception as e:
    raw = b''
print('  落盘字节数:', len(raw))

if raw:
    print('\n--- 原始前 32 字节（十六进制）---')
    print('  ', ' '.join('%02X' % b for b in raw[:32]))
    try:
        u = raw.decode('utf-8')
        print('  严格 UTF-8 解码: 成功')
        enc = 'utf-8'
    except Exception as ex:
        print('  严格 UTF-8 解码: **失败** ->', ex)
        u = None
    if u is None:
        try:
            g = raw.decode('gb18030')
            print('  GB18030 解码: 成功  ← 说明这份清单是 GBK 系')
            u = g
        except Exception as ex:
            print('  GB18030 解码也失败:', ex)
            u = raw.decode('latin-1')
    lines = u.splitlines()
    print('  行数:', len(lines))
    print('\n--- 清单全文（最多 1200 字符）---')
    print(u[:1200])
    print('\n--- 分片行（非 # 开头）---')
    segs = [l for l in lines if l.strip() and not l.strip().startswith('#')]
    for s in segs[:6]:
        print('   raw:', repr(s))
    print('   分片行数:', len(segs))

print('\n=== 2) 分片 .ts 的响应（只取 1 字节）===')
for label, extra in [
    ('带 Referer=站点根', ['-H', 'Referer: ' + SITE, '-r', '0-0']),
    ('不带 Referer    ', ['-r', '0-0']),
    ('HEAD 带 Referer ', ['-I', '-H', 'Referer: ' + SITE]),
]:
    print('  %-18s %s  %s' % (label, curl(TS, extra)[0], curl(TS, extra)[1]))

print('\n=== 3) 清单本身不带 Referer / 不带 Range ===')
print('  不带 Referer ->', curl(M3U8)[0])
print('  带 Referer 且 Range 0-0 ->', curl(M3U8, ['-H', 'Referer: ' + SITE, '-r', '0-0'])[0])
