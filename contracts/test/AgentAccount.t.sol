// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentAccount} from "../src/AgentAccount.sol";
import {IERC20} from "../src/lib/Token.sol";
import {PackedUserOperation} from "../src/interfaces/IAccount.sol";
import {MockUSDT, MockMarket, MockDex} from "./Mocks.sol";

contract AgentAccountTest is Test {
    AgentAccount acc;
    MockUSDT usdt;
    MockMarket market;
    MockMarket other;

    address owner = address(0x99);
    address agentKey = address(0xA1);
    address agentIdEoa = address(0x81bf);
    address entryPoint = address(0xE7);

    uint48 tomorrow;

    function setUp() public {
        vm.warp(1_700_000_000);
        tomorrow = uint48(block.timestamp + 1 days);

        usdt = new MockUSDT();
        market = new MockMarket(address(usdt));
        other = new MockMarket(address(usdt));

        // 主测试套**不收费**（feeTo = 0）：85 条既有断言是围绕「账户少多少钱」写的，
        // 开着费会把每一条都搅乱。收费逻辑在 FeeTest 里单独测，
        // 顺带这一行也就是「feeTo = 0 等于整条费率关闭」那条路的回归锁。
        acc = new AgentAccount(entryPoint, address(0), 0, 0);
        acc.initialize(owner, agentKey, agentIdEoa, "guatan");

        usdt.mint(address(acc), 500e18);
        usdt.mint(address(market), 1_000e18); // 市场有钱可以退
    }

    // ───────────────────────── 工具 ─────────────────────────

    function _one(bytes32 salt, address mkt, uint128 amount) internal view returns (AgentAccount.NoteInput[] memory b) {
        b = new AgentAccount.NoteInput[](1);
        b[0] = AgentAccount.NoteInput({
            salt: salt, market: mkt, asset: address(usdt), amount: amount, expiry: tomorrow,
            // 测试里的默认是 false（旧行为）。出口检查有自己的一组测试。
            requireReturn: false, dataHash: bytes32(0)
        });
    }

    function _issue(bytes32 salt, address mkt, uint128 amount) internal returns (bytes32 id) {
        id = acc.noteIdOf(salt, mkt, address(usdt), amount, tomorrow, false, bytes32(0));
        vm.prank(owner);
        acc.issueBatch(_one(salt, mkt, amount), new bytes32[](0));
    }

    function _netOut(bytes32 id) internal view returns (uint128 n) {
        (,,, n,,,,,) = acc.notes(id);
    }

    function _closed(bytes32 id) internal view returns (bool c) {
        (,,,,,, c,,) = acc.notes(id);
    }

    // ──────────────────── 不变式 I1：available ────────────────────

    function test_available_equals_balance_minus_reserved() public {
        assertEq(acc.available(address(usdt)), 500e18);
        _issue("a", address(market), 400e18);
        assertEq(acc.available(address(usdt)), 100e18);
        assertEq(acc.reserved(0, address(usdt)), 400e18);
    }

    function test_issue_over_budget_reverts_whole_batch() public {
        AgentAccount.NoteInput[] memory b = new AgentAccount.NoteInput[](2);
        b[0] = AgentAccount.NoteInput("a", address(market), address(usdt), 400e18, tomorrow, false, bytes32(0));
        b[1] = AgentAccount.NoteInput("b", address(market), address(usdt), 200e18, tomorrow, false, bytes32(0));

        vm.prank(owner);
        vm.expectRevert(AgentAccount.OverBudget.selector);
        acc.issueBatch(b, new bytes32[](0));

        // 一张都没开出来
        assertEq(acc.reserved(0, address(usdt)), 0);
        assertEq(acc.available(address(usdt)), 500e18);
    }

    function test_only_owner_can_issue() public {
        vm.prank(agentKey);
        vm.expectRevert(AgentAccount.NotOwner.selector);
        acc.issueBatch(_one("a", address(market), 1e18), new bytes32[](0));
    }

    function test_duplicate_noteId_reverts() public {
        _issue("a", address(market), 100e18);
        vm.prank(owner);
        vm.expectRevert(AgentAccount.NoteExists.selector);
        acc.issueBatch(_one("a", address(market), 100e18), new bytes32[](0));
    }

    // ──────────────────── 花票：netOut 与找零 ────────────────────

    function test_spend_reduces_reserved_by_actual_spend() public {
        bytes32 id = _issue("a", address(market), 200e18);

        vm.prank(agentKey);
        acc.spend(id, address(0), 0, abi.encodeCall(MockMarket.take, (137e18)));

        assertEq(_netOut(id), 137e18);
        // reserved 承载的是这张票还没花掉的部分
        assertEq(acc.reserved(0, address(usdt)), 200e18 - 137e18);
        // 找零 63 自动回到可用池：余额 363，reserved 63
        assertEq(usdt.balanceOf(address(acc)), 363e18);
        assertEq(acc.available(address(usdt)), 300e18);
    }

    /// 第一道防线是 approve 上限：市场根本拉不到超过票面的钱。
    /// 合约里的 OverNote 是第二道（纵深防御），正常路径打不到它。
    function test_spend_cannot_exceed_note_amount() public {
        bytes32 id = _issue("a", address(market), 100e18);
        vm.prank(agentKey);
        vm.expectRevert(); // CallFailed(BEP20: transfer amount exceeds allowance)
        acc.spend(id, address(0), 0, abi.encodeCall(MockMarket.take, (101e18)));

        assertEq(_netOut(id), 0);
        assertEq(acc.reserved(0, address(usdt)), 100e18);
        assertEq(usdt.balanceOf(address(acc)), 500e18, unicode"一分钱都没出去");
    }

    /// 票面上写死了收款方：spend 只收 noteId + calldata，目标地址没有参数可以改。
    function test_spend_target_is_taken_from_the_note_not_the_caller() public {
        bytes32 id = _issue("a", address(market), 100e18);

        vm.prank(agentKey);
        acc.spend(id, address(0), 0, abi.encodeCall(MockMarket.take, (100e18)));

        assertEq(usdt.balanceOf(address(market)), 1_100e18, unicode"钱只能进票面写的那个市场");
        assertEq(usdt.balanceOf(address(other)), 0, unicode"别的市场一分拿不到");
        assertEq(usdt.allowance(address(acc), address(other)), 0, unicode"也从没给过它额度");
    }

    /// 没拿到 approve 的地址，自己上门也拉不走钱。
    function test_unapproved_market_cannot_pull() public {
        _issue("a", address(market), 100e18);
        vm.expectRevert(bytes("BEP20: transfer amount exceeds allowance"));
        other.take(1e18);
    }

    function test_approve_is_reset_to_zero_after_spend() public {
        bytes32 id = _issue("a", address(market), 200e18);
        vm.prank(agentKey);
        acc.spend(id, address(0), 0, abi.encodeCall(MockMarket.take, (10e18)));
        assertEq(usdt.allowance(address(acc), address(market)), 0, unicode"approve 必须归零");
    }

    function test_failed_market_call_reverts_everything() public {
        bytes32 id = _issue("a", address(market), 100e18);
        uint256 before = acc.reserved(0, address(usdt));
        vm.prank(agentKey);
        vm.expectRevert();
        acc.spend(id, address(0), 0, abi.encodeCall(MockMarket.boom, ()));
        assertEq(acc.reserved(0, address(usdt)), before);
        assertEq(_netOut(id), 0);
    }

    function test_only_agentKey_can_spend() public {
        bytes32 id = _issue("a", address(market), 100e18);
        vm.prank(owner);
        vm.expectRevert(AgentAccount.NotAgentKey.selector);
        acc.spend(id, address(0), 0, abi.encodeCall(MockMarket.take, (1e18)));
    }

    // ─────── 承重回归锁：netOut 必须原地 clamp，不能用累计流水反推 ───────

    /// 来回倒腾一百次，净流出上限始终是票面，挖不出额外额度。
    function test_roundTrip_cannot_mine_extra_budget() public {
        bytes32 id = _issue("a", address(market), 100e18);

        for (uint256 i; i < 100; ++i) {
            vm.prank(agentKey);
            acc.spend(id, address(0), 0, abi.encodeCall(MockMarket.roundTrip, (100e18, 100e18)));
        }

        // 一百轮进出，净流出 0，票面原封不动
        assertEq(_netOut(id), 0, unicode"净流出应回到 0");
        assertEq(acc.reserved(0, address(usdt)), 100e18, unicode"额度不该被挖走");
        assertEq(usdt.balanceOf(address(acc)), 500e18, unicode"钱一分没少");
    }

    /// 赚了的钱进可用池，不会让票面长大。
    function test_profit_goes_to_available_not_to_the_note() public {
        bytes32 id = _issue("a", address(market), 100e18);

        vm.prank(agentKey);
        acc.spend(id, address(0), 0, abi.encodeCall(MockMarket.take, (100e18)));
        assertEq(_netOut(id), 100e18);

        // 卖回来 150：净流出被 clamp 到 0，多出来的 50 进可用池
        vm.prank(agentKey);
        acc.spend(id, address(0), 0, abi.encodeCall(MockMarket.give, (150e18)));

        assertEq(_netOut(id), 0, unicode"netOut 最多降到 0");
        assertEq(acc.reserved(0, address(usdt)), 100e18, unicode"票面不会因为赚钱而长大");
        assertEq(usdt.balanceOf(address(acc)), 550e18);
        assertEq(acc.available(address(usdt)), 450e18, unicode"多出来的 50 全进可用池");
    }

    /// 亏的钱从票的额度里扣。
    function test_loss_comes_out_of_the_note() public {
        bytes32 id = _issue("a", address(market), 100e18);

        vm.prank(agentKey);
        acc.spend(id, address(0), 0, abi.encodeCall(MockMarket.roundTrip, (100e18, 80e18))); // 亏 20

        assertEq(_netOut(id), 20e18);
        assertEq(acc.reserved(0, address(usdt)), 80e18);
        assertEq(usdt.balanceOf(address(acc)), 480e18);
    }

    // ──────────────────── 退票 / 过期 / 恐慌按钮 ────────────────────

    function test_cancel_releases_unspent_part() public {
        bytes32 id = _issue("a", address(market), 200e18);
        vm.prank(agentKey);
        acc.spend(id, address(0), 0, abi.encodeCall(MockMarket.take, (50e18)));

        vm.prank(owner);
        acc.cancel(id);

        assertTrue(_closed(id));
        assertEq(acc.reserved(0, address(usdt)), 0);
        assertEq(acc.available(address(usdt)), 450e18);
    }

    function test_cancel_twice_reverts() public {
        bytes32 id = _issue("a", address(market), 100e18);
        vm.startPrank(owner);
        acc.cancel(id);
        vm.expectRevert(AgentAccount.NoteClosedAlready.selector);
        acc.cancel(id);
        vm.stopPrank();
    }

    function test_reclaim_only_after_expiry() public {
        bytes32 id = _issue("a", address(market), 100e18);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;

        vm.prank(agentKey);
        vm.expectRevert(AgentAccount.NoteNotExpired.selector);
        acc.reclaim(ids);

        vm.warp(uint256(tomorrow) + 1);
        vm.prank(agentKey);
        acc.reclaim(ids);
        assertEq(acc.reserved(0, address(usdt)), 0);
    }

    function test_expired_note_cannot_be_spent() public {
        bytes32 id = _issue("a", address(market), 100e18);
        vm.warp(uint256(tomorrow) + 1);
        vm.prank(agentKey);
        vm.expectRevert(AgentAccount.NoteExpired.selector);
        acc.spend(id, address(0), 0, abi.encodeCall(MockMarket.take, (1e18)));
    }

    function test_bumpEpoch_voids_everything_in_one_call() public {
        _issue("a", address(market), 100e18);
        _issue("b", address(market), 100e18);
        _issue("c", address(market), 100e18);
        assertEq(acc.available(address(usdt)), 200e18);

        vm.prank(owner);
        acc.bumpEpoch();

        assertEq(acc.epoch(), 1);
        assertEq(acc.reserved(1, address(usdt)), 0, unicode"新桶天生为 0");
        assertEq(acc.available(address(usdt)), 500e18, unicode"全部额度当场回来");
    }

    function test_old_epoch_note_cannot_be_spent_or_cancelled() public {
        bytes32 id = _issue("a", address(market), 100e18);
        vm.prank(owner);
        acc.bumpEpoch();

        vm.prank(agentKey);
        vm.expectRevert(AgentAccount.WrongEpoch.selector);
        acc.spend(id, address(0), 0, abi.encodeCall(MockMarket.take, (1e18)));

        // 旧 epoch 的票不许 cancel，否则 reserved -= 会打到新桶上直接下溢
        vm.prank(owner);
        vm.expectRevert(AgentAccount.WrongEpoch.selector);
        acc.cancel(id);
    }

    function test_issueBatch_reclaims_first_then_issues() public {
        bytes32 old = _issue("a", address(market), 400e18);
        vm.warp(uint256(tomorrow) + 1);
        uint48 later = uint48(block.timestamp + 1 days);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = old;
        AgentAccount.NoteInput[] memory b = new AgentAccount.NoteInput[](1);
        b[0] = AgentAccount.NoteInput("b", address(market), address(usdt), 450e18, later, false, bytes32(0));

        // 不先回收就开不出 450；先回收就能，一笔交易完成
        vm.prank(owner);
        acc.issueBatch(b, ids);

        assertEq(acc.reserved(0, address(usdt)), 450e18);
        assertTrue(_closed(old));
    }

    // ──────────────────────── 回扫 ────────────────────────

    function test_sweep_pulls_from_agentId_eoa() public {
        usdt.mint(agentIdEoa, 56e18);
        vm.prank(agentIdEoa);
        usdt.approve(address(acc), type(uint256).max);

        vm.prank(agentKey);
        uint256 got = acc.sweep(address(usdt), agentIdEoa);

        assertEq(got, 56e18);
        assertEq(usdt.balanceOf(agentIdEoa), 0);
        assertEq(usdt.balanceOf(address(acc)), 556e18);
    }

    function test_sweep_capped_by_allowance() public {
        usdt.mint(agentIdEoa, 100e18);
        vm.prank(agentIdEoa);
        usdt.approve(address(acc), 40e18);

        vm.prank(agentKey);
        assertEq(acc.sweep(address(usdt), agentIdEoa), 40e18);
        assertEq(usdt.balanceOf(agentIdEoa), 60e18);
    }

    function test_sweep_needs_operator() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(AgentAccount.NotOperator.selector);
        acc.sweep(address(usdt), agentIdEoa);
    }

    // ─────────────────── 身份锚与 owner 权限 ───────────────────

    function test_agentId_is_read_only_and_grants_nothing() public {
        assertEq(acc.agentIdEoa(), agentIdEoa);
        assertEq(acc.agentId(), "guatan");

        // 身份地址既不能开票也不能花票
        vm.startPrank(agentIdEoa);
        vm.expectRevert(AgentAccount.NotOwner.selector);
        acc.issueBatch(_one("x", address(market), 1e18), new bytes32[](0));
        vm.expectRevert(AgentAccount.NotOwner.selector);
        acc.bumpEpoch();
        vm.stopPrank();
    }

    function test_cannot_initialize_twice() public {
        vm.expectRevert(AgentAccount.AlreadyInitialized.selector);
        acc.initialize(address(0xBAD), address(0xBAD), address(0), "");
    }

    function test_withdraw_cannot_touch_reserved() public {
        _issue("a", address(market), 400e18);

        vm.startPrank(owner);
        vm.expectRevert(AgentAccount.OverBudget.selector);
        acc.withdraw(address(usdt), owner, 101e18);

        acc.withdraw(address(usdt), owner, 100e18);
        vm.stopPrank();

        assertEq(usdt.balanceOf(owner), 100e18);
        assertEq(acc.available(address(usdt)), 0);
    }

    function test_rotate_agentKey() public {
        bytes32 id = _issue("a", address(market), 100e18);
        vm.prank(owner);
        acc.rotateAgentKey(address(0xA2));

        vm.prank(agentKey);
        vm.expectRevert(AgentAccount.NotAgentKey.selector);
        acc.spend(id, address(0), 0, abi.encodeCall(MockMarket.take, (1e18)));

        vm.prank(address(0xA2));
        acc.spend(id, address(0), 0, abi.encodeCall(MockMarket.take, (1e18)));
    }

    // ──────────────────── ERC-4337 入口 ────────────────────

    function test_validateUserOp_only_from_entryPoint() public {
        vm.expectRevert(AgentAccount.NotEntryPoint.selector);
        acc.validateUserOp(_op(hex""), bytes32(0), 0);
    }

    function test_validateUserOp_accepts_agentKey_signature() public {
        (address signer, uint256 pk) = makeAddrAndKey("agent");
        vm.prank(owner);
        acc.rotateAgentKey(signer);

        bytes32 h = keccak256("userOpHash");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, MessageHashUtils_toEthSigned(h));

        vm.prank(entryPoint);
        uint256 vd = acc.validateUserOp(_op(abi.encodePacked(r, s, v)), h, 0);
        assertEq(vd, 0, unicode"agentKey 的签名应该通过");
    }

    function test_validateUserOp_rejects_other_signature() public {
        (, uint256 pk) = makeAddrAndKey("stranger");
        bytes32 h = keccak256("userOpHash");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, MessageHashUtils_toEthSigned(h));

        vm.prank(entryPoint);
        uint256 vd = acc.validateUserOp(_op(abi.encodePacked(r, s, v)), h, 0);
        assertEq(vd, 1, unicode"别人的签名必须被拒");
    }

    // ──────────── cancelBatch：界面上「撤掉一行」是一笔交易 ────────────

    function test_cancelBatch_closes_all_and_restores_available() public {
        bytes32 a = _issue("a", address(market), 100e18);
        bytes32 b = _issue("b", address(market), 150e18);
        bytes32 c = _issue("c", address(other), 50e18);
        assertEq(acc.available(address(usdt)), 200e18);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = a;
        ids[1] = b;
        vm.prank(owner);
        acc.cancelBatch(ids);

        assertTrue(_closed(a));
        assertTrue(_closed(b));
        assertFalse(_closed(c), unicode"没点名的票不动");
        assertEq(acc.available(address(usdt)), 450e18);
    }

    /// 已经花掉的那部分不退回 —— 只退没花的。
    function test_cancelBatch_only_gives_back_the_unspent_part() public {
        bytes32 id = _issue("a", address(market), 400e18);
        vm.prank(agentKey);
        acc.spend(id, address(0), 0, abi.encodeCall(MockMarket.take, (100e18)));

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        vm.prank(owner);
        acc.cancelBatch(ids);
        assertEq(acc.reserved(0, address(usdt)), 0);
        assertEq(acc.available(address(usdt)), 400e18, unicode"余额 400（花出去 100），全部可用");
    }

    /// 一张坏的整批都不许过 —— 不能一半成功一半失败。
    function test_cancelBatch_is_all_or_nothing() public {
        bytes32 a = _issue("a", address(market), 100e18);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = a;
        ids[1] = bytes32(uint256(0xdead));
        vm.prank(owner);
        vm.expectRevert(AgentAccount.NoteUnknown.selector);
        acc.cancelBatch(ids);
        assertFalse(_closed(a), unicode"整批回滚");
    }

    function test_cancelBatch_only_owner() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = _issue("a", address(market), 100e18);
        vm.prank(agentKey);
        vm.expectRevert(AgentAccount.NotOwner.selector);
        acc.cancelBatch(ids);
    }

    // ──────── onlyOperator：EntryPoint 也得算，否则回扫走不了车道 ────────

    /// 回归锁：2026-11-22 主网实测撞到的。sweep 是 onlyOperator（agentKey 或 owner），
    /// 而 EntryPoint 两个都不是 —— 回扫的 UserOp 落地了但 op revert，错误码 NotOperator。
    /// 加上 EntryPoint 不是放宽权限：它只会执行 validateUserOp 放行过的 op，
    /// 而那里只认 agentKey 的签名。
    function test_sweep_through_entryPoint() public {
        usdt.mint(agentIdEoa, 100e18);
        vm.prank(agentIdEoa);
        usdt.approve(address(acc), type(uint256).max);

        vm.prank(entryPoint);
        uint256 got = acc.sweep(address(usdt), agentIdEoa);

        assertEq(got, 100e18, unicode"EntryPoint 调回扫必须拉得动");
        assertEq(usdt.balanceOf(address(acc)), 600e18);
    }

    /// reclaim 同病同治：过期票的额度回收也该能走车道。
    function test_reclaim_through_entryPoint() public {
        bytes32 id = _issue("a", address(market), 400e18);
        vm.warp(tomorrow + 1);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        vm.prank(entryPoint);
        acc.reclaim(ids);

        assertTrue(_closed(id));
        assertEq(acc.reserved(0, address(usdt)), 0);
    }

    /// 但别人还是不行 —— 这条只放 EntryPoint 进来，不是对所有人开门。
    function test_operator_still_rejects_strangers() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(AgentAccount.NotOperator.selector);
        acc.sweep(address(usdt), agentIdEoa);
    }

    // ──────────── payout：④ ⑤ 唯一能把钱送出去的那条路 ────────────

    /// 回归锁：⑤ 的 market 是 AgentID 的 EOA。spend 走不通 —— 调一个 EOA 什么都不发生，
    /// approve 又在同一笔里归零，钱到不了。payout 是补上的那条「推」。
    function test_payout_is_the_only_way_to_reach_an_eoa_market() public {
        bytes32 id = _issue("a", agentIdEoa, 400e18);

        // 先证明 spend 在这里是无效的：调用成功，但一分钱都没动
        vm.prank(agentKey);
        acc.spend(id, address(0), 0, hex"");
        assertEq(usdt.balanceOf(agentIdEoa), 0, unicode"调 EOA 什么都不会发生");
        assertEq(_netOut(id), 0);
        assertEq(usdt.allowance(address(acc), agentIdEoa), 0, unicode"approve 已经归零，EOA 也拉不走");

        // payout 才送得到
        vm.prank(agentKey);
        acc.payout(id, 100e18);
        assertEq(usdt.balanceOf(agentIdEoa), 100e18);
        assertEq(_netOut(id), 100e18);
        assertEq(acc.reserved(0, address(usdt)), 300e18);
    }

    /// 目标地址不是参数 —— 从票里取。调度器被打穿也只能打到这张票自己的对手方。
    function test_payout_target_is_taken_from_the_note() public {
        bytes32 id = _issue("a", agentIdEoa, 400e18);
        vm.prank(agentKey);
        acc.payout(id, 50e18);
        assertEq(usdt.balanceOf(agentIdEoa), 50e18);
        assertEq(usdt.balanceOf(address(market)), 1_000e18, unicode"别的地址一分钱都收不到");
    }

    function test_payout_cannot_exceed_the_note() public {
        bytes32 id = _issue("a", agentIdEoa, 400e18);
        vm.prank(agentKey);
        vm.expectRevert(AgentAccount.OverNote.selector);
        acc.payout(id, 400e18 + 1);

        vm.prank(agentKey);
        acc.payout(id, 300e18);
        vm.prank(agentKey);
        vm.expectRevert(AgentAccount.OverNote.selector);
        acc.payout(id, 101e18);  // 300 + 101 > 400
    }

    function test_payout_and_spend_share_the_same_note_rules() public {
        bytes32 id = _issue("a", agentIdEoa, 400e18);
        vm.prank(owner);
        acc.cancel(id);

        vm.prank(agentKey);
        vm.expectRevert(AgentAccount.NoteClosedAlready.selector);
        acc.payout(id, 1e18);
    }

    function test_payout_only_agentKey() public {
        bytes32 id = _issue("a", agentIdEoa, 400e18);
        vm.prank(owner);
        vm.expectRevert(AgentAccount.NotAgentKey.selector);
        acc.payout(id, 1e18);
    }

    function test_payout_zero_rejected() public {
        bytes32 id = _issue("a", agentIdEoa, 400e18);
        vm.prank(agentKey);
        vm.expectRevert(AgentAccount.BadAmount.selector);
        acc.payout(id, 0);
    }

    /// 调度器发的 UserOp 走 executePayout，必须和直调同样有效。
    function test_executePayout_from_entryPoint() public {
        bytes32 id = _issue("a", agentIdEoa, 400e18);
        vm.prank(entryPoint);
        acc.executePayout(id, 100e18);
        assertEq(usdt.balanceOf(agentIdEoa), 100e18);
        assertEq(_netOut(id), 100e18);
    }

    function test_executePayout_rejects_everyone_else() public {
        bytes32 id = _issue("a", agentIdEoa, 400e18);
        vm.prank(owner);
        vm.expectRevert(AgentAccount.NotAgentKey.selector);
        acc.executePayout(id, 1e18);
    }

    /// 回扫是「拉」：payout 出去、AgentID 授权、sweep 拉回来，一轮 ⑤ 的闭环。
    function test_identity_round_payout_then_sweep_back() public {
        bytes32 id = _issue("a", agentIdEoa, 400e18);

        vm.prank(agentKey);
        acc.payout(id, 400e18);
        assertEq(acc.available(address(usdt)), 100e18);
        assertEq(acc.reserved(0, address(usdt)), 0, unicode"票花光了，承诺也就清了");
        assertEq(acc.parked(id), 400e18, unicode"钱停在 AgentID 上，记这张票头上");

        vm.prank(agentIdEoa);
        usdt.approve(address(acc), type(uint256).max);

        // 这一轮还没说完事，所以回扫**一分都不拉** —— 那 400 它还要用。
        vm.prank(agentKey);
        assertEq(acc.sweep(address(usdt), agentIdEoa), 0, unicode"没 release 就不该拉走它还要用的钱");

        vm.prank(agentKey);
        assertEq(acc.release(id), 400e18);
        assertEq(acc.parked(id), 0);

        vm.prank(agentKey);
        uint256 got = acc.sweep(address(usdt), agentIdEoa);
        assertEq(got, 400e18, unicode"说完事了，这里没真去 mint，所以 400 原样回来");
        assertEq(usdt.balanceOf(address(acc)), 500e18);
        assertEq(acc.available(address(usdt)), 500e18, unicode"钱回来就重新可用");
    }

    /// 回归锁 · 2026-11-25 真实撞到过：
    /// 旧版靠用户脚本里「同时只放一轮」的闸，结果**同一轮补仓**被自己挡住了 ——
    /// r9 推了 2.97 占着闸，价格涨了要补的 r10 发不出去，只能手工 settle --sweep false 绕。
    /// 改成按票记账之后，两轮各记各的，谁也不挡谁。
    function test_two_identity_rounds_run_in_parallel() public {
        bytes32 r9 = _issue("r9", agentIdEoa, 300e18);
        bytes32 r10 = _issue("r10", agentIdEoa, 200e18);

        vm.prank(agentKey);
        acc.payout(r9, 300e18);

        // 关键：第二轮**不需要等第一轮结束**。
        vm.prank(agentKey);
        acc.payout(r10, 200e18);

        assertEq(acc.parked(r9), 300e18);
        assertEq(acc.parked(r10), 200e18);
        assertEq(acc.parkedAsset(address(usdt)), 500e18, unicode"两轮各记各的，汇总 500");

        vm.prank(agentIdEoa);
        usdt.approve(address(acc), type(uint256).max);

        vm.prank(agentKey);
        assertEq(acc.sweep(address(usdt), agentIdEoa), 0, unicode"两轮的钱都还要用，一分不拉");

        // r9 花完了说一声，只解它那一份。
        vm.prank(agentKey);
        acc.release(r9);
        assertEq(acc.parkedAsset(address(usdt)), 200e18, unicode"只解 r9，r10 的 200 还留着");

        vm.prank(agentKey);
        assertEq(acc.sweep(address(usdt), agentIdEoa), 300e18, unicode"拉回 r9 那份，r10 的留在原地");
        assertEq(usdt.balanceOf(agentIdEoa), 200e18);
    }

    /// ② Aster 的提现落在同一个 AgentID 钱包上，但它的票 market 是入金口、不是 AgentID，
    /// 所以不进 parked —— 它那笔钱该拉多少拉多少，不该被 ⑤ 占着的部分挡住。
    /// 这就是回扫撞车那个洞：旧版 sweep 不分青红皂白「有多少拉多少」。
    function test_sweep_pulls_unparked_money_but_keeps_parked() public {
        bytes32 id = _issue("a", agentIdEoa, 300e18);

        vm.prank(agentKey);
        acc.payout(id, 300e18);

        // Aster 把 170 提现回 AgentID —— 和 parked 无关的钱。
        usdt.mint(agentIdEoa, 170e18);

        vm.prank(agentIdEoa);
        usdt.approve(address(acc), type(uint256).max);

        vm.prank(agentKey);
        assertEq(acc.sweep(address(usdt), agentIdEoa), 170e18, unicode"Aster 的 170 拉得走");
        assertEq(usdt.balanceOf(agentIdEoa), 300e18, unicode"⑤ 还要用的 300 原地不动");
    }

    /// `min(账面, 余额)` 里的 min 不是保险，是必须的：
    /// mint 会把钱真的花掉，那时候余额比账面少，按账面硬扣会下溢。
    function test_parked_capped_by_actual_balance_after_spending() public {
        bytes32 id = _issue("a", agentIdEoa, 300e18);

        vm.prank(agentKey);
        acc.payout(id, 300e18);

        // AgentID 真去 mint 了，花掉 280，只剩 20。
        vm.prank(agentIdEoa);
        usdt.transfer(address(0xdead), 280e18);

        vm.prank(agentIdEoa);
        usdt.approve(address(acc), type(uint256).max);

        vm.prank(agentKey);
        assertEq(acc.sweepable(address(usdt), agentIdEoa), 0, unicode"账面 300 > 余额 20，留全部、不下溢");

        vm.prank(agentKey);
        acc.release(id);

        vm.prank(agentKey);
        assertEq(acc.sweep(address(usdt), agentIdEoa), 20e18, unicode"解了之后把剩的 20 拉回来");
    }

    /// ①② 的票 market 填的是市场合约，钱根本不经过 AgentID —— 不该记 parked。
    function test_direct_market_note_never_parks() public {
        bytes32 id = _issue("a", address(market), 300e18);

        vm.prank(agentKey);
        acc.payout(id, 300e18);

        assertEq(acc.parked(id), 0, unicode"钱去的是市场合约，不停在 AgentID 上");
        assertEq(acc.parkedAsset(address(usdt)), 0);
    }

    /// agent 失联时主人得能自己解 —— onlyOperator 含 owner。
    function test_owner_can_release_when_agent_is_gone() public {
        bytes32 id = _issue("a", agentIdEoa, 300e18);

        vm.prank(agentKey);
        acc.payout(id, 300e18);

        vm.prank(owner);
        assertEq(acc.release(id), 300e18, unicode"主人自己能解，不至于永远卡住");
        assertEq(acc.parkedAsset(address(usdt)), 0);
    }

    /// 回扫那一笔要一次做完「解账 + 拉回」—— 拆两笔要两条车道、两次 gas。
    function test_releaseAndSweep_does_both_in_one_call() public {
        bytes32 id = _issue("a", agentIdEoa, 300e18);

        vm.prank(agentKey);
        acc.payout(id, 300e18);

        vm.prank(agentIdEoa);
        usdt.approve(address(acc), type(uint256).max);

        vm.prank(agentKey);
        uint256 got = acc.releaseAndSweep(id, address(usdt), agentIdEoa);
        assertEq(got, 300e18, unicode"一笔就把自己推出去的钱拉回来了");
        assertEq(acc.parked(id), 0);
        assertEq(acc.parkedAsset(address(usdt)), 0);
        assertEq(usdt.balanceOf(agentIdEoa), 0);
    }

    /// 只解自己那份 —— 别的轮次占着的照样留在原地。
    function test_releaseAndSweep_leaves_other_rounds_alone() public {
        bytes32 r9 = _issue("r9", agentIdEoa, 300e18);
        bytes32 r10 = _issue("r10", agentIdEoa, 200e18);

        vm.startPrank(agentKey);
        acc.payout(r9, 300e18);
        acc.payout(r10, 200e18);
        vm.stopPrank();

        vm.prank(agentIdEoa);
        usdt.approve(address(acc), type(uint256).max);

        vm.prank(agentKey);
        assertEq(acc.releaseAndSweep(r9, address(usdt), agentIdEoa), 300e18);
        assertEq(usdt.balanceOf(agentIdEoa), 200e18, unicode"r10 的 200 一分没动");
        assertEq(acc.parked(r10), 200e18);
    }

    function test_release_is_not_public() public {
        bytes32 id = _issue("a", agentIdEoa, 300e18);
        vm.prank(agentKey);
        acc.payout(id, 300e18);

        vm.prank(address(0xbad));
        vm.expectRevert(AgentAccount.NotOperator.selector);
        acc.release(id);
    }

    // ──────── execute：调度器发的每一笔 UserOp 都走这里，是整条车道的落点 ────────

    /// 回归锁：execute 曾经写成 this.spend(...)，那是一次外部调用，
    /// msg.sender 会变成本合约自己，过不了 onlyAgentKey —— 整个 4337 通道是死的。
    function test_execute_from_entryPoint_actually_spends() public {
        bytes32 id = _issue("a", address(market), 400e18);

        vm.prank(entryPoint);
        acc.execute(id, address(0), 0, abi.encodeCall(MockMarket.take, (100e18)));

        assertEq(_netOut(id), 100e18, unicode"EntryPoint 调 execute 必须真的花出去");
        assertEq(acc.reserved(0, address(usdt)), 300e18);
    }

    /// 不走 bundler 的直发路径（gas 自己付）也要能用同一把钥匙。
    function test_execute_from_agentKey_actually_spends() public {
        bytes32 id = _issue("a", address(market), 400e18);

        vm.prank(agentKey);
        acc.execute(id, address(0), 0, abi.encodeCall(MockMarket.take, (100e18)));

        assertEq(_netOut(id), 100e18);
    }

    function test_execute_rejects_everyone_else() public {
        bytes32 id = _issue("a", address(market), 400e18);

        vm.prank(owner); // owner 也不行：花票只归 agentKey
        vm.expectRevert(AgentAccount.NotAgentKey.selector);
        acc.execute(id, address(0), 0, abi.encodeCall(MockMarket.take, (1e18)));
    }

    /// execute 和 spend 必须是同一套票据校验，不能绕过。
    function test_execute_is_subject_to_the_same_note_rules() public {
        bytes32 id = _issue("a", address(market), 400e18);

        vm.prank(owner);
        acc.cancel(id);

        vm.prank(entryPoint);
        vm.expectRevert(AgentAccount.NoteClosedAlready.selector);
        acc.execute(id, address(0), 0, abi.encodeCall(MockMarket.take, (1e18)));
    }

    function MessageHashUtils_toEthSigned(bytes32 h) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", h));
    }

    function _op(bytes memory sig) internal view returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: address(acc),
            nonce: 0,
            initCode: hex"",
            callData: hex"",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: hex"",
            signature: sig
        });
    }
    // ═══════════════ sellInto：一张票自由买卖（2026-11-24 加）═══════════════
    //
    // owner 定的方向：「给 agent 额度，让它自由买卖，不要过多约束它的策略」。
    // 原来 approve 只能给票上那一个币，所以每买一种币、想卖回去就得再开一张那个币的票。
    //
    // 打开之后**还守住**的只有三条，这些测试就是钉这三条的：
    //   · market 仍然是票上钉死的那个
    //   · 卖出之后票的计价资产余额**必须增加** → 持仓只能换成计价资产，不能被送走
    //   · 过期 / epoch / closed 三道闸照走

    function _dexNote(bytes32 salt, address dex, uint128 amount) internal returns (bytes32) {
        return _issue(salt, dex, amount);
    }

    /// 正常卖出：CAKE 换回 USDT，换回来的钱冲减 netOut。
    function test_sellInto_credits_the_note() public {
        MockDex dex = new MockDex();
        MockUSDT cake = new MockUSDT();
        cake.mint(address(acc), 100e18);
        usdt.mint(address(dex), 1_000e18);

        bytes32 id = _dexNote("s", address(dex), 200e18);

        // 先花掉 150：netOut = 150
        vm.prank(agentKey);
        acc.spend(id, address(0), 0, abi.encodeCall(MockDex.buy, (address(usdt), 150e18)));
        assertEq(_netOut(id), 150e18);
        assertEq(acc.available(address(usdt)), 300e18);

        // 卖 40 个 CAKE 换回 60 USDT
        vm.prank(agentKey);
        uint256 back = acc.sellInto(
            id, address(cake), 40e18, abi.encodeCall(MockDex.sell, (address(cake), 40e18, address(usdt), 60e18))
        );

        assertEq(back, 60e18);
        assertEq(_netOut(id), 90e18, unicode"换回来的钱要从 netOut 扣回去");
        assertEq(cake.balanceOf(address(acc)), 60e18, unicode"卖掉了 40");
        // ❗ available 一动不动 —— 卖回来的钱**不是白捡的钱**，它只是把票的额度还回去。
        // 余额 +60、reserved 也 +60，两边抵消。这条分不清就会以为卖一次就多出一笔可用。
        assertEq(acc.available(address(usdt)), 300e18, unicode"卖回来只还额度，不增加可用");
    }

    /// ❗ 承重：市场拉走币却什么都不给 —— 必须 revert，否则持仓能从这个口子被送走。
    function test_sellInto_reverts_when_nothing_comes_back() public {
        MockDex dex = new MockDex();
        MockUSDT cake = new MockUSDT();
        cake.mint(address(acc), 100e18);

        bytes32 id = _dexNote("s", address(dex), 200e18);

        vm.prank(agentKey);
        vm.expectRevert(AgentAccount.NothingCameBack.selector);
        acc.sellInto(id, address(cake), 40e18, abi.encodeCall(MockDex.steal, (address(cake), 40e18)));

        assertEq(cake.balanceOf(address(acc)), 100e18, unicode"revert 之后币一个都没少");
    }

    /// ❗ 承重：钱送给第三方而不是账户 —— 同样挡住。
    function test_sellInto_reverts_when_proceeds_go_elsewhere() public {
        MockDex dex = new MockDex();
        MockUSDT cake = new MockUSDT();
        cake.mint(address(acc), 100e18);
        usdt.mint(address(dex), 1_000e18);

        bytes32 id = _dexNote("s", address(dex), 200e18);

        vm.prank(agentKey);
        vm.expectRevert(AgentAccount.NothingCameBack.selector);
        acc.sellInto(
            id,
            address(cake),
            40e18,
            abi.encodeCall(MockDex.sellToOther, (address(cake), 40e18, address(usdt), 60e18, address(0xBAD)))
        );
    }

    /// 只收钱不卖币 —— 这不是一笔卖出，挡住（否则能当成「白嫖额度」）。
    function test_sellInto_reverts_when_nothing_was_sold() public {
        MockDex dex = new MockDex();
        MockUSDT cake = new MockUSDT();
        cake.mint(address(acc), 100e18);
        usdt.mint(address(dex), 1_000e18);

        bytes32 id = _dexNote("s", address(dex), 200e18);

        vm.prank(agentKey);
        vm.expectRevert(AgentAccount.NothingSold.selector);
        acc.sellInto(id, address(cake), 40e18, abi.encodeCall(MockDex.onlyGive, (address(usdt), 60e18)));
    }

    /// 卖的就是计价资产 —— 那是 spend 的活，不许走这条路。
    function test_sellInto_rejects_the_quote_asset() public {
        MockDex dex = new MockDex();
        bytes32 id = _dexNote("s", address(dex), 200e18);

        vm.prank(agentKey);
        vm.expectRevert(AgentAccount.SameAsset.selector);
        acc.sellInto(id, address(usdt), 1e18, abi.encodeCall(MockDex.nothing, ()));
    }

    /// market 是票上钉死的：这张票的 market 是 dex，就调不到 other。
    function test_sellInto_market_stays_pinned() public {
        MockDex dex = new MockDex();
        MockDex evil = new MockDex();
        MockUSDT cake = new MockUSDT();
        cake.mint(address(acc), 100e18);
        usdt.mint(address(evil), 1_000e18);

        bytes32 id = _dexNote("s", address(dex), 200e18);

        // calldata 是给 evil 准备的，但 sellInto 只会调 dex —— dex 上没有这笔钱，拉不动
        vm.prank(agentKey);
        vm.expectRevert();
        acc.sellInto(id, address(cake), 40e18, abi.encodeCall(MockDex.sell, (address(cake), 40e18, address(usdt), 60e18)));
        // evil 一分钱没动
        assertEq(usdt.balanceOf(address(evil)), 1_000e18);
    }

    /// approve 调完要归零，和 spend 同一条纪律。
    function test_sellInto_zeroes_the_approval() public {
        MockDex dex = new MockDex();
        MockUSDT cake = new MockUSDT();
        cake.mint(address(acc), 100e18);
        usdt.mint(address(dex), 1_000e18);

        bytes32 id = _dexNote("s", address(dex), 200e18);
        vm.prank(agentKey);
        acc.sellInto(id, address(cake), 40e18, abi.encodeCall(MockDex.sell, (address(cake), 40e18, address(usdt), 60e18)));

        assertEq(cake.allowance(address(acc), address(dex)), 0, unicode"授权必须归零");
    }

    /// 换回来的钱比花出去的多 —— netOut 夹在 0，不会变成负数。
    function test_sellInto_clamps_at_zero() public {
        MockDex dex = new MockDex();
        MockUSDT cake = new MockUSDT();
        cake.mint(address(acc), 100e18);
        usdt.mint(address(dex), 1_000e18);

        bytes32 id = _dexNote("s", address(dex), 200e18);
        vm.prank(agentKey);
        acc.spend(id, address(0), 0, abi.encodeCall(MockDex.buy, (address(usdt), 50e18)));

        vm.prank(agentKey);
        acc.sellInto(id, address(cake), 40e18, abi.encodeCall(MockDex.sell, (address(cake), 40e18, address(usdt), 300e18)));
        assertEq(_netOut(id), 0, unicode"夹在 0");
    }

    /// 过期票卖不了。
    function test_sellInto_respects_expiry() public {
        MockDex dex = new MockDex();
        MockUSDT cake = new MockUSDT();
        cake.mint(address(acc), 100e18);
        bytes32 id = _dexNote("s", address(dex), 200e18);

        vm.warp(uint256(tomorrow) + 1);
        vm.prank(agentKey);
        vm.expectRevert(AgentAccount.NoteExpired.selector);
        acc.sellInto(id, address(cake), 40e18, abi.encodeCall(MockDex.nothing, ()));
    }

    /// 只有 agentKey / owner / EntryPoint 能调。
    function test_sellInto_only_operator() public {
        MockDex dex = new MockDex();
        bytes32 id = _dexNote("s", address(dex), 200e18);

        vm.prank(address(0xBAD));
        vm.expectRevert(AgentAccount.NotAgentKey.selector);
        acc.sellInto(id, address(0x1234), 1e18, abi.encodeCall(MockDex.nothing, ()));
    }

    // ═══════════ withdrawNative：原生 BNB 要能取出来（2026-11-24 加）═══════════
    //
    // 不加这个，原生 BNB 进了账户就出不去：withdraw 走 safeTransfer 只认 ERC20，
    // withdrawDeposit 取的是 EntryPoint 的存款格。结果是只能被当 gas 烧掉。

    function test_owner_can_take_native_back() public {
        vm.deal(address(acc), 1 ether);
        address payable to = payable(address(0x7777));

        vm.prank(owner);
        acc.withdrawNative(to, 0.4 ether);

        assertEq(to.balance, 0.4 ether);
        assertEq(address(acc).balance, 0.6 ether);
    }

    function test_only_owner_can_take_native_back() public {
        vm.deal(address(acc), 1 ether);
        vm.prank(agentKey);
        vm.expectRevert(AgentAccount.NotOwner.selector);
        acc.withdrawNative(payable(address(0x7777)), 1 wei);
    }
    // ═══ owner 2026-11-24 问的那条：赚的钱 agent 能不能转走 ═══
    //
    // 答案：不能。但要分清楚钱回到账户之后落在哪个格子里。

    /// 赚超过票面的那部分**落进 available**，票的额度不会被撑大，agent 够不着。
    function test_profit_lands_in_available_and_the_note_is_not_inflated() public {
        MockDex dex = new MockDex();
        MockUSDT cake = new MockUSDT();
        cake.mint(address(acc), 100e18);
        usdt.mint(address(dex), 1_000e18);

        bytes32 id = _dexNote("p", address(dex), 200e18);
        assertEq(acc.available(address(usdt)), 300e18);

        // 把票花干净：netOut = 200，reserved = 0，余额 300
        vm.prank(agentKey);
        acc.spend(id, address(0), 0, abi.encodeCall(MockDex.buy, (address(usdt), 200e18)));
        assertEq(_netOut(id), 200e18);
        assertEq(acc.reserved(acc.epoch(), address(usdt)), 0);

        // 卖回 300 —— 比花出去的多 100，那 100 就是赚的
        vm.prank(agentKey);
        acc.sellInto(id, address(cake), 40e18, abi.encodeCall(MockDex.sell, (address(cake), 40e18, address(usdt), 300e18)));

        assertEq(usdt.balanceOf(address(acc)), 600e18);
        assertEq(_netOut(id), 0, unicode"票回满");
        assertEq(acc.reserved(acc.epoch(), address(usdt)), 200e18, unicode"reserved 夹在票面 200，不会变成 300");
        assertEq(acc.available(address(usdt)), 400e18, unicode"赚的 100 落进可用：300 → 400");
    }

    /// agent 够不到「可用」的三条门，一条一条堵死。
    function test_agent_cannot_reach_available() public {
        MockDex dex = new MockDex();
        bytes32 id = _dexNote("p", address(dex), 200e18);

        // ① 提款：只有 owner
        vm.prank(agentKey);
        vm.expectRevert(AgentAccount.NotOwner.selector);
        acc.withdraw(address(usdt), address(0xBAD), 1e18);

        // ② sellInto 卖计价资产：挡住。否则这就是把 available 搬走的口子
        vm.prank(agentKey);
        vm.expectRevert(AgentAccount.SameAsset.selector);
        acc.sellInto(id, address(usdt), 300e18, abi.encodeCall(MockDex.nothing, ()));

        // ③ 自己开票：只有 owner
        vm.prank(agentKey);
        vm.expectRevert(AgentAccount.NotOwner.selector);
        acc.issueBatch(_one("x", address(dex), 300e18), new bytes32[](0));
    }

    /// 一张票的**累计净流出**永远 ≤ 票面 —— 来回卖再花，也撑不破。
    function test_one_note_can_never_leak_more_than_its_face() public {
        MockDex dex = new MockDex();
        MockUSDT cake = new MockUSDT();
        cake.mint(address(acc), 500e18);
        usdt.mint(address(dex), 5_000e18);

        bytes32 id = _dexNote("p", address(dex), 200e18);
        uint256 bal0 = usdt.balanceOf(address(acc));

        // 来回跑三轮：每轮花满 200，再卖回 200
        for (uint256 i; i < 3; ++i) {
            vm.prank(agentKey);
            acc.spend(id, address(0), 0, abi.encodeCall(MockDex.buy, (address(usdt), 200e18)));
            vm.prank(agentKey);
            acc.sellInto(
                id, address(cake), 10e18, abi.encodeCall(MockDex.sell, (address(cake), 10e18, address(usdt), 200e18))
            );
        }

        // 最后再花满一次，不卖回
        vm.prank(agentKey);
        acc.spend(id, address(0), 0, abi.encodeCall(MockDex.buy, (address(usdt), 200e18)));

        // 跑了四轮，账户净少的只有 200 —— 票面
        assertEq(bal0 - usdt.balanceOf(address(acc)), 200e18, unicode"累计净流出 = 票面，一分不多");

        // 再想花一分都不行。注意**报的不是 OverNote** —— 额度花完之后 headroom = 0，
        // approve 归零，市场连拉都拉不动，revert 在市场那一层就发生了（CallFailed）。
        // 这比 OverNote 更早一层：OverNote 是「真的转超了」才触发的兜底。
        vm.prank(agentKey);
        vm.expectRevert();
        acc.spend(id, address(0), 0, abi.encodeCall(MockDex.buy, (address(usdt), 1e18)));
        assertEq(bal0 - usdt.balanceOf(address(acc)), 200e18, unicode"失败之后还是 200");
    }
    // ═══ 出口检查：买到的东西必须回账户（2026-11-24 加）═══
    //
    // 这个洞在 v1–v4 一直存在，主网实测过：
    //   tx 0xe7c8224b…bf00 —— 账户 USDT −0.1、账户 WBNB +0、黑洞地址 +0.000177，
    //   而票据照样正确封顶。**票封的是「走了多少」，不是「买到的东西回没回来」。**
    //
    // 靠什么成立：一次 router 调用只有一个收款人。所以只要要求「申报的那个币在
    // 账户里必须变多」，输出就只能回账户 —— minOut 填多小都挡得住。

    function _issueRR(bytes32 salt, address mkt, uint128 amount, bool rr) internal returns (bytes32 id) {
        id = acc.noteIdOf(salt, mkt, address(usdt), amount, tomorrow, rr, bytes32(0));
        AgentAccount.NoteInput[] memory b = new AgentAccount.NoteInput[](1);
        b[0] = AgentAccount.NoteInput({
            salt: salt, market: mkt, asset: address(usdt), amount: amount, expiry: tomorrow, requireReturn: rr,
            dataHash: bytes32(0)
        });
        vm.prank(owner);
        acc.issueBatch(b, new bytes32[](0));
    }

    /// ❗ 这条就是主网上那一笔，搬进测试里：把 to 填成别人，必须 revert。
    function test_buy_sent_to_a_stranger_is_rejected() public {
        MockDex dex = new MockDex();
        MockUSDT cake = new MockUSDT();
        cake.mint(address(dex), 1_000e18);
        address stranger = address(0xBAD);

        bytes32 id = _issueRR("r", address(dex), 200e18, true);

        vm.prank(agentKey);
        vm.expectRevert(AgentAccount.NothingBought.selector);
        acc.spend(id, address(cake), 1, abi.encodeCall(MockDex.swapTo, (address(usdt), 100e18, address(cake), 50e18, stranger)));

        assertEq(usdt.balanceOf(address(acc)), 500e18, unicode"revert 之后一分钱没动");
        assertEq(cake.balanceOf(stranger), 0);
        assertEq(_netOut(id), 0);
    }

    /// 同一笔，收款人填账户自己 —— 正常放行。
    function test_buy_sent_to_the_account_goes_through() public {
        MockDex dex = new MockDex();
        MockUSDT cake = new MockUSDT();
        cake.mint(address(dex), 1_000e18);

        bytes32 id = _issueRR("r", address(dex), 200e18, true);

        vm.prank(agentKey);
        acc.spend(
            id, address(cake), 50e18,
            abi.encodeCall(MockDex.swapTo, (address(usdt), 100e18, address(cake), 50e18, address(acc)))
        );

        assertEq(cake.balanceOf(address(acc)), 50e18);
        assertEq(_netOut(id), 100e18);
    }

    /// minOut 填 1 wei 照样挡得住 —— 去向保证和 minOut 的大小无关。
    function test_tiny_minOut_still_blocks_the_stranger() public {
        MockDex dex = new MockDex();
        MockUSDT cake = new MockUSDT();
        cake.mint(address(dex), 1_000e18);

        bytes32 id = _issueRR("r", address(dex), 200e18, true);

        vm.prank(agentKey);
        vm.expectRevert(AgentAccount.NothingBought.selector);
        acc.spend(id, address(cake), 1, abi.encodeCall(MockDex.swapTo, (address(usdt), 100e18, address(cake), 50e18, address(0xBAD))));
    }

    /// 滑点没达到也挡住 —— 这一条是 agent 自己的保护，不是去向保证。
    function test_minOut_also_guards_slippage() public {
        MockDex dex = new MockDex();
        MockUSDT cake = new MockUSDT();
        cake.mint(address(dex), 1_000e18);

        bytes32 id = _issueRR("r", address(dex), 200e18, true);

        vm.prank(agentKey);
        vm.expectRevert(AgentAccount.NothingBought.selector);
        acc.spend(id, address(cake), 60e18, abi.encodeCall(MockDex.swapTo, (address(usdt), 100e18, address(cake), 50e18, address(acc))));
    }

    /// requireReturn 的票不许不申报 —— 否则 agent 填 0 就把检查关掉了。
    function test_requireReturn_note_must_declare_an_out_asset() public {
        MockDex dex = new MockDex();
        bytes32 id = _issueRR("r", address(dex), 200e18, true);

        vm.startPrank(agentKey);
        vm.expectRevert(AgentAccount.NeedOutAsset.selector);
        acc.spend(id, address(0), 0, abi.encodeCall(MockDex.nothing, ()));
        vm.expectRevert(AgentAccount.NeedOutAsset.selector);
        acc.spend(id, address(usdt), 1, abi.encodeCall(MockDex.nothing, ())); // 申报计价资产也不行
        vm.expectRevert(AgentAccount.NeedOutAsset.selector);
        acc.spend(id, address(0x1234), 0, abi.encodeCall(MockDex.nothing, ())); // minOut = 0 也不行
        vm.stopPrank();
    }

    /// ❗ ②③④ 是入金：钱出去链上什么都不回来。它们必须还能用。
    function test_deposit_notes_still_work_with_nothing_coming_back() public {
        bytes32 id = _issueRR("d", address(market), 200e18, false);

        vm.prank(agentKey);
        acc.spend(id, address(0), 0, abi.encodeCall(MockMarket.take, (150e18)));

        assertEq(_netOut(id), 150e18, unicode"入金照常走得通");
    }

    /// 标志是 owner 开票时定的，agent 选不了：换个标志就是另一张票的 id。
    function test_the_flag_is_part_of_the_note_id() public {
        bytes32 withRR = acc.noteIdOf("x", address(market), address(usdt), 100e18, tomorrow, true, bytes32(0));
        bytes32 without = acc.noteIdOf("x", address(market), address(usdt), 100e18, tomorrow, false, bytes32(0));
        assertTrue(withRR != without, unicode"标志必须进 id，否则 owner 签的那个 id 没承诺这条边界");
    }

    /// 没开 requireReturn 的票，申报了也照样查 —— 标志只决定「能不能不申报」。
    function test_declaring_opts_into_the_check_even_without_the_flag() public {
        MockDex dex = new MockDex();
        MockUSDT cake = new MockUSDT();
        cake.mint(address(dex), 1_000e18);

        bytes32 id = _issueRR("r", address(dex), 200e18, false);

        vm.prank(agentKey);
        vm.expectRevert(AgentAccount.NothingBought.selector);
        acc.spend(id, address(cake), 1, abi.encodeCall(MockDex.swapTo, (address(usdt), 100e18, address(cake), 50e18, address(0xBAD))));
    }
}

