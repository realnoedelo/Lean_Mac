#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
bash -n disable_bloat_services.sh

user_targets=(
  com.apple.intelligencecontextd
  com.apple.intelligenceflowd
  com.apple.intelligencetasksd
  com.apple.knowledgeconstructiond
  com.apple.corespotlightd
  com.apple.corespotlightservice
  com.apple.managedcorespotlightd
  com.apple.proactiveeventtrackerd
)
system_targets=(
  com.apple.wifianalyticsd
  com.apple.analyticsd
  com.apple.cloudtelemetryd
  com.apple.osanalytics.diagnosticmonitor
)

for service in "${user_targets[@]}"; do
  grep -Fq "disable_service \"$service\"" disable_bloat_services.sh
done
for service in "${system_targets[@]}"; do
  grep -Fq "\"$service|" disable_bloat_services.sh
done
grep -Fq 'Checking System-Level Services by exact launchd name' disable_bloat_services.sh
grep -Fq 'MODE="interactive"' disable_bloat_services.sh
grep -Fq 'MODE="list"' disable_bloat_services.sh
grep -Fq 'MODE="dry-run"' disable_bloat_services.sh
if grep -Fq 'Skipping - No sudo in automated mode' disable_bloat_services.sh; then
  echo 'system service skip path still present' >&2
  exit 1
fi

echo "service inventory regression checks passed"
