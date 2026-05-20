// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {RaffleManager4} from "../src/RaffleManager4.sol";

/// @notice Enter free raffle using EIP-712 signature.
/// Assumes RaffleManager4 is already deployed with trustedSigner = 0x14dC...9955.

contract EnterFreeRaffle is Script {
    address constant TRUSTED_SIGNER_ADDR = 0x14dC79964da2C08b23698B3D3cc7Ca32193d9955;
    uint256 constant TRUSTED_SIGNER_KEY = 0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356;

    bytes32 constant FREE_ENTRY_TYPEHASH = keccak256("FreeEntry(uint256 raffleId,address user)");
    string constant EIP712_NAME = "RaffleManager4";
    string constant EIP712_VERSION = "1";

    function run() external {
        address raffleManager = 0xA041C709ce7F333F4F932289a92CA87CA99246d9;
        uint256 participantKey = vm.envUint("PARTICIPANT_1_KEY");
        address freeEntryUser = vm.addr(participantKey);

        uint256 raffleId = 1;

        console.log("=== Enter Free Raffle ===");
        console.log("Raffle Manager:", raffleManager);
        console.log("Free Entry User:", freeEntryUser);
        console.log("Raffle ID:", raffleId);

        bytes memory signature = _signFreeEntry(TRUSTED_SIGNER_KEY, raffleManager, raffleId, freeEntryUser);
        console.log("Signature:", _bytesToHex(signature));

        vm.broadcast(participantKey);
        RaffleManager4(raffleManager).enterFreeRaffle(raffleId, signature);
        console.log("Free entry successful!");
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
