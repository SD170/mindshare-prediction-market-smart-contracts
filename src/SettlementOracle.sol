// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISettlementOracle} from "./interfaces/ISettlementOracle.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "openzeppelin-contracts/contracts/utils/cryptography/MessageHashUtils.sol";


contract SettlementOracle is ISettlementOracle {
    address public immutable owner;
    address private signer;

    mapping(bytes32 => Resolution) private _res;
    mapping(bytes32 => bool) public usedHash;

    event SignerUpdated(address indexed signer);
    event Posted(
        bytes32 indexed marketId,
        uint8 winner,
        bytes32 snapshotHash,
        uint64 resolvedAt
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "owner");
        _;
    }

    constructor(address _signer) {
        owner = msg.sender;
        signer = _signer;
        emit SignerUpdated(_signer);
    }

    function getSigner() external view returns (address) {
        return signer;
    }

    function setSigner(address s) external onlyOwner {
        signer = s;
        emit SignerUpdated(s);
    }

    function getResolution(
        bytes32 marketId
    )
        external
        view
        returns (uint8 winner, bytes32 snapshotHash, uint64 resolvedAt)
    {
        Resolution memory r = _res[marketId];
        return (r.winner, r.snapshotHash, r.resolvedAt);
    }

    function post(Resolution calldata r, bytes calldata sig) external {
        // For production, upgrade to full EIP-712 typed data.
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
                address(this)
            )
        );
        require(!usedHash[blob], "dup");
        usedHash[blob] = true;

        address rec = ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(blob), sig);
        require(rec == signer, "sig");
        require(r.resolvedAt <= block.timestamp, "time");

        _res[r.marketId] = r;
        emit Posted(r.marketId, r.winner, r.snapshotHash, r.resolvedAt);
    }
}
