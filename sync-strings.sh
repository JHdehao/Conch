#!/bin/zsh
# Rebuilds for macOS and iOS, merges every localizable string from both into
# Conch/Localizable.xcstrings, and lists the ones still missing a translation.
set -e
cd "${0:A:h}"
flags=(-project Conch.xcodeproj -scheme Conch -derivedDataPath build/dd -skipPackageUpdates -skipPackagePluginValidation -skipMacroValidation)
# Both platforms must build: strings from a failed build would be stale or missing.
for destination in 'platform=macOS,arch=arm64' 'generic/platform=iOS Simulator'; do
  log=$(xcodebuild $flags -destination "$destination" build 2>&1)
  print -r -- "$log" | grep -E " error:|BUILD (SUCCEEDED|FAILED)" | grep -v buildCommands || true
  if ! print -r -- "$log" | grep -q "BUILD SUCCEEDED"; then
    echo "✗ $destination 编译失败，没有同步字符串"
    exit 1
  fi
done
find build/dd/Build/Intermediates.noindex/Conch.build/Debug*/Conch.build/Objects-normal -name "*.stringsdata" -print0 \
  | xargs -0 xcrun xcstringstool sync Conch/Localizable.xcstrings --stringsdata 2>&1 | grep -v staleness || true
python3 - <<'PY'
import json, re
strings = json.load(open('Conch/Localizable.xcstrings'))['strings']
cjk = re.compile(r'[一-鿿]')
todo = [k for k, v in strings.items() if cjk.search(k) and {'en', 'zh-Hant'} - set(v.get('localizations', {}))]
print(f'{len(todo)} strings need translation (en / zh-Hant):')
for k in todo: print('  ' + json.dumps(k, ensure_ascii=False))
PY
