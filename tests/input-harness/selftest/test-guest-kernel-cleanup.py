#!/usr/bin/env python3
import importlib.util
import io
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DRIVER_PATH = ROOT / "session" / "driver.py"


def load_driver():
    spec = importlib.util.spec_from_file_location("pf_guest_driver_cleanup", DRIVER_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeStream:
    def __init__(self):
        self.closed = False

    def write(self, _value):
        pass

    def flush(self):
        pass

    def close(self):
        self.closed = True


class FakeProcess:
    def __init__(self, line):
        self.stdin = FakeStream()
        self.stdout = io.StringIO(line)
        self.returncode = None
        self.killed = False
        self.waited = False

    def wait(self, timeout=None):
        del timeout
        self.waited = True
        self.returncode = 0
        return 0

    def kill(self):
        self.killed = True
        self.returncode = -9


class Writer:
    def emit(self, *_args, **_kwargs):
        pass


def main():
    driver = load_driver()
    created = []

    for label, line, error in (
        ("eof", "", ValueError),
        ("malformed", "not-json\n", ValueError),
        ("bad-record", '{"kind":"keyboard","name":"kbd"}\n', RuntimeError),
    ):
        def keyboard_failure(*_args, **_kwargs):
            process = FakeProcess(line)
            created.append(process)
            return process

        driver.subprocess.Popen = keyboard_failure
        try:
            driver.KernelInput("keyboard", Writer())
            raise AssertionError(f"{label} keyboard startup was accepted")
        except error:
            pass
        assert created[-1].stdin.closed and created[-1].waited

    lines = iter((
        '{"kind":"keyboard","name":"kbd","event_node":"/dev/input/event1"}\n',
        '{"kind":"keyboard","name":"mouse","event_node":"/dev/input/event2"}\n',
    ))

    def mouse_failure(*_args, **_kwargs):
        process = FakeProcess(next(lines))
        created.append(process)
        return process

    driver.subprocess.Popen = mouse_failure
    inputs = []
    try:
        driver.create_kernel_inputs(Writer(), inputs)
        raise AssertionError("bad mouse startup was accepted")
    except RuntimeError:
        pass
    finally:
        for source in inputs:
            source.destroy()
    assert len(inputs) == 1
    assert created[-2].stdin.closed and created[-2].waited
    assert created[-1].stdin.closed and created[-1].waited
    print("guest-kernel-cleanup: PASS keyboard_startup=eof_malformed_bad_record_cleaned mouse_startup=cleaned registered_source=cleaned")


if __name__ == "__main__":
    sys.exit(main())
