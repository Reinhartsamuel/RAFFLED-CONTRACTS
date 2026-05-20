// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {RaffleManager4} from "../src/RaffleManager4.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deploys RaffleManager4, creates a raffle, and enters free raffle with EIP-712 signature.
///
/// PREREQUISITES (.env):
///   DEPLOYER_PRIVATE_KEY – deployer/host wallet
///   RPC_URL – Base Sepolia RPC
///   MOCK_USDC – MockUSDC address
///   VRF_COORDINATOR, KEY_HASH, SUB_ID – Chainlink VRF params (from .env)

interface IMockUSDC {
    function mint(address to, uint256 amount) external;
}

contract CreateAndEnterFreeRaffle is Script {
    uint256 constant DURATION = 2 hours;
    uint256 constant TICKET_PRICE = 1e6;
    uint256 constant PRIZE_AMOUNT = 10e6;
    uint256 constant MAX_CAP = 10;

    address constant FREE_ENTRY_USER = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;
    address constant TRUSTED_SIGNER_ADDR = 0x14dC79964da2C08b23698B3D3cc7Ca32193d9955;
    uint256 constant TRUSTED_SIGNER_KEY = 0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356;

    bytes32 constant FREE_ENTRY_TYPEHASH = keccak256("FreeEntry(uint256 raffleId,address user)");
    string constant EIP712_NAME = "RaffleManager4";
    string constant EIP712_VERSION = "1";

    function run() external {
        address mockUsdc = vm.envAddress("MOCK_USDC");
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 participantKey = vm.envUint("PARTICIPANT_1_KEY");
        address deployer = vm.addr(deployerKey);
        address freeEntryUser = vm.addr(participantKey);

        address vrfCoordinator = vm.envOr(
            "VRF_COORDINATOR",
            address(0x5C210eF41CD1a72de73bF76eC39637bB0d3d7BEE)
        );
        bytes32 keyHash = vm.envOr(
            "KEY_HASH",
            bytes32(0x9e1344a1247c8a1785d0a4681a27152bffdb43666ae5bf7d14d24a5efd44bf71)
        );
        uint256 subId = vm.envOr("SUB_ID", uint256(1));

        console.log("=== Deploy RaffleManager4 + Free Entry ===");
        console.log("Deployer      :", deployer);
        console.log("Free Entry User:", freeEntryUser);
        console.log("Mock USDC     :", mockUsdc);

        // Step 1: Deploy RaffleManager4
        console.log("");
        console.log("--- Step 1: Deploying RaffleManager4 ---");
        address raffleManager;
        {
            vm.startBroadcast(deployerKey);
            RaffleManager4 mgr = new RaffleManager4(
                vrfCoordinator,
                keyHash,
                subId,
                mockUsdc,
                deployer,
                TRUSTED_SIGNER_ADDR
            );
            raffleManager = address(mgr);
            vm.stopBroadcast();
        }
        console.log("RaffleManager4 deployed to:", raffleManager);

        // Step 2: Create raffle
        console.log("");
        console.log("--- Step 2: Creating ERC-20 raffle ---");
        uint256 raffleId;
        vm.startBroadcast(deployerKey);
        IMockUSDC(mockUsdc).mint(deployer, PRIZE_AMOUNT);
        IERC20(mockUsdc).approve(raffleManager, PRIZE_AMOUNT);
        raffleId = RaffleManager4(raffleManager).createRaffleERC20(
            mockUsdc,
            PRIZE_AMOUNT,
            TICKET_PRICE,
            MAX_CAP,
            DURATION
        );
        vm.stopBroadcast();
        console.log("Raffle created with ID:", raffleId);

        // Step 3: Generate EIP-712 signature for the free entry user
        console.log("");
        console.log("--- Step 3: Generating EIP-712 signature ---");
        bytes memory signature = _signFreeEntry(TRUSTED_SIGNER_KEY, raffleManager, raffleId, freeEntryUser);
        console.log("Signature:", _bytesToHex(signature));

        // Step 4: Enter free raffle
        console.log("");
        console.log("--- Step 4: Entering free raffle ---");
        console.log("User:", freeEntryUser);
        console.log("Raffle ID:", raffleId);

        vm.broadcast(participantKey);
        RaffleManager4(raffleManager).enterFreeRaffle(raffleId, signature);
        console.log("Free entry successful!");

        console.log("");
        console.log("=== Done ===");
        console.log("RaffleManager4:", raffleManager);
        console.log("Raffle ID:", raffleId);
        console.log("Free Entry Tx: user=", freeEntryUser, "raffleId=", raffleId);
    }

    function _signFreeEntry(
        uint256 signerKey,
        address verifyingContract,
        uint256 raffleId,
        address user
    ) internal view returns (bytes memory) {
        uint256 chainId = block.chainid;

        bytes32 DOMAIN_TYPEHASH = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes(EIP712_NAME)),
                keccak256(bytes(EIP712_VERSION)),
                chainId,
                verifyingContract
            )
        );

        bytes32 structHash = keccak256(abi.encode(FREE_ENTRY_TYPEHASH, raffleId, user));
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _bytesToHex(bytes memory b) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory str = new bytes(2 + b.length * 2);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < b.length; i++) {
            str[2 + i * 2] = hexChars[uint8(b[i] >> 4)];
            str[3 + i * 2] = hexChars[uint8(b[i] & 0x0f)];
        }
        return string(str);
    }
}
