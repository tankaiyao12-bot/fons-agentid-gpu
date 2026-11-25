// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AgentAccount} from "./AgentAccount.sol";
import {Clones} from "./lib/Clones.sol";
import {Sig} from "./lib/Token.sol";

/// @title AgentAccountFactory
/// @notice 一笔交易开户：校验认领签名 + CREATE2 部署 + 写死三个地址。
///
/// 为什么能「先在 agent 里接入，再去网页开户」：
///   salt 只由 skill 手里已有的东西决定（agentKey · agentIdEoa · agentId），
///   所以账户地址在部署之前就能算出来，AgentID 可以对一个还不存在的地址签认领。
///   owner 是网页那一步才填的，**不进 salt** —— 否则 skill 算不出地址。
contract AgentAccountFactory {
    using Clones for address;

    /// 认领签名的 EIP-712 结构：{ account, agentId, deadline }
    bytes32 public constant CLAIM_TYPEHASH = keccak256("Claim(address account,string agentId,uint256 deadline)");

    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    address public immutable implementation;
    bytes32 private immutable _domainSeparator;
    uint256 private immutable _chainId;

    event AccountCreated(
        address indexed account, address indexed owner, address indexed agentIdEoa, address agentKey, string agentId
    );

    error ClaimExpired();
    error BadClaim();
    error ZeroAddress();

    /// @dev 费率在**工厂**上定死，所有这个工厂开出来的账户共用一套、且不可改。
    ///      要换费率就部署新工厂 —— 老账户完全不受影响，这是刻意的。
    constructor(address entryPoint_, address feeTo_, uint16 tradeFeeBps_, uint16 drawFeeBps_) {
        implementation = address(new AgentAccount(entryPoint_, feeTo_, tradeFeeBps_, drawFeeBps_));
        _chainId = block.chainid;
        _domainSeparator = _buildDomainSeparator();
    }

    // ─────────────────────── 地址预计算 ───────────────────────

    /// @notice skill 在本地就能算：不需要链上调用，也不需要知道 owner。
    function saltOf(address agentKey, address agentIdEoa, string calldata agentId) public pure returns (bytes32) {
        return keccak256(abi.encode(agentKey, agentIdEoa, keccak256(bytes(agentId))));
    }

    function addressOf(address agentKey, address agentIdEoa, string calldata agentId) public view returns (address) {
        return implementation.predict(saltOf(agentKey, agentIdEoa, agentId), address(this));
    }

    // ───────────────────────── 开户 ─────────────────────────

    /// @notice 一笔交易写完 owner / agentKey / agentIdEoa。
    /// @param claimSig AgentID 对 { account, agentId, deadline } 的 EIP-712 签名。
    ///                 agentIdEoa 传 0 表示这个用户没有 AgentID，此时不校验签名。
    /// @dev 已经部署过就直接返回那个地址（4337 的 initCode 可能被重放，不能 revert）。
    function createAccount(
        address owner,
        address agentKey,
        address agentIdEoa,
        string calldata agentId,
        uint256 deadline,
        bytes calldata claimSig
    ) external returns (address account) {
        if (owner == address(0) || agentKey == address(0)) revert ZeroAddress();

        bytes32 salt = saltOf(agentKey, agentIdEoa, agentId);
        account = implementation.predict(salt, address(this));
        if (account.code.length != 0) return account;

        if (agentIdEoa != address(0)) {
            if (block.timestamp > deadline) revert ClaimExpired();
            bytes32 digest = claimDigest(account, agentId, deadline);
            if (Sig.recoverRaw(digest, claimSig) != agentIdEoa) revert BadClaim();
        }

        account = implementation.cloneDeterministic(salt);
        AgentAccount(payable(account)).initialize(owner, agentKey, agentIdEoa, agentId);

        emit AccountCreated(account, owner, agentIdEoa, agentKey, agentId);
    }

    // ───────────────────────── EIP-712 ─────────────────────────

    function claimDigest(address account, string memory agentId, uint256 deadline) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(CLAIM_TYPEHASH, account, keccak256(bytes(agentId)), deadline));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    function domainSeparator() public view returns (bytes32) {
        return block.chainid == _chainId ? _domainSeparator : _buildDomainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256("fons-agentid-GPU"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }
}
