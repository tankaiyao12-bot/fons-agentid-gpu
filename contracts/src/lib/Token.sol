// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice 只要三件事的最小封装。BSC 上有不返回 bool 的老代币（USDT 就是），所以不能直接信返回值。
library Token {
    error TransferFailed();
    error ApproveFailed();

    function safeTransfer(address token, address to, uint256 amount) internal {
        _call(token, abi.encodeCall(IERC20.transfer, (to, amount)), TransferFailed.selector);
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        _call(token, abi.encodeCall(IERC20.transferFrom, (from, to, amount)), TransferFailed.selector);
    }

    /// @dev 先归零再设值：有些代币（USDT 风格）不允许从非零额度直接改成另一个非零额度。
    function forceApprove(address token, address spender, uint256 amount) internal {
        if (amount != 0 && IERC20(token).allowance(address(this), spender) != 0) {
            _call(token, abi.encodeCall(IERC20.approve, (spender, 0)), ApproveFailed.selector);
        }
        _call(token, abi.encodeCall(IERC20.approve, (spender, amount)), ApproveFailed.selector);
    }

    function _call(address token, bytes memory data, bytes4 err) private {
        (bool ok, bytes memory ret) = token.call(data);
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) {
            assembly ("memory-safe") {
                mstore(0x00, err)
                revert(0x00, 0x04)
            }
        }
    }
}

/// @notice 够用的 ECDSA：只做 65 字节签名的 recover，并且挡掉可延展的高位 s。
library Sig {
    error BadSignature();

    /// @notice digest 已经是最终要签的那 32 字节（EIP-712 走这条）。
    function recoverRaw(bytes32 digest, bytes memory sig) internal pure returns (address) {
        if (sig.length != 65) revert BadSignature();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) revert BadSignature();
        if (v != 27 && v != 28) revert BadSignature();
        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert BadSignature();
        return signer;
    }

    /// @notice 外面套一层 personal_sign 前缀（4337 的 UserOp 签名走这条）。
    function recoverEth(bytes32 hash, bytes memory sig) internal pure returns (address) {
        return recoverRaw(keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)), sig);
    }
}
