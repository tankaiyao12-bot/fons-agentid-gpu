// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice EIP-1167 最小代理 + CREATE2。自带一份，不引第三方库。
/// @dev 关键性质：地址只由 (工厂, salt, 实现) 决定，**部署之前就能算出来**。
///      整个「先在 agent 里接入、再去网页一笔开户」的顺序就靠这条成立 ——
///      AgentID 能对一个还不存在的地址签认领。
library Clones {
    error DeployFailed();

    function cloneDeterministic(address impl, bytes32 salt) internal returns (address instance) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, impl))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create2(0, ptr, 0x37, salt)
        }
        if (instance == address(0)) revert DeployFailed();
    }

    function predict(address impl, bytes32 salt, address deployer) internal pure returns (address predicted) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, impl))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf3ff00000000000000000000000000000000)
            mstore(add(ptr, 0x38), shl(0x60, deployer))
            mstore(add(ptr, 0x4c), salt)
            mstore(add(ptr, 0x6c), keccak256(ptr, 0x37))
            predicted := and(keccak256(add(ptr, 0x37), 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }
}
