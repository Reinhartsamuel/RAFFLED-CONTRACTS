// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/// @title  FreeEntryVerifier
/// @notice EIP-712 signature verifier for free raffle entries.
///         Validates backend-signed free entry claims and prevents double-claiming.
/// @dev    Inherited by RaffleManager4. The owner address matches RaffleManager4's
///         Ownable owner so access control is consistent across the inheritance chain.
contract FreeEntryVerifier is EIP712("RaffleManager4", "1") {
    using ECDSA for bytes32;

    // ── State ────────────────────────────────────────────────────────────
    address public trustedSigner;
    address public verifierOwner;

    /// @notice Tracks which users have already claimed free entry per raffle.
    mapping(uint256 => mapping(address => bool)) public freeEntryClaimed;

    // ── Errors ───────────────────────────────────────────────────────────
    error InvalidSigner();
    error AlreadyClaimed();
    error NotOwner();

    // ── Events ───────────────────────────────────────────────────────────
    event FreeEntryClaimed(uint256 raffleId, address user, address signer);
    event TrustedSignerUpdated(address oldSigner, address newSigner);

    // ── Type hash (matches backend) ──────────────────────────────────────
    bytes32 private constant FREE_ENTRY_TYPEHASH = keccak256(
        "FreeEntry(uint256 raffleId,address user)"
    );

    // ── Modifiers ────────────────────────────────────────────────────────
    modifier onlyVerifierOwner() {
        if (msg.sender != verifierOwner) revert NotOwner();
        _;
    }

    // ── Constructor ──────────────────────────────────────────────────────
    constructor(address _trustedSigner, address _owner) {
        require(_trustedSigner != address(0), "Invalid signer");
        require(_owner != address(0), "Invalid owner");
        trustedSigner = _trustedSigner;
        verifierOwner = _owner;
    }

    // ── Admin ────────────────────────────────────────────────────────────
    function setTrustedSigner(address _newSigner) external onlyVerifierOwner {
        require(_newSigner != address(0), "Invalid signer");
        emit TrustedSignerUpdated(trustedSigner, _newSigner);
        trustedSigner = _newSigner;
    }

    // ── Core verification logic (mirrors enterFreeRaffle) ────────────────
    /// @notice Verify EIP-712 signature and record free entry claim.
    /// @param raffleId  Target raffle.
    /// @param user      User address claiming free entry.
    /// @param signature EIP-712 signature from trustedSigner.
    function verifyAndClaim(uint256 raffleId, address user, bytes calldata signature)
        public
        returns (bool success)
    {
        // 1. Prevent double-claim
        if (freeEntryClaimed[raffleId][user]) revert AlreadyClaimed();

        // 2. Build digest exactly as EIP-712 specifies
        bytes32 structHash = keccak256(abi.encode(FREE_ENTRY_TYPEHASH, raffleId, user));
        bytes32 digest     = _hashTypedDataV4(structHash);

        // 3. Recover signer and verify
        address recovered = digest.recover(signature);
        if (recovered != trustedSigner) revert InvalidSigner();

        // 4. Mark as claimed
        freeEntryClaimed[raffleId][user] = true;

        emit FreeEntryClaimed(raffleId, user, trustedSigner);
        return true;
    }

    // ── Views ────────────────────────────────────────────────────────────
    /// @notice Compute the expected digest for external verification/testing.
    function computeDigest(uint256 raffleId, address user) external view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(FREE_ENTRY_TYPEHASH, raffleId, user));
        return _hashTypedDataV4(structHash);
    }
    
    function recoverSigner(uint256 raffleId, address user, bytes calldata signature) external view returns (address) {
        bytes32 structHash = keccak256(abi.encode(FREE_ENTRY_TYPEHASH, raffleId, user));
        bytes32 digest     = _hashTypedDataV4(structHash);
        return digest.recover(signature);
    }

    function isSignatureEligible(uint256 raffleId, address user, bytes calldata signature) external view returns (bool) {
        if (freeEntryClaimed[raffleId][user]) return false;

        bytes32 structHash = keccak256(abi.encode(FREE_ENTRY_TYPEHASH, raffleId, user));
        bytes32 digest     = _hashTypedDataV4(structHash);
        address recovered = digest.recover(signature);
        return recovered == trustedSigner;
    }
}
