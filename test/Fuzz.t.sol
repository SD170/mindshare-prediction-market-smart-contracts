// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {ParimutuelMarket} from "src/ParimutuelMarket.sol";
import {ISettlementOracle} from "src/interfaces/ISettlementOracle.sol";

contract FuzzTest is BaseTest {
    function testFuzz_ProRata_NoFee(uint96 aAmt, uint96 bAmt) public {
        // constrain amounts to non-zero, reasonable range
        aAmt = uint96(bound(aAmt, 1e6, 1e24));
        bAmt = uint96(bound(bAmt, 1e6, 1e24));

        uint64 lockTime = uint64(block.timestamp + 100);
        uint64 resolveTime = lockTime + 900;
        (ParimutuelMarket mkt, bytes32 id) = _createMarket(
            "QF",
            lockTime,
            resolveTime
        );

        vm.startPrank(ALICE);
        stake.approve(address(mkt), type(uint256).max);
        mkt.deposit(1, aAmt);
        vm.stopPrank();
        vm.startPrank(BOB);
        stake.approve(address(mkt), type(uint256).max);
        mkt.deposit(2, bAmt);
        vm.stopPrank();

        vm.warp(lockTime);
        mkt.close();
        vm.warp(resolveTime);
        ISettlementOracle.Resolution memory r = ISettlementOracle.Resolution({
            marketId: id,
            winner: 1,
            snapshotHash: keccak256("json"),
            resolvedAt: uint64(block.timestamp),
            challengeUntil: 0,
            nonce: 1
        });
        oracle.post(
            r,
            _signResolution(
                r.marketId,
                r.winner,
                r.snapshotHash,
                r.resolvedAt,
                r.challengeUntil,
                r.nonce
            )
        );
        mkt.settle();

        uint256 before = stake.balanceOf(ALICE);
        vm.prank(ALICE);
        mkt.redeem();
        uint256 payout = stake.balanceOf(ALICE) - before;

        // expected = (aAmt / aAmt) * (aAmt + bAmt) = aAmt + bAmt
        // But user only staked aAmt; delta equals gross
        assertEq(payout, uint256(aAmt) + uint256(bAmt));
    }
}
