#!/usr/bin/env python3
"""Keep unread-PTY SSH state; only disposable loopback fixtures and owned helpers.

The lifecycle/status readers continue independently of the paused PTY reader.
This is not the application's OCaml/AppKit prompt implementation.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import select
import shlex
import signal
import subprocess
import tempfile
import time

from run import Case
from ssh_fixture import SSHFixture


class PausableCase(Case):
    paused = False

    def drain(self):
        if not self.paused:
            super().drain()


def snapshot(case, child, observer, label):
    events = observer.control(None, 8, 0)
    result = subprocess.run(
        ['/bin/ps', '-o', 'pid=,ppid=,pgid=,stat=,wchan=',
         '-p', f'{case.pid},{child}'], capture_output=True, text=True,
        timeout=3, check=False)
    return {'label': label, 'time': round(time.monotonic() - case.started, 6),
            'ps_fields': 'pid ppid pgid stat wchan', 'ps': result.stdout.strip(),
            'ps_returncode': result.returncode,
            'note_exit': [{'pid': e.ident, 'flags': e.flags, 'fflags': e.fflags,
                           'data': e.data} for e in events],
            'transport_exited': bool(case.event('TransportExited')),
            'cleanup_complete': bool(case.event('CleanupComplete'))}


def sample_transport(child):
    with tempfile.TemporaryDirectory(prefix='unison-pty-sample-') as temporary:
        path = Path(temporary) / 'sample.txt'
        result = subprocess.run(['/usr/bin/sample', str(child), '1', '1', '-file',
                                 str(path)], capture_output=True, text=True, timeout=8)
        text = path.read_text() if path.exists() else ''
        graph = text.partition('Call graph:')[2].partition('Binary Images:')[0]
        # Keep stacks only, not the process header, launch environment or image paths.
        graph = re.sub(r'/[^\s]+', '<path>', graph)
        return {'returncode': result.returncode, 'call_graph': graph.strip(),
                'stderr': re.sub(r'/[^\s]+', '<path>', result.stderr)}


def trial(helper, output, mode, repeat, sample):
    case = None
    observer = select.kqueue()
    observations = []
    try:
        with SSHFixture(grace=1) as fixture:
            wrapper = '(trap "" TERM; exec /bin/sleep 30) & exec ' + shlex.join(
                fixture.argv(encrypted=True))
            case = PausableCase(helper, ['/bin/sh', '-c', wrapper], terminal=True)
            case.until(lambda: b'Enter passphrase' in case.output)
            child = int(case.event('TransportStarted')[0]['line'].split()[2])
            observer.control([select.kevent(child, filter=select.KQ_FILTER_PROC,
                flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                fflags=select.KQ_NOTE_EXIT)], 0, 0)
            # Match the earlier experiment: let the server expire, then answer.
            time.sleep(6)
            observations.append(snapshot(case, child, observer, 'before-answer'))
            case.paused = mode != 'drained-control'
            os.write(case.io, (fixture.passphrase + '\n').encode())
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                case.drain()
                time.sleep(.01)
            observations.append(snapshot(case, child, observer, 'two-seconds-after-answer'))
            if sample and case.paused and not case.event('TransportExited'):
                observations[-1]['sample'] = sample_transport(child)
            if mode == 'resume-read':
                case.paused = False
            elif mode == 'stop-without-reading':
                # Signal only our own unreaped helper. Its reserved-group TERM/KILL
                # sequence tests forced teardown without a forwarded-PID signal.
                case.send(signal.SIGTERM)
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    if case.event('CleanupComplete'):
                        break
                    time.sleep(.01)
                observations.append(snapshot(case, child, observer, 'after-helper-stop-unread'))
                case.paused = False
            case.finish(seconds=8)
            clean = lambda value: fixture.clean(value).replace(
                fixture.passphrase, '<fixture-secret>')
            data = case.record(mode, clean)
            data['observations'] = observations
            data['repeat'] = repeat
            data['helper_sha256'] = hashlib.sha256(helper.read_bytes()).hexdigest()
            data['scope'] = 'Signed helper; loopback key-passphrase SSH, not server-password or app prompt reader.'
            data['result'] = 'observed'
            (output / f'{mode}-{repeat}.json').write_text(json.dumps(data, indent=2) + '\n')
            expected = (255,) if mode != 'stop-without-reading' else (255, -9, -15)
            assert case.rc in expected
            assert case.verified() and case.event('CleanupComplete')
            print(mode, repeat, 'exit', case.rc, 'observations',
                  [(v['label'], v['transport_exited'], v['cleanup_complete'])
                   for v in observations], flush=True)
    except BaseException as error:
        if case:
            (output / f'{mode}-{repeat}-failure.json').write_text(json.dumps({
                'error': type(error).__name__, 'observations': observations,
                'records': case.records}, indent=2) + '\n')
        raise
    finally:
        observer.close()
        if case and case.rc is None:
            case.paused = False
            case.send(signal.SIGTERM)
            case.finish(seconds=8)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--helper', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--repeats', type=int, default=1)
    parser.add_argument('--sample', action='store_true')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    for repeat in range(1, args.repeats + 1):
        for mode in ('drained-control', 'resume-read', 'stop-without-reading'):
            trial(args.helper.resolve(), args.output, mode, repeat, args.sample)


if __name__ == '__main__':
    main()
