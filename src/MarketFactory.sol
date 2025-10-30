// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ParimutuelMarket} from "./ParimutuelMarket.sol";

contract MarketFactory {
    address public immutable implementation;
    address public stakeToken;
    address public oracle;
    address public feeSink;
    uint16  public feeBps; // 0 for MVP
    address public owner;

    event MarketCreated(address indexed market, bytes32 indexed marketId, uint64 lockTime, uint64 resolveTime);
    event ParamsUpdated(address stakeToken, address oracle, address feeSink, uint16 feeBps);

    modifier onlyOwner() { require(msg.sender == owner, "owner"); _; }

    constructor(address _implementation, address _stakeToken, address _oracle, address _feeSink) {
        implementation = _implementation;
        stakeToken = _stakeToken;
        oracle = _oracle;
        feeSink = _feeSink;
        owner = msg.sender;
        feeBps = 0;
    }

    function setParams(address _stakeToken, address _oracle, address _feeSink, uint16 _feeBps) external onlyOwner {
        stakeToken = _stakeToken; oracle = _oracle; feeSink = _feeSink; feeBps = _feeBps;
        emit ParamsUpdated(_stakeToken, _oracle, _feeSink, _feeBps);
    }

    function computeMarketId(bytes32 questionHash, uint64 lockTime) public view returns (bytes32) {
        return keccak256(abi.encode(address(this), questionHash, lockTime));
    }

    function createMarket(bytes32 questionHash, uint64 lockTime, uint64 resolveTime)
        external onlyOwner returns (address market, bytes32 marketId)
    {
        marketId = computeMarketId(questionHash, lockTime);
        market = Clones.clone(implementation);
        ParimutuelMarket(payable(market)).initialize(
            stakeToken,
            oracle,
            feeSink,
            marketId,
            questionHash,
            lockTime,
            resolveTime,
            feeBps
        );
        emit MarketCreated(market, marketId, lockTime, resolveTime);
    }

    function cancel(address market) external onlyOwner {
        ParimutuelMarket(market).cancel();
    }
}