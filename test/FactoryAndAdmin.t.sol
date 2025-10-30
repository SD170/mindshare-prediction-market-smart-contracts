// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {ParimutuelMarket} from "src/ParimutuelMarket.sol";
import {ISettlementOracle} from "src/interfaces/ISettlementOracle.sol";

contract FactoryAndAdminTest is BaseTest {
    function test_Factory_CreateCancelAndRefund() public {
        uint64 lockTime = uint64(block.timestamp + 100);
        uint64 resolveTime = lockTime + 900;
        (ParimutuelMarket mkt, ) = _createMarket("Q8", lockTime, resolveTime);

        vm.startPrank(ALICE);
        stake.approve(address(mkt), type(uint256).max);
        mkt.deposit(1, 10 ether);
        vm.stopPrank();

        // only factory can cancel
        vm.expectRevert(bytes("factory"));
        mkt.cancel();
        // factory cancels
        factory.cancel(address(mkt));

        // users can refund 1:1
        uint256 b = stake.balanceOf(ALICE);
        vm.prank(ALICE);
        mkt.refund();
        assertEq(stake.balanceOf(ALICE) - b, 10 ether);
    }

    function test_Fee_On_Gross() public {
        // set protocol fee
        factory.setParams(address(stake), address(oracle), address(this), 1000); // 10%
        uint64 lockTime = uint64(block.timestamp + 100);
        uint64 resolveTime = lockTime + 900;
        (ParimutuelMarket mkt, bytes32 id) = _createMarket(
            "Q9",
            lockTime,
            resolveTime
        );

        vm.startPrank(ALICE);
        stake.approve(address(mkt), type(uint256).max);
        mkt.deposit(1, 60 ether);
        vm.stopPrank();
        vm.startPrank(BOB);
        stake.approve(address(mkt), type(uint256).max);
        mkt.deposit(2, 40 ether);
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

        // gross=100, fee=10, net=90, per-unit YES=90/60=1.5, Alice staked 60 -> payout=90
        uint256 b = stake.balanceOf(ALICE);
        vm.prank(ALICE);
        mkt.redeem();
        assertEq(stake.balanceOf(ALICE) - b, 90 ether);
    }
}
