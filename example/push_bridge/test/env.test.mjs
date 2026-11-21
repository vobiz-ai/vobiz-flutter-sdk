// Settings: the .env reader never turns a description into a value, and a
// key that cannot be the bridge key is refused at start.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { createBridge, parseEnv } from '../push-bridge.mjs';
import { AUTH_TOKEN, PUBLIC_URL } from './helpers.mjs';

const EXAMPLE = fs.readFileSync(path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '.env.example'), 'utf8');

test('.env.example reads cleanly, and so does every setting in it once uncommented', () => {
  const parsed = parseEnv(EXAMPLE);
  assert.deepEqual(parsed.problems, []);
  assert.equal(parsed.values.PORT, '8787');
  assert.equal(parsed.values.ROUTES, '');

  const commented = EXAMPLE.split(/\r?\n/).filter((line) => /^#\s*[A-Z0-9_]+=/.test(line));
  assert.ok(commented.length >= 15, `found ${commented.length} optional settings`);
  for (const line of commented) {
    const uncommented = parseEnv(line.replace(/^#/, ''));
    assert.deepEqual(uncommented.problems, [], line);
    const [name, value] = Object.entries(uncommented.values)[0];
    assert.doesNotMatch(value, /\s/, `${name} would read as "${value}"`);
  }
  assert.equal(parseEnv('BRIDGE_KEY=').values.BRIDGE_KEY, '');
});

test('a description left on a setting\'s line is refused, never read as the value', () => {
  const old = parseEnv([
    'BRIDGE_KEY=               the pairing key; generated and saved in bridge-state.json if empty',
    'FORCE_ATTACH=true        true moves the number here even if another application has it',
    'ROUTES=+918000000001=alice   which endpoints each number rings',
    'PORT=8787',
  ].join('\n'));
  assert.deepEqual(Object.keys(old.values), ['PORT']);
  assert.equal(old.problems.length, 3);
  assert.match(old.problems[0], /^line 1: the value of BRIDGE_KEY has a space/);
  assert.match(old.problems[2], /^line 3: the value of ROUTES/);
  assert.ok(old.problems.every((p) => !/pairing|moves|endpoints/.test(p)), 'a problem never repeats the value');
});

test('a # comment after a value is dropped; quoted values are kept as written', () => {
  const { values, problems } = parseEnv([
    'FORCE_ATTACH=true   # move the number here',
    'RING_SECONDS=45#not a comment without a space before it',
    'VOBIZ_APP_NAME="My Vobiz App"  # quoted: the space is meant',
    'JWT_SUB=\'agent 42 # not a comment\'',
    'CALLER_ID_MODE=#only a comment',
    'lowercase=ignored',
    '  # an indented comment',
    'BAD="not closed',
  ].join('\r\n'));
  assert.deepEqual(values, {
    FORCE_ATTACH: 'true',
    VOBIZ_APP_NAME: 'My Vobiz App',
    JWT_SUB: 'agent 42 # not a comment',
  });
  assert.equal(problems.length, 2);
  assert.match(problems[0], /^line 2: the value of RING_SECONDS has a space/);
  assert.match(problems[1], /^line 8: the quoted value of BAD/);
});

test('a bridge key that is short or has a space is refused at start, also in local mode', () => {
  const sentence = 'the pairing key; generated and saved in bridge-state.json if empty';
  for (const BRIDGE_KEY of [sentence, 'short-key', 'a key-with-a-space-0123456789']) {
    assert.throws(
      () => createBridge({ env: { PUBLIC_URL, VOBIZ_AUTH_TOKEN: AUTH_TOKEN, BRIDGE_KEY }, stateFile: '/nonexistent/x.json' }),
      (e) => e.code === 'BRIDGE_CONFIG' && /BRIDGE_KEY must be at least 16 characters/.test(e.message) && !e.message.includes(BRIDGE_KEY),
      BRIDGE_KEY,
    );
    assert.throws(
      () => createBridge({ env: { ALLOW_UNSIGNED_WEBHOOKS: 'true', BRIDGE_KEY }, stateFile: '/nonexistent/x.json' }),
      /BRIDGE_KEY/,
    );
  }
});
