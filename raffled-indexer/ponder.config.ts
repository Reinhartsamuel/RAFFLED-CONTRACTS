import { createConfig } from "ponder";

import { RaffledCoreAbi } from "./abis/RaffledCoreAbi";

const RAW_DATABASE_URL = process.env.DATABASE_URL;

if (!RAW_DATABASE_URL || !RAW_DATABASE_URL.startsWith("postgres")) {
  throw new Error(
    "FATAL: DATABASE_URL is not set or is not a Postgres connection string. " +
      "This indexer requires an external Postgres database (e.g. Aiven) and REFUSES to start with the embedded PGlite database. " +
      "Set DATABASE_URL in .env (e.g. postgres://user:pass@host:port/dbname?sslmode=require) and restart.",
  );
}

const RPC_URL = process.env.PONDER_RPC_URL_84532;

if (!RPC_URL) {
  throw new Error(
    "FATAL: PONDER_RPC_URL_84532 is not set. This indexer requires an API-keyed RPC " +
      "(e.g. Alchemy/QuickNode) because free public RPCs Cloudflare-ban datacenter IPs. " +
      "Set PONDER_RPC_URL_84532 in .env.local and restart.",
  );
}

// Realtime newHeads subscription endpoint. Ponder polls (1s) instead of
// subscribing whenever `ws` is undefined, so derive the wss URL from the
// same API key (https://... -> wss://...). Override with PONDER_WS_URL_84532
// if the provider's ws endpoint differs from the http one.
const WS_URL = process.env.PONDER_WS_URL_84532 ?? RPC_URL.replace(/^http/, "ws");

// pg-connection-string >= 2.x treats sslmode=require/prefer/verify-ca as
// aliases for verify-full, i.e. it validates the server certificate against
// the system trust store. Aiven uses a private CA, so that fails with
// "Connection terminated unexpectedly". Opting into libpq compatibility
// keeps the connection encrypted but skips CA verification, which is the
// correct behavior for Aiven-style private-CA endpoints.
const DATABASE_URL =
  /[?&]sslmode=(require|prefer|verify-ca)(&|$)/.test(RAW_DATABASE_URL) &&
  !/[?&]uselibpqcompat/.test(RAW_DATABASE_URL)
    ? `${RAW_DATABASE_URL}${RAW_DATABASE_URL.includes("?") ? "&" : "?"}uselibpqcompat=true`
    : RAW_DATABASE_URL;

export default createConfig({
  database: {
    kind: "postgres",
    connectionString: DATABASE_URL,
  },
  chains: {
    baseSepolia: {
      id: 84532,
      // API-keyed RPC only. The public endpoints (sepolia.base.org,
      // publicnode, drpc) Cloudflare-ban the VPS's datacenter IP (HTTP 403
      // error code 1010), so as "failover" they only add retry spam.
      rpc: [RPC_URL],
      // Real-time newHeads via WebSocket (eth_subscribe). Without this,
      // Ponder polls eth_getBlockByNumber every 1s, which is what burns CU
      // even when idle. With ws, idle blocks arrive via subscription for
      // free; eth_getLogs only fires when a block's bloom filter matches
      // a RaffledCore event (i.e. actual raffle activity).
      ws: WS_URL,
      // Pin the eth_getLogs chunk size. Without this, Ponder's adaptive
      // range logic collapses the chunk to 1 block on RPC errors, turning
      // the ~2.6M-block backfill into millions of per-block requests that
      // exhaust free-tier CU quotas and drown PM2 logs in retry WARNs.
      ethGetLogsBlockRange: 1000,
    },
  },
  contracts: {
    RaffledCore: {
      chain: "baseSepolia",
      abi: RaffledCoreAbi,
      address:
        (process.env.RAFFLED_CORE_ADDRESS as `0x${string}` | undefined) ??
        "0xc17eee20B4990021bE9cc8eCB7833706465bb8b9",
      startBlock: 45269179,
    },
  },
});
