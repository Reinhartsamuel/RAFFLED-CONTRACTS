// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {RaffleManager3} from "../src/RaffleManager3.sol";

/// @notice Deployment script for RaffleManager3.
///
/// PREREQUISITES (must be set in .env):
///   DEPLOYER_PRIVATE_KEY  – deployer wallet private key
///   VRF_COORDINATOR       – 0x5C210eF41CD1a72de73bF76eD3691d07C814f8E  (Base Sepolia)
///   KEY_HASH              – 0x9e9e46732b32662b9adc6f3abdf6c5e926a666d174a4d6b8e39c6ea957bf1630
///   SUB_ID                – your Chainlink VRF subscription ID
///   MOCK_USDC             – payment token address
///   MOCK_TREASURY         – treasury address for platform fees
///
/// DRY-RUN (no broadcast, simulation only):
///   forge script script/Deploy3.s.sol:Deploy3 --rpc-url $RPC_URL -vvv
///
/// BROADCAST (real deployment):
///   forge script script/Deploy3.s.sol:Deploy3 --rpc-url $RPC_URL --broadcast --verify -vvv
///

/// @dev Minimal MockNFT deployed alongside RaffleManager3 for testing.
contract MockNFT {
    string public name   = "Mock NFT";
    string public symbol = "MNFT";

    uint256 private _nextId = 1;

    mapping(uint256 => address) private _owners;
    mapping(uint256 => address) private _approvals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);

    function mint(address to) external returns (uint256 tokenId) {
        tokenId = _nextId++;
        _owners[tokenId] = to;
        emit Transfer(address(0), to, tokenId);
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return _owners[tokenId];
    }

    function approve(address to, uint256 tokenId) external {
        _approvals[tokenId] = to;
        emit Approval(_owners[tokenId], to, tokenId);
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        return _approvals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
    }

    function isApprovedForAll(address owner, address operator) external view returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory) public {
        require(_owners[tokenId] == from, "not owner");
        require(
            _approvals[tokenId] == msg.sender
                || _owners[tokenId] == msg.sender
                || _operatorApprovals[from][msg.sender],
            "not approved"
        );
        _approvals[tokenId] = address(0);
        _owners[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        safeTransferFrom(from, to, tokenId, "");
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x80ac58cd  // ERC721
            || interfaceId == 0x5b5e139f  // ERC721Metadata
            || interfaceId == 0x01ffc9a7; // ERC165
    }
}

contract Deploy3 is Script {
    function run() external returns (RaffleManager3 raffle, MockNFT nft) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        address vrfCoordinator = vm.envAddress("VRF_COORDINATOR");
        bytes32 keyHash        = vm.envBytes32("KEY_HASH");
        uint256 subId          = vm.envUint("SUB_ID");
        address paymentToken   = vm.envAddress("MOCK_USDC");
        address treasury       = vm.envAddress("MOCK_TREASURY");

        vm.startBroadcast(deployerKey);
        raffle = new RaffleManager3(vrfCoordinator, keyHash, subId, paymentToken, treasury);
        nft    = new MockNFT();
        vm.stopBroadcast();

        console.log("RaffleManager3 deployed:", address(raffle));
        console.log("MockNFT deployed       :", address(nft));
        console.log("");
        console.log("Add to .env:");
        console.log("RAFFLE_MANAGER=", address(raffle));
        console.log("MOCK_NFT=", address(nft));
        console.log("");
        console.log("Then add RaffleManager3 as a consumer on vrf.chain.link");
    }
}
