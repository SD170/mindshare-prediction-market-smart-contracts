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
        
        // Read market config from JSON file or environment variable
        string memory configJson;
        try vm.envString("MARKETS_CONFIG_JSON") returns (string memory envJson) {
            configJson = envJson;
        } catch {
            // Fallback to reading from file
            string memory configPath = vm.envOr("MARKETS_CONFIG_PATH", string("markets-config.json"));
            configJson = vm.readFile(configPath);
        }
        
        vm.startBroadcast(pk);
        
        MarketFactory factory = MarketFactory(factoryAddress);
        
        // Get current timestamp and set times
        uint64 baseTime = uint64(block.timestamp);
        uint64 lockTime = baseTime + 5 minutes; // Lock in 5 minutes
        uint64 resolveTime = lockTime + 10 seconds; // Resolve 10 seconds after lock
        
        console.log("\n=== Market Configuration (JSON) ===");
        console.log("[");
        
        // Parse and create Top-10 markets
        uint256 top10Count = configJson.readUint(".top10Count");
        
        for (uint i = 0; i < top10Count; i++) {
            string memory projectName = configJson.readString(string.concat(".top10[", vm.toString(i), "].projectName"));
            
            bytes32 questionHash = keccak256(
                abi.encodePacked("TOP10:", projectName, ":", vm.toString(lockTime))
            );
            
            (address market, bytes32 marketId) = factory.createMarket(
                questionHash,
                lockTime,
                resolveTime
            );
            
            console.log("  {");
            console.log("    \"type\": \"top10\",");
            console.log("    \"projectName\": \"%s\",", projectName);
            console.log("    \"lockTime\": %d,", lockTime);
            console.log("    \"resolveTime\": %d,", resolveTime);
            console.log("    \"questionHash\": \"%s\",", vm.toString(questionHash));
            console.log("    \"marketId\": \"%s\",", vm.toString(marketId));
            console.log("    \"marketAddress\": \"%s\"", market);
            console.log("  },");
        }
        
        // Parse and create H2H markets
        uint256 h2hCount = configJson.readUint(".h2hCount");
        
        for (uint i = 0; i < h2hCount; i++) {
            string memory projectA = configJson.readString(string.concat(".h2h[", vm.toString(i), "].projectA"));
            string memory projectB = configJson.readString(string.concat(".h2h[", vm.toString(i), "].projectB"));
            
            bytes32 questionHash = keccak256(
                abi.encodePacked("H2H:", projectA, ":", projectB, ":", vm.toString(lockTime))
            );
            
            (address market, bytes32 marketId) = factory.createMarket(
                questionHash,
                lockTime,
                resolveTime
            );
            
            console.log("  {");
            console.log("    \"type\": \"h2h\",");
            console.log("    \"projectA\": \"%s\",", projectA);
            console.log("    \"projectB\": \"%s\",", projectB);
            console.log("    \"lockTime\": %d,", lockTime);
            console.log("    \"resolveTime\": %d,", resolveTime);
            console.log("    \"questionHash\": \"%s\",", vm.toString(questionHash));
            console.log("    \"marketId\": \"%s\",", vm.toString(marketId));
            console.log("    \"marketAddress\": \"%s\"", market);
            if (i < h2hCount - 1) {
                console.log("  },");
            } else {
                console.log("  }");
            }
        }
        
        console.log("]");
        console.log("\n=== All markets created successfully! ===");
        
        vm.stopBroadcast();
    }
}

