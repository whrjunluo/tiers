"""Raw-count reports for deterministic workflow grades."""

from __future__ import annotations

import json
import sys
from pathlib import Path


def build_report(rows: list[dict]) -> dict:
    report: dict = {"variants": {}}
    for row in rows:
        variant = row.get("variant", "unknown")
        summary = report["variants"].setdefault(
            variant, {"runs": 0, "infrastructure_errors": 0, "metrics": {}}
        )
        summary["runs"] += 1
        if row.get("status") == "infrastructure_error":
            summary["infrastructure_errors"] += 1
            continue
        for name, value in (row.get("metrics") or {}).items():
            if not isinstance(value, bool):
                continue
            metric = summary["metrics"].setdefault(
                name, {"numerator": 0, "denominator": 0, "rate": 0.0}
            )
            metric["denominator"] += 1
            if value:
                metric["numerator"] += 1
            metric["rate"] = metric["numerator"] / metric["denominator"]
    return report


def render_markdown(report: dict) -> str:
    lines = ["# Tiers Evaluation Report", ""]
    for variant, summary in sorted((report.get("variants") or {}).items()):
        lines.extend(
            [
                f"## {variant}",
                "",
                f"Runs: {summary['runs']}",
                f"Infrastructure errors: {summary['infrastructure_errors']}",
                "",
                "| Metric | Result | Rate |",
                "|---|---:|---:|",
            ]
        )
        for name, metric in sorted(summary["metrics"].items()):
            count = f"{metric['numerator']}/{metric['denominator']}"
            lines.append(f"| {name} | {count} | {metric['rate']:.1%} |")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) != 1:
        print("usage: python3 -m eval.report RESULTS_DIR", file=sys.stderr)
        return 2
    root = Path(args[0])
    rows = []
    for path in sorted(root.glob("**/grade.json")):
        with path.open(encoding="utf-8") as handle:
            rows.append(json.load(handle))
    report = build_report(rows)
    output = root / "report.json"
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(render_markdown(report), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
