#!/usr/bin/env python3
# Linux 上补翻译用（sync-strings.sh 要 Xcode）：stdin 每行「简体<TAB>English<TAB>繁體」，
# 写进 Conch/Localizable.xcstrings；已有的条目会被覆盖。输出格式与 Xcode 一致（逐字节）。
# 键必须和代码里的字面量完全一样；带插值的写成格式符，如「共 %lld 个」「连接 %@」。
import json, sys, pathlib

path = pathlib.Path(__file__).resolve().parent.parent / 'Conch/Localizable.xcstrings'
catalog = json.loads(path.read_text(encoding='utf-8'))
for line in sys.stdin:
    line = line.rstrip('\n')
    if not line.strip():
        continue
    key, en, hant = line.split('\t')
    catalog['strings'][key] = {'localizations': {
        'en': {'stringUnit': {'state': 'translated', 'value': en}},
        'zh-Hant': {'stringUnit': {'state': 'translated', 'value': hant}},
    }}
    print('+', key)
path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, separators=(',', ' : '), sort_keys=True) + '\n',
                encoding='utf-8')
