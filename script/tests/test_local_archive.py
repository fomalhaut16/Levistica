"""Exercise the real shell entry with command stubs; never signal real apps."""
import json
import os
import pathlib
import plistlib
import shlex
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
STUB = r'''#!/usr/bin/env python3
import json, os, pathlib, plistlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ['ARCHIVE_TEST_ROOT'])
with (root/'events.jsonl').open('a') as f: f.write(json.dumps({'command':name,'args':args})+'\n')
if name == 'xcodebuild':
    def arg(flag): return args[args.index(flag)+1]
    if args[-1] == 'archive':
        archive = pathlib.Path(arg('-archivePath'))
        app = archive/'Products/Applications/Levistica.app'
    else:
        app = pathlib.Path(arg('-derivedDataPath'))/'Build/Products'/arg('-configuration')/'Levistica.app'
    app.joinpath('Contents/MacOS').mkdir(parents=True, exist_ok=True)
    values = dict(x.split('=',1) for x in args if '=' in x and not x.startswith('-'))
    info = {'CFBundleIdentifier':'dev.fomalhaut16.Levistica',
            'LevisticaSourceRevision':values['LEVISTICA_SOURCE_REVISION'],
            'LevisticaSourceState':values['LEVISTICA_SOURCE_STATE']}
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    (app/'Contents/MacOS/Levistica').write_bytes(b'synthetic archive binary')
elif name == 'codesign':
    if '-d' in args:
        sys.stdout.buffer.write(plistlib.dumps({'com.apple.security.app-sandbox':True,
                                              'com.apple.security.network.client':True}))
elif name == 'PlistBuddy':
    key = args[1].split(' :',1)[1]
    data = plistlib.loads(pathlib.Path(args[2]).read_bytes())
    if key not in data: sys.exit(1)
    value = data[key]
    print(str(value).lower() if isinstance(value,bool) else value)
elif name == 'pgrep': print('123')
elif name == 'ps': print(root/'.local/DerivedData/Build/Products/Release/Levistica.app/Contents/MacOS/Levistica')
elif name == 'kill':
    if '-0' in args: sys.exit(1)
else:
    sys.exit(98)
'''


class LocalArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)/'checkout with spaces'
        script = self.root/'script'; script.mkdir(parents=True)
        tools = self.root/'fake tools'; tools.mkdir()
        commands = {'/usr/bin/pgrep':'pgrep', '/bin/ps':'ps', '/bin/kill':'kill',
                    '/usr/bin/xcodebuild':'xcodebuild', '/usr/bin/codesign':'codesign',
                    '/usr/libexec/PlistBuddy':'PlistBuddy', '/usr/bin/open':'open',
                    '/usr/bin/xcrun':'xcrun', '/usr/bin/log':'log'}
        text = (ROOT/'script/build_and_run.sh').read_text()
        for original, name in commands.items():
            path = tools/name; path.write_text(STUB); path.chmod(0o700)
            text = text.replace(original, shlex.quote(str(path)))
        self.entry = script/'build_and_run.sh'; self.entry.write_text(text)
        (script/'check-app-processes.py').write_text("import os,json,pathlib\np=pathlib.Path(os.environ['ARCHIVE_TEST_ROOT'])/'events.jsonl'\nwith p.open('a') as f:f.write(json.dumps({'command':'preflight','args':[]})+'\\n')\n")
        self.normal = self.root/'.local/DerivedData/Build/Products/Release/Levistica.app'
        (self.normal/'Contents/MacOS').mkdir(parents=True)
        (self.normal/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'dev.fomalhaut16.Levistica'}))
        self.sentinel = self.normal/'Contents/MacOS/Levistica'
        self.sentinel.write_bytes(b'leave the running binary unchanged')
        self.environment = {k:v for k,v in os.environ.items() if not k.startswith('LEVISTICA_') and k != 'CONFIGURATION'}
        self.environment.update(CONFIGURATION='Release', ARCHIVE_TEST_ROOT=str(self.root))

    def run_entry(self, mode='--archive-local', **environment):
        return subprocess.run(['bash', str(self.entry), mode], env={**self.environment, **environment},
                              capture_output=True, text=True, timeout=10)

    def events(self):
        path = self.root/'events.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_archive_builds_in_fresh_directories_without_discovery_stop_or_launch(self):
        for _ in range(2):
            result = self.run_entry()
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            self.assertIn('Local archive:', result.stdout)
            self.assertIn('Local validation only', result.stdout)
        events = self.events()
        self.assertEqual({event['command'] for event in events}, {'xcodebuild','codesign','PlistBuddy'})
        builds = [event['args'] for event in events if event['command']=='xcodebuild']
        archives = [pathlib.Path(args[args.index('-archivePath')+1]) for args in builds]
        self.assertEqual(len(set(archives)), 2)
        for args, archive in zip(builds, archives):
            self.assertEqual(args[-1], 'archive')
            self.assertEqual(archive.parent.parent, self.root/'.local/archives')
            self.assertEqual(pathlib.Path(args[args.index('-derivedDataPath')+1]), archive.parent/'DerivedData')
            self.assertTrue((archive/'Products/Applications/Levistica.app/Contents/Info.plist').exists())
            self.assertEqual(archive.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.sentinel.read_bytes(), b'leave the running binary unchanged')

    def test_diagnostic_test_and_debug_requests_are_rejected_before_commands(self):
        for changed in [dict(CONFIGURATION='Debug'),dict(LEVISTICA_EPHEMERAL='1'),
                        dict(LEVISTICA_PROFILE='1'),dict(LEVISTICA_MEASUREMENT='1'),
                        dict(LEVISTICA_MALLOC_STACKS='1'),dict(LEVISTICA_MEASUREMENT_PERSIST_METADATA='1'),
                        dict(LEVISTICA_MEASUREMENT_STORE_ID='d575e91e-e879-40ff-913c-96d4101cbe11'),
                        dict(LEVISTICA_SESSION_TEST_ID='d575e91e-e879-40ff-913c-96d4101cbe11')]:
            with self.subTest(changed=changed):
                result = self.run_entry(**changed)
                self.assertEqual(result.returncode, 2, result.stdout+result.stderr)
                self.assertEqual(self.events(), [])
                self.assertFalse((self.root/'.local/archives').exists())

    def test_archive_refuses_a_linked_output_parent_before_commands(self):
        outside = self.root/'elsewhere'; outside.mkdir()
        (self.root/'.local/archives').symlink_to(outside, target_is_directory=True)
        result = self.run_entry()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.events(), [])
        self.assertEqual(list(outside.iterdir()), [])

    def test_original_build_mode_still_checks_and_stops_its_known_process(self):
        result = self.run_entry('--build')
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        names = [event['command'] for event in self.events()]
        self.assertIn('preflight', names)
        self.assertIn('pgrep', names)
        self.assertIn('kill', names)
        self.assertNotIn('open', names)
        args = next(e['args'] for e in self.events() if e['command']=='xcodebuild')
        self.assertEqual(args[-1], 'build')
        self.assertNotIn('-archivePath', args)
