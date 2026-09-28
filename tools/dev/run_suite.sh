#!/bin/bash
# ============================================================================
# Прогон сюиты с гейтом числа тестов (поручение владельца 10.08).
#
# Гремлин «0 тестов → TEST SUCCEEDED» кусал ТРИЖДЫ (фильтр по имени
# метода Swift Testing, параллельная сборка в общем DerivedData,
# оборванный xcresult): вердикт снимается ТОЛЬКО из xcresult, и число
# прогнанных обязано быть не меньше пола из expected_test_floor.txt.
# Пол поднимается руками при добавлении тестов (снижение — осознанно).
#
# Использование: tools/dev/run_suite.sh [доп. аргументы xcodebuild]
# ============================================================================
set -u
cd "$(dirname "$0")/../../ios/Chappe" || exit 1

FLOOR=$(cat "$(dirname "$0")/expected_test_floor.txt")
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project Chappe.xcodeproj -scheme Chappe \
    -destination "platform=iOS Simulator,name=iPhone 17 Pro" \
    "$@" > /dev/null 2>&1
RESULT_BUNDLE=$(ls -td ~/Library/Developer/Xcode/DerivedData/Chappe-*/Logs/Test/*.xcresult 2>/dev/null | head -1)

python3 - "$RESULT_BUNDLE" "$FLOOR" <<'EOF'
import json, subprocess, sys
bundle, floor = sys.argv[1], int(sys.argv[2])
try:
    raw = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "summary",
         "--path", bundle],
        capture_output=True, text=True, check=True).stdout
    d = json.loads(raw)
except Exception as e:
    print(f"КРАСНЫЙ: xcresult не читается ({e}) — вердикта НЕТ")
    sys.exit(1)
passed, failed = d.get("passedTests", 0), d.get("failedTests", 0)
ran = passed + failed
print(f"прогнано {ran} (пол {floor}): passed {passed}, failed {failed}, "
      f"result {d.get('result')}")
if d.get("result") != "Passed":
    print("КРАСНЫЙ: сюита не Passed")
    sys.exit(1)
if ran < floor:
    print(f"КРАСНЫЙ: прогнано {ran} < пола {floor} — молчаливое "
          f"«0 тестов → SUCCEEDED» больше не проходит")
    sys.exit(1)
print("ЗЕЛЁНЫЙ: сюита прошла и число тестов не ниже пола")
EOF
