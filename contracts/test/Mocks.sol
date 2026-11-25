// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "../src/lib/Token.sol";

/// @notice 仿 BSC-USDT：18 位小数，approve 从非零改非零会 revert。
contract MockUSDT {
    string public constant name = "Mock USDT";
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        require(amount == 0 || allowance[msg.sender][spender] == 0, "USDT: approve from non-zero");
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "BEP20: transfer amount exceeds allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        require(balanceOf[from] >= amount, "BEP20: transfer amount exceeds balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice 一个会从调用方拉钱、也可能退钱回去的「市场」。
contract MockMarket {
    IERC20 public immutable token;

    constructor(address token_) {
        token = IERC20(token_);
    }

    /// 拉走 amount —— 模拟一次买入
    function take(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
    }

    /// 退回 amount —— 模拟一次卖出 / 找零
    function give(uint256 amount) external {
        token.transfer(msg.sender, amount);
    }

    /// 先拉后退：一次 swap 里既花钱又收钱
    function roundTrip(uint256 takeAmt, uint256 giveAmt) external {
        token.transferFrom(msg.sender, address(this), takeAmt);
        token.transfer(msg.sender, giveAmt);
    }

    /// 真实 Aster 存款桥的形状：**付钱的是 msg.sender，记账的是 account 参数**，
    /// 两者完全独立。收款账户就写在 calldata 里 —— 这正是 dataHash 要钉死的东西。
    /// 2026-11-24 主网核实过签名 `depositFor(address,address,uint256,uint256)`。
    address public creditedTo;

    function depositFor(address asset, address account, uint256 amount) external {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        creditedTo = account;
    }

    function boom() external pure {
        revert("market says no");
    }
}

/// @notice 两种币的「市场」—— 卖 A 换 B。给 sellInto 用。
contract MockDex {
    /// 正常卖出：拉走 sell，付出 buy
    function sell(address sellT, uint256 sellAmt, address buyT, uint256 buyAmt) external {
        IERC20(sellT).transferFrom(msg.sender, address(this), sellAmt);
        IERC20(buyT).transfer(msg.sender, buyAmt);
    }

    /// **攻击**：拉走币，什么都不给。sellInto 必须挡住这个。
    function steal(address sellT, uint256 sellAmt) external {
        IERC20(sellT).transferFrom(msg.sender, address(this), sellAmt);
    }

    /// 白给：不拉币，只付钱 —— 这不是一笔卖出
    function onlyGive(address buyT, uint256 buyAmt) external {
        IERC20(buyT).transfer(msg.sender, buyAmt);
    }

    /// 把钱送到第三方，不是送回调用方
    function sellToOther(address sellT, uint256 sellAmt, address buyT, uint256 buyAmt, address to) external {
        IERC20(sellT).transferFrom(msg.sender, address(this), sellAmt);
        IERC20(buyT).transfer(to, buyAmt);
    }

    /// 买入：拉走计价资产（模拟花票），用来给 sellInto 的测试先造出 netOut
    function buy(address payT, uint256 payAmt) external {
        IERC20(payT).transferFrom(msg.sender, address(this), payAmt);
    }

    /// 真实 Pancake 的形状：出钱的是 msg.sender，收币的是 to —— 两者是分开的。
    /// 2026-11-24 主网实测证实过（tx 0xe7c8224b…bf00）。
    function swapTo(address payT, uint256 payAmt, address getT, uint256 getAmt, address to) external {
        IERC20(payT).transferFrom(msg.sender, address(this), payAmt);
        IERC20(getT).transfer(to, getAmt);
    }

    function nothing() external {}
}
