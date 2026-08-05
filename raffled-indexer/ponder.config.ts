import { createConfig } from "ponder";

import { RaffledCoreAbi } from "./abis/RaffledCoreAbi";

export default createConfig({
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
      startBlock: 0,
    },
  },
});
