// Morrow Finance: builds offer trees with the Midnight SDK and writes root, leaves and padded offers as test vectors.
// @author adiii.eth

import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const nodeModules = join(here, "..", "cache", "sdk", "node_modules");
const { Offer, TreeUtils } = await import(join(nodeModules, "@morpho-org/midnight-sdk/lib/esm/index.js"));
const { encodeAbiParameters, zeroAddress } = await import(join(nodeModules, "viem/_esm/index.js"));

const collateralTuple = {
  type: "tuple[]",
  components: [
    { name: "token", type: "address" },
    { name: "lltv", type: "uint256" },
    { name: "liquidationCursor", type: "uint256" },
    { name: "oracle", type: "address" },
  ],
};
const marketTuple = {
  type: "tuple",
  components: [
    { name: "chainId", type: "uint256" },
    { name: "midnight", type: "address" },
    { name: "loanToken", type: "address" },
    { name: "collateralParams", ...collateralTuple },
    { name: "maturity", type: "uint256" },
    { name: "rcfThreshold", type: "uint256" },
    { name: "enterGate", type: "address" },
    { name: "liquidatorGate", type: "address" },
  ],
};
const offerTuple = {
  type: "tuple[]",
  components: [
    { name: "market", ...marketTuple },
    { name: "buy", type: "bool" },
    { name: "maker", type: "address" },
    { name: "start", type: "uint256" },
    { name: "expiry", type: "uint256" },
    { name: "tick", type: "uint256" },
    { name: "group", type: "bytes32" },
    { name: "callback", type: "address" },
    { name: "callbackData", type: "bytes" },
    { name: "receiverIfMakerIsSeller", type: "address" },
    { name: "ratifier", type: "address" },
    { name: "reduceOnly", type: "bool" },
    { name: "maxUnits", type: "uint128" },
    { name: "maxAssets", type: "uint128" },
    { name: "continuousFeeCap", type: "uint256" },
  ],
};

function offerAt(i) {
  const twoCollaterals = i % 2 === 1;
  const collateralParams = [
    { token: "0x00000000000000000000000000000000000070a0", lltv: 770000000000000000n, liquidationCursor: 250000000000000000n, oracle: "0x0000000000000000000000000000000000008000" },
  ];
  if (twoCollaterals) {
    collateralParams.push({ token: "0x00000000000000000000000000000000000070b0", lltv: 860000000000000000n, liquidationCursor: 300000000000000000n, oracle: "0x0000000000000000000000000000000000008001" });
  }
  return Offer.create({
    market: {
      chainId: 8453n,
      midnight: "0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A",
      loanToken: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
      collateralParams,
      maturity: 1_800_000_000n + BigInt(i),
      rcfThreshold: 3_000_000_000n,
      enterGate: zeroAddress,
      liquidatorGate: zeroAddress,
    },
    buy: i % 3 !== 0,
    maker: `0x${(0x9000 + i).toString(16).padStart(40, "0")}`,
    start: BigInt(i),
    tick: 5_000n + 4n * BigInt(i),
    expiry: 3_600n + BigInt(i),
    callback: `0x${(0xcb00 + i).toString(16).padStart(40, "0")}`,
    callbackData: `0x${i.toString(16).padStart(64, "0")}`,
    ratifier: "0x800B5F12A61B8198a5a6EfD794Cac6699B294d63",
    maxUnits: i % 2 === 0 ? 100n + BigInt(i) : 0n,
    maxAssets: i % 2 === 0 ? 0n : 1_000n + BigInt(i),
    continuousFeeCap: 317097919n,
  });
}

const outDir = join(here, "vectors");
mkdirSync(outDir, { recursive: true });
for (const n of [1, 2, 3, 5, 8, 33]) {
  const offers = Array.from({ length: n }, (_, i) => offerAt(i));
  const d = TreeUtils.buildDescriptor(offers);
  const encoded = encodeAbiParameters(
    [{ type: "bytes32" }, { type: "bytes32[]" }, offerTuple],
    [d.root, d.leaves, d.offers],
  );
  writeFileSync(join(outDir, `offer_tree_${n}.hex`), encoded);
  console.log(`n=${n} padded=${d.offers.length} root=${d.root}`);
}
