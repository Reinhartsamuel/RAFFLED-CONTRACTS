// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {FreeEntryVerifier} from "../src/FreeEntryVerifier.sol";
import {RaffleManager4} from "../src/RaffleManager4.sol";
import {VRFCoordinatorV2_5Mock} from "./mocks/VRFCoordinatorV2_5Mock.sol";
import {StandardERC20}          from "./mocks/StandardERC20.sol";
import {MockERC721}             from "./mocks/MockERC721.sol";
import {IERC20}                 from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721}                from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract FreeEntryVerifierTest is Test {
    RaffleManager4 raffleManager;
    VRFCoordinatorV2_5Mock coord;
    StandardERC20          prize;
    StandardERC20          usdc;
    MockERC721             nft;

        address TREASURY;

    // Private key for Anvil test account 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
    uint256 constant SIGNER_PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    address constant SIGNER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant USER   = 0x753dFC03b4d37B3a316D0Fe5aB9F677C0D3C20f8;
    address constant VERIFIER_ADDRESS = 0x5FbDB2315678afecb367f032d93F642f64180aa3;


    bytes32 constant KEYHASH      = keccak256("test_keyhash");
    uint256 constant SUB_ID       = 1;
    
    function setUp() external {
        coord = new VRFCoordinatorV2_5Mock();
        prize = new StandardERC20("Prize", "PZ", 100_000e18);
        usdc  = new StandardERC20("USDC", "USDC", 1_000_000e18);
        nft   = new MockERC721();
                TREASURY = makeAddr("treasury");

        // mgr = new RaffleManager3(
        //     address(coord), KEYHASH, SUB_ID, address(usdc), TREASURY
        // );
        raffleManager = new RaffleManager4(address(coord), KEYHASH, SUB_ID, address(usdc), TREASURY, SIGNER);
        console.log("Raffle Manager as Verifier deployed at", address(raffleManager));
    }

    function test_recoverSigner() external view {
        bytes32 digest = raffleManager.computeDigest(1, USER);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PRIVATE_KEY, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        address recoveredSigner = raffleManager.recoverSigner(1, USER, signature);
        console.log("Recovered Signer:", recoveredSigner);
        console.log("Expected Signer:", SIGNER);
        console.log("Match:", recoveredSigner == SIGNER);
        
        assertEq(recoveredSigner, SIGNER, "Signature should recover to expected signer");
    }

    function test_verifyAndClaim() external {
        bytes32 digest = raffleManager.computeDigest(1, USER);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PRIVATE_KEY, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        bool success = raffleManager.verifyAndClaim(1, USER, signature);
        assertTrue(success, "verifyAndClaim should return true");

        bool claimed = raffleManager.freeEntryClaimed(1, USER);
        assertTrue(claimed, "freeEntryClaimed should be true after claim");
    }

    function test_verifyAndClaim_revertDoubleClaim() external {
        bytes32 digest = raffleManager.computeDigest(1, USER);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PRIVATE_KEY, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        raffleManager.verifyAndClaim(1, USER, signature);

        vm.expectRevert(FreeEntryVerifier.AlreadyClaimed.selector);
        raffleManager.verifyAndClaim(1, USER, signature);
    }

    function test_verifyAndClaim_revertInvalidSigner() external {
        bytes memory badSignature = hex"1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef12";

        vm.expectRevert();
        raffleManager.verifyAndClaim(1, USER, badSignature);
    }

    function test_setTrustedSigner_onlyOwner() external {
        address newSigner = makeAddr("newSigner");
        raffleManager.setTrustedSigner(newSigner);
        assertEq(raffleManager.trustedSigner(), newSigner);
    }

    function test_setTrustedSigner_revertsOnZeroAddress() external {
        vm.expectRevert();
        raffleManager.setTrustedSigner(address(0));
    }

    function test_setTrustedSigner_nonOwnerReverts() external {
        vm.prank(USER);
        vm.expectRevert(FreeEntryVerifier.NotOwner.selector);
        raffleManager.setTrustedSigner(USER);
    }

    function test_setTrustedSigner_emitsEvent() external {
        address newSigner = makeAddr("newSigner");
        vm.expectEmit(true, true, false, true);
        emit FreeEntryVerifier.TrustedSignerUpdated(SIGNER, newSigner);
        raffleManager.setTrustedSigner(newSigner);
    }

    function test_verifierOwnerMatchesRaffleManagerOwner() external view {
        assertEq(raffleManager.verifierOwner(), raffleManager.owner());
    }
}
