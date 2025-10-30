// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {ParimutuelMarket} from "src/ParimutuelMarket.sol";
import {ISettlementOracle} from "src/interfaces/ISettlementOracle.sol";

contract MarketNegativeTest is BaseTest {
    function test_Revert_DepositAfterLock() public {
        uint64 lockTime = uint64(block.timestamp + 1);
        uint64 resolveTime = lockTime + 900;
        (ParimutuelMarket mkt, ) = _createMarket("Q", lockTime, resolveTime);

        // enter Locked phase
        vm.warp(lockTime);
        mkt.close();

        // deposit after lock -> phase revert
        vm.startPrank(ALICE);
        stake.approve(address(mkt), type(uint256).max);
        vm.expectRevert(abi.encodePacked("phase"));
        mkt.deposit(1, 1 ether);
        vm.stopPrank();
    }

    function test_Revert_InvalidOutcome() public {
        uint64 lockTime = uint64(block.timestamp + 3600);
        uint64 resolveTime = lockTime + 900;
        (ParimutuelMarket mkt, ) = _createMarket("Q2", lockTime, resolveTime);

        vm.startPrank(ALICE);
        stake.approve(address(mkt), type(uint256).max);
        vm.expectRevert(abi.encodePacked("outcome"));
        mkt.deposit(3, 1 ether); // only 1 or 2 allowed
        vm.stopPrank();
    }

    function test_Revert_SettleEarly_NoResolution() public {
        uint64 lockTime = uint64(block.timestamp + 100);
        uint64 resolveTime = lockTime + 900;
        (ParimutuelMarket mkt, bytes32 id) = _createMarket(
            "Q3",
            lockTime,
            resolveTime
        );

        // add minimal liquidity so flows are realistic
        vm.startPrank(ALICE);
        stake.approve(address(mkt), type(uint256).max);
        mkt.deposit(1, 1 ether);
        vm.stopPrank();

        vm.warp(lockTime);
        mkt.close();

        // settle before resolveTime -> "time"
        vm.expectRevert(abi.encodePacked("time"));
        mkt.settle();

        // after resolveTime but no oracle post -> "nores"
        vm.warp(resolveTime);
        vm.expectRevert(abi.encodePacked("nores"));
        mkt.settle();

        // (optional) sanity: now post a valid resolution so test doesn't leave unresolved storage
        vm.warp(resolveTime + 1);
        ISettlementOracle.Resolution memory r = ISettlementOracle.Resolution({
            marketId: id,
            winner: 1,
            snapshotHash: keccak256("json"),
            resolvedAt: uint64(block.timestamp),
            challengeUntil: 0,
            nonce: 1
        });
        bytes memory sig = _signResolution(
            r.marketId,
            r.winner,
            r.snapshotHash,
            r.resolvedAt,
            r.challengeUntil,
            r.nonce
        );
        oracle.post(r, sig);
        mkt.settle(); // should succeed now (no assert needed)
    }

    function test_Revert_InvalidOracleSig() public {
        uint64 lockTime = uint64(block.timestamp + 100);
        uint64 resolveTime = lockTime + 900;
        (ParimutuelMarket mkt, bytes32 id) = _createMarket(
            "Q4",
            lockTime,
            resolveTime
        );

        vm.warp(lockTime);
        mkt.close();

        // craft a resolution with a bad signature (signed by wrong key)
        ISettlementOracle.Resolution memory r = ISettlementOracle.Resolution({
            marketId: id,
            winner: 1,
            snapshotHash: keccak256("json"),
            resolvedAt: lockTime + 901,
            challengeUntil: 0,
            nonce: 123
        });

        bytes32 blob = keccak256(
            abi.encode(
                keccak256(
                    "Resolve(bytes32 marketId,uint8 winner,bytes32 snapshotHash,uint64 resolvedAt,uint64 challengeUntil,uint256 nonce,address this)"
                ),
                r.marketId,
                r.winner,
                r.snapshotHash,
                r.resolvedAt,
                r.challengeUntil,
                r.nonce,
                address(oracle)
            )
        );
        // sign with random pk (not ORACLE_PK), using Ethereum Signed Message hash
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", blob));
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(uint256(999), ethHash);
        bytes memory badSig = abi.encodePacked(rr, ss, v);

        vm.expectRevert(abi.encodePacked("sig"));
        oracle.post(r, badSig);
    }

    function test_RedeemLosingSide_PaysZero_DoesNotRevert() public {
        uint64 lockTime = uint64(block.timestamp + 100);
        uint64 resolveTime = lockTime + 900;
        (ParimutuelMarket mkt, bytes32 id) = _createMarket(
            "Q6",
            lockTime,
            resolveTime
        );

        // ALICE on outcome 1; BOB on outcome 2
        vm.startPrank(ALICE);
        stake.approve(address(mkt), type(uint256).max);
        mkt.deposit(1, 1 ether);
        vm.stopPrank();

        vm.startPrank(BOB);
        stake.approve(address(mkt), type(uint256).max);
        mkt.deposit(2, 2 ether);
        vm.stopPrank();

        vm.warp(lockTime);
        mkt.close();

        // outcome 2 wins
        vm.warp(resolveTime);
        ISettlementOracle.Resolution memory r = ISettlementOracle.Resolution({
            marketId: id,
            winner: 2,
            snapshotHash: keccak256("json"),
            resolvedAt: uint64(block.timestamp),
            challengeUntil: 0,
            nonce: 7
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

        // ALICE is on losing side; redeem should succeed but pay 0, and further redeem should revert ("done")
        uint256 before = stake.balanceOf(ALICE);
        vm.prank(ALICE);
        mkt.redeem(); // pays 0
        uint256 afterBal = stake.balanceOf(ALICE);
        assertEq(afterBal - before, 0);

        vm.expectRevert(abi.encodePacked("done"));
        vm.prank(ALICE);
        mkt.redeem();
    }

    function test_Revert_RefundOnlyWhenCancelled() public {
        uint64 lockTime = uint64(block.timestamp + 100);
        uint64 resolveTime = lockTime + 900;
        (ParimutuelMarket mkt, ) = _createMarket("Q7", lockTime, resolveTime);

        vm.startPrank(ALICE);
        stake.approve(address(mkt), type(uint256).max);
        mkt.deposit(1, 1 ether);
        vm.stopPrank();

        // refund outside Cancelled phase -> "phase"
        vm.expectRevert(abi.encodePacked("phase"));
        vm.prank(ALICE);
        mkt.refund();
    }

    function test_FactoryOnlyCancel() public {
        uint64 lockTime = uint64(block.timestamp + 100);
        uint64 resolveTime = lockTime + 900;
        (ParimutuelMarket mkt, ) = _createMarket("Q8", lockTime, resolveTime);

        // direct cancel call from non-factory should revert
        vm.expectRevert(abi.encodePacked("factory"));
        mkt.cancel();
    }
}
