#!/bin/bash
# ============================================================================
# Запуск Chappe на подключённом iPhone одной командой (п.4 брифа 30.07).
#
#   tools/dev/run_on_device.sh [аргументы запуска приложения]
#
# Примеры:
#   tools/dev/run_on_device.sh                        # просто запустить
#   tools/dev/run_on_device.sh --bench-punctuation    # прогнать бенч
#
# Сам находит устройство (первое подключённое), собирает, ставит,
# запускает с переданными аргументами и печатает консоль приложения
# (Ctrl+C — отцепиться; приложение продолжит работать).
# UDID можно навязать переменной DEVICE_UDID, схему — SCHEME.
# ============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT="$REPO_ROOT/ios/Chappe/Chappe.xcodeproj"
SCHEME="${SCHEME:-Chappe}"
BUNDLE_ID="com.chappe.app"
DERIVED="$REPO_ROOT/ios/Chappe/build-device"

# xcode-select обязан указывать на полный Xcode — иначе нет devicectl
if ! xcrun --find devicectl >/dev/null 2>&1; then
    echo "ОШИБКА: xcrun не находит devicectl."
    echo "Почини: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    exit 1
fi

# — устройство: первое подключённое (или DEVICE_UDID из окружения).
# Имя устройства содержит пробелы, поэтому колонки awk ненадёжны —
# берём идентификатор по форме UUID.
if [ -z "${DEVICE_UDID:-}" ]; then
    DEVICE_UDID=$(xcrun devicectl list devices 2>/dev/null \
        | grep -i connected \
        | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' \
        | head -1)
fi
if [ -z "$DEVICE_UDID" ]; then
    echo "ОШИБКА: подключённый iPhone не найден (кабель? разблокирован?)"
    xcrun devicectl list devices
    exit 1
fi
echo "== Устройство: $DEVICE_UDID"

echo "== Сборка ($SCHEME)…"
xcodebuild build -project "$PROJECT" -scheme "$SCHEME" \
    -destination "platform=iOS,id=$DEVICE_UDID" \
    -derivedDataPath "$DERIVED" -allowProvisioningUpdates -quiet

APP="$DERIVED/Build/Products/Debug-iphoneos/$SCHEME.app"
echo "== Установка…"
xcrun devicectl device install app --device "$DEVICE_UDID" "$APP" >/dev/null

echo "== Запуск: $BUNDLE_ID $*"
# --console печатает stdout приложения прямо сюда
xcrun devicectl device process launch --console --terminate-existing \
    --device "$DEVICE_UDID" "$BUNDLE_ID" "$@"
