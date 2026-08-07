import { createConfig } from "ponder";

import { RaffledCoreAbi } from "./abis/RaffledCoreAbi";

const DATABASE_URL = process.env.DATABASE_URL;

if (!DATABASE_URL || !DATABASE_URL.startsWith("postgres")) {
  throw new Error(
    "FATAL: DATABASE_URL is not set or is not a Postgres connection string. " +
      "This indexer requires an external Postgres database (e.g. Aiven) and REFUSES to start with the embedded PGlite database. " +
      "Set DATABASE_URL in .env.local (e.g. postgres://user:pass@host:port/dbname?sslmode=require) and restart.",
  );
}

export default createConfig({
  database: {
    kind: "postgres",
    connectionString: DATABASE_URL,
  },
  chains: {
    baseSepolia: {
      id: 84532,
      rpc: process.env.PONDER_RPC_URL_84532!,
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
