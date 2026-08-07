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
      // Primary RPC from .env/.env.local, with public RPCs as automatic
      // failover so a dead provider key can't stop indexing. Ponder keeps
      // a health-tracked bucket per URL and spreads load across healthy ones.
      rpc: [
        process.env.PONDER_RPC_URL_84532 ?? "https://sepolia.base.org",
        "https://sepolia.base.org",
        "https://base-sepolia.publicnode.com",
        "https://base-sepolia.drpc.org",
      ],
    },
  },
  contracts: {
    RaffledCore: {
      chain: "baseSepolia",
      abi: RaffledCoreAbi,
      address:
        process.env.RAFFLED_CORE_ADDRESS ??
        "0xc17eee20B4990021bE9cc8eCB7833706465bb8b9",
      startBlock: 42699846,
    },
  },
});
