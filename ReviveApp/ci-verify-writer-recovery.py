#!/usr/bin/env python3
"""Fail closed unless real native stalled writes were resumed and verified."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import platform

FIXTURE = '9dd43aa46f2a77c386999a3dd493c3811b32ed335c17cee860f0dd34c8c8e334'

def validate_receipt(path, source, architecture, counterfactual=False):
    data = json.loads(path.read_text(encoding='utf-8'))
    assert data['sourceCommit'] == source and data['architecture'] == architecture
    assert data['faultKind'] == 'CONTROLLED_NATIVE_CALLBACK_DELIVERY_LOSS'
    assert data['sourceFixtureSHA256'] == FIXTURE and data['sourceUnchanged'] is True
    assert data['expectedAudioSamples'] == 142 and data['expectedVideoSamples'] == 91
    assert data['recordingFailure'] is None and data['nativeCallbackForwardingRemainedDisabled'] is True
    events = data['events']
    assert [e['sequence'] for e in events] == list(range(1, len(events) + 1))
    assert all(e['operationID'] == data['operationID'] for e in events)
    assert all(a['monotonicSeconds'] <= b['monotonicSeconds'] for a, b in zip(events, events[1:]))
    journal = path.with_name(data['eventJournal'])
    assert journal.parent == path.parent
    assert [json.loads(line) for line in journal.read_text(encoding='utf-8').splitlines()] == events
    def rows(name, media=None):
        return [e for e in events if e['event'] == name and (media is None or e.get('mediaType') == media)]
    def one(name, media=None):
        found = rows(name, media)
        assert len(found) == 1, (path.name, name, media, len(found))
        return found[0]
    started = one('writer.started')
    assert started['readerIdentity'] and started['writerIdentity']
    for event in events:
        for key in ('readerIdentity', 'writerIdentity'):
            if key in event: assert event[key] == started[key]
    fault = one('test.native.delivery.withheld')
    initial = [e for e in rows('append.success', 'soun') if e['origin'] == 'native']
    assert len(initial) == 1 and initial[0]['bufferSamples'] > 0
    assert initial[0]['sequence'] < fault['sequence']
    checkpoints = rows('test.stall.checkpoint', 'soun')
    stall = one('test.stall.confirmed', 'soun')
    assert len(checkpoints) >= 2 and stall['stableSeconds'] >= 1 and stall['progressAgeSeconds'] >= 1
    before = stall['readSamples']
    assert 0 < before < 142 and stall['appendBuffers'] == 1
    for checkpoint in checkpoints:
        assert checkpoint['readSamples'] == before and checkpoint['appendBuffers'] == 1
        assert checkpoint['ready'] is True and checkpoint['finished'] is False and checkpoint['eof'] is False
        assert checkpoint['markAsFinishedReturned'] is False
        assert checkpoint['readerStatus'] == checkpoint['writerStatus'] == 1
        assert checkpoint['stage'] == 'pumping'
    assert fault['sequence'] < stall['sequence']
    assert one('input.finished', 'meta')['sequence'] < stall['sequence']
    appended = [e for e in rows('append.success', 'soun') if e['origin'] == 'fallback' and e['bufferSamples'] > 0]
    summary = {'receipt': path.name, 'operationID': data['operationID'], 'mode': data['mode'],
        'configuration': data['configuration'], 'architecture': architecture,
        'beforeAudioSamples': before, 'expectedAudioSamples': 142,
        'stallSeconds': stall['stableSeconds'], 'receiptSHA256': hashlib.sha256(path.read_bytes()).hexdigest()}
    if data['mode'] == 'positive':
        armed = one('test.recovery.armed', 'soun')
        entries = rows('fallback.enter', 'soun')
        assert stall['sequence'] < armed['sequence'] and entries
        assert armed['sequence'] < entries[0]['sequence']
        if counterfactual:
            assert data['status'] == 'FAIL' and not appended
            assert not rows('completion.success') and not rows('test.files.verified')
            assert 'RECOVERY_EXPECTED_APPEND_NOT_OBSERVED' in data['error']
            assert one('test.deadline.expired') and one('completion.failure')
            summary['counterfactual'] = 'REAL_STALL_ARMED_TIMER_ENTERED_BUT_NO_APPEND_TEST_FAILED'
            return summary
        assert data['status'] == 'PASS' and appended
        assert entries[0]['sequence'] < appended[0]['sequence']
        assert appended[0]['readSamples'] > before and appended[0]['appendBuffers'] > 1
        assert sum(e['bufferSamples'] for e in rows('append.success', 'soun')) == 142
        assert sum(e['bufferSamples'] for e in rows('append.success', 'vide')) == 91
        assert appended[0]['sequence'] < one('input.eof', 'soun')['sequence']
        for media in ('soun', 'vide'):
            assert one('input.eof', media)['sequence'] < one('input.finished', media)['sequence']
        finishes = [one('input.finished', media) for media in ('soun', 'vide', 'meta')]
        assert all(e['markAsFinishedReturned'] is True for e in finishes)
        finish = one('writer.finish.enter')
        callback = one('writer.finish.callback')
        completed = one('completion.success')
        verified = one('test.files.verified')
        assert max(e['sequence'] for e in finishes) < finish['sequence'] < callback['sequence'] < completed['sequence'] < verified['sequence']
        assert callback['writerStatus'] == 2 and not rows('completion.failure')
        pair = data['pair']
        assert data['pairValidation'] == 'STRICT_JPG_MOV_AND_COMPRESSED_PAYLOAD_PASS'
        assert pair['sourceUnchanged'] and pair['compressedAudioPreserved'] and pair['compressedVideoPreserved']
        assert pair['audioSamples'] == 142 and pair['videoSamples'] == 91
        checks = {check['code']: check['status'] for check in pair['checks']}
        assert checks and all(value == 'pass' for value in checks.values())
        assert {'image.decode', 'video.decode', 'audio.decode', 'pair.assetID', 'video.stillImageTime', 'video.duration'} <= checks.keys()
        for kind in ('image', 'movie'):
            media = path.parent / pair[kind + 'File']
            assert media.resolve().is_relative_to(path.parent.resolve()) and not media.is_symlink()
            assert hashlib.sha256(media.read_bytes()).hexdigest() == pair[kind + 'SHA256']
        summary.update({'resumedAudioSamples': 142 - before, 'afterAudioSamples': 142,
            'recoveryAppendSeconds': appended[0]['monotonicSeconds'] - armed['monotonicSeconds'],
            'pairAssetID': pair['assetID'], 'movieSHA256': pair['movieSHA256']})
    else:
        assert not counterfactual and data['mode'] == 'negative' and data['status'] == 'PASS'
        held = one('test.negative.control.held', 'soun')
        assert held['stableSeconds'] >= 2 and held['sequence'] > stall['sequence']
        assert not data['recoveryArmed'] and not rows('test.recovery.armed')
        assert not rows('fallback.enter', 'soun') and not appended
        assert not rows('completion.success') and not rows('writer.finish.callback')
        assert held['sequence'] < one('test.cancellation.requested')['sequence'] < one('completion.failure')['sequence'] < one('test.cancellation.completed')['sequence']
        assert data['cancelledThroughNativeFailureDrain'] is True
    return summary

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--directory', type=Path, default=Path(__file__).resolve().parent / 'build/ci-evidence')
    p.add_argument('--source', default=os.environ.get('GITHUB_SHA', 'LOCAL_NATIVE_TEST'))
    p.add_argument('--architecture', default=platform.machine())
    args = p.parse_args()
    paths = sorted(args.directory.glob('WriterRecovery-*.json'))
    summaries = [validate_receipt(path, args.source, args.architecture) for path in paths]
    assert len(summaries) == 8
    for configuration in ('debug', 'release'):
        selected = [r for r in summaries if r['configuration'] == configuration]
        assert sum(r['mode'] == 'positive' for r in selected) == 3
        assert sum(r['mode'] == 'negative' for r in selected) == 1
    counterfactual = json.loads((args.directory / 'Counterfactual/CounterfactualVerification.json').read_text(encoding='utf-8'))
    assert counterfactual['status'] == 'EXPECTED_NATIVE_RECOVERY_TEST_FAILURE_CONFIRMED'
    assert counterfactual['sourceCommit'] == args.source and counterfactual['architecture'] == args.architecture
    engine = Path(__file__).resolve().parent / 'Sources/Revive/Engine.swift'
    checksum = hashlib.sha256(engine.read_bytes()).hexdigest()
    assert counterfactual['originalEngineSHA256'] == checksum
    report = {'status': 'NATIVE_STALL_RECOVERY_AND_NEGATIVE_CONTROLS_VERIFIED',
        'sourceCommit': args.source, 'architecture': args.architecture, 'engineSHA256': checksum,
        'faultKind': 'CONTROLLED_NATIVE_CALLBACK_DELIVERY_LOSS', 'positiveRecoveries': 6,
        'negativeControls': 2, 'counterfactualVerified': True, 'results': summaries}
    (args.directory / 'WriterRecoveryVerification.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))

if __name__ == '__main__': main()
