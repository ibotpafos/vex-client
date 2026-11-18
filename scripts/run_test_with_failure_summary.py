"""Stream a test command unchanged; repeat bounded diagnostics at the end on failure."""
import re
import signal
import subprocess
import sys

LINE_LIMIT = 8192
DIAGNOSTIC_LIMIT = 20
DIAGNOSTIC = re.compile(
    rb"XCTAssert|error: -\[|Test Case '.+' failed|"
    rb"\.swift:\d+(?::\d+)?: error:|^\s*(?:error:|fatal error:)|"
    rb"Executed .+ with [1-9]\d* failures?"
)


def main(args):
    if not args:
        print("A test command is required.", file=sys.stderr)
        return 2
    try:
        child = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    except OSError as error:
        print(f"Could not start test command (errno {error.errno}).", file=sys.stderr)
        return 127
    previous = signal.getsignal(signal.SIGTERM)

    def terminate(signum, _frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, terminate)
    diagnostics, pending = [], bytearray()

    def record_line():
        line = bytes(pending)
        if len(diagnostics) < DIAGNOSTIC_LIMIT and DIAGNOSTIC.search(line):
            diagnostics.append(line)
        pending.clear()

    try:
        while chunk := child.stdout.read1(4096):
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
            parts = chunk.split(b"\n")
            for index, part in enumerate(parts):
                pending.extend(part[:max(0, LINE_LIMIT - len(pending))])
                if index < len(parts) - 1:
                    record_line()
        record_line()
        result = child.wait()
    finally:
        signal.signal(signal.SIGTERM, previous)
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        child.stdout.close()
    if result:
        print(f"\nTest failure summary (exit {result}; first {DIAGNOSTIC_LIMIT} diagnostics; {LINE_LIMIT} bytes per line):", flush=True)
        if diagnostics:
            for line in diagnostics:
                print(line.decode("utf-8", errors="replace"), flush=True)
        else:
            print("No XCTest/compiler diagnostic line captured; the command still failed.", flush=True)
    return result if result >= 0 else 128 - result


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
