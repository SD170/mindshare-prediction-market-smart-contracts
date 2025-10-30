// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {ISettlementOracle} from "src/interfaces/ISettlementOracle.sol";
import {ParimutuelMarket} from "src/ParimutuelMarket.sol";

contract MarketHappyTest is BaseTest {
    function test_Deposit_Close_Settle_Redeem() public {
        uint64 lockTime = uint64(block.timestamp + 1 hours);
        uint64 resolveTime = lockTime + 15 minutes;
        (ParimutuelMarket mkt, bytes32 id) = _createMarket("2025-11-01:TOP5:X", lockTime, resolveTime);

        vm.startPrank(ALICE);
        stake.approve(address(mkt), type(uint256).max);
        mkt.deposit(1, 60 ether); // YES
        vm.stopPrank();

        vm.startPrank(BOB);
        stake.approve(address(mkt), type(uint256).max);
        mkt.deposit(2, 40 ether); // NO
        vm.stopPrank();

        // lock
        vm.warp(lockTime);
        mkt.close();

        // oracle post winner=1
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

        // settle
        mkt.settle();

        // redeem winners (ALICE)
        uint256 balBefore = stake.balanceOf(ALICE);
        vm.prank(ALICE);
        mkt.redeem();
        uint256 balAfter = stake.balanceOf(ALICE);

        // Alice staked 60, gross=100 -> payout 100
        assertApproxEqAbs(balAfter - balBefore, 100 ether, 1);

        // Bob should get nothing; redeem succeeds but pays 0
        uint256 bobBefore = stake.balanceOf(BOB);
        vm.prank(BOB);
        mkt.redeem();
        uint256 bobAfter = stake.balanceOf(BOB);
        assertEq(bobAfter - bobBefore, 0);
    }

    function test_MultiUsers_BothSides_ExactProRata() public {
        uint64 lockTime = uint64(block.timestamp + 1 hours);
        uint64 resolveTime = lockTime + 1 hours;
        (ParimutuelMarket mkt, bytes32 id) = _createMarket("H2H:A-vs-B", lockTime, resolveTime);

        // YES pool: 70 total (40 + 30)
        vm.startPrank(ALICE);
        stake.approve(address(mkt), type(uint256).max);
        mkt.deposit(1, 40 ether);
        vm.stopPrank();

        vm.startPrank(BOB);
        stake.approve(address(mkt), type(uint256).max);
        mkt.deposit(1, 30 ether);
        vm.stopPrank();

        // NO pool: 30 total
        vm.startPrank(CHARLIE);
        stake.approve(address(mkt), type(uint256).max);
        mkt.deposit(2, 30 ether);
        vm.stopPrank();

        vm.warp(lockTime);
        mkt.close();

        // YES wins
        vm.warp(resolveTime);
        ISettlementOracle.Resolution memory r = ISettlementOracle.Resolution({
            marketId: id,
            winner: 1,
            snapshotHash: keccak256("json2"),
            resolvedAt: uint64(block.timestamp),
            challengeUntil: 0,
            nonce: 2
        });
        bytes memory sig = _signResolution(r.marketId, r.winner, r.snapshotHash, r.resolvedAt, r.challengeUntil, r.nonce);
        oracle.post(r, sig);
        mkt.settle();

        // Gross = 100. Per-unit YES = 100/70 = 1.428571...
        uint256 b0 = stake.balanceOf(ALICE);
        vm.prank(ALICE); mkt.redeem();
        uint256 pAlice = stake.balanceOf(ALICE) - b0;
        assertApproxEqAbs(pAlice, 57_142857142857142857, 10); // 40 * 1.428571...

        uint256 b1 = stake.balanceOf(BOB);
        vm.prank(BOB); mkt.redeem();
        uint256 pBob = stake.balanceOf(BOB) - b1;
        assertApproxEqAbs(pBob, 42_857142857142857143, 10); // 30 * 1.428571...
    }
}