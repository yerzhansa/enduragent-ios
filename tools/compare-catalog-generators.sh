#!/bin/sh
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
catalogs="$(cd "${1:-$root/packages/i18n/catalogs}" && pwd)"
outputs="apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach"
work="$(mktemp -d)"

swift build --quiet --package-path "$root/tools" --product generate-catalogs
swift_generator="$(swift build --package-path "$root/tools" --show-bin-path)/generate-catalogs"

for generator in typescript swift; do
	mkdir -p "$work/$generator/packages/i18n/scripts"
	cp -R "$catalogs" "$work/$generator/packages/i18n/catalogs"
done
cp "$root/packages/i18n/scripts/generate-swift-catalog.ts" "$work/typescript/packages/i18n/scripts/"

typescript_status=0
(cd "$work/typescript" && node packages/i18n/scripts/generate-swift-catalog.ts > summary.txt 2> errors.txt) || typescript_status=$?
swift_status=0
(cd "$work/swift" && "$swift_generator" > summary.txt 2> errors.txt) || swift_status=$?

echo "catalogs: $catalogs"
(cd "$catalogs" && shasum -a 256 -- *.json)
echo "outputs kept in: $work"
echo "exit status: typescript $typescript_status, swift $swift_status"
if [ "$typescript_status" -ne 0 ] || [ "$swift_status" -ne 0 ]; then
	if [ "$typescript_status" -ne 0 ] && [ "$swift_status" -ne 0 ]; then
		echo "both generators reject these catalogs"
		exit 0
	fi
	echo "only one generator rejects these catalogs"
	cat "$work/typescript/errors.txt" "$work/swift/errors.txt"
	exit 1
fi

status=0
for file in summary.txt "$outputs/I18n/CatalogKey.generated.swift" "$outputs/Resources/Phrasebook.json"; do
	for generator in typescript swift; do
		echo "$generator $(cd "$work/$generator" && shasum -a 256 -- "$file")"
	done
	cmp "$work/typescript/$file" "$work/swift/$file" || status=1
done
if [ "$status" -eq 0 ]; then
	echo "byte-identical"
fi
exit "$status"
