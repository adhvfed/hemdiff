#!/usr/bin/env python3
"""Real executable CLI/MCP contract tests; uses only disposable fixtures and stdlib.
Usage: python3 contract.py /absolute/path/to/hemdiff
"""
import json
import os
import pathlib
import queue
import subprocess
import sys
import tempfile
import threading
import time
import unittest

BINARY = str(pathlib.Path(sys.argv.pop(1)).resolve())

class Client:
    def __init__(self, state):
        self.process = subprocess.Popen([BINARY, '--state-directory', str(state), 'mcp'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.messages = queue.Queue()
        def read():
            for line in self.process.stdout:
                self.messages.put(json.loads(line))
            self.messages.put(None)
        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()
        self.counter = 0
        self.notifications = []
        self.request('initialize', {'protocolVersion': '2025-11-25', 'capabilities': {}, 'clientInfo': {'name': 'hemdiff-tests', 'version': '1'}})
        self.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
    def send(self, value):
        self.process.stdin.write(json.dumps(value).encode() + b'\n'); self.process.stdin.flush()
    def request(self, method, params=None):
        self.counter += 1
        self.send({'jsonrpc': '2.0', 'id': self.counter, 'method': method, 'params': params or {}})
        while True:
            message = self.messages.get(timeout=45)
            if message is None:
                raise AssertionError('MCP exited: ' + self.process.stderr.read().decode())
            if message.get('id') == self.counter: return message
            self.notifications.append(message)
    def tool(self, name, arguments=None, meta=None):
        params = {'name': name, 'arguments': arguments or {}}
        if meta: params['_meta'] = meta
        return self.request('tools/call', params)
    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try: self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill(); self.process.wait(); raise
        self.reader.join(timeout=2)
        self.process.stdout.close(); self.process.stderr.close()

class Contract(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='hemdiff-protocol-')
        self.base = pathlib.Path(self.temp.name).resolve()
        self.state = self.base / 'state'
    def tearDown(self): self.temp.cleanup()
    def cli(self, *args, success=True):
        result = subprocess.run([BINARY, '--state-directory', str(self.state), *args], capture_output=True, timeout=45)
        self.assertEqual(result.returncode == 0, success, result.stderr.decode())
        return json.loads(result.stdout if success else result.stderr)
    def test_help_has_no_state_side_effect(self):
        for option in ['--help', '--version']:
            result = subprocess.run([BINARY, '--state-directory', str(self.state), option], capture_output=True)
            self.assertEqual(result.returncode, 0)
            self.assertFalse(self.state.exists())
        self.cli('status', 'unexpected', success=False)
        self.assertFalse(self.state.exists())
    def test_sdk_protocol_and_read_only_defaults(self):
        client = Client(self.state)
        try:
            listed = client.request('tools/list')['result']['tools']
            self.assertEqual({tool['name'] for tool in listed}, {'status', 'inventory', 'prepare_cleanup', 'execute_cleanup', 'cleanup_receipt'})
            execute = next(tool for tool in listed if tool['name'] == 'execute_cleanup')
            self.assertTrue(execute['annotations']['destructiveHint'])
            status = client.tool('status')['result']['structuredContent']
            self.assertEqual(status['roots'], [])
            self.assertTrue(status['hostID'])
            page = client.tool('inventory', {'limit': 1}, {'progressToken': 'scan'})['result']['structuredContent']
            self.assertEqual(page['candidates'], [])
            self.assertTrue(any(m.get('method') == 'notifications/progress' for m in client.notifications))
            self.assertIn('error', client.tool('permissions_grant', {'root': '/'}))
            self.assertIn('error', client.tool('inventory', {'root': '/'}))
            self.assertIn('error', client.tool('inventory', {'limit': 1.5}))
            self.assertIn('error', client.tool('prepare_cleanup', {'candidate_ids': ['x', 'x']}))
            self.assertIn('error', client.request('method/unknown'))
            self.assertTrue(client.tool('cleanup_receipt', {'plan_id': 'missing'})['result']['isError'])
            self.assertTrue(client.tool('inventory', {'cursor': 'expired:0'})['result']['isError'])
        finally: client.close()
    def test_real_cleanup_pagination_revocation_receipts(self):
        project = self.base / 'project'; project.mkdir()
        subprocess.run(['git', 'init', '-q', str(project)], check=True)
        (project / 'package.json').write_text('{"private":true}')
        (project / 'source.txt').write_text('must survive')
        for directory in ['.next', 'node_modules']:
            (project / directory).mkdir(); (project / directory / 'output').write_bytes(b'x' * 8192)
        root = self.cli('roots', 'add', str(project))
        candidates = self.cli('inventory')['candidates']
        self.assertEqual(len(candidates), 2)
        self.assertTrue(all(not candidate['authorized'] for candidate in candidates))
        self.cli('plan', candidates[0]['id'], success=False)
        self.cli('permissions', 'grant', root['id'], 'nextBuild', 'nodeModules')
        # Production quiet-period policy is intentionally not disabled for tests.
        time.sleep(31)
        client = Client(self.state)
        try:
            page = client.tool('inventory', {'limit': 1})['result']['structuredContent']
            second = client.tool('inventory', {'cursor': page['nextCursor'], 'limit': 1})['result']['structuredContent']
            self.assertEqual(second['snapshotID'], page['snapshotID'])
            self.assertNotEqual(second['candidates'][0]['id'], page['candidates'][0]['id'])
            ids = [page['candidates'][0]['id']]
            plan = client.tool('prepare_cleanup', {'candidate_ids': ids})['result']['structuredContent']
            self.assertIn('id', plan, plan)
            self.cli('permissions', 'revoke', root['id'])
            refused = client.tool('execute_cleanup', {'plan_id': plan['id'], 'host_id': plan['hostID']})['result']
            # Service may return a persisted refused/partial receipt or tool error.
            self.assertTrue(refused.get('isError') or not refused['structuredContent']['removedArtifactIDs'])
            self.assertTrue((project / '.next').exists()); self.assertTrue((project / 'node_modules').exists())
            self.cli('permissions', 'grant', root['id'], 'nextBuild', 'nodeModules')
            plan = client.tool('prepare_cleanup', {'candidate_ids': ids})['result']['structuredContent']
            result = client.tool('execute_cleanup', {'plan_id': plan['id'], 'host_id': plan['hostID']})['result']['structuredContent']
            self.assertEqual(result['outcome'], 'completed', result)
            self.assertEqual(result['removedArtifactIDs'], ids)
            self.assertEqual((project / 'source.txt').read_text(), 'must survive')
        finally: client.close()
        client = Client(self.state)
        try:
            receipt = client.tool('cleanup_receipt', {'plan_id': plan['id']})['result']['structuredContent']
            retry = client.tool('execute_cleanup', {'plan_id': plan['id'], 'host_id': plan['hostID']})['result']['structuredContent']
            self.assertEqual(receipt, result); self.assertEqual(retry, result)
        finally: client.close()
    def test_disconnect_cancels_inventory_and_exits(self):
        project = self.base / 'project'; project.mkdir()
        for index in range(3000): (project / str(index)).mkdir()
        self.cli('roots', 'add', str(project))
        client = Client(self.state)
        try:
            client.send({'jsonrpc': '2.0', 'id': 99, 'method': 'tools/call', 'params': {'name': 'inventory', 'arguments': {}, '_meta': {'progressToken': 'disconnect'}}})
            while True:
                message = client.messages.get(timeout=10)
                self.assertIsNotNone(message)
                if message.get('method') == 'notifications/progress': break
            client.send({'jsonrpc': '2.0', 'method': 'notifications/cancelled', 'params': {'requestId': 99, 'reason': 'test cancellation'}})
        finally: client.close()
        self.assertEqual(len(list(project.iterdir())), 3000)

    def test_oversized_frame_terminates_without_state_write(self):
        process = subprocess.Popen([BINARY, '--state-directory', str(self.state), 'mcp'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            try: process.stdin.write(b'x' * (1024 * 1024 + 1)); process.stdin.flush()
            except BrokenPipeError: pass
            process.wait(timeout=10)
            self.assertFalse(self.state.exists())
        finally:
            if process.poll() is None: process.kill(); process.wait()
            try: process.stdin.close()
            except BrokenPipeError: pass
            process.stdout.close(); process.stderr.close()

if __name__ == '__main__': unittest.main()
