#!/usr/bin/env -S deno run --allow-read --allow-write

import { MerkleTree } from "npm:merkletreejs@0.6.0";
import { getAddress, keccak256, solidityPacked } from "npm:ethers@6";

function usage() {
  console.error([
    "Usage:",
    "  deno run --allow-read --allow-write generate-whitelist-merkle.js <input-json> [output-json]",
    "",
    "Input JSON formats supported:",
    "  1) [\"0x...\", \"0x...\"]",
    "  2) { \"addresses\": [\"0x...\", \"0x...\"] }",
    "",
    "Example:",
    "  deno run --allow-read --allow-write generate-whitelist-merkle.js whitelist-addresses.json whitelist-merkle.json",
  ].join("\n"));
}

async function loadAddresses(inputPath) {
  const raw = await Deno.readTextFile(inputPath);
  const parsed = JSON.parse(raw);

  if (Array.isArray(parsed)) return parsed;
  if (parsed && Array.isArray(parsed.addresses)) return parsed.addresses;

  throw new Error("Invalid input JSON. Expected an array or an object with an 'addresses' array.");
}

function normalizeAndValidate(addresses) {
  const unique = new Set();
  const normalized = [];

  for (const addr of addresses) {
    if (typeof addr !== "string") {
      throw new Error(`Invalid address entry (not string): ${String(addr)}`);
    }

    const checksum = getAddress(addr.trim());
    const key = checksum.toLowerCase();

    if (!unique.has(key)) {
      unique.add(key);
      normalized.push(checksum);
    }
  }

  if (normalized.length === 0) {
    throw new Error("No valid addresses found in input.");
  }

  return normalized;
}

function hashLeaf(address) {
  return keccak256(solidityPacked(["address"], [address]));
}

async function main() {
  const inputArg = Deno.args[0];
  const outputArg = Deno.args[1] ?? "whitelist-merkle.json";

  if (!inputArg) {
    usage();
    Deno.exit(1);
  }

  const inputPath = new URL(inputArg, `file://${Deno.cwd()}/`).pathname;
  const outputPath = new URL(outputArg, `file://${Deno.cwd()}/`).pathname;

  const addresses = normalizeAndValidate(await loadAddresses(inputPath));
  const leaves = addresses.map(hashLeaf);

  const tree = new MerkleTree(leaves, keccak256, {
    sortLeaves: true,
    sortPairs: true,
  });

  const merkleRoot = tree.getHexRoot();

  const entries = addresses.map((address, index) => ({
    index,
    address,
    leaf: leaves[index],
    proof: tree.getHexProof(leaves[index]),
  }));

  const output = {
    merkleRoot,
    totalAddresses: addresses.length,
    generatedAt: new Date().toISOString(),
    entries,
  };

  await Deno.writeTextFile(outputPath, `${JSON.stringify(output, null, 2)}\n`);

  console.log(`Merkle root: ${merkleRoot}`);
  console.log(`Addresses: ${addresses.length}`);
  console.log(`Output: ${outputPath}`);
}

main().catch((error) => {
  console.error(`Error: ${error.message}`);
  Deno.exit(1);
});
