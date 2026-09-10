import type { PublicClient } from 'viem';
import { randomnessFulfilledEvent } from '../abi.ts';
import type { Alerter } from '../alerts.ts';
import type { KeeperConfig } from '../config.ts';
import { getRaffleView, summarizeSettlementReceipt } from '../contract.ts';
import type { Logger } from '../logger.ts';
import type { StateStore } from '../state.ts';
import type { TxSender } from '../tx.ts';
import { RaffleStatus, raffleStatusName } from '../types.ts';

export interface SettleJobDeps {
  cfg: KeeperConfig;
  logger: Logger;
  publicClient: PublicClient;
  sender: TxSender;
  state: StateStore;
  alert: Alerter;
}

/**
 * Cron #2 — settlement relayer.
 *
 * There is no on-chain view for "RESOLVED and un-settled", so the queue is
 * derived from `RandomnessFulfilled` logs:
 *   1. scan new blocks (chunked eth_getLogs) from the persisted cursor and
 *      enqueue every fulfilled raffleId; on first run, look back N blocks to
 *      catch fulfilled-but-unsettled raffles from before the keeper started;
 *   2. for each due queue item, read getRaffle(): only RESOLVED goes to
 *      `settle()` (reorg / already-settled are dropped);
 *   3. escrowed payouts (PayoutEscrowed / NftEscrowed) are logged and the
 *      raffle is marked settled — never retried.
 */
export class SettleJob {
  readonly #cfg: KeeperConfig;
  readonly #logger: Logger;
  readonly #publicClient: PublicClient;
  readonly #sender: TxSender;
  readonly #state: StateStore;
  readonly #alert: Alerter;

  constructor(deps: SettleJobDeps) {
    this.#cfg = deps.cfg;
    this.#logger = deps.logger;
    this.#publicClient = deps.publicClient;
    this.#sender = deps.sender;
    this.#state = deps.state;
    this.#alert = deps.alert;
  }

