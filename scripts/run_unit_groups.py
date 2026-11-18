"""Run every canonical unit group, retaining failures instead of short-circuiting."""
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import time


def main():
    root = Path.cwd()
    commands = json.loads((root / 'package.json').read_text())['scripts']['test:unit'].split(' && ')
    output = root / '.test-results/unit'
    output.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, CI='1', PATH=str(root / 'node_modules/.bin') + os.pathsep + os.environ['PATH'])
    rows = []
    for index, command in enumerate(commands, 1):
        name = f'unit-{index}'
        started = time.monotonic()
        try:
            child = subprocess.Popen(shlex.split(command), cwd=root, env=env,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            try:
                try:
                    stdout, stderr = child.communicate(timeout=300)
                    code = child.returncode
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    stdout, stderr = child.communicate()
                    stderr += b'\nTIMEOUT after 300 seconds\n'
                    code = 124
            finally:
                # npm/tsx children must not survive a timeout or interrupt.
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                child.wait()
        except OSError as error:
            stdout, stderr, code = b'', str(error).encode(), 127
        (output / f'{name}.stdout').write_bytes(stdout)
        (output / f'{name}.stderr').write_bytes(stderr)
        rows.append({'name': name, 'command': command, 'exit': code,
                     'seconds': round(time.monotonic() - started, 2),
                     'stdout': f'{name}.stdout', 'stderr': f'{name}.stderr'})
        (output / 'results.json').write_text(json.dumps(rows, indent=2) + '\n')
        print(f'{name}: {"PASS" if code == 0 else "FAIL"} (exit {code}) {command}', flush=True)
    failures = sum(row['exit'] != 0 for row in rows)
    print(f'{len(rows)} groups: {len(rows) - failures} passed, {failures} failed. Report: {output / "results.json"}')
    return int(failures > 0)


if __name__ == '__main__':
    raise SystemExit(main())
