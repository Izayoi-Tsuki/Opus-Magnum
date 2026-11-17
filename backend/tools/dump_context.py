"""把某个问题送进模型前的完整提示词写到文件里，方便排查回答为什么跑偏。

    python tools/dump_context.py cache/questions.txt cache/context.txt
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from api.app import build_state  # noqa: E402


def main() -> None:
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    st = build_state(rerank=True, dense=True)
    a = st.assistant
    out = []
    for q in [x.strip() for x in src.read_text(encoding="utf-8").splitlines() if x.strip()]:
        rw = a.rewriter.rewrite(q, [])
        ctx = a.gather(rw)
        for m in a.messages(rw, ctx, []):
            out.append(f"===== {m['role']} =====\n{m['content']}")
        out.append("#" * 60)
    dst.write_text("\n\n".join(out), encoding="utf-8")


if __name__ == "__main__":
    main()
