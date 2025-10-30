// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {ISettlementOracle} from "./interfaces/ISettlementOracle.sol";

contract ParimutuelMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Phase {
        Trading,
        Locked,
        Resolved,
        Cancelled
    }

    struct Pools {
        uint128 A;
        uint128 B;
    }
    struct Account {
        uint128 aClaims;
        uint128 bClaims;
        bool redeemed;
    }

    // NOTE: no immutables here; clones must set via initialize()
    IERC20 public stakeToken;
    ISettlementOracle public oracle;
    address public factory;

    bytes32 public marketId;
    bytes32 public questionHash;

    uint64 public lockTime;
    uint64 public resolveTime;
    uint16 public feeBps; // 0 for MVP
    address public feeSink;

    Pools public pools;
    Phase public phase;
    uint8 public winner; // 1 or 2

    mapping(address => Account) public a;

    bool private initialized;

    event Deposit(address indexed user, uint8 indexed outcome, uint256 amount);
    event Locked(uint64 at);
    event Resolved(uint8 winner, bytes32 snapshotHash);
    event Redeem(address indexed user, uint256 payout, uint256 fee);
    event Cancelled();

    modifier onlyFactory() {
        require(msg.sender == factory, "factory");
        _;
    }
    modifier inPhase(Phase p) {
        require(phase == p, "phase");
        _;
    }

    // Constructor runs only on the implementation; clones won't execute it.
    constructor() {}

    function initialize(
        address _stakeToken,
        address _oracle,
        address _feeSink,
        bytes32 _marketId,
        bytes32 _questionHash,
        uint64 _lockTime,
        uint64 _resolveTime,
        uint16 _feeBps
    ) external {
        require(!initialized, "inited");
        initialized = true;

        // capture factory as the caller (must be MarketFactory)
        factory = msg.sender;

        stakeToken = IERC20(_stakeToken);
        oracle = ISettlementOracle(_oracle);
        feeSink = _feeSink;
        marketId = _marketId;
        questionHash = _questionHash;
        lockTime = _lockTime;
        resolveTime = _resolveTime;
        feeBps = _feeBps;

        phase = Phase.Trading;
    }

    function deposit(
        uint8 outcome,
        uint256 amount
    ) external nonReentrant inPhase(Phase.Trading) {
        require(block.timestamp < lockTime, "locked");
        require(outcome == 1 || outcome == 2, "outcome");
        stakeToken.safeTransferFrom(msg.sender, address(this), amount);

        Account storage acc = a[msg.sender];
        if (outcome == 1) {
            pools.A += uint128(amount);
            acc.aClaims += uint128(amount);
        } else {
            pools.B += uint128(amount);
            acc.bClaims += uint128(amount);
        }
        emit Deposit(msg.sender, outcome, amount);
    }

    function close() external inPhase(Phase.Trading) {
        require(block.timestamp >= lockTime, "time");
        phase = Phase.Locked;
        emit Locked(uint64(block.timestamp));
    }

    function settle() external inPhase(Phase.Locked) {
        require(block.timestamp >= resolveTime, "time");
        (uint8 w, bytes32 snap, ) = oracle.getResolution(marketId);
        require(w == 1 || w == 2, "nores");
        winner = w;
        phase = Phase.Resolved;
        emit Resolved(w, snap);
    }

    function redeem() external nonReentrant inPhase(Phase.Resolved) {
        Account storage acc = a[msg.sender];
        require(!acc.redeemed, "done");
        acc.redeemed = true;

        uint256 Y = pools.A;
        uint256 N = pools.B;
        uint256 gross = Y + N;

        uint256 fee = 0;
        if (feeBps > 0) {
            fee = (gross * feeBps) / 10_000;
            stakeToken.safeTransfer(feeSink, fee);
            gross -= fee;
        }

        uint256 payout;
        if (winner == 1) {
            require(Y > 0, "Y=0");
            payout = (uint256(acc.aClaims) * gross) / Y;
        } else {
            require(N > 0, "N=0");
            payout = (uint256(acc.bClaims) * gross) / N;
        }
        acc.aClaims = 0;
        acc.bClaims = 0;

        stakeToken.safeTransfer(msg.sender, payout);
        emit Redeem(msg.sender, payout, fee);
    }

    function cancel() external onlyFactory {
        require(phase != Phase.Resolved, "resolved");
        phase = Phase.Cancelled;
        emit Cancelled();
    }

    function refund() external nonReentrant inPhase(Phase.Cancelled) {
        Account storage acc = a[msg.sender];
        uint256 amt = uint256(acc.aClaims) + uint256(acc.bClaims);
        require(amt > 0, "0");
        acc.aClaims = 0;
        acc.bClaims = 0;
        stakeToken.safeTransfer(msg.sender, amt);
    }
}
