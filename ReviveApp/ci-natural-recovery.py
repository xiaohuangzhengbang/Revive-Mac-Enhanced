#!/usr/bin/env python3
"""Capture a naturally stalled native writer and verify the same writer recovers.

Normal successful loops never satisfy this gate. Native callbacks and their
sample processing are not suppressed, delayed or replaced by this experiment.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import platform
import signal
import subprocess
import sys
import time
import uuid

FIXTURE = '9dd43aa46f2a77c386999a3dd493c3811b32ed335c17cee860f0dd34c8c8e334'

def validate_natural(path, source, architecture):
    data = json.loads(path.read_text(encoding='utf-8'))
    assert data['status'] == 'NATURE_RECOVERED'
    assert data['sourceCommit'] == source and data['architecture'] == architecture
    assert data['configuration'] == 'release' and data['evidenceKind'] == 'NATURAL_NATIVE_CALLBACK_STALL'
    assert data['artificialFaultInjected'] is False and data['perBufferInstrumentationBeforeFallback'] is False
    assert data['nativeCallbackHookInvocations'] == data['yieldHookInvocations'] == 0
    assert data['productionNoProgressTimeoutSeconds'] == 120
    assert data['sourceFixtureSHA256'] == FIXTURE
    assert data['expectedAudioSamples'] == 142 and data['expectedVideoSamples'] == 91
    assert data['naturalStallsObserved'] == data['nativeRecoveriesVerified'] == 1
    count = data['recoveredAttempt']
    assert 1 <= count == data['attemptsStarted'] == data['attemptsCompleted'] <= data['attemptsBudget']
    assert [row['iteration'] for row in data['attempts']] == list(range(1, count + 1))
    assert all(row['status'] == 'NORMAL_WRITE_COMPLETED_NO_STALL' for row in data['attempts'][:-1])
    assert data['attempts'][-1]['status'] == 'NATURE_RECOVERED'
    attempt_path = path.parent / data['recoveryReceiptFile']
    assert attempt_path.parent == path.parent
    attempt = json.loads(attempt_path.read_text(encoding='utf-8'))
    assert attempt['status'] == 'NATURE_RECOVERED' and attempt['sourceCommit'] == source
    assert attempt['artificialFaultInjected'] is False and attempt['naturalStallObserved'] is True
    assert attempt['nativeCallbackHookInvocations'] == attempt['yieldHookInvocations'] == 0
    assert attempt['evidenceKind'] == data['evidenceKind'] and attempt['configuration'] == 'release'
    events = attempt['events']
    assert [row['sequence'] for row in events] == list(range(1, len(events) + 1))
    assert all(row['operationID'] == attempt['operationID'] for row in events)
    assert all(a['capturedAtUptime'] <= b['capturedAtUptime'] for a, b in zip(events, events[1:]))
    journal = path.parent / data['recoveryEventFile']
    assert journal.parent == path.parent
    assert attempt['eventFile'] == journal.name
    assert events == [json.loads(line) for line in journal.read_text(encoding='utf-8').splitlines()]
    assert not any(row['event'] == 'driver.yielded' or 'withheld' in row['event'] or 'forbidden' in row['event'] for row in events)
    def rows(name, media=None):
        return [row for row in events if row['event'] == name and (media is None or row.get('mediaType') == media)]
    def one(name, media=None):
        selected = rows(name, media)
        assert len(selected) == 1, (name, media, len(selected))
        return selected[0]
    start = one('writer.started')
    assert start['passiveNaturalCapture'] is True
    for row in events:
        for field in ('readerIdentity', 'writerIdentity'):
            if field in row: assert row[field] == start[field]
    stall = one('test.natural.stall.confirmed', 'soun')
    checkpoints = rows('test.natural.stall.checkpoint', 'soun')
    assert len(checkpoints) >= 2 and stall['stableSeconds'] >= 1 and stall['progressAgeSeconds'] >= 2
    assert stall['readerStatus'] == stall['writerStatus'] == 1 and stall['stage'] == 'pumping'
    assert stall['ready'] is True and stall['eof'] is False and stall['finished'] is False
    before = stall['readSamples']
    assert 0 < before < 142 and stall['appendBuffers'] > 0 and stall['fallbackDrives'] == 0
    stable = [row for row in checkpoints if row.get('checkpointStartedAtUptime') == stall['checkpointStartedAtUptime']]
    assert len(stable) >= 2
    assert all(row['readSamples'] == before and row['appendBuffers'] == stall['appendBuffers']
               and row['ready'] is True and row['fallbackDrives'] == 0 for row in stable)
    metadata = one('input.finished', 'meta')
    assert metadata['sequence'] < stall['sequence'] and metadata['markAsFinishedReturned'] is True
    armed = one('test.natural.recovery.armed', 'soun')
    entries = rows('fallback.enter', 'soun')
    assert entries and stall['sequence'] < armed['sequence'] < entries[0]['sequence']
    resumed = [row for row in rows('append.success', 'soun') if row['origin'] == 'fallback'
               and row['bufferSamples'] > 0 and row['sequence'] > entries[0]['sequence']]
    assert resumed and resumed[0]['readSamples'] > before and resumed[0]['appendBuffers'] > stall['appendBuffers']
    all_appends_after_entry = [row for row in rows('append.success', 'soun')
                              if row['bufferSamples'] > 0 and row['sequence'] > entries[0]['sequence']]
    assert before + sum(row['bufferSamples'] for row in all_appends_after_entry) == 142
    eof = one('input.eof', 'soun')
    assert eof['readSamples'] == 142 and eof['eof'] is True
    assert resumed[-1]['sequence'] < eof['sequence']
    for media in ('soun', 'vide'):
        assert one('input.eof', media)['sequence'] < one('input.finished', media)['sequence']
        assert one('input.finished', media)['markAsFinishedReturned'] is True
    finish = one('writer.finish.enter')
    callback = one('writer.finish.callback')
    completed = one('completion.success')
    files = one('test.files.verified')
    assert max(one('input.finished', media)['sequence'] for media in ('soun', 'vide', 'meta')) < finish['sequence']
    assert finish['sequence'] < callback['sequence'] < completed['sequence'] < files['sequence']
    assert callback['writerStatus'] == completed['writerStatus'] == 2
    assert not rows('completion.failure') and not rows('test.deadline.expired')
    pair = data['pair']
    assert pair == attempt['pair']
    assert pair['sourceUnchanged'] and pair['compressedVideoPreserved'] and pair['compressedAudioPreserved']
    assert pair['audioSamples'] == 142 and pair['videoSamples'] == 91
    checks = {check['code']: check['status'] for check in pair['checks']}
    assert all(value == 'pass' for value in checks.values())
    assert {'image.decode', 'video.decode', 'audio.decode', 'pair.assetID', 'video.stillImageTime', 'video.duration'} <= checks.keys()
    for kind in ('image', 'movie'):
        media = path.parent / pair[kind + 'File']
        assert media.resolve().is_relative_to(path.parent.resolve()) and not media.is_symlink()
        assert hashlib.sha256(media.read_bytes()).hexdigest() == pair[kind + 'SHA256']
    return {'status': 'NATURAL_NATIVE_STALL_AND_SAME_WRITER_RECOVERY_VERIFIED', 'sourceCommit': source,
        'architecture': architecture, 'configuration': 'release', 'attempt': count,
        'operationID': attempt['operationID'], 'readerIdentity': start['readerIdentity'], 'writerIdentity': start['writerIdentity'],
        'beforeAudioSamples': before, 'afterAudioSamples': 142,
        'actualFallbackBufferSamples': [row['bufferSamples'] for row in resumed],
        'stableSeconds': stall['stableSeconds'], 'globalNoProgressSeconds': stall['progressAgeSeconds'],
        'nativeCallbackHookInvocations': 0, 'yieldHookInvocations': 0, 'artificialFaultInjected': False,
        'summaryFile': path.name, 'summarySHA256': hashlib.sha256(path.read_bytes()).hexdigest(),
        'pair': pair}

def main():
    root = Path(__file__).resolve().parent
    if sys.platform != 'darwin': raise SystemExit('Natural native capture requires macOS.')
    evidence = root / 'build/ci-evidence'
    output = evidence / ('Natural-' + str(uuid.uuid4()))
    output.mkdir(parents=True)
    source, architecture = os.environ.get('GITHUB_SHA', 'LOCAL_NOT_CI_BOUND'), platform.machine()
    env = os.environ.copy()
    env.update(REVIVE_NATURAL_CAPTURE='1', REVIVE_NATURAL_ITERATIONS='500', REVIVE_NATURAL_OUTPUT_DIR=str(output))
    env.pop('REVIVE_WRITER_TRACE_DIR', None)
    log = output / 'NativeNaturalCapture.log'
    forced = False
    with log.open('wb') as handle:
        process = subprocess.Popen(['swift', 'test', '-c', 'release', '--filter',
            'testCapturesNaturalNativeStallAndVerifiesRecovery'], cwd=root, env=env,
            stdout=handle, stderr=subprocess.STDOUT, start_new_session=True)
        started, pending, sampled = time.monotonic(), {}, set()
        def pids():
            lines = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True).splitlines()
            return [int(line.split(None, 1)[0]) for line in lines if str(root / '.build') in line and 'RevivePackageTests.xctest' in line]
        try:
            while process.poll() is None:
                active = [path for path in output.glob('NaturalWriterAttempt-*.jsonl') if not path.with_suffix('.json').exists()]
                for path in active:
                    pending.setdefault(path.name, time.monotonic())
                    age = time.monotonic() - pending[path.name]
                    if age > 20 and path.name not in sampled:
                        sampled.add(path.name)
                        for pid in pids():
                            subprocess.run(['sample', str(pid), '3', '-file', str(output / f'Native-Hang-{pid}.txt')],
                                capture_output=True, timeout=12, check=False)
                    if age > 40: forced = True
                if forced or time.monotonic() - started > 15 * 60:
                    forced = True
                    break
                time.sleep(1)
        finally:
            if process.poll() is None:
                for pid in pids():
                    try: os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError: pass
                os.killpg(process.pid, signal.SIGKILL)
            code = process.wait()
    summaries = list(output.glob('NaturalWriterRecovery-*.json'))
    base = {'sourceCommit': source, 'architecture': architecture, 'configuration': 'release',
        'testExitCode': code, 'forcedTermination': forced,
        'engineSHA256': hashlib.sha256((root / 'Sources/Revive/Engine.swift').read_bytes()).hexdigest(),
        'attemptsBudget': 500, 'evidenceDirectory': output.relative_to(evidence).as_posix()}
    result = {**base, 'status': 'FAIL'}
    try:
        assert len(summaries) == 1
        raw = json.loads(summaries[0].read_text(encoding='utf-8'))
        if raw['status'] == 'NOT_OBSERVED':
            result.update(status='NOT_OBSERVED', attemptsCompleted=raw['attemptsCompleted'])
        else:
            assert code == 0 and not forced
            result.update(validate_natural(summaries[0], source, architecture))
    except Exception as error:
        result['error'] = str(error)
    (evidence / 'NativeNaturalRecoveryVerification.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result, indent=2))
    if result['status'] != 'NATURAL_NATIVE_STALL_AND_SAME_WRITER_RECOVERY_VERIFIED':
        print(log.read_text(encoding='utf-8', errors='replace')[-12000:])
        raise SystemExit(78 if result['status'] == 'NOT_OBSERVED' else 1)

if __name__ == '__main__': main()
