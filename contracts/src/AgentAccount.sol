// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20, Token, Sig} from "./lib/Token.sol";
import {IAccount, IEntryPoint, PackedUserOperation} from "./interfaces/IAccount.sol";

/// @title AgentAccount
/// @notice 把一份余额切成 N 张互不重叠的支出承诺（票据），用 ERC-4337 二维 nonce 让它们互不阻塞地上链。
///
/// 三把钥匙，角色严格分开：
///   owner      用户自己掌控的冷地址。只签 开票 / 收回 / 提款 / 换 agentKey。
///   agentKey   skill 在用户机器上生成的热钥匙。只签 花票 / 回扫 / 回收过期额度，打不开金库。
///   agentIdEoa 身份锚，部署时由认领签名写入，**只读，不给任何权限**。
///
/// 设计稿：https://claude.ai/artifact/TfyXvDF7ARj2krV33U9icp
contract AgentAccount is IAccount {
    using Token for address;

    // ─────────────────────────── 类型 ───────────────────────────

    struct Note {
        address market; // 只能和这个地址来往
        address asset; // 计价资产，通常 USDT
        uint128 amount; // 净流出上限（不是余量）
        uint128 netOut; // 累计转出 − 累计转回，向下 clamp 到 0
        uint48 expiry;
        uint32 epoch; // != 当前 epoch 就作废
        bool closed; // 被 cancel / reclaim / bumpEpoch 关掉
        /// true = 花这张票**必须有东西回到账户**。开票时由 owner 定，agent 选不了。
        /// 不开这一条，agent 能把买到的币直接发给任意地址：`_spend` 只量计价资产的
        /// 进出，**不看市场把输出发给了谁**。2026-11-24 主网实测证实过
        /// （tx 0xe7c8224b…bf00：账户 USDT −0.1，账户 WBNB +0，黑洞地址 +0.000177）。
        /// ②③④ 是入金，钱出去链上什么都不回来，所以它们必须填 false。
        bool requireReturn;
        /// 非 0 = 这张票的 calldata **必须一字不差**等于这个哈希的原像。
        ///
        /// 为什么要有它：`_spend` 只钉死 `market`，**calldata 里的参数是 agent 填的**。
        /// 入金型市场（② Aster `depositFor(asset, account, amt, broker)`）的收款账户
        /// 就在 calldata 里 —— agent 能把钱记到自己的 Aster 账户名下。
        /// 2026-11-24 链上模拟证实：account 填陌生地址，v5 合约照样放行。
        ///
        /// `requireReturn` 堵不了这类：入金**本来就没东西回来**。
        ///
        /// 0 = 不管（① 交易票：参数随行情变，钉死就没法交易了）。
        bytes32 dataHash;
    }

    struct NoteInput {
        bytes32 salt;
        address market;
        address asset;
        uint128 amount;
        uint48 expiry;
        /// 见 Note.requireReturn。① Pancake 这类填 true，②③④ 入金填 false。
        bool requireReturn;
        /// 见 Note.dataHash。① 交易填 0，②③ 入金填 keccak256(那一笔确切的 calldata)。
        bytes32 dataHash;
    }

    // ─────────────────────────── 状态 ───────────────────────────

    IEntryPoint public immutable entryPoint;

    /// 手续费。**三个都是 immutable** —— 部署后谁也改不了，owner 也不行。
    /// 这是刻意的：费率可改就等于「平台随时能多收」，披露了也没用。
    /// 要改费率只有一条路——部署新工厂，老账户完全不受影响。
    address public immutable feeTo;
    /// ① 交易（`requireReturn = true`）：买卖**各收一次**，扣在计价资产的流出上。
    uint16 public immutable tradeFeeBps;
    /// ②③④⑤ 注资 / 取用（`requireReturn = false` 和所有 `payout`）：收一次。
    uint16 public immutable drawFeeBps;

    address public owner;
    address public agentKey;

    /// 身份锚。部署时一次性写入，之后永久可读、永远不可当钥匙用。
    address public agentIdEoa;
    string public agentId;

    uint32 public epoch;

    mapping(bytes32 => Note) public notes;

    /// 按 epoch 分桶：bumpEpoch 后换新桶，新桶天生为 0，不需要遍历。
    mapping(uint32 => mapping(address => uint256)) public reserved;

    /// 停在 AgentID 钱包上、还没结的钱。按票记，一张票一笔。
    /// @dev 为什么需要：AgentID 上的 USDT 是一个池子、没有标签，sweep 只会
    ///      「有多少拉多少」。记下「这张票推了多少还没花完」，回扫时留住这些，
    ///      剩下的随便拉 —— 这样**不用串行**也不会把别人还要用的钱拉走。
    ///      v7 之前靠用户脚本里一道「同时只放一轮」的闸，那个会卡住同一轮补仓。
    mapping(bytes32 => uint256) public parked;

    /// 同上，按资产汇总 —— sweep 是按资产拉的，所以要这个口径。
    mapping(address => uint256) public parkedAsset;

    // ─────────────────────────── 事件 ───────────────────────────

    event NoteIssued(
        bytes32 indexed noteId,
        address indexed market,
        address indexed asset,
        uint128 amount,
        uint48 expiry,
        uint32 epoch,
        bool requireReturn,
        bytes32 dataHash
    );
    /// 扣了多少费。bps 一起发出来，这样从事件就能复核费率，不用去读合约。
    event FeeTaken(address indexed asset, uint256 amount, uint16 bps);
    event NoteSpent(bytes32 indexed noteId, address indexed market, uint128 netOutBefore, uint128 netOutAfter);
    /// 卖出：sold = 卖掉多少那个币，back = 换回多少计价资产。
    event SoldInto(
        bytes32 indexed noteId,
        address indexed sellAsset,
        uint256 sold,
        uint256 back,
        uint128 netOutBefore,
        uint128 netOutAfter
    );
    event NoteClosed(bytes32 indexed noteId, uint128 released, bytes1 reason); // 'c'ancel / 'r'eclaim
    event EpochBumped(uint32 indexed from, uint32 indexed to);
    event Swept(address indexed asset, address indexed from, uint256 amount);

    /// 往 AgentID 推了一笔，开始计这张票的「还没结」。
    event Parked(bytes32 indexed noteId, address indexed asset, uint256 amount, uint256 noteTotal);

    /// 这张票这轮结束了，解掉它占的那部分。
    event Released(bytes32 indexed noteId, address indexed asset, uint256 amount);
    event AgentKeyRotated(address indexed from, address indexed to);
    event OwnerTransferred(address indexed from, address indexed to);
    event Withdrawn(address indexed asset, address indexed to, uint256 amount);

    // ─────────────────────────── 错误 ───────────────────────────

    error NotOwner();
    error NotAgentKey();
    error NotOperator(); // agentKey 或 owner
    error NotEntryPoint();
    error AlreadyInitialized();
    error ZeroAddress();
    error BadAmount();
    error BadExpiry();
    error NoteExists();
    error NoteUnknown();
    error NoteClosedAlready();
    error NoteExpired();
    error NoteNotExpired();
    error WrongEpoch();
    error WrongMarket();
    error OverBudget();
    error OverNote();
    error CallFailed(bytes ret);
    error NothingBought();   // 买入之后申报的那个币没回到账户 —— 被送给别人了，不许
    error NeedOutAsset();    // 这张票要求有东西回来，但没申报要买什么
    error NothingCameBack(); // 卖出之后票的计价资产没增加 —— 持仓被送走了，不许
    error NothingSold();
    error FeeTooHigh();      // 构造参数超过 2% 硬顶
    error WrongCalldata();   // 票钉死了 calldata，这一笔对不上     // 要卖的那个币余额没减少 —— 这不是一笔卖出
    error SameAsset();       // 卖的就是票的计价资产 —— 那是 spend 的活

    // ─────────────────────────── 修饰 ───────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyAgentKey() {
        if (msg.sender != agentKey) revert NotAgentKey();
        _;
    }

    /// 回扫和回收额度两件事不碰金库，所以两把钥匙都能做。
    ///
    /// EntryPoint 也算 —— 它**只会执行 validateUserOp 放行过的 op**，而那里只认
    /// agentKey 的签名。所以「EntryPoint 在调」等价于「agentKey 在调」，不是放宽权限。
    /// 不加这一条，sweep 和 reclaim 就走不了车道（2026-11-22 主网实测：NotOperator）。
    modifier onlyOperator() {
        if (msg.sender != agentKey && msg.sender != owner && msg.sender != address(entryPoint)) {
            revert NotOperator();
        }
        _;
    }

    // ─────────────────────────── 构造 ───────────────────────────

    /// @param feeTo_ 收款地址。为 0 则整条费率逻辑关闭（测试、以及「先不收费」的那版）。
    /// @param tradeFeeBps_ 交易费，万分之几。
    /// @param drawFeeBps_ 注资 / 取用费，万分之几。
    constructor(address entryPoint_, address feeTo_, uint16 tradeFeeBps_, uint16 drawFeeBps_) {
        if (entryPoint_ == address(0)) revert ZeroAddress();
        // 上限写死 2%：构造参数是部署者填的，但**写进字节码的东西要自己有边界**，
        // 这样「费率多少」这件事不用信任部署者，读合约就知道最坏情况。
        if (tradeFeeBps_ > 200 || drawFeeBps_ > 200) revert FeeTooHigh();
        entryPoint = IEntryPoint(entryPoint_);
        feeTo = feeTo_;
        tradeFeeBps = tradeFeeBps_;
        drawFeeBps = drawFeeBps_;
    }

    /// @dev 扣费。从账户直接转给 feeTo，**不占票的额度** —— 票面是「给市场的预算」，
    ///      费是平台另收的。所以 `available()` 里它体现为余额减少，不是 reserved 增加。
    function _feeOf(uint256 base, uint16 bps) internal view returns (uint256) {
        if (feeTo == address(0) || bps == 0 || base == 0) return 0;
        return (base * bps) / 10_000;
    }

    function _pay(address asset, uint256 f, uint16 bps) internal {
        if (f == 0) return;
        asset.safeTransfer(feeTo, f);
        emit FeeTaken(asset, f, bps);
    }

    /// 算完直接付。payout 用 —— 那条路上票面校验在前面已经做过。
    function _fee(address asset, uint256 base, uint16 bps) internal returns (uint256 f) {
        f = _feeOf(base, bps);
        _pay(asset, f, bps);
    }

    /// @notice 由工厂在 CREATE2 部署后立刻调用，一笔交易写完三个地址。
    /// @dev 认领签名由工厂校验：账户地址在部署前就能算出来，所以 AgentID 可以先签一个还不存在的地址。
    function initialize(address owner_, address agentKey_, address agentIdEoa_, string calldata agentId_) external {
        if (owner != address(0)) revert AlreadyInitialized();
        if (owner_ == address(0) || agentKey_ == address(0)) revert ZeroAddress();
        owner = owner_;
        agentKey = agentKey_;
        agentIdEoa = agentIdEoa_; // 允许为 0：没有 AgentID 的用户也能开户
        agentId = agentId_;
        emit OwnerTransferred(address(0), owner_);
        emit AgentKeyRotated(address(0), agentKey_);
    }

    // ─────────────────────────── 读数 ───────────────────────────

    /// 界面要的四个读数之一。available = 余额 − 本 epoch 已承诺。
    function available(address asset) public view returns (uint256) {
        uint256 bal = IERC20(asset).balanceOf(address(this));
        uint256 res = reserved[epoch][asset];
        return bal > res ? bal - res : 0;
    }

    function noteIdOf(
        bytes32 salt,
        address market,
        address asset,
        uint128 amount,
        uint48 expiry,
        bool requireReturn,
        bytes32 dataHash
    ) public view returns (bytes32) {
        // requireReturn 和 dataHash 都必须进 id：不进的话，两张只差这个标志的票会撞
        // 同一个 id，而且 owner 签的那个 id 就没有承诺这条边界。
        return keccak256(
            abi.encode(address(this), epoch, salt, market, asset, amount, expiry, requireReturn, dataHash)
        );
    }

    // ────────────────────── 动作 1：开票 ──────────────────────

    /// @notice 一笔交易开完所有票。先回收过期额度，再按累加后的 reserved 校验。
    /// @dev 必须是 batch：多张票都改同一个 reserved，分开发就是多笔有依赖的交易。
    function issueBatch(NoteInput[] calldata batch, bytes32[] calldata reclaimIds) external onlyOwner {
        if (reclaimIds.length != 0) _reclaim(reclaimIds);

        uint32 e = epoch;
        for (uint256 i; i < batch.length; ++i) {
            NoteInput calldata n = batch[i];
            if (n.amount == 0) revert BadAmount();
            if (n.expiry <= block.timestamp) revert BadExpiry();
            if (n.market == address(0) || n.asset == address(0)) revert ZeroAddress();

            bytes32 id = noteIdOf(n.salt, n.market, n.asset, n.amount, n.expiry, n.requireReturn, n.dataHash);
            if (notes[id].amount != 0) revert NoteExists();

            notes[id] = Note({
                market: n.market,
                asset: n.asset,
                amount: n.amount,
                netOut: 0,
                expiry: n.expiry,
                epoch: e,
                closed: false,
                requireReturn: n.requireReturn,
                dataHash: n.dataHash
            });
            reserved[e][n.asset] += n.amount;
            emit NoteIssued(id, n.market, n.asset, n.amount, n.expiry, e, n.requireReturn, n.dataHash);
        }

        // 累加后再校验一次：超额的票一张都开不出来，而不是开出来之后花不动。
        for (uint256 i; i < batch.length; ++i) {
            address asset = batch[i].asset;
            if (reserved[e][asset] > IERC20(asset).balanceOf(address(this))) revert OverBudget();
        }
    }

    // ────────────────────── 动作 2：花票 ──────────────────────

    /// @notice 用一张票调它写死的那个市场。
    /// @dev 实际花费用前后余额差量出来，不信任被调方的返回值。
    ///      netOut 原地 clamp —— 不能用累计流水反推，那会让来回倒腾挖出额外额度。
    /// @param outAsset 申报「这一笔要买回来的币」。填 0 表示不期待任何东西回来
    ///                  —— 只有 `requireReturn = false` 的票（②③④ 入金）允许这样。
    /// @param minOut    至少要回来多少。**它的大小不影响去向保证** —— 一次 router
    ///                  调用只有一个收款人，所以哪怕填 1 wei，把 `to` 填成别人
    ///                  也会让账户余额纹丝不动而 revert。大小只是 agent 自己的滑点保护。
    function spend(bytes32 noteId, address outAsset, uint256 minOut, bytes calldata data)
        external
        onlyAgentKey
        returns (bytes memory)
    {
        return _spend(noteId, outAsset, minOut, data);
    }

    /// 一张票能不能动的全部条件。spend 和 payout 共用，两条路径不可能分叉。
    function _live(bytes32 noteId) internal view returns (Note storage n) {
        n = notes[noteId];
        if (n.amount == 0) revert NoteUnknown();
        if (n.closed) revert NoteClosedAlready();
        if (n.epoch != epoch) revert WrongEpoch();
        if (n.expiry <= block.timestamp) revert NoteExpired();
    }

    function _spend(bytes32 noteId, address outAsset, uint256 minOut, bytes calldata data)
        internal
        returns (bytes memory ret)
    {
        Note storage n = _live(noteId);

        // ❗ 出口检查（2026-11-24 加）。没有它，agent 能把买到的币发给任意地址：
        //    下面那段只量 `n.asset` 的进出，**完全不看市场把输出发给了谁**。
        //    主网实测过 tx 0xe7c8224b…bf00 —— 账户 USDT −0.1、账户 WBNB +0、
        //    黑洞地址 +0.000177，而票据照样正确封顶。封的是「走了多少」，
        //    不是「买到的东西回没回来」。
        //
        //    靠什么成立：**一次 router 调用只有一个收款人**。所以只要要求「申报的
        //    那个币在账户里必须变多」，输出就只能回账户。minOut 填多小都挡得住。
        //    它管不了**价格**（agent 照样能买垃圾币）—— 那是策略，不归我们管。
        if (n.requireReturn) {
            if (outAsset == address(0) || outAsset == n.asset || minOut == 0) revert NeedOutAsset();
        }

        // ❗ calldata 闸（2026-11-24 加）。上面那条管的是「买的东西回不回来」，
        //    管不了「这笔调用的参数是什么」。入金型市场的收款账户就写在 calldata 里
        //    （② Aster `depositFor(asset, account, amt, broker)`），agent 能把钱
        //    记到自己名下 —— 链上模拟证实 v5 对此完全放行。
        //    开票时钉死哈希，agent 的自由度归零。
        if (n.dataHash != bytes32(0) && keccak256(data) != n.dataHash) revert WrongCalldata();

        IERC20 token = IERC20(n.asset);
        address market = n.market;
        uint128 before = n.netOut;
        // outAsset 填了就查，不管票上标志如何 —— 标志只决定「能不能不填」。
        uint256 got0 = outAsset == address(0) ? 0 : IERC20(outAsset).balanceOf(address(this));

        // 纪律强制点：approve 只能给这张票剩下的额度，调完立刻归零。
        uint256 headroom = n.amount - before;
        uint256 bal0 = token.balanceOf(address(this));
        n.asset.forceApprove(market, headroom);

        bool ok;
        (ok, ret) = market.call(data);
        if (!ok) revert CallFailed(ret);

        n.asset.forceApprove(market, 0);

        if (outAsset != address(0)) {
            uint256 got1 = IERC20(outAsset).balanceOf(address(this));
            if (got1 < got0 || got1 - got0 < minOut) revert NothingBought();
        }

        uint256 bal1 = token.balanceOf(address(this));

        // netOut' = clamp(netOut + 转出 − 转回, 0, amount)
        uint128 nAfter;
        if (bal0 >= bal1) {
            uint256 out = bal0 - bal1;
            uint256 raw = uint256(before) + out;
            nAfter = raw > n.amount ? n.amount : uint128(raw);
            if (raw > n.amount) revert OverNote(); // 净流出不得超过票面
        } else {
            uint256 back = bal1 - bal0;
            nAfter = back >= before ? 0 : before - uint128(back);
        }

        // ❗ 费**算进票面**（v7 改，v6 是另收的）。基数 = 这一笔实际的净流出。
        //
        //    v6 把费放在票面之外，有两个后果，2026-11-24 用测试钉死过：
        //      · 票面 = 全部余额时，花满票会因为付不出费而整笔 revert（TransferFailed）
        //      · 核心承诺「**≤ 票面的钱会离开账户**」不成立 —— 实际离开 票面 + 费
        //    算进票面之后，`issueBatch` 那道 reserved ≤ 余额 的闸就顺带保证了费付得出来。
        //
        //    代价：一张 100 的票，真正能送到市场的是 ~99.75。agent 要留出这点头寸
        //    （skill 会自动算）。换来的是票面那个数**字面成立**，不用加脚注。
        uint256 fee;
        if (nAfter > before) {
            uint16 bps = n.requireReturn ? tradeFeeBps : drawFeeBps;
            fee = _feeOf(nAfter - before, bps);
            uint256 total = uint256(before) + (nAfter - before) + fee;
            if (total > n.amount) revert OverNote();
            nAfter = uint128(total);
        }

        n.netOut = nAfter;
        // reserved 承载的是这张票还没花掉的部分：amount − netOut
        if (nAfter > before) {
            reserved[epoch][n.asset] -= (nAfter - before);
        } else if (nAfter < before) {
            reserved[epoch][n.asset] += (before - nAfter);
        }

        emit NoteSpent(noteId, market, before, nAfter);
        if (fee != 0) _pay(n.asset, fee, n.requireReturn ? tradeFeeBps : drawFeeBps);
    }

    /// @notice 把账户持有的**任意** ERC20 卖回这张票的计价资产。
    ///
    /// 为什么要有这个：原来 `approve` 只能给票上那一个币，所以每买一种币、
    /// 想卖回去就得**再开一张那个币的票**。owner 定的方向是「给 agent 额度，
    /// 让它自由买卖，不要过多约束它的策略」，所以把卖出这条路打开。
    ///
    /// 打开之后还守住的（这是全部，别多想）：
    ///   · market **仍然是票上钉死的那个** —— 不能 approve 给任意地址
    ///   · 卖出之后**票的计价资产余额必须增加**，增加多少就从 netOut 扣回多少
    ///     → 持仓只能**换成**计价资产，不能被**送走**
    ///   · 票的过期 / epoch / closed 三道闸一样走 `_live`
    ///
    /// 明确**不**保证的：卖出的**价格**。agent 可以把 1000 个币卖成 1 wei。
    /// 这是策略问题不是安全问题 —— 而且买入那一侧本来就敞着（`_spend` 只量
    /// `n.asset` 的进出，**根本不检查买回来的东西去了哪**），所以这条不会更差。
    ///
    /// @param sellAsset 要卖掉的币。不能是票的计价资产（那是 `spend` 的活）。
    /// @param sellAmount approve 给 market 的额度。调完归零。
    /// @return back 这一笔换回来多少计价资产。
    function sellInto(bytes32 noteId, address sellAsset, uint256 sellAmount, bytes calldata data)
        external
        returns (uint256 back)
    {
        _onlyEntryPointOrAgentKey();
        return _sellInto(noteId, sellAsset, sellAmount, data);
    }

    function _sellInto(bytes32 noteId, address sellAsset, uint256 sellAmount, bytes calldata data)
        internal
        returns (uint256 back)
    {
        Note storage n = _live(noteId);
        if (sellAsset == n.asset) revert SameAsset();
        if (sellAmount == 0) revert BadAmount();

        address market = n.market;
        uint256 sell0 = IERC20(sellAsset).balanceOf(address(this));
        uint256 quote0 = IERC20(n.asset).balanceOf(address(this));

        // 和 spend 同一条纪律：approve 精确额度，调完立刻归零。
        sellAsset.forceApprove(market, sellAmount);
        (bool ok, bytes memory ret) = market.call(data);
        if (!ok) revert CallFailed(ret);
        sellAsset.forceApprove(market, 0);

        uint256 sell1 = IERC20(sellAsset).balanceOf(address(this));
        uint256 quote1 = IERC20(n.asset).balanceOf(address(this));

        // 这两条是**承重的**：少一条，持仓就能从这个口子被送走。
        if (sell1 >= sell0) revert NothingSold();
        if (quote1 <= quote0) revert NothingCameBack();

        back = quote1 - quote0;

        // 换回来的钱冲减这张票的净流出，和 spend 里「钱回来」那一支同一套算法。
        uint128 before = n.netOut;
        uint128 nAfter = back >= before ? 0 : before - uint128(back);
        // ❗ 卖出腿也收费（v7 加，owner 2026-11-24 定「买卖各收」）。
        //    v6 只在净流出**增加**时扣，卖回来让 netOut 下降，所以第二腿一分不收
        //    —— 主网实测过（tx 0xf551…b600 买入收 0.25%，tx 0x728a…b077 卖出收 0）。
        //    基数 = 真正卖回来的计价资产。费从回款里扣，所以 netOut 只减净额，
        //    `余额 − reserved` 这个不变量才守得住。
        uint256 fee = _feeOf(back, tradeFeeBps);
        if (fee != 0) {
            uint256 net = back - fee;
            nAfter = net >= before ? 0 : before - uint128(net);
        }

        n.netOut = nAfter;
        if (nAfter < before) {
            reserved[epoch][n.asset] += (before - nAfter);
        }

        emit SoldInto(noteId, sellAsset, sell0 - sell1, back, before, nAfter);
        _pay(n.asset, fee, tradeFeeBps);
    }

    // ────────────────── 动作 2b：按票付款 ──────────────────

    /// @notice 把票面额度**推**给票里写着的那个地址。
    /// @dev 为什么要这条：spend 的动作是「approve 给 market + 调它」，对**合约**成立，
    ///      但 ⑤ 身份类的 market 是 AgentID 的 EOA —— 调一个 EOA 什么都不发生，
    ///      approve 又在同一笔里归零了，钱根本到不了。④ 供血到入金口同理。
    ///      这条和 spend 共用 _live 的校验和同一套 netOut 记账，区别只是「推」而不是「调」。
    ///      目标地址同样不是参数，从票里取 —— 结构上就只能打到这张票自己的对手方。
    function payout(bytes32 noteId, uint128 amount) external onlyAgentKey returns (uint256) {
        return _payout(noteId, amount);
    }

    function _payout(bytes32 noteId, uint128 amount) internal returns (uint256 out) {
        Note storage n = _live(noteId);
        if (amount == 0) revert BadAmount();
        uint128 before = n.netOut;
        if (amount > n.amount - before) revert OverNote();

        IERC20 token = IERC20(n.asset);
        address to = n.market;

        // 照样用余额差量：代币再怪，我们少掉多少就记多少，不信 transfer 的返回值。
        uint256 bal0 = token.balanceOf(address(this));
        n.asset.safeTransfer(to, amount);
        uint256 bal1 = token.balanceOf(address(this));
        out = bal0 - bal1;

        // 费算进票面（见 _spend 里那段注释）。payout 永远是「钱出去不回来」，走取用档。
        uint256 fee = _feeOf(out, drawFeeBps);
        uint256 raw = uint256(before) + out + fee;
        if (raw > n.amount) revert OverNote();

        n.netOut = uint128(raw);
        reserved[epoch][n.asset] -= (out + fee);
        emit NoteSpent(noteId, to, before, uint128(raw));

        // 钱停在 AgentID 上的，记一笔「还没结」。回扫时留住这些。
        // 判据就是目的地 —— ③ Predict 和 ⑤ 身份门禁 mint 的票，market 填的
        // 都是 AgentID 地址；①② 填的是市场合约，不进这里。
        if (to == agentIdEoa && to != address(0)) {
            parked[noteId] += out;
            parkedAsset[n.asset] += out;
            emit Parked(noteId, n.asset, out, parked[noteId]);
        }

        _pay(n.asset, fee, drawFeeBps);
    }

    // ───────────────── 动作 3 / 4：退票与恐慌按钮 ─────────────────

    /// @notice 退单张：把这张票没花掉的额度退回可用池。
    function cancel(bytes32 noteId) external onlyOwner {
        _cancel(noteId);
    }

    /// @notice 退一批。
    /// @dev 界面上同一个市场的几张票合并成一行，「撤掉」那个按钮撤的是一行 ——
    ///      一行一笔交易，而不是让主人签 N 次。和 reclaim 的区别：那条只收**已过期**的，
    ///      这条收的是还活着的。两件事都要有。
    function cancelBatch(bytes32[] calldata ids) external onlyOwner {
        for (uint256 i; i < ids.length; ++i) _cancel(ids[i]);
    }

    function _cancel(bytes32 noteId) internal {
        Note storage n = notes[noteId];
        if (n.amount == 0) revert NoteUnknown();
        if (n.closed) revert NoteClosedAlready();
        if (n.epoch != epoch) revert WrongEpoch(); // 旧 epoch 的票不许动，否则会打到新桶上下溢

        uint128 rest = n.amount - n.netOut;
        n.closed = true;
        reserved[epoch][n.asset] -= rest;
        emit NoteClosed(noteId, rest, "c");
    }

    /// @notice 恐慌按钮：一条指令作废全部在外票据。
    /// @dev 就是 epoch++，没有循环 —— 新桶从没写过，天生是 0。
    ///      局限：追不到已经挂在 Predict / Aster 上的链下签名单，界面必须提示。
    function bumpEpoch() external onlyOwner {
        uint32 from = epoch;
        epoch = from + 1;
        emit EpochBumped(from, from + 1);
    }

    /// @notice 回收已过期票的额度。合约不枚举 —— 调度器从 NoteIssued 事件里知道有哪些。
    function reclaim(bytes32[] calldata ids) external onlyOperator {
        _reclaim(ids);
    }

    function _reclaim(bytes32[] calldata ids) internal {
        uint32 e = epoch;
        for (uint256 i; i < ids.length; ++i) {
            Note storage n = notes[ids[i]];
            if (n.amount == 0) revert NoteUnknown();
            if (n.closed) revert NoteClosedAlready();
            if (n.epoch != e) revert WrongEpoch();
            if (n.expiry > block.timestamp) revert NoteNotExpired();

            uint128 rest = n.amount - n.netOut;
            n.closed = true;
            reserved[e][n.asset] -= rest;
            emit NoteClosed(ids[i], rest, "r");
        }
    }

    // ────────────────────── 动作 5：回扫 ──────────────────────

    /// @notice 把 AgentID EOA 上的残余拉回来。
    /// @dev 必须是「拉」不是「推」：让 EOA 自己发交易就占掉它那条唯一的 nonce 队列。
    ///      前提是 EOA 开户时一次性 approve 给本账户。
    function sweep(address asset, address from) external onlyOperator returns (uint256 amount) {
        amount = sweepable(asset, from);
        if (amount == 0) return 0;
        asset.safeTransferFrom(from, address(this), amount);
        emit Swept(asset, from, amount);
    }

    /// @notice 这一刻能从 `from` 拉回多少 —— 把还没结的那部分留下。
    /// @dev 三个口径取最小：余额、授权、余额减去该留的。
    ///      `min(parkedAsset, 余额)` 里的 min 是必须的：AgentID 可能已经把钱花掉
    ///      一部分了（mint 就是这样），那时候余额比账面少，按账面扣会得负数。
    ///      ② Aster 的回款不在 parkedAsset 里，所以自动就拉得走 —— 不用特判。
    function sweepable(address asset, address from) public view returns (uint256) {
        uint256 bal = IERC20(asset).balanceOf(from);
        if (bal == 0) return 0;

        if (from == agentIdEoa && from != address(0)) {
            uint256 owed = parkedAsset[asset];
            uint256 keep = owed < bal ? owed : bal;
            bal -= keep;
            if (bal == 0) return 0;
        }

        uint256 allowed = IERC20(asset).allowance(from, address(this));
        return allowed < bal ? allowed : bal;
    }

    /// @notice 这张票这一轮完了 —— 解掉它占的「还没结」。
    /// @dev 为什么要显式说一声：钱花掉变成别的币之后（mint 就是），USDT 永远
    ///      不会原样回来，合约在链上看不见这件事，只能由 agent 来销账。
    ///      不调的后果只是**少拉一点回来**，钱还在 AgentID 上 —— 不会卡住任何业务。
    ///      onlyOperator 含 owner，所以 agent 失联时主人自己能解。
    function release(bytes32 noteId) external onlyOperator returns (uint256 freed) {
        return _release(noteId);
    }

    /// @notice 这一轮完了：先解账，再把能拉的拉回来 —— **一笔交易**。
    /// @dev 为什么合成一个：拆成 release + sweep 两笔就要两条车道、两次 gas，
    ///      而且中间那一刻「已解账但还没拉回」是个没必要存在的中间态。
    ///      回扫本来就是调度器排的一笔 UserOp，这里让它一次做完。
    function releaseAndSweep(bytes32 noteId, address asset, address from)
        external
        onlyOperator
        returns (uint256 amount)
    {
        _release(noteId);
        amount = sweepable(asset, from);
        if (amount == 0) return 0;
        asset.safeTransferFrom(from, address(this), amount);
        emit Swept(asset, from, amount);
    }

    function _release(bytes32 noteId) internal returns (uint256 freed) {
        freed = parked[noteId];
        if (freed == 0) return 0;
        address asset = notes[noteId].asset;
        parked[noteId] = 0;
        parkedAsset[asset] -= freed;
        emit Released(noteId, asset, freed);
    }

    // ───────────────────── ERC-4337 入口 ─────────────────────

    /// @dev 硬规矩：这里**只能**读自己那张票的 slot，绝不能读 available 或余额。
    ///      EntryPoint 的 handleOps 先把一批 op 全验完再逐个执行，验的时候前面那笔还没花钱。
    ///      超额在开票那一刻就挡掉了，所以这里不需要、也不许再查一次预算。
    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds)
        external
        override
        returns (uint256 validationData)
    {
        if (msg.sender != address(entryPoint)) revert NotEntryPoint();

        address signer = Sig.recoverEth(userOpHash, userOp.signature);
        validationData = signer == agentKey ? 0 : 1; // 1 = SIG_VALIDATION_FAILED

        if (missingAccountFunds != 0) {
            (bool ok,) = payable(msg.sender).call{value: missingAccountFunds}("");
            ok; // EntryPoint 自己会因为余额不足而 revert，这里不替它判断
        }
    }

    /// @notice EntryPoint 执行阶段的入口。花票走这里。
    function execute(bytes32 noteId, address outAsset, uint256 minOut, bytes calldata data)
        external
        returns (bytes memory)
    {
        _onlyEntryPointOrAgentKey();
        // 走内部调用。写成 this.spend(...) 会让 msg.sender 变成本合约自己，过不了 onlyAgentKey。
        return _spend(noteId, outAsset, minOut, data);
    }

    /// @notice EntryPoint 执行阶段的入口。按票付款走这里（④ ⑤）。
    function executePayout(bytes32 noteId, uint128 amount) external returns (uint256) {
        _onlyEntryPointOrAgentKey();
        return _payout(noteId, amount);
    }

    function _onlyEntryPointOrAgentKey() internal view {
        if (msg.sender != address(entryPoint) && msg.sender != agentKey) revert NotAgentKey();
    }

    // ───────────────────── owner 的几件事 ─────────────────────

    function rotateAgentKey(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        emit AgentKeyRotated(agentKey, next);
        agentKey = next;
    }

    function transferOwner(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        emit OwnerTransferred(owner, next);
        owner = next;
    }

    /// @notice 提款只能提可用部分，已承诺的动不了。
    function withdraw(address asset, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount > available(asset)) revert OverBudget();
        asset.safeTransfer(to, amount);
        emit Withdrawn(asset, to, amount);
    }

    function addDeposit() external payable {
        entryPoint.depositTo{value: msg.value}(address(this));
    }

    function withdrawDeposit(address payable to, uint256 amount) external onlyOwner {
        entryPoint.withdrawTo(to, amount);
    }

    /// @notice 把账户自己那笔**原生 BNB** 取出来。
    /// @dev 不加这一条，原生 BNB 进了账户就**出不去**：`withdraw` 走 `safeTransfer`
    ///      只认 ERC20，`withdrawDeposit` 取的是 EntryPoint 的存款格，不是这里的余额。
    ///      结果是账户里的原生 BNB 只能被当 gas 烧掉，owner 拿不回来 ——
    ///      agent 要是在账户里把 WBNB unwrap 了，那笔钱就变成只能当 gas 的死钱。
    ///      （2026-11-23 发现，重部署时补上。）
    function withdrawNative(address payable to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert CallFailed("");
        emit Withdrawn(address(0), to, amount); // asset=0 表示原生币
    }

    receive() external payable {}
}
