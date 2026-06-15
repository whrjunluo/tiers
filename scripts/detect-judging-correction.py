#!/usr/bin/env python3
"""dev-workflow 进化检测 —— UserPromptSubmit hook。

判级纠正发生在「我输出判级 → 用户下一条反驳」之间，Stop hook 看不到，
故挂在 UserPromptSubmit：用户提交消息时回看上一轮，若本条疑似纠正判级，
向上下文注入一条提醒，让我用 learnings.sh 记录。检测失败一律静默退出，绝不打断。
"""
import sys, json, re

def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    prompt = data.get("prompt", "") or ""
    tpath = data.get("transcript_path", "") or ""

    # 本条用户消息是否带「纠正 + 级别」信号
    neg = re.search(r"(不对|不是|应该|错了|纠正|改成|其实是|太重|太轻|过度|降级|升级到)", prompt)
    lvl = re.search(r"[Ll][0-4]", prompt)
    if not (neg and lvl):
        return

    # 上一轮我是否真的输出过判级行（避免误报）
    had_judge = False
    try:
        with open(tpath, "r", encoding="utf-8") as f:
            lines = f.readlines()
        for ln in lines[-12:]:
            try:
                obj = json.loads(ln)
            except Exception:
                continue
            msg = obj.get("message", {}) or {}
            if msg.get("role") != "assistant":
                continue
            content = msg.get("content", "")
            if isinstance(content, list):
                text = " ".join(c.get("text", "") for c in content if isinstance(c, dict))
            else:
                text = str(content)
            if "级别" in text and ("=" in text or "＝" in text):
                had_judge = True
    except Exception:
        return
    if not had_judge:
        return

    # UserPromptSubmit：stdout 直接注入上下文
    print(
        "📈 [dev-workflow 进化检测] 用户本轮疑似纠正了你上一轮的判级。"
        "处理完这条请求后，记得运行 "
        "`${CLAUDE_PLUGIN_ROOT}/scripts/learnings.sh add <category> <project> \"<note>\"` "
        "把这次纠正记进全局 LEARNINGS.md（category 必须取自词表，note 写清「我原判 Lx → 应为 Ly，因为…」）。"
    )

if __name__ == "__main__":
    main()
