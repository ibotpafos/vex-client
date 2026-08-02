#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This preflight is intended for macOS hosts." >&2
  exit 2
fi

for command_name in dotnet node npm xmllint; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command is missing: $command_name" >&2
    exit 2
  fi
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

while IFS= read -r -d '' xml_file; do
  xmllint --noout "$xml_file"
done < <(
  find \
    native-windows/src/Vex.Windows.App \
    native-windows/packaging \
    -type f \
    \( -name '*.xaml' -o -name '*.xml' -o -name '*.manifest' \) \
    -print0
)
node scripts/validate_native_windows_xaml.mjs

# Roslyn can analyze the WinUI C# sources on macOS even though the Windows PE
# XAML compiler cannot execute here. The Windows CI build remains the compile
# and runtime source of truth for generated XAML code.
dotnet format \
  native-windows/src/Vex.Windows.App/Vex.Windows.App.csproj \
  --verify-no-changes \
  --severity warn \
  --no-restore

dotnet run \
  --project native-windows/tests/Vex.Windows.Core.Tests/Vex.Windows.Core.Tests.csproj \
  -c Release
dotnet build \
  native-windows/src/Vex.Windows.Client/Vex.Windows.Client.csproj \
  -c Release
dotnet build \
  native-windows/src/Vex.Windows.Service/Vex.Windows.Service.csproj \
  -c Release \
  -r win-x64 \
  -p:EnableWindowsTargeting=true
dotnet build \
  native-windows/src/Vex.Windows.Service/Vex.Windows.Service.csproj \
  -c Release \
  -r win-arm64 \
  -p:EnableWindowsTargeting=true

audit_dir="$(mktemp -d)"
trap 'rm -rf "$audit_dir"' EXIT
for project_name in Vex.Windows.App Vex.Windows.Client Vex.Windows.Service; do
  project_path="native-windows/src/$project_name/$project_name.csproj"
  audit_path="$audit_dir/$project_name.json"
  dotnet package list \
    --project "$project_path" \
    --vulnerable \
    --include-transitive \
    --format json >"$audit_path"
  node - "$audit_path" <<'NODE'
const fs = require("node:fs");
const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const stack = [report];
while (stack.length > 0) {
  const value = stack.pop();
  if (Array.isArray(value)) {
    stack.push(...value);
    continue;
  }
  if (value && typeof value === "object") {
    const keys = Object.keys(value);
    if (
      keys.some((key) => key.toLowerCase().includes("advisory")) ||
      keys.some((key) => key.toLowerCase() === "severity")
    ) {
      throw new Error(`Vulnerable NuGet package found in ${process.argv[2]}`);
    }
    stack.push(...Object.values(value));
  }
}
NODE
done

npm run check
git diff --check

echo "Native Windows macOS preflight passed."
