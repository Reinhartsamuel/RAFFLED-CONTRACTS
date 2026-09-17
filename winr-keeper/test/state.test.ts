import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import type { Logger } from '../src/logger.ts';
import { StateStore } from '../src/state.ts';

function silentLogger(): Logger {
  const logger: Logger = {
    debug: () => undefined,
    info: () => undefined,
    warn: () => undefined,
    error: () => undefined,
    child: () => logger,
  };
  return logger;
}

// Regression: the chunk size learned from one provider's eth_getLogs cap was
// persisted globally, so after switching to a wide-range RPC the keeper kept
// asking for the old (10-block) range and could never catch up to the head.
test('learned log chunk size is scoped to the RPC it was learned from', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'winr-keeper-state-'));
  const file = join(dir, 'keeper-state.json');

  const first = await StateStore.open(file, silentLogger());
  try {
    assert.equal(first.learnedLogChunkSize('https://metered.example'), null);
    first.setLearnedLogChunkSize('https://metered.example', 10n);
    assert.equal(first.learnedLogChunkSize('https://metered.example'), 10n);
    assert.equal(first.learnedLogChunkSize('https://wide-range.example'), null);
    await first.flush();
  } finally {
    await first.close();
  }

  const reopened = await StateStore.open(file, silentLogger());
  try {
    assert.equal(reopened.learnedLogChunkSize('https://metered.example'), 10n);
    assert.equal(reopened.learnedLogChunkSize('https://wide-range.example'), null);
    reopened.setLearnedLogChunkSize('https://wide-range.example', 5_000n);
    assert.equal(reopened.learnedLogChunkSize('https://wide-range.example'), 5_000n);
    assert.equal(reopened.learnedLogChunkSize('https://metered.example'), null);
  } finally {
    await reopened.close();
    await rm(dir, { recursive: true, force: true });
  }
});
