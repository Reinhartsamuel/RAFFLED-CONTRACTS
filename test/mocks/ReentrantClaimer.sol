// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RaffleManager} from "../../src/RaffleManager.sol";

/// @notice Attack contract that tries to re-enter `claimRefund` inside its
///         `receive()` callback.  The `nonReentrant` guard must block the
///         second call and the attacker must receive exactly one refund.
contract ReentrantClaimer {
    RaffleManager public raffle;
    uint256       public targetRaffleId;

    /// @notice Set by the test before the first claimRefund call.
    bool public reentrantAttempted;
    bool public reentrantSucceeded;

    constructor(RaffleManager _raffle) {
        raffle = _raffle;
    }

    function setTarget(uint256 id) external {
        targetRaffleId = id;
    }

    /// @notice Proxy that forwards a ticket purchase to RaffleManager.
    function enterRaffle(uint256 _id, uint256 _count) external payable {
        raffle.enterRaffle{ value: msg.value }(_id, _count);
    }

    /// @notice Initiates the first (legitimate) claimRefund call.
    function claimRefund() external {
        raffle.claimRefund(targetRaffleId);
    }

    /// @dev  On the first ETH receipt, attempt a second claimRefund.
    ///       The try/catch prevents this contract's receive from reverting
    ///       (which would propagate and fail the outer call).
    receive() external payable {
        if (!reentrantAttempted) {
            reentrantAttempted = true;
            try raffle.claimRefund(targetRaffleId) {
                reentrantSucceeded = true;   // should never reach here
            } catch {
                // blocked by nonReentrant – expected path
            }
        }
    }
}
