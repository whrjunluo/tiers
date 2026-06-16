#!/usr/bin/env python3
"""dev-workflow 进化检测 —— UserPromptSubmit hook。

判级纠正发生在「我输出判级 → 用户下一条反驳」之间，Stop hook 看不到，
故挂在 UserPromptSubmit：用户提交消息时回看上一轮，若本条疑似纠正判级，
向上下文注入一条提醒，让我用 learnings.sh 记录。检测失败一律静默退出，绝不打断。
"""
import sys, json, re

CORRECTION_RE = re.compile(r"(不对|不是|应该|错了|纠正|改成|其实是|太重|太轻|过度|降级|升级到)")
LEVEL_RE = re.compile(r"[Ll][0-4]")
JUDGMENT_RE = re.compile(r"级别\s*[=＝]")


def prompt_mentions_level_correction(prompt):
    return all((CORRECTION_RE.search(prompt), LEVEL_RE.search(prompt)))


def assistant_text_from_record(record):
    msg = record.get("message", {})
    if msg.get("role") != "assistant":
        return ""

    content = msg.get("content", "")
    if isinstance(content, list):
        return " ".join(c.get("text", "") for c in content if isinstance(c, dict))
    return str(content)


def transcript_has_recent_judgment(transcript_path, max_lines=12):
    try:
        with open(transcript_path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except Exception:
        return False

    for line in lines[-max_lines:]:
        try:
            text = assistant_text_from_record(json.loads(line))
        except Exception:
            continue
        if JUDGMENT_RE.search(text):
            return True
    return False


def build_reminder():
    return (
        "📈 [dev-workflow 进化检测] 用户本轮疑似纠正了你上一轮的判级。"
        "处理完这条请求后，记得运行 "
        "`<plugin-root>/scripts/learnings.sh add <category> <project> \"<note>\"` "
        "把这次纠正记进全局 LEARNINGS.md（category 必须取自词表，note 写清「我原判 Lx → 应为 Ly，因为…」）。"
    )

def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    prompt = data.get("prompt", "")
    tpath = data.get("transcript_path", "")

    if not prompt_mentions_level_correction(prompt):
        return

    # 上一轮我是否真的输出过判级行（避免误报）
    if not transcript_has_recent_judgment(tpath):
        return

    # UserPromptSubmit：stdout 直接注入上下文
    print(build_reminder())

if __name__ == "__main__":
    main()
