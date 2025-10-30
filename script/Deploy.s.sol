// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {ParimutuelMarket} from "src/ParimutuelMarket.sol";
import {MarketFactory} from "src/MarketFactory.sol";
import {SettlementOracle} from "src/SettlementOracle.sol";
import {StakeToken} from "src/StakeToken.sol";

contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        // 1) Deploy mock stake token (replace with USDC test token if you prefer)
        StakeToken stake = new StakeToken();

        // 2) Deploy oracle with signer == deployer for MVP; update later
        SettlementOracle oracle = new SettlementOracle(vm.addr(pk));

        // 3) Deploy market implementation and factory
        ParimutuelMarket impl = new ParimutuelMarket();
        MarketFactory factory = new MarketFactory(address(impl), address(stake), address(oracle), vm.addr(pk));

        // 4) Example market creation (Top-5 for entity X on date D)
        bytes32 questionHash = keccak256(abi.encodePacked("2025-11-01:TOP5:entity-x"));
        uint64 lockTime = uint64(block.timestamp + 1 days);
        uint64 resolveTime = lockTime + 15 minutes;
        factory.createMarket(questionHash, lockTime, resolveTime);

        vm.stopBroadcast();
    }
}