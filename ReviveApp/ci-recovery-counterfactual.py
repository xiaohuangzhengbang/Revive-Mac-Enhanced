#!/usr/bin/env python3
"""Prove the native recovery regression fails if fallback cannot drive media.

Only an isolated package copy is mutated. The app source checkout is read-only.
"""
from pathlib import Path
import hashlib
import importlib.util
import json
import os
import platform
import re
import signal
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent
if sys.platform != 'darwin': raise SystemExit('Native counterfactual requires macOS.')
OUT = ROOT / 'build/ci-evidence/Counterfactual'
OUT.mkdir(parents=True, exist_ok=True)
original = (ROOT / 'Sources/Revive/Engine.swift').read_bytes()
needle = b'                    onRecovery?()\n                    drive()'
normalized = original.replace(b'\r\n', b'\n')
assert normalized.count(needle) == 1
mutated = normalized.replace(needle, b'                    onRecovery?()\n                    // Counterfactual: intentionally omit the production drive.')
source = os.environ.get('GITHUB_SHA', 'LOCAL_NATIVE_TEST')
spec = importlib.util.spec_from_file_location('recovery_validator', ROOT / 'ci-verify-writer-recovery.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory(prefix='Revive-Recovery-Counterfactual-') as temporary:
    package = Path(temporary) / 'ReviveApp'
    package.mkdir()
    shutil.copy2(ROOT / 'Package.swift', package / 'Package.swift')
    for folder in ('Sources', 'Tests'):
        shutil.copytree(ROOT / folder, package / folder)
    (package / 'Sources/Revive/Engine.swift').write_bytes(mutated)
    log = OUT / 'NativeCounterfactual.log'
    with log.open('wb') as handle:
        process = subprocess.Popen(['swift', 'test', '-c', 'release', '--filter',
            'testNativeStalledWriterResumesViaFallbackAndPreservesPair'], cwd=package,
            stdout=handle, stderr=subprocess.STDOUT, start_new_session=True)
        started, case_started, sampled = time.monotonic(), None, False
        def owned_pids():
            lines = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True).splitlines()
            return [int(line.split(None, 1)[0]) for line in lines if str(package / '.build') in line
                    and 'RevivePackageTests.xctest' in line]
        try:
            while process.poll() is None:
                text = log.read_text(encoding='utf-8', errors='replace')
                if case_started is None and re.search(r'Test Case .*testNativeStalledWriterResumesViaFallbackAndPreservesPair.*started', text):
                    case_started = time.monotonic()
                age = time.monotonic() - case_started if case_started is not None else 0
                if age >= 20 and not sampled:
                    sampled = True
                    for pid in owned_pids():
                        subprocess.run(['sample', str(pid), '3', '-file', str(OUT / f'Counterfactual-Hang-{pid}.txt')],
                                       capture_output=True, timeout=12, check=False)
                if age > 45 or time.monotonic() - started > 600:
                    raise RuntimeError('Counterfactual XCTest did not exit after its own cancellation deadline')
                time.sleep(1)
        finally:
            if process.poll() is None:
                for pid in owned_pids():
                    try: os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError: pass
                os.killpg(process.pid, signal.SIGKILL)
            return_code = process.wait()
    assert return_code != 0, 'A disabled fallback must fail the positive native recovery regression'
    receipts = list((package / 'build/ci-evidence').glob('WriterRecovery-release-positive-*.json'))
    assert len(receipts) == 1, 'Expected an actual first-cycle recovery assertion failure, not a build error'
    receipt = module.validate_receipt(receipts[0], source, platform.machine(), counterfactual=True)
    details = OUT / 'FailedNativeRecovery'
    shutil.copytree(package / 'build/ci-evidence', details, dirs_exist_ok=True)
    assert (ROOT / 'Sources/Revive/Engine.swift').read_bytes() == original
    report = {'status': 'EXPECTED_NATIVE_RECOVERY_TEST_FAILURE_CONFIRMED', 'sourceCommit': source,
        'architecture': platform.machine(), 'configuration': 'release', 'testExitCode': return_code,
        'originalEngineSHA256': hashlib.sha256(original).hexdigest(),
        'mutatedEngineSHA256': hashlib.sha256(mutated).hexdigest(),
        'mutation': 'Omit only fallback drive invocation in isolated package copy', 'receipt': receipt}
    (OUT / 'CounterfactualVerification.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))
