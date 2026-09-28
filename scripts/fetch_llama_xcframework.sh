#!/bin/sh
# Скачивает llama.xcframework запиненного релиза llama.cpp в ios/LlamaKit/.
# Бинарь большой (~260 МБ zip) и в git не хранится — этот скрипт надо
# запустить один раз после клонирования репозитория, до сборки в Xcode.
#
# Пин версии: b10107 (см. docs/llama_swift_plan.md §1). Обновление тега —
# осознанный коммит с перегоном сверки фазы 2 (план §3).
set -e

TAG="b10107"
DEST="$(cd "$(dirname "$0")/.." && pwd)/ios/LlamaKit"
ZIP="llama-${TAG}-xcframework.zip"
URL="https://github.com/ggml-org/llama.cpp/releases/download/${TAG}/${ZIP}"

if [ -d "$DEST/llama.xcframework" ]; then
    echo "llama.xcframework уже на месте: $DEST/llama.xcframework"
    exit 0
fi

echo "Качаю $ZIP (релиз $TAG, ~260 МБ)…"
mkdir -p "$DEST"
curl -L -f --retry 5 -o "/tmp/$ZIP" "$URL"
echo "Распаковываю…"
unzip -q -o "/tmp/$ZIP" -d "/tmp/llama-xcfw-$TAG"
# В архиве фреймворк лежит в build-apple/llama.xcframework
FOUND=$(find "/tmp/llama-xcfw-$TAG" -name "llama.xcframework" -maxdepth 3 -type d | head -1)
if [ -z "$FOUND" ]; then
    echo "ОШИБКА: llama.xcframework не найден в архиве" >&2
    exit 1
fi
mv "$FOUND" "$DEST/llama.xcframework"
rm -rf "/tmp/$ZIP" "/tmp/llama-xcfw-$TAG"
echo "Готово: $DEST/llama.xcframework"
