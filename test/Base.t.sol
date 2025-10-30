// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {StakeToken} from "src/StakeToken.sol";
import {ParimutuelMarket} from "src/ParimutuelMarket.sol";
import {MarketFactory} from "src/MarketFactory.sol";
import {SettlementOracle} from "src/SettlementOracle.sol";
import {ISettlementOracle} from "src/interfaces/ISettlementOracle.sol";

abstract contract BaseTest is Test {
    StakeToken internal stake;
    SettlementOracle internal oracle;
    ParimutuelMarket internal impl;
    MarketFactory internal factory;

    // test accounts
    address internal ALICE;
    address internal BOB;
    address internal CHARLIE;

    // oracle signing key (we control both pk and address)
    uint256 internal ORACLE_PK;
    address internal ORACLE_SIGNER;

    function setUp() public virtual {
        // deterministic keys
        ORACLE_PK = uint256(keccak256("ORACLE_PK"));
        ORACLE_SIGNER = vm.addr(ORACLE_PK);

        ALICE = makeAddr("ALICE");
        BOB = makeAddr("BOB");
        CHARLIE = makeAddr("CHARLIE");

        stake = new StakeToken();
        oracle = new SettlementOracle(ORACLE_SIGNER);
        impl = new ParimutuelMarket();
        factory = new MarketFactory(
            address(impl),
            address(stake),
            address(oracle),
            address(this)
        );

        // fund users
        stake.transfer(ALICE, 1_000_000 ether);
        stake.transfer(BOB, 1_000_000 ether);
        stake.transfer(CHARLIE, 1_000_000 ether);
    }

    function _createMarket(
        string memory question,
        uint64 lockTime,
        uint64 resolveTime
    ) internal returns (ParimutuelMarket mkt, bytes32 id) {
        bytes32 qh = keccak256(bytes(question));
        (address m, bytes32 mid) = factory.createMarket(
            qh,
            lockTime,
            resolveTime
        );
        mkt = ParimutuelMarket(payable(m));
        id = mid;
    }

    function _signResolution(
        bytes32 marketId,
        uint8 winner,
        bytes32 snapshotHash,
        uint64 resolvedAt,
        uint64 challengeUntil,
        uint256 nonce
    ) internal view returns (bytes memory sig) {
        // must mirror SettlementOracle.sol blob hashing
        bytes32 blob = keccak256(
            abi.encode(
                keccak256(
                    "Resolve(bytes32 marketId,uint8 winner,bytes32 snapshotHash,uint64 resolvedAt,uint64 challengeUntil,uint256 nonce,address this)"
                ),
                marketId,
                winner,
                snapshotHash,
                resolvedAt,
                challengeUntil,
                nonce,
                address(oracle)
            )
        );
        // sign the Ethereum Signed Message variant to match oracle verification
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", blob));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ORACLE_PK, ethHash);
        sig = abi.encodePacked(r, s, v);
    }
}
