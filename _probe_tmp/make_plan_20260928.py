# -*- coding: utf-8 -*-
"""把审查简报包成 5 道"独立任务"（同一份内容、5 个锚行 ID），每家一条。
   顺便写一份临时 .env（CDP_PORT=19222）—— 9222 被宿主 IDE 占着，用它会秒失败。
"""
import io, json, os, sys
sys.stdout.reconfigure(encoding='utf-8')

BRIEF = r'E:/自用WIN10-最强没有之一/VideoGrab/_五家审查简报-内置播放器与下载器-20260928.md'
PLAN = r'E:/自用WIN10-最强没有之一/_probe_tmp/plan_review_20260928.json'
ENV_SRC = r'E:/自用WIN10-最强没有之一/AgentChat/.env'
ENV_TMP = r'E:/自用WIN10-最强没有之一/_probe_tmp/ac_review.env'

brief = io.open(BRIEF, encoding='utf-8').read()
print('简报 %d 字符' % len(brief))

REQ = """
────────────────────────────────────────
【回答要求】（这几条请务必遵守）

1. 按上面「4. 请重点回答」里的编号**逐条**回答：A1、A2、A3、A4、B1、B2、B3、B4、X1 ——
   **一条都不许跳**；确实答不了的，就写"这条我判断不了，因为……"。
2. **用简体中文回答。**
3. **直接给结论，不要复述或回显题目/背景/要求清单**（重复一遍题目对我没有任何价值）。
4. 每条结论都要**落到具体代码**：指出文件名 + 那一段里的关键行（例如
   "PlaylistRelay 里 `guard let scheme = remote.scheme` 这一行"）。
   只给"建议加错误处理"这种方向性的话，对我没用。
5. **不确定就明说不确定**，不要为了凑数编造。我宁可看到"这条我没把握"，也不要错的结论。
6. 回答的**第一行**必须单独一行写：`[ANSWER {ID}]`
"""

PROVIDERS = [
    ('R1', 'qwen'),
    ('R2', 'minimax'),
    ('R3', 'mimo'),
    ('R4', 'deepseek'),
    ('R5', 'doubao'),
]

subtasks = []
for i, (rid, prov) in enumerate(PROVIDERS, start=1):
    prompt = ('【Task %d】[ANSWER %s]\n\n' % (i, rid)) + brief + REQ.replace('{ID}', rid)
    subtasks.append({
        'id': rid.lower(),
        'primary': prov,
        'depends_on': [],
        'questions': [rid],
        'prompt': prompt,
    })

plan = {
    # claude/gemini/chatgpt/kimi/chatglm 在本机不可用或会被静默 coerce，一律排除
    'exclude': ['claude', 'gemini', 'chatgpt', 'kimi', 'chatglm'],
    'subtasks': subtasks,
}

io.open(PLAN, 'w', encoding='utf-8').write(json.dumps(plan, ensure_ascii=False, indent=1))
print('计划已写：%s（%d 道，%d 字符）' % (PLAN, len(subtasks), len(json.dumps(plan, ensure_ascii=False))))

# ── 临时 .env：只改 CDP_PORT 和 LOG_FILE ─────────────────────────────
src = io.open(ENV_SRC, encoding='utf-8').read()
out = []
for line in src.split('\n'):
    if line.startswith('CDP_PORT='):
        out.append('CDP_PORT=19222')
    elif line.startswith('LOG_FILE='):
        out.append('LOG_FILE=E:\\自用WIN10-最强没有之一\\_probe_tmp\\ac_review_chrome.log')
    else:
        out.append(line)
io.open(ENV_TMP, 'w', encoding='utf-8').write('\n'.join(out))
print('临时 env 已写：%s' % ENV_TMP)
for l in io.open(ENV_TMP, encoding='utf-8').read().split('\n'):
    if l.strip() and not l.strip().startswith('#'):
        print('   ', l.strip()[:100])