/// 费率 + calldata 闸。单开一个合约是因为主测试套刻意零费
/// （那 85 条断言围绕「账户少多少钱」写的，开着费会把每条都搅乱）。
contract FeeAndDataHashTest is Test {
    AgentAccount acc;
    MockUSDT usdt;
    MockMarket market;
    MockDex dex;
    MockUSDT coin;

    address owner = address(0x99);
    address agentKey = address(0xA1);
    address agentIdEoa = address(0x81bf);
    address entryPoint = address(0xE7);
    address feeTo = address(0xFEE);

    uint16 constant TRADE_BPS = 25;  // 0.25%
    uint16 constant DRAW_BPS = 100;  // 1%

    uint48 tomorrow;

    function setUp() public {
        vm.warp(1_700_000_000);
        tomorrow = uint48(block.timestamp + 1 days);
        usdt = new MockUSDT();
        market = new MockMarket(address(usdt));
        dex = new MockDex();
        coin = new MockUSDT();
        acc = new AgentAccount(entryPoint, feeTo, TRADE_BPS, DRAW_BPS);
        acc.initialize(owner, agentKey, agentIdEoa, "guatan");
        usdt.mint(address(acc), 1000e18);
        coin.mint(address(dex), 1000e18); // dex 要有货才卖得出来
        usdt.mint(address(dex), 1000e18); // 也要有 USDT 才收得回来
    }

    function _issue(bytes32 salt, address mkt, uint128 amt, bool rr, bytes32 dh) internal returns (bytes32 id) {
        id = acc.noteIdOf(salt, mkt, address(usdt), amt, tomorrow, rr, dh);
        AgentAccount.NoteInput[] memory b = new AgentAccount.NoteInput[](1);
        b[0] = AgentAccount.NoteInput({
            salt: salt, market: mkt, asset: address(usdt),
            amount: amt, expiry: tomorrow, requireReturn: rr, dataHash: dh
        });
        vm.prank(owner);
        acc.issueBatch(b, new bytes32[](0));
    }

    // ───────────── 费率上限是写进字节码的 ─────────────

    function test_constructor_rejects_fee_above_2pct() public {
        vm.expectRevert(AgentAccount.FeeTooHigh.selector);
        new AgentAccount(entryPoint, feeTo, 201, 0);
        vm.expectRevert(AgentAccount.FeeTooHigh.selector);
        new AgentAccount(entryPoint, feeTo, 0, 201);
    }

    function test_fee_fields_are_immutable() public view {
        assertEq(acc.feeTo(), feeTo);
        assertEq(acc.tradeFeeBps(), TRADE_BPS);
        assertEq(acc.drawFeeBps(), DRAW_BPS);
        // 没有 setter —— 这一条靠接口本身保证，不是靠断言。
    }

    // ───────────── 分档：按 requireReturn，不按函数 ─────────────

    function test_trade_note_charges_trade_bps_per_leg() public {
        bytes32 id = _issue("t", address(dex), 100e18, true, bytes32(0));
        uint256 f0 = usdt.balanceOf(feeTo);

        // 买：花 40 USDT 换回 coin
        vm.prank(agentKey);
        acc.spend(id, address(coin), 1, abi.encodeCall(MockDex.sell, (address(usdt), 40e18, address(coin), 7e18)));
        uint256 afterBuy = usdt.balanceOf(feeTo) - f0;
        assertEq(afterBuy, uint256(40e18) * TRADE_BPS / 10_000, unicode"买入那腿该收 0.25%");

        // 卖：coin 卖回 USDT —— 第二腿。netOut 下降，所以这一腿不触发扣费。
        // 这是刻意的：否则同一笔钱来回倒腾会被反复收费。
        vm.prank(agentKey);
        acc.sellInto(id, address(coin), 7e18, abi.encodeCall(MockDex.sell, (address(coin), 7e18, address(usdt), 39e18)));
        uint256 sellFee = usdt.balanceOf(feeTo) - f0 - afterBuy;
        assertEq(sellFee, uint256(39e18) * TRADE_BPS / 10_000, unicode"卖出腿也该收 0.25%（v7 起，owner 定的买卖各收）");
    }

    function test_deposit_note_charges_draw_bps() public {
        bytes32 id = _issue("d", address(market), 100e18, false, bytes32(0));
        uint256 f0 = usdt.balanceOf(feeTo);
        vm.prank(agentKey);
        acc.spend(id, address(0), 0, abi.encodeCall(MockMarket.take, (50e18)));
        assertEq(usdt.balanceOf(feeTo) - f0, uint256(50e18) * DRAW_BPS / 10_000, unicode"入金该收 1%，不是 0.25%");
    }

    function test_payout_always_charges_draw_bps() public {
        bytes32 id = _issue("p", address(market), 100e18, false, bytes32(0));
        uint256 f0 = usdt.balanceOf(feeTo);
        vm.prank(agentKey);
        acc.payout(id, 30e18);
        assertEq(usdt.balanceOf(feeTo) - f0, uint256(30e18) * DRAW_BPS / 10_000);
    }

    function test_fee_is_on_actual_spend_not_face_value() public {
        bytes32 id = _issue("x", address(market), 1000e18, false, bytes32(0));
        uint256 f0 = usdt.balanceOf(feeTo);
        vm.prank(agentKey);
        acc.payout(id, 1e18); // 票面 1000，只花 1
        assertEq(usdt.balanceOf(feeTo) - f0, uint256(1e18) * DRAW_BPS / 10_000, unicode"没花的钱不收费");
    }

    /// v7 改了语义：费**算进票面**。所以票面 100 的票，送到市场的上限是 ~99.01
    /// （100 / 1.01），不是 100 —— 换来的是「≤ 票面的钱会离开账户」字面成立。
    function test_fee_counts_against_the_note_budget() public {
        bytes32 id = _issue("q", address(market), 100e18, false, bytes32(0));
        vm.prank(agentKey);
        vm.expectRevert(AgentAccount.OverNote.selector);
        acc.payout(id, 100e18);          // 100 + 1% 的费 = 101 > 票面，不许

        uint256 b0 = usdt.balanceOf(address(acc));
        vm.prank(agentKey);
        acc.payout(id, 99e18);           // 99 + 0.99 = 99.99 ≤ 100，可以
        (,,, uint128 netOut,,,,,) = acc.notes(id);
        assertEq(netOut, 99e18 + 99e16, unicode"netOut 要把费算进去");
        assertEq(usdt.balanceOf(address(market)), 99e18, unicode"市场收到的还是全额");
        assertLe(b0 - usdt.balanceOf(address(acc)), 100e18, unicode"离开账户的不超过票面");
    }

    // ───────────── calldata 闸：2026-11-24 那个洞的回归锁 ─────────────

    function test_pinned_calldata_rejects_any_change() public {
        bytes memory good = abi.encodeCall(MockMarket.take, (50e18));
        bytes32 id = _issue("h", address(market), 100e18, false, keccak256(good));

        vm.prank(agentKey);
        acc.spend(id, address(0), 0, good); // 原样 → 放行

        bytes memory bad = abi.encodeCall(MockMarket.take, (50e18 + 1)); // 差 1 wei
        vm.prank(agentKey);
        vm.expectRevert(AgentAccount.WrongCalldata.selector);
        acc.spend(id, address(0), 0, bad);
    }

    /// 这一条锁的就是 Aster 那个场景：收款账户写在 calldata 里，
    /// v5 对此完全放行（链上模拟证实过）。
    function test_deposit_note_cannot_redirect_beneficiary() public {
        address stranger = address(0xBAD);
        bytes memory toUs = abi.encodeCall(MockMarket.depositFor, (address(usdt), agentIdEoa, 50e18));
        bytes32 id = _issue("a", address(market), 100e18, false, keccak256(toUs));

        bytes memory toThem = abi.encodeCall(MockMarket.depositFor, (address(usdt), stranger, 50e18));
        vm.prank(agentKey);
        vm.expectRevert(AgentAccount.WrongCalldata.selector);
        acc.spend(id, address(0), 0, toThem);

        vm.prank(agentKey);
        acc.spend(id, address(0), 0, toUs); // 填对了才放行
        assertEq(market.creditedTo(), agentIdEoa);
    }

    function test_dataHash_is_part_of_noteId() public view {
        bytes32 a = acc.noteIdOf("s", address(market), address(usdt), 1e18, tomorrow, false, bytes32(0));
        bytes32 b = acc.noteIdOf("s", address(market), address(usdt), 1e18, tomorrow, false, keccak256("x"));
        assertTrue(a != b, unicode"不进票号的话，owner 签的 id 就没承诺这条边界");
    }

    function test_zero_dataHash_leaves_calldata_free() public {
        bytes32 id = _issue("z", address(market), 100e18, false, bytes32(0));
        vm.prank(agentKey);
        acc.spend(id, address(0), 0, abi.encodeCall(MockMarket.take, (10e18)));
        vm.prank(agentKey);
        acc.spend(id, address(0), 0, abi.encodeCall(MockMarket.take, (20e18))); // 参数不同，照样放行
        (,,, uint128 netOut,,,,,) = acc.notes(id);
        // 30 的净流出 + 1% 取用费 = 30.3
        assertEq(netOut, 30e18 + 30e16, unicode"netOut 含费");
    }
}

