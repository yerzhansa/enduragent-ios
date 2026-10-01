set -euo pipefail
repo=$(git rev-parse --show-toplevel)
build_root=${1:?Pass a scratch directory for the frozen v1 build}
if [ -e "$build_root/stores" ]; then
    echo "Use a fresh scratch directory to avoid appending to existing seed stores." >&2
    exit 1
fi
v1_commit=82254bbda75ba79b0156d7efd3deac223489b2b0
mkdir -p "$build_root/source"
git archive "$v1_commit" apps/ios/Packages/EnduragentCoach apps/ios/Enduragent/Fixtures/FirstWeekFixture.swift | tar -x -C "$build_root/source"
package="$build_root/source/apps/ios/Packages/EnduragentCoach"
cp "$repo/tools/v1-upgrade-stores/SeedUpgradeStores.swift" "$package/Tests/EnduragentCoachTests/"
cp "$build_root/source/apps/ios/Enduragent/Fixtures/FirstWeekFixture.swift" "$package/Tests/EnduragentCoachTests/"
UPGRADE_STORE_OUTPUT="$build_root/stores" caffeinate -i swift test --disable-sandbox --package-path "$package" --filter SeedUpgradeStores
for scenario in history review; do
    destination="$repo/apps/ios/Packages/EnduragentCoach/Tests/EnduragentCoachTests/Fixtures/v1-upgrade/$scenario"
    mkdir -p "$destination"
    for name in synced local; do
        source="$build_root/stores/$scenario/$name-records.store"
        sqlite3 "$source" 'PRAGMA wal_checkpoint(TRUNCATE);'
        cp "$source" "$destination/$name-records.store"
    done
done
