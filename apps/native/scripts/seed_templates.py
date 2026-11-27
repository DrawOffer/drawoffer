"""从后端模板种子迁移读出模板目录，输出与 `GET /api/resume-templates` 同形的 JSON。

客户端不保存模板副本：纸面检查和本地假后端都在运行时调用本脚本，模板内容、名称、
分类与 layout_plan 全部来自 upstream 的迁移 SQL 和后端自己的布局编译器。
只复现与模板内容有关的种子（0079 精选、0100 Muse 样例与定义、0101/0102 改名、
0103 压缩样例、0104 分类与停用、0085 分类），管理员后台的改动不在此列。

运行（只需 pydantic，不安装后端全部依赖）：
  uv run --no-project --with 'pydantic[email]>=2.10,<3' python apps/native/scripts/seed_templates.py [--keys a,b] [--all] [--validation]
"""

from __future__ import annotations

import argparse
from copy import deepcopy
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
BACKEND = ROOT / "upstream/apps/backend"
SQL = BACKEND / "migrations/sql"
sys.path.insert(0, str(BACKEND / "src"))

from drawoffer.domain.resume import CanonicalResumeDocument, TemplateDefinition, compile_layout_plan  # noqa: E402

# 纸面检查的代表样本：覆盖精选蓝色版式与六种 Muse 版式（侧栏、色块、深色、照片、页眉、三区）。
SAMPLE_KEYS = (
    "featured-campus-cn", "featured-professional-cn", "featured-product-cn",
    "muse-badge-cn", "muse-hello-cn", "muse-code-cn", "muse-polaroid-cn",
    "muse-blackmast-cn", "muse-triptych-cn",
)
LITERAL = r"'((?:[^']|'')*)'"


def unquote(value: str) -> str:
    return value.replace("''", "'")


def read(name: str) -> str:
    path = SQL / f"{name}.up.sql"
    if not path.exists():
        sys.exit(f"缺少后端种子 {path.relative_to(ROOT)}：先执行 git submodule update --init upstream")
    return path.read_text(encoding="utf-8")


def catalog() -> dict[str, dict]:
    rows: dict[str, dict] = {}

    def add(key: str, name: str, description: str, data: str, style: str) -> None:
        rows[key] = {"key": key, "name": unquote(name), "description": unquote(description),
                     "data": json.loads(unquote(data)), "style": json.loads(unquote(style)),
                     "style_categories": [], "use_cases": [], "active": True, "rank": len(rows) + 1}

    featured = re.findall(rf"\('(featured-[a-z-]+)', {LITERAL}, {LITERAL},\s*CAST\({LITERAL} AS JSON\),\s*CAST\({LITERAL} AS JSON\)", read("0079"), re.S)
    for row in featured:
        add(*row)
    labels = re.findall(
        rf"SET style_categories_json = CAST\({LITERAL} AS JSON\),\s*use_cases_json = CAST\({LITERAL} AS JSON\),.*?WHERE `key` = '([a-z-]+)'",
        read("0085"), re.S)
    for styles, uses, key in labels:
        if key in rows:
            rows[key]["style_categories"], rows[key]["use_cases"] = json.loads(styles), json.loads(uses)

    muse = read("0100")
    samples = dict(re.findall(rf"SET @muse_sample_(\w+) = CAST\({LITERAL} AS JSON\)", muse))
    entries = re.findall(rf"VALUES \('(muse-[a-z]+-cn)', {LITERAL}, {LITERAL}, @muse_sample_(\w+), CAST\({LITERAL} AS JSON\)", muse)
    if len(entries) != 79:
        sys.exit(f"0100 Muse 种子解析出 {len(entries)} 套，预期 79；后端种子格式已变，需要更新本脚本")
    for key, name, description, sample, style in entries:
        add(key, name, description, samples[sample], style)

    for migration in ("0101", "0102"):
        for name, key, old in re.findall(rf"SET name = {LITERAL}\s*WHERE `key` = '([a-z-]+)' AND BINARY name = BINARY {LITERAL}", read(migration)):
            if key in rows and rows[key]["name"] == unquote(old):
                rows[key]["name"] = unquote(name)
    for data, key, old in re.findall(rf"SET data_json = CAST\({LITERAL} AS JSON\)\s*WHERE `key` = '([a-z-]+)' AND data_json = CAST\({LITERAL} AS JSON\)", read("0103")):
        if key in rows and rows[key]["data"] == json.loads(unquote(old)):
            rows[key]["data"] = json.loads(unquote(data))

    curation = re.search(rf"SET @muse_curation = CAST\({LITERAL} AS JSON\)", read("0104"))
    featured_count = len(featured)
    for item in json.loads(unquote(curation.group(1))):
        row = rows.get(item["key"])
        if row is None or row["style"] != item["definition"]:
            continue
        if not item["rank"]:
            row["active"] = False
            continue
        row["rank"] = featured_count + item["rank"]
        if not row["style_categories"] and not row["use_cases"]:
            row["style_categories"], row["use_cases"] = item["style_categories"], item["use_cases"]
    return rows


