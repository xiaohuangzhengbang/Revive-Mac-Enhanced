#!/usr/bin/env python3
"""Supervise a fixed native XCTest budget and sample only this test process."""
from datetime import datetime, timezone
from pathlib import Path
import json
import hashlib
import os
import platform
import signal
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent
OUT = ROOT / 'build/writer-diagnostics'
OUT.mkdir(parents=True, exist_ok=True)
if sys.platform != 'darwin':
    raise SystemExit('Native writer diagnostics require macOS.')
iterations = int(os.environ.get('REVIVE_STRESS_ITERATIONS', '40'))
assert 1 <= iterations <= 1000
env = os.environ.copy()
env['REVIVE_STRESS_ITERATIONS'] = str(iterations)
metadata_delay = int(env.get('REVIVE_WRITER_META_DELAY_MS', '0') or '0')
assert 0 <= metadata_delay <= 250
env['REVIVE_WRITER_META_DELAY_MS'] = str(metadata_delay)
env['REVIVE_WRITER_TRACE_DIR'] = str(OUT)
engine_ref = env.get('REVIVE_DIAGNOSTIC_ENGINE_REF', '')
allowed_baselines = {'cfebf02826f2bd9790a82b62d9b1a9e506e6fe46',
                     '7e11055dd2db2942d9b29c9770fbda3a1eaeb331'}
if engine_ref:
    assert engine_ref in allowed_baselines and metadata_delay == 0
    subprocess.run(['git', 'fetch', '--depth=1', 'origin', engine_ref], cwd=ROOT, check=True)
    historical = subprocess.check_output(['git', 'show', engine_ref + ':ReviveApp/Sources/Revive/Engine.swift'], cwd=ROOT)
    (ROOT / 'Sources/Revive/Engine.swift').write_bytes(historical)
    (OUT / 'CounterfactualEngine.swift.txt').write_bytes(historical)
environment = {'sourceCommit': env.get('GITHUB_SHA'), 'architecture': platform.machine(),
    'iterations': iterations, 'reuseItem': env.get('REVIVE_STRESS_REUSE_ITEM', '0'),
    'metadataDelayMs': metadata_delay,
    'engineReference': engine_ref or env.get('GITHUB_SHA'),
    'engineSourceSHA256': hashlib.sha256((ROOT / 'Sources/Revive/Engine.swift').read_bytes()).hexdigest(),
    'testFilter': 'EngineTests|testRepeatedNativePreviewsKeepProducingVerifiedPairs',
    'startedAtUtc': datetime.now(timezone.utc).isoformat()}
(OUT / 'Environment.json').write_text(json.dumps(environment, indent=2), encoding='utf-8')
log_path = OUT / 'NativeStress.log'
test_log = log_path.open('wb')
process = subprocess.Popen(['swift', 'test', '--filter', environment['testFilter']],
    cwd=ROOT, env=env, stdout=test_log, stderr=subprocess.STDOUT, start_new_session=True)
started = time.monotonic()
last_iteration = None
iteration_started = None
sampled = set()
forced = False

def test_pids():
    """Match the exact executable under our checkout, never other user apps."""
    text = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True)
    found = []
    for line in text.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and str(ROOT / '.build') in fields[1] and \
                'RevivePackageTests.xctest' in fields[1]:
            pid = int(fields[0])
            if os.getpgid(pid) == process.pid:
                found.append(pid)
    return found

def sample(reason):
    # Preserve the closed intermediate movie even for historical engines that
    # have no in-process trace. This only reads our synthetic test scratch root.
    for source in Path(tempfile.gettempdir()).glob('Revive-*/Preview_*/.revive-*/prepared.MOV'):
        destination = OUT / f'Forensic-{last_iteration}-{source.parent.name}'
        destination.mkdir(exist_ok=True)
        for media in (source, source.with_name('IMG_LIVE.MOV')):
            target = destination / media.name
            if media.exists() and not target.exists():
                try:
                    shutil.copy2(media, target)
                except OSError as error:
                    (destination / 'CopyError.txt').write_text(str(error), encoding='utf-8')
    for pid in test_pids():
        target = OUT / f'Stack-{last_iteration}-{reason}-pid{pid}.txt'
        try:
            subprocess.run(['sample', str(pid), '3', '-file', str(target)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=12, check=False)
        except subprocess.TimeoutExpired:
            (OUT / 'SamplerTimeout.txt').write_text('sample did not return in 12 seconds', encoding='utf-8')

try:
    while process.poll() is None:
        ledger = OUT / 'StressIterations.jsonl'
        if ledger.exists():
            rows = []
            for line in ledger.read_text(encoding='utf-8').splitlines():
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    pass  # The writer may currently be completing the last line.
            if rows:
                latest = rows[-1]
                key = latest.get('iteration')
                event = latest.get('event')
                if event == 'start' and key != last_iteration:
                    last_iteration = key
                    iteration_started = time.monotonic()
                elif event in ('finish', 'failed'):
                    iteration_started = None
        if iteration_started is not None:
            age = time.monotonic() - iteration_started
            for threshold in (20, 40, 90):
                key = (last_iteration, threshold)
                if age >= threshold and key not in sampled:
                    sampled.add(key)
                    sample(str(threshold) + 's')
            if age > 210:
                sample('hard-deadline')
                forced = True
                break
        if time.monotonic() - started > 20 * 60:
            sample('job-deadline')
            forced = True
            break
        time.sleep(2)
finally:
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
    return_code = process.wait()
    test_log.close()

ledger = OUT / 'StressIterations.jsonl'
rows = [json.loads(line) for line in ledger.read_text(encoding='utf-8').splitlines()] if ledger.exists() else []
finishes = [r for r in rows if r.get('event') == 'finish']
failures = [r for r in rows if r.get('event') == 'failed']
passed = not forced and return_code == 0 and len(finishes) == iterations and not failures
summary = {**environment, 'status': 'PASS_WITHIN_FIXED_BUDGET' if passed else 'FAILURE_OR_HANG_CAPTURED',
    'testExitCode': return_code, 'forcedTermination': forced,
    'completedIterations': len(finishes), 'failedIterations': len(failures),
    'elapsedSeconds': time.monotonic() - started}
(OUT / 'DiagnosticSummary.json').write_text(json.dumps(summary, indent=2), encoding='utf-8')
print(json.dumps(summary, indent=2))
if not passed:
    print(log_path.read_text(encoding='utf-8', errors='replace')[-16000:])
raise SystemExit(0 if passed else 1)
