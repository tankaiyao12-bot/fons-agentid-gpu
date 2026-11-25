// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentAccount} from "../src/AgentAccount.sol";
import {AgentAccountFactory} from "../src/AgentAccountFactory.sol";

contract AgentAccountFactoryTest is Test {
    AgentAccountFactory f;

    address entryPoint = address(0xE7);
    address owner = address(0x99);
    address agentKey = address(0xA1);

    address agentIdEoa;
    uint256 agentIdPk;

    string constant HANDLE = "guatan";
    uint256 deadline;

    function setUp() public {
        vm.warp(1_700_000_000);
        deadline = block.timestamp + 1 hours;
        (agentIdEoa, agentIdPk) = makeAddrAndKey("agentId");
        f = new AgentAccountFactory(entryPoint, address(0), 0, 0);
    }

    function _claim(address account, string memory handle, uint256 dl, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, f.claimDigest(account, handle, dl));
        return abi.encodePacked(r, s, v);
    }

    // ──────────── 整条设计的地基：地址在部署前就能算出来 ────────────

    /// skill 只拿着 agentKey / agentIdEoa / handle，就能算出账户地址 —— 不需要 owner、不需要链上。
    function test_address_is_predictable_before_deploy() public {
        address predicted = f.addressOf(agentKey, agentIdEoa, HANDLE);
        assertEq(predicted.code.length, 0, unicode"此刻链上还没有这个账户");

        bytes memory sig = _claim(predicted, HANDLE, deadline, agentIdPk);
        address actual = f.createAccount(owner, agentKey, agentIdEoa, HANDLE, deadline, sig);

        assertEq(actual, predicted, unicode"预计算地址必须和真实部署地址一致");
        assertGt(actual.code.length, 0);
    }

    /// salt 不含 owner —— 否则 skill 在网页那一步之前根本算不出地址。
    function test_salt_does_not_depend_on_owner() public view {
        bytes32 s1 = f.saltOf(agentKey, agentIdEoa, HANDLE);
        bytes32 s2 = f.saltOf(agentKey, agentIdEoa, HANDLE);
        assertEq(s1, s2);
        // 参数里压根没有 owner，这条断言是结构性的：saltOf 的签名就不收 owner
    }

    function test_three_addresses_written_in_one_tx() public {
        address predicted = f.addressOf(agentKey, agentIdEoa, HANDLE);
        bytes memory sig = _claim(predicted, HANDLE, deadline, agentIdPk);
        AgentAccount acc = AgentAccount(payable(f.createAccount(owner, agentKey, agentIdEoa, HANDLE, deadline, sig)));

        assertEq(acc.owner(), owner);
        assertEq(acc.agentKey(), agentKey);
        assertEq(acc.agentIdEoa(), agentIdEoa);
        assertEq(acc.agentId(), HANDLE);
        assertEq(acc.epoch(), 0);
    }

    // ──────────────────── 认领签名的四个口子 ────────────────────

    function test_wrong_signer_rejected() public {
        (, uint256 strangerPk) = makeAddrAndKey("stranger");
        address predicted = f.addressOf(agentKey, agentIdEoa, HANDLE);
        bytes memory sig = _claim(predicted, HANDLE, deadline, strangerPk);

        vm.expectRevert(AgentAccountFactory.BadClaim.selector);
        f.createAccount(owner, agentKey, agentIdEoa, HANDLE, deadline, sig);
    }

    function test_expired_claim_rejected() public {
        address predicted = f.addressOf(agentKey, agentIdEoa, HANDLE);
        bytes memory sig = _claim(predicted, HANDLE, deadline, agentIdPk);

        vm.warp(deadline + 1);
        vm.expectRevert(AgentAccountFactory.ClaimExpired.selector);
        f.createAccount(owner, agentKey, agentIdEoa, HANDLE, deadline, sig);
    }

    /// 签的是 handle A，拿去开 handle B 的户 —— 签名对不上。
    function test_claim_is_bound_to_the_handle() public {
        address predicted = f.addressOf(agentKey, agentIdEoa, "alice");
        bytes memory sig = _claim(predicted, "alice", deadline, agentIdPk);

        vm.expectRevert(AgentAccountFactory.BadClaim.selector);
        f.createAccount(owner, agentKey, agentIdEoa, "bob", deadline, sig);
    }

    /// 换一把 agentKey 就换一个地址，旧签名签的是旧地址，重放不了。
    function test_claim_cannot_be_replayed_to_another_account() public {
        address a1 = f.addressOf(agentKey, agentIdEoa, HANDLE);
        bytes memory sig = _claim(a1, HANDLE, deadline, agentIdPk);

        address otherKey = address(0xA2);
        assertTrue(f.addressOf(otherKey, agentIdEoa, HANDLE) != a1);

        vm.expectRevert(AgentAccountFactory.BadClaim.selector);
        f.createAccount(owner, otherKey, agentIdEoa, HANDLE, deadline, sig);
    }

    /// 没有 AgentID 的用户也能开户，此时不校验签名。
    function test_no_agentId_means_no_claim_needed() public {
        AgentAccount acc =
            AgentAccount(payable(f.createAccount(owner, agentKey, address(0), "", 0, hex"")));
        assertEq(acc.agentIdEoa(), address(0));
        assertEq(acc.owner(), owner);
    }

    // ──────────────────────── 幂等 ────────────────────────

    /// 4337 的 initCode 可能被重放，第二次必须安静地返回同一个地址，不能 revert、也不能改写 owner。
    function test_second_create_is_idempotent() public {
        address predicted = f.addressOf(agentKey, agentIdEoa, HANDLE);
        bytes memory sig = _claim(predicted, HANDLE, deadline, agentIdPk);

        address a1 = f.createAccount(owner, agentKey, agentIdEoa, HANDLE, deadline, sig);
        address a2 = f.createAccount(address(0xBAD), agentKey, agentIdEoa, HANDLE, deadline, sig);

        assertEq(a1, a2);
        assertEq(AgentAccount(payable(a1)).owner(), owner, unicode"owner 不会被第二次调用改写");
    }

    // ───────────── 记录一个已知的残余风险，不是 bug ─────────────

    /// 接入码（agentKey 地址 + AgentID 地址 + 认领签名）如果泄漏，别人能抢先用自己的 owner 部署。
    /// 后果是**抢占地址 + 归属被污染**，不是丢钱 —— 那个账户里本来就没有钱。
    /// 受害者换一把 agentKey 就换一个地址，照样能开户，不会被永久锁死。
    /// 真正的缓解是 deadline：接入码有有效期，skill 应该开短一点。
    function test_known_residual_leaked_code_can_be_front_run() public {
        address predicted = f.addressOf(agentKey, agentIdEoa, HANDLE);
        bytes memory sig = _claim(predicted, HANDLE, deadline, agentIdPk);

        address attacker = address(0xBAD);
        vm.prank(attacker);
        address squatted = f.createAccount(attacker, agentKey, agentIdEoa, HANDLE, deadline, sig);

        assertEq(AgentAccount(payable(squatted)).owner(), attacker, unicode"这是已知行为，不是 bug");

        // 受害者的退路：换一把 agentKey，地址就变了，照样开得出户
        address freshKey = address(0xA9);
        address recovered = f.addressOf(freshKey, agentIdEoa, HANDLE);
        assertTrue(recovered != squatted);
        bytes memory sig2 = _claim(recovered, HANDLE, deadline, agentIdPk);
        assertEq(f.createAccount(owner, freshKey, agentIdEoa, HANDLE, deadline, sig2), recovered);
    }

    // ──────────────────── 克隆出来的账户是活的 ────────────────────

    function test_clone_shares_implementation_but_not_storage() public {
        address p1 = f.addressOf(agentKey, agentIdEoa, HANDLE);
        f.createAccount(owner, agentKey, agentIdEoa, HANDLE, deadline, _claim(p1, HANDLE, deadline, agentIdPk));

        address key2 = address(0xA2);
        address p2 = f.addressOf(key2, agentIdEoa, HANDLE);
        f.createAccount(address(0x98), key2, agentIdEoa, HANDLE, deadline, _claim(p2, HANDLE, deadline, agentIdPk));

        assertEq(AgentAccount(payable(p1)).owner(), owner);
        assertEq(AgentAccount(payable(p2)).owner(), address(0x98));
        assertEq(address(AgentAccount(payable(p1)).entryPoint()), entryPoint, unicode"immutable 透过代理照样读得到");
    }
}