  async run(): Promise<void> {
    const startedAt = Date.now();
    const scanned = await this.#scanFulfilledLogs();
    const settled = await this.#processQueue();
    this.#logger.info('settle cycle complete', {
      ...scanned,
      ...settled,
      queue: this.#state.queueSize(),
      durationMs: Date.now() - startedAt,
    });
  }

  // ── Step 1: RandomnessFulfilled -> queue ──────────────────────────────────

  async #scanFulfilledLogs(): Promise<{ logsSeen: number; enqueued: number }> {
    const latest = await this.#publicClient.getBlockNumber();
    let from: bigint;

    if (this.#state.lastScannedBlock !== null) {
      from = this.#state.lastScannedBlock + 1n;
    } else if (this.#cfg.startBlock !== undefined) {
      from = this.#cfg.startBlock;
      this.#logger.info('first run: scanning from RAFFLE_START_BLOCK', { fromBlock: from.toString() });
    } else {
      from = latest > this.#cfg.logLookbackBlocks ? latest - this.#cfg.logLookbackBlocks : 0n;
      this.#logger.info('first run: scanning recent blocks for fulfilled-but-unsettled raffles', {
        fromBlock: from.toString(),
        lookbackBlocks: this.#cfg.logLookbackBlocks.toString(),
      });
    }

    if (from > latest) return { logsSeen: 0, enqueued: 0 };

    let logsSeen = 0;
    let enqueued = 0;
    for (let start = from; start <= latest; start += this.#cfg.logChunkSize) {
      const end = start + this.#cfg.logChunkSize - 1n > latest ? latest : start + this.#cfg.logChunkSize - 1n;
      const logs = await this.#publicClient.getLogs({
        address: this.#cfg.contractAddress,
        event: randomnessFulfilledEvent,
        fromBlock: start,
        toBlock: end,
      });
      logsSeen += logs.length;
      for (const log of logs) {
        if (log.args.raffleId === undefined) continue;
        if (this.#state.enqueue(log.args.raffleId)) {
          enqueued += 1;
          this.#logger.info('enqueued fulfilled raffle for settlement', { raffleId: log.args.raffleId.toString() });
        }
      }
      // Persist per chunk: a crash mid-scan resumes after the last chunk
      // instead of replaying the whole window.
      this.#state.setScannedBlock(end);
      await this.#state.flush();
    }

    return { logsSeen, enqueued };
  }

  // ── Step 2: queue -> settle() ─────────────────────────────────────────────

  async #processQueue(): Promise<{ tried: number; settled: number; requeued: number; abandoned: number }> {
    const due = this.#state.dueQueue();
    const outcome = { tried: 0, settled: 0, requeued: 0, abandoned: 0 };

    for (const item of due) {
      const raffleId = BigInt(item.raffleId);
      outcome.tried += 1;

      let status: number;
      try {
        const raffle = await getRaffleView(this.#publicClient, this.#cfg.contractAddress, raffleId);
        status = Number(raffle.status);
      } catch (error) {
        // Read failure: leave the item due so the next cycle retries.
        this.#logger.warn('could not read raffle status — will retry next cycle', {
          raffleId,
          error: error instanceof Error ? error.message : String(error),
        });
        continue;
      }

      if (status !== RaffleStatus.RESOLVED) {
        this.#state.dequeue(raffleId);
        if (status === RaffleStatus.PENDING_VRF) {
          // The RandomnessFulfilled log was reorged away (or has not taken
          // effect); the raffle will emit again when re-fulfilled, and the
          // resolve sweep handles a PENDING_VRF stall.
          this.#logger.debug('fulfilled log not effective — dropped from queue', { raffleId });
        } else {
          this.#logger.debug('raffle no longer RESOLVED — dropped from queue', {
            raffleId,
            status: raffleStatusName(status),
          });
        }
        continue;
      }

      const result = await this.#settleOne(raffleId);
      if (result === 'settled') {
        outcome.settled += 1;
      } else if (result === 'requeued') {
        outcome.requeued += 1;
      } else {
        outcome.abandoned += 1;
      }
    }

    return outcome;
  }

  async #settleOne(raffleId: bigint): Promise<'settled' | 'requeued' | 'abandoned'> {
    const result = await this.#sender.send(
      { functionName: 'settle', args: [raffleId] },
      { label: 'settle', raffleId },
    );

    if (result.kind === 'dry-run') {
      this.#logger.info('dry-run: would settle raffle', { raffleId });
      return 'settled';
    }

    if (result.kind === 'ok') {
      const summary = summarizeSettlementReceipt(result.receipt);
      if (summary.escrows.length > 0) {
        // Push-with-escrow fallback: the payout transfer failed and the
        // recipient must pull-claim. The raffle is COMPLETED — do not retry.
        this.#alert.alert(
          'settle completed but some payouts were escrowed — recipients must pull-claim (claim/claimNft)',
          { raffleId, tx: result.hash, escrows: summary.escrows },
          { key: `escrow-${raffleId}` },
        );
      }
      this.#logger.info('raffle settled', {
        raffleId,
        tx: result.hash,
        winner: summary.winner,
        events: summary.eventNames,
      });
      this.#state.markSettled(raffleId);
      return 'settled';
    }

    if (result.kind === 'reverted' && result.error.name === 'RaffleNotResolved') {
      // Permissionless: someone else got there first (or it was cancelled).
      this.#logger.info('raffle no longer RESOLVED on-chain — marking settled', { raffleId });
      this.#state.markSettled(raffleId);
      return 'settled';
    }

    // Failure path: bounded cross-cycle retry with exponential backoff.
    const errorText = result.kind === 'reverted' ? (result.error.name ?? result.error.shortMessage) : result.error.shortMessage;
    const nextAttempt = this.#state.attemptsFor(raffleId) + 1;
    const delayMs = Math.min(this.#cfg.txRetryBaseMs * 2 ** (nextAttempt - 1), 5 * 60_000);
    const attempts = this.#state.bumpAttempt(raffleId, errorText, delayMs);

    if (attempts >= this.#cfg.settleMaxAttempts) {
      this.#state.abandon(raffleId, errorText);
      this.#alert.alert(
        'settle abandoned after repeated failures — manual intervention required',
        { raffleId, attempts, lastError: errorText },
        { key: `settle-abandoned-${raffleId}` },
      );
      return 'abandoned';
    }

    this.#logger.warn('settle failed — retrying with backoff', {
      raffleId,
      attempt: attempts,
      maxAttempts: this.#cfg.settleMaxAttempts,
      retryInMs: delayMs,
      error: errorText,
    });
    return 'requeued';
  }
}
