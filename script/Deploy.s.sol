// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ParimutuelMarket} from "src/ParimutuelMarket.sol";
import {MarketFactory} from "src/MarketFactory.sol";
import {SettlementOracle} from "src/SettlementOracle.sol";
import {StakeToken} from "src/StakeToken.sol";

contract Deploy is Script {

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        vm.startBroadcast(pk);

        // 1) Deploy mock stake token (replace with USDC test token if you prefer)
        StakeToken stake = new StakeToken();

        // 2) Deploy oracle with signer == deployer for MVP; update later
        SettlementOracle oracle = new SettlementOracle(deployer);

        // 3) Deploy market implementation and factory
        ParimutuelMarket impl = new ParimutuelMarket();
        MarketFactory factory = new MarketFactory(address(impl), address(stake), address(oracle), deployer);

        vm.stopBroadcast();

        // Log deployed addresses (can be saved manually or via broadcast artifacts)
        console.log("\n=== Deployment Addresses ===");
        console.log("SettlementOracle:", address(oracle));
        console.log("MarketFactory:", address(factory));
        console.log("StakeToken:", address(stake));
        console.log("Implementation:", address(impl));
        console.log("Deployer:", deployer);
        console.log("Signer:", deployer);
        console.log("\nCopy these addresses to oracle/config/contracts.json");
    }
}