// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {MarketFactory} from "src/MarketFactory.sol";
import {ParimutuelMarket} from "src/ParimutuelMarket.sol";

contract CreateMarkets is Script {
    using stdJson for string;

    struct MarketConfig {
        string marketType; // "top10" or "h2h"
        string projectName; // for top10
        string projectA; // for h2h
        string projectB; // for h2h
        uint64 lockTime;
        uint64 resolveTime;
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address factoryAddress = vm.envAddress("FACTORY_ADDRESS");
        
        vm.startBroadcast(pk);
        
        MarketFactory factory = MarketFactory(factoryAddress);
        
        // Get current timestamp and set times
        uint64 baseTime = uint64(block.timestamp);
        uint64 lockTime = baseTime + 5 minutes; // Lock in 5 minutes (for testing)
        uint64 resolveTime = lockTime + 15 minutes; // Resolve 15 min after lock
        
        // Create 5 Top-10 markets
        string[5] memory top10Projects = ["Ethereum", "Uniswap", "Aave", "Chainlink", "Polygon"];
        
        console.log("\n=== All 10 markets created successfully! ===");
        console.log("\n=== Market Configuration (JSON) ===");
        console.log("Copy the JSON below and import via backend API /api/admin/markets/import");
        console.log("[");
        
        // Create and output Top-10 markets
        for (uint i = 0; i < top10Projects.length; i++) {
            bytes32 questionHash = keccak256(
                abi.encodePacked("TOP10:", top10Projects[i], ":", vm.toString(lockTime))
            );
            
            (address market, bytes32 marketId) = factory.createMarket(
                questionHash,
                lockTime,
                resolveTime
            );
            
            console.log("  {");
            console.log("    \"type\": \"top10\",");
            console.log("    \"projectName\": \"%s\",", top10Projects[i]);
            console.log("    \"lockTime\": %d,", lockTime);
            console.log("    \"resolveTime\": %d,", resolveTime);
            console.log("    \"questionHash\": \"%s\",", vm.toString(questionHash));
            console.log("    \"marketId\": \"%s\",", vm.toString(marketId));
            console.log("    \"marketAddress\": \"%s\"", market);
            console.log("  },");
        }
        
        // Create 5 Head-to-Head markets
        string[5] memory h2hProjectA = ["Ethereum", "Uniswap", "Arbitrum", "Base", "Solana"];
        string[5] memory h2hProjectB = ["Bitcoin", "Aave", "Optimism", "Polygon", "Avalanche"];
        
        // Create and output H2H markets
        for (uint i = 0; i < h2hProjectA.length; i++) {
            bytes32 questionHash = keccak256(
                abi.encodePacked("H2H:", h2hProjectA[i], ":", h2hProjectB[i], ":", vm.toString(lockTime))
            );
            
            (address market, bytes32 marketId) = factory.createMarket(
                questionHash,
                lockTime,
                resolveTime
            );
            
            console.log("  {");
            console.log("    \"type\": \"h2h\",");
            console.log("    \"projectA\": \"%s\",", h2hProjectA[i]);
            console.log("    \"projectB\": \"%s\",", h2hProjectB[i]);
            console.log("    \"lockTime\": %d,", lockTime);
            console.log("    \"resolveTime\": %d,", resolveTime);
            console.log("    \"questionHash\": \"%s\",", vm.toString(questionHash));
            console.log("    \"marketId\": \"%s\",", vm.toString(marketId));
            console.log("    \"marketAddress\": \"%s\"", market);
            if (i < h2hProjectA.length - 1) {
                console.log("  },");
            } else {
                console.log("  }");
            }
        }
        
        console.log("]");
        
        vm.stopBroadcast();
    }
}

