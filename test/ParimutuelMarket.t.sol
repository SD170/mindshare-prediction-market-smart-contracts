// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {ParimutuelMarket} from "src/ParimutuelMarket.sol";
import {ISettlementOracle} from "src/interfaces/ISettlementOracle.sol";

contract ParimutuelMarketTest is BaseTest {
    address alice = address(0xA11CE);
    address bob   = address(0xB0B);

    function _mk(bytes32 qh, uint64 lockTime, uint64 resolveTime) internal returns (ParimutuelMarket mkt, bytes32 id) {
        return _createMarket(string(abi.encodePacked(qh)), lockTime, resolveTime);
    }

    function test_Flow_Deposit_Close_Settle_Redeem() public {
        bytes32 qh = keccak256("2025-11-01:TOP5:X");
        uint64 lockTime = uint64(block.timestamp + 1 hours);
        uint64 resolveTime = lockTime + 15 minutes;
        (ParimutuelMarket mkt, bytes32 id) = _mk(qh, lockTime, resolveTime);

        // approvals
        vm.startPrank(ALICE);
        stake.approve(address(mkt), type(uint256).max);
        mkt.deposit(1, 60 ether);
        vm.stopPrank();

        vm.startPrank(BOB);
        stake.approve(address(mkt), type(uint256).max);
        mkt.deposit(2, 40 ether);
        vm.stopPrank();

        // lock
        vm.warp(lockTime);
        mkt.close();

        // oracle post & settle (winner=1)
        vm.warp(resolveTime);
        ISettlementOracle.Resolution memory r = ISettlementOracle.Resolution({
            marketId: id,
            winner: 1,
            snapshotHash: keccak256("json"),
            resolvedAt: uint64(block.timestamp),
            challengeUntil: 0,
            nonce: 1
        });
        bytes memory sig = _signResolution(r.marketId, r.winner, r.snapshotHash, r.resolvedAt, r.challengeUntil, r.nonce);
        oracle.post(r, sig);

        mkt.settle();

        // redeem
        uint256 balBefore = stake.balanceOf(ALICE);
        vm.prank(ALICE);
        mkt.redeem();
        uint256 balAfter = stake.balanceOf(ALICE);

        // Alice staked 60, gross=100, per-unit=100/60=1.666..., payout=~100
        assertApproxEqAbs(balAfter - balBefore, 100 ether, 1e9);
    }

}