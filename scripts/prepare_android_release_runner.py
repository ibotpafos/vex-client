"""Reserve Android signing space on the disposable GitHub Ubuntu runner only."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
MIN_FREE = 24 * 1024**3
# Android compilation uses none of these preinstalled toolchains or emulator
# images. Keep Java, Go, Node, NDK, SDK platforms, workspace and build caches.
UNUSED = tuple(map(Path, (
    '/usr/share/dotnet',
    '/usr/local/.ghcup',
    '/usr/local/share/powershell',
    '/opt/hostedtoolcache/CodeQL',
    '/usr/local/lib/android/sdk/system-images',
)))


def require_hosted_tag():
    """Refuse local, self-hosted, fork and branch executions before any sudo."""
    expected = {'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'github-hosted',
                'RUNNER_OS': 'Linux', 'GITHUB_REPOSITORY': 'ibotpafos/vex-client',
                'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF_TYPE': 'tag'}
    if any(os.environ.get(k) != v for k, v in expected.items()):
        raise ValueError('Disposable GitHub-hosted Android tag job required')
    if (not os.environ.get('GITHUB_REF', '').startswith('refs/tags/android-v')
            or str(ROOT) != '/home/runner/work/vex-client/vex-client'
            or os.environ.get('GITHUB_WORKSPACE') != str(ROOT)):
        raise ValueError('Exact Android release workspace required')


def removable(path):
    """Select an existing fixed directory without indirect or mounted paths."""
    return (path.is_dir() and not any(p.is_symlink() for p in (path, *path.parents))
            and not path.is_mount())


def prepare(execute=False):
    """Report a dry run by default; explicitly clear only unused hosted tools."""
    if execute:
        require_hosted_tag()
    before = shutil.disk_usage(ROOT).free
    targets = [str(p) for p in UNUSED if removable(p)]
    if execute and targets:
        subprocess.run(['sudo', '-n', 'rm', '-rf', '--one-file-system', '--', *targets], check=True)
    after = shutil.disk_usage(ROOT).free
    result = {'executed': execute, 'free_before_bytes': before,
              'free_after_bytes': after, 'minimum_free_bytes': MIN_FREE,
              'unused_tool_directories': targets}
    print(json.dumps(result))
    if execute and after < MIN_FREE:
        raise ValueError('Android native build requires at least 24 GiB free after SDK installation')
    return result


def main():
    """Require an explicit execution flag; the default never removes files."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    prepare(args.execute)


if __name__ == '__main__':
    main()