def record(index: int, row: dict) -> dict:
    """按后端 template_record 的方式校验并编译，字段与接口响应一致。"""
    data = CanonicalResumeDocument.model_validate(row["data"])
    style = TemplateDefinition.model_validate(row["style"])
    return {
        "id": str(index), "key": row["key"], "name": row["name"], "description": row["description"],
        "style_categories": row["style_categories"], "use_cases": row["use_cases"],
        "data": data.model_dump(mode="json"), "style": style.model_dump(mode="json"),
        "layout_plan": compile_layout_plan(data, style).model_dump(mode="json"),
        "switchable": True, "incompatibility_reason": None,
    }


def recompiled(case: dict) -> dict:
    data = CanonicalResumeDocument.model_validate(case["data"])
    style = TemplateDefinition.model_validate(case["style"])
    case["layout_plan"] = compile_layout_plan(data, style).model_dump(mode="json")
    return case


def validation_cases(rows: dict[str, dict]) -> list[dict]:
    """在种子模板上派生的边界用例：字体回退、超长正文、私有图片 assets 注入。内容虚构。"""
    muse, campus = record(0, rows["muse-badge-cn"]), record(0, rows["featured-campus-cn"])
    cases = []
    for font in ("source-han-serif", "lxgw-wenkai", "Native Missing Fixture Font"):
        case = deepcopy(muse)
        case["name"] = "字体回退：" + font
        case["style"]["tokens"]["font_family"] = font
        cases.append(recompiled(case))
    case = deepcopy(muse)
    case["name"] = "长正文滚动边界"
    case["data"]["sections"][0]["blocks"][0]["runs"][0]["text"] = ("长正文校验：内容应完整保留，能够滚动至末尾。" * 180) + "长正文结束标记"
    cases.append(recompiled(case))
    case = deepcopy(campus)
    case["name"] = "私有图片 assets 注入"
    source = "/api/resumes/42/assets/fixture.png"
    case["data"]["identity"]["avatar"] = {
        "node_id": "node_private000000000000000001", "source_refs": [],
        "media_kind": "avatar", "src": source, "alt": "虚构私有头像",
        "width": 108, "width_unit": "px", "height_px": None,
        "align": None, "system_fallback": False,
    }
    case["assets"] = {source: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgmJn2HwADmwH/sEIMpQAAAABJRU5ErkJggg=="}
    cases.append(recompiled(case))
    return cases


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--keys", help="逗号分隔的模板 key；默认取纸面检查的 9 个代表样本")
    parser.add_argument("--all", action="store_true", help="输出种子里全部启用模板（按种子顺序）")
    parser.add_argument("--validation", action="store_true", help="附带 validation 边界用例")
    args = parser.parse_args()
    rows = catalog()
    if args.all:
        picked = sorted((r for r in rows.values() if r["active"]), key=lambda r: r["rank"])
    else:
        keys = args.keys.split(",") if args.keys else list(SAMPLE_KEYS)
        missing = [k for k in keys if k not in rows]
        if missing:
            sys.exit(f"后端种子里没有模板 {', '.join(missing)}")
        picked = [rows[k] for k in keys]
    templates = [record(index, row) for index, row in enumerate(picked, start=1)]
    output: dict = {"templates": templates}
    if args.validation:
        output["validation"] = validation_cases(rows)
    json.dump(output, sys.stdout, ensure_ascii=False)


if __name__ == "__main__":
    main()
