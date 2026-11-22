"""把编译器提取的字符串同步进 .xcstrings 之后，写入中文译文和英文的单复数。
源语言是英文（键就是代码里的英文原文）。用法见 App/scripts/i18n.sh。
有需要翻译却没有中文的键时，列出来并以非零退出。"""
import json, re, sys, os
sys.path.insert(0, os.path.dirname(__file__))
from i18n_zh import ZH, TABLES, PLURAL_EN, NO_TRANSLATE

path = sys.argv[1]
table = os.path.basename(path).removesuffix(".xcstrings")
zh = TABLES.get(table, ZH)
cat = json.load(open(path))
cat["sourceLanguage"] = "en"
missing = []


def unit(v):
    return {"stringUnit": {"state": "translated", "value": v}}


for key, entry in cat["strings"].items():
    entry.pop("shouldTranslate", None)
    loc = {}
    if key in PLURAL_EN and table == "Localizable":
        loc["en"] = {"variations": {"plural": {k: unit(v) for k, v in PLURAL_EN[key].items()}}}
    if key in zh:
        loc["zh-Hans"] = unit(zh[key])
    elif key in NO_TRANSLATE or not re.search("[A-Za-z]{2}", SPEC.sub("", key) if (SPEC := re.compile(r"%(\d+\$)?(lld|ld|d|@|lf|f|u)")) else key):
        entry["shouldTranslate"] = False   # 产品名、格式串之类
    else:
        missing.append(key)
    if loc:
        entry["localizations"] = loc
    else:
        entry.pop("localizations", None)

json.dump(cat, open(path, "w"), ensure_ascii=False, indent=2, sort_keys=True)
open(path, "a").write("\n")
unused = sorted(set(zh) - set(cat["strings"]))
if unused:
    print(f"{table}：译文里有用不到的键：", *unused, sep="\n  ")
if missing:
    print(f"{table}：缺中文译文（或者加进 NO_TRANSLATE）：", *missing, sep="\n  ")
    sys.exit(1)
print(f"{table} OK：{len(cat['strings'])} 个键")
