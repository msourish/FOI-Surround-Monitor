#!/usr/bin/python3
"""Public selection/manifest tests. All native discovery and starts are mocked."""
import argparse
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import monitor_backend as m


def output(uid='test-output-one',name='Example HDMI output',available=True):
    return {'uid':uid,'name':name,'sample_rate':48000,'encoded_format':'cac3',
        'available':available,'unavailable_reason':None if available else 'device_occupied'}


class PublicOutputs(unittest.TestCase):
    def runtime(self,path):
        for name in m.REQUIRED_FILES:
            item=path/name;item.write_bytes(('example local build: '+name).encode());item.chmod(0o700)
        (path/'backend_manifest.json').write_text(json.dumps({'schema_version':1,
            'files':{name:m.sha(path/name) for name in m.REQUIRED_FILES}}))

    def test_safe_unique_and_explicit_selection(self):
        one=output();two=output('test-output-two','Another HDMI output')
        self.assertEqual(m.select_output([one]),one)
        self.assertEqual(m.select_output([one,two],two['uid']),two)
        for values,requested in (([],None),([one,two],None),([one],'missing-output'),
                ([output(available=False)],None),([one,output('busy',available=False)],None)):
            with self.assertRaises(RuntimeError):m.select_output(values,requested)

    def test_inventory_rejects_wrong_format_or_identity(self):
        self.assertEqual(m.validate_output_inventory({'schema_version':1,'outputs':[output()]}),[output()])
        variants=[{**output(),'sample_rate':44100},{**output(),'encoded_format':'lpcm'},
            {**output(),'available':1},{**output(),'uid':'bad\nuid'},{**output(),'uid':'bad"uid'},
            {**output(),'uid':'bad\\uid'}]
        for candidate in variants:
            with self.assertRaises(ValueError):m.validate_output_inventory({'schema_version':1,'outputs':[candidate]})
        with self.assertRaises(ValueError):m.validate_output_inventory({'schema_version':1,'outputs':[output(),output()]})

    def test_local_encoder_hash_is_accepted_but_tampering_is_not(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);self.runtime(root)
            self.assertEqual(m.verify_runtime(root)['ffmpeg'],m.sha(root/'ffmpeg'))
            (root/'ffmpeg').write_bytes(b'changed after manifest')
            with self.assertRaises(ValueError):m.verify_runtime(root)
            self.runtime(root);(root/'ffmpeg').chmod(0o600)
            with self.assertRaises(ValueError):m.verify_runtime(root)

    def test_symlinked_executable_is_refused_even_with_matching_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);self.runtime(root)
            target=root/'encoder-target';(root/'ffmpeg').rename(target);(root/'ffmpeg').symlink_to(target)
            with self.assertRaises(ValueError):m.verify_runtime(root)

    def test_discovery_verifies_before_calling_read_only_native_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);self.runtime(root)
            native=SimpleNamespace(returncode=0,stdout=json.dumps({'schema_version':1,'outputs':[output()]}).encode(),stderr=b'')
            with patch.object(m.subprocess,'run',return_value=native) as run:
                self.assertEqual(m.discover_outputs(root),[output()])
                self.assertEqual(run.call_args.args[0],[str(root/'coreaudio_ac3_monitor_sink'),'--list-compatible'])
                self.assertEqual(run.call_args.kwargs['stdin'],m.subprocess.DEVNULL)
                self.assertEqual(run.call_args.kwargs['timeout'],5)
            (root/'coreaudio_ac3_monitor_sink').write_bytes(b'mismatch')
            with patch.object(m.subprocess,'run') as run:
                with self.assertRaises(ValueError):m.discover_outputs(root)
                run.assert_not_called()

    def test_device_disappearing_after_discovery_has_no_fallback(self):
        args=argparse.Namespace(session_dir='/tmp/public-selection-offline',
            status_json='/tmp/public-selection-offline/status.json',
            stop_file='/tmp/public-selection-offline/stop.request',parent_pid=None,output_device='test-selected-output')
        monitor=m.Monitor(args)
        self.assertEqual(monitor.snapshot()['output']['uid'],'test-selected-output')
        self.assertEqual(monitor.lock_path,Path('/tmp')/('foi-fairlight-monitor-'+str(os.getuid())+'.lock'))
        commands=monitor.commands()
        self.assertEqual(commands['sink'][commands['sink'].index('--device')+1],'test-selected-output')
        self.assertEqual(Path(commands['encoder'][0]).name,'ffmpeg')
        wrong={'continuous':True,'device_uid':'different-output','format':'cac3','carrier_sample_rate':48000,
            'required_encoded_channels':6,'prebuffer_bursts':2,'input_read':False,'audio_device_started':False}
        with patch.object(monitor,'spawn',return_value=object()) as spawn,patch.object(monitor,'wait_ready',return_value=wrong):
            with self.assertRaises(RuntimeError):monitor.start()
            self.assertEqual(spawn.call_count,1)

    def test_encoder_command_retains_verified_audio_parameters(self):
        command=m.encoder_command(Path('/example/bundled/ffmpeg'))
        for option,value in (('-max_size','36864'),('-c:a','ac3'),('-b:a','448k'),('-ar','48000'),('-dialnorm','-31')):
            self.assertEqual(command[command.index(option)+1],value)
        self.assertEqual(command[-3:],['-f','spdif','pipe:1'])
        self.assertNotIn('-af',command);self.assertNotIn('-re',command)


if __name__=='__main__':unittest.main(verbosity=2)
