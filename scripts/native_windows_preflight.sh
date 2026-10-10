#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

for command_name in dotnet node python3 pwsh; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command is missing: $command_name" >&2
    exit 2
  fi
done

python3 - <<'PY'
from pathlib import Path
import xml.etree.ElementTree as ET
for root in [Path('native-windows/src/Vex.Windows.App'), Path('native-windows/packaging')]:
    for source in root.rglob('*'):
        if any(part in ('bin', 'obj', 'out', 'published') for part in source.parts):
            continue
        if source.is_file() and source.suffix in ('.xaml', '.xml', '.manifest'):
            ET.parse(source)
print('Windows XML/XAML documents are well formed.')
PY
node scripts/validate_native_windows_xaml.mjs
node native-windows/scripts/validate-packaging-static.mjs
pwsh -NoProfile -File native-windows/scripts/validate-powershell-parse.ps1
pwsh -NoProfile -File native-windows/tests/ReleaseValidation.Tests.ps1
pwsh -NoProfile -File native-windows/tests/NetworkSafetyPolicy.Tests.ps1
pwsh -NoProfile -File native-windows/tests/BootstrapOwnership.Tests.ps1
pwsh -NoProfile -File native-windows/tests/VpnAcceptance.Tests.ps1
pwsh -NoProfile -File native-windows/tests/SmokeApplication.Tests.ps1
pwsh -NoProfile -File native-windows/tests/UiPreviewProtocolRegistration.Tests.ps1
pwsh -NoProfile -File native-windows/tests/UiPreviewContext.Tests.ps1

dotnet run --project native-windows/tests/Vex.Windows.Core.Tests/Vex.Windows.Core.Tests.csproj -c Release
for architecture in x64 arm64; do
  dotnet publish native-windows/src/Vex.Windows.Service/Vex.Windows.Service.csproj \
    -c Release -r "win-$architecture" -p:Platform="$architecture" -p:EnableWindowsTargeting=true
done

git diff --check
echo "Portable native Windows preflight passed; WinUI compilation and real tunnel acceptance require Windows."
