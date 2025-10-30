// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ISettlementOracle {
    struct Resolution {
        bytes32 marketId;
        uint8 winner; // 1 or 2
        bytes32 snapshotHash; // keccak256(json)
        uint64 resolvedAt; // unix
        uint64 challengeUntil; // unix (optional gating)
        uint256 nonce; // replay protection
    }

    function getSigner() external view returns (address);

    function getResolution(
        bytes32 marketId
    )
        external
        view
        returns (uint8 winner, bytes32 snapshotHash, uint64 resolvedAt);

    function post(Resolution calldata r, bytes calldata sig) external;
}
