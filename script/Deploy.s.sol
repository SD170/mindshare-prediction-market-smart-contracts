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

        // 1) Use existing stake token if provided, otherwise deploy new one
        address stakeAddress;
        try vm.envAddress("STAKE_TOKEN_ADDRESS") returns (address existingToken) {
            stakeAddress = existingToken;
            console.log("Using existing StakeToken:", stakeAddress);
        } catch {
            // Deploy new token if STAKE_TOKEN_ADDRESS not set
            StakeToken stake = new StakeToken();
            stakeAddress = address(stake);
            console.log("Deployed new StakeToken:", stakeAddress);
        }

        // 2) Deploy oracle with signer == deployer for MVP; update later
        SettlementOracle oracle = new SettlementOracle(deployer);

        // 3) Deploy market implementation and factory
        ParimutuelMarket impl = new ParimutuelMarket();
        MarketFactory factory = new MarketFactory(address(impl), stakeAddress, address(oracle), deployer);

        vm.stopBroadcast();

        // Log deployed addresses
        console.log("\n=== Deployment Addresses ===");
        console.log("SettlementOracle:", address(oracle));
        console.log("MarketFactory:", address(factory));
        console.log("StakeToken:", stakeAddress);
        console.log("Implementation:", address(impl));
        console.log("Deployer:", deployer);
        console.log("Signer:", deployer);
        
        // Output JSON for API
        console.log("\n=== Contracts JSON (for API) ===");
        console.log("{");
        console.log('  "contracts": [');
        console.log('    {"type": "settlementOracle", "address": "', address(oracle), '"},');
        console.log('    {"type": "marketFactory", "address": "', address(factory), '"},');
        console.log('    {"type": "stakeToken", "address": "', stakeAddress, '"},');
        console.log('    {"type": "implementation", "address": "', address(impl), '"}');
        console.log("  ]");
        console.log("}");
        
        console.log("\nTo reuse this token in future deployments, set:");
        console.log("export STAKE_TOKEN_ADDRESS=", stakeAddress);
    }
}