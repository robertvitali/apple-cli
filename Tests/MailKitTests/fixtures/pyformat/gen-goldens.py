#!/usr/bin/env python3
"""Golden generator for PyFormat (gap37): executes THE ORACLE'S OWN engine —
string.Formatter().vformat, exactly what apple-mail-mcp templates.py _substitute calls —
over a synthetic matrix and records output or the raised error's message. Never reasoned;
regenerate with: python3 gen-goldens.py > goldens.json
Synthetic inputs only (repo rule: no real data in fixtures)."""
import json, string

f = string.Formatter()
VARS = {"x": "hi", "name": "Ada", "width": "6", "empty": "",
        "uni": "héllo", "q": "it's", "qq": 'say "hi"', "both": '\'"', "tabs": "a\tb",
        "long": "abcdefghij",
        # B1 (code-point vs grapheme) family — decomposed accent, ZWJ family emoji,
        # regional-indicator flag, CRLF, astral emoji. Python counts CODE POINTS.
        "dec": "e\u0301abc", "fam": "\U0001F468\u200D\U0001F469\u200D\U0001F467",
        "flag": "\U0001F1FA\U0001F1F8xy", "crlf": "a\r\nb", "smile": "\U0001F600ab"}

CASES = [
    "{x}", "{x:>5}", "{x:<5}", "{x:^5}", "{x:*>5}", "{x:*^7}", "{x:05}",
    "{x:.1}", "{long:.4}", "{long:>6.3}", "{x:s}", "{x:5s}",
    "{x!r}", "{x!s}", "{x!a}", "{uni!r}", "{uni!a}", "{q!r}", "{qq!r}", "{both!r}", "{tabs!r}",
    "{x:{width}}", "{name} and {x:>{width}}",
    "{x[0]}", "{x[1]}", "{x[-1]}", "{long[3]}",
    "{empty:>3}", "{empty!r}",
    "pre {x:>4} post", "{{literal}} {x}",
    # B1 code-point family: width / precision / index against multi-code-point graphemes
    "{dec:.1}", "{dec:.2}", "{dec[1]}", "{dec[4]}", "{dec:>10}", "{dec:*^12}",
    "{fam:.1}", "{fam:.2}", "{fam[1]}", "{fam[2]}", "{fam[4]}", "{fam:>10}",
    "{flag:.2}", "{flag[1]}", "{flag[2]}",
    "{crlf[2]}", "{crlf:.3}",
    "{smile:.1}", "{smile[1]}", "{smile:>5}",
    # B2: zero-flag with explicit align but no explicit fill
    "{x:<05}", "{x:>05}", "{x:^05}", "{x:0<5}", "{x:9<5}",
    # L4: unicode decimal-digit index (Py_UNICODE_TODECIMAL accepts Nd digits)
    "{long[\u0663]}",
    # error cases
    "{x:d}", "{x:>5d}", "{x:+5}", "{x:#5}", "{x:,}", "{x:=5}", "{x!z}",
    "{x.y}", "{x[5]}", "{x[abc]}", "{x[-4]}",
    # M3 message-shape cases
    "{x: }", "{x: 5}", "{x:z}", "{x:z5}", "{x:ss}", "{x:5ss}", "{x:.}",
    "{x:.99999999999999999999}", "{x:99999999999999999999}",
    # B3 malformed-but-committed fields (Python raises; the old scanner leaked verbatim)
    "{ x }", "{x }", "{2x}", "{x]}", "{x.}", "{x[}", "{x[0}",
    "{x!}", "{x!rr}", "{x!!r}", "{x!r[0]}", "{}", "{0}", "{1}",
]

rows = []
for t in CASES:
    row = {"template": t}
    try:
        row["output"] = f.vformat(t, (), dict(VARS))
    except KeyError as e:
        row["error"] = "KeyError:" + str(e.args[0])
    except Exception as e:
        row["error"] = str(e)
    rows.append(row)
print(json.dumps({"vars": VARS, "rows": rows}, indent=1, ensure_ascii=False))