/// v6 的缺陷：费从票面**之外**另收，所以
///   ① 票面 = 全部余额时，花满票会因为付不出费而整笔 revert
///   ② 核心承诺「≤ 票面的钱会离开账户」不成立 —— 实际离开 票面 + 费
contract FeeBudgetTest is Test {
    AgentAccount acc;
    MockUSDT usdt;
    MockMarket market;
    address owner = address(0x99);
    address agentKey = address(0xA1);
    address feeTo = address(0xFEE);
    uint48 tomorrow;

    function setUp() public {
        vm.warp(1_700_000_000);
        tomorrow = uint48(block.timestamp + 1 days);
        usdt = new MockUSDT();
        market = new MockMarket(address(usdt));
        acc = new AgentAccount(address(0xE7), feeTo, 25, 100);
        acc.initialize(owner, agentKey, address(0x81bf), "guatan");
        usdt.mint(address(acc), 100e18);
    }

    function _issue(uint128 amt, bool rr) internal returns (bytes32 id) {
        id = acc.noteIdOf("b", address(market), address(usdt), amt, tomorrow, rr, bytes32(0));
        AgentAccount.NoteInput[] memory b = new AgentAccount.NoteInput[](1);
        b[0] = AgentAccount.NoteInput({ salt: "b", market: address(market), asset: address(usdt),
            amount: amt, expiry: tomorrow, requireReturn: rr, dataHash: bytes32(0) });
        vm.prank(owner);
        acc.issueBatch(b, new bytes32[](0));
    }

    /// v6 在这里会 TransferFailed（余额清零，付不出费）。v7 把费算进票面，
    /// 所以这张票的可送出上限变成 ~99.01，而**整张票能花到一分不剩**。
    function test_full_balance_note_can_be_spent_to_the_last_wei() public {
        bytes32 id = _issue(100e18, false);   // 票面 = 全部余额
        vm.prank(agentKey);
        acc.payout(id, 99e18);                // 99 + 0.99 费 = 99.99
        (,,, uint128 netOut,,,,,) = acc.notes(id);
        assertEq(netOut, 99e18 + 99e16);
        assertEq(usdt.balanceOf(address(acc)), 100e18 - 99e18 - 99e16, unicode"账户没被掏空，费付得出来");
    }

    function test_never_more_than_face_value_leaves_the_account() public {
        bytes32 id = _issue(50e18, false);
        uint256 b0 = usdt.balanceOf(address(acc));
        vm.prank(agentKey);
        acc.payout(id, 49e18);   // 49 + 0.49 = 49.49 ≤ 50
        uint256 left = b0 - usdt.balanceOf(address(acc));
        assertLe(left, 50e18, unicode"离开账户的不能超过票面 —— 这是产品的核心承诺");
    }
}
