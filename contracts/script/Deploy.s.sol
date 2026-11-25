// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {AgentAccount} from "../src/AgentAccount.sol";
import {AgentAccountFactory} from "../src/AgentAccountFactory.sol";

/// @notice 一笔交易建 factory + implementation，然后当场把三件会「只在上链那一刻才炸」的事核一遍。
/// @dev    用法：ENTRY_POINT=0x… forge script script/Deploy.s.sol --rpc-url <url> --private-key <key> --broadcast
contract Deploy is Script {
    function run() external {
        address entryPoint = vm.envAddress("ENTRY_POINT");
        address feeTo = vm.envAddress("FEE_TO");
        uint16 tradeBps = uint16(vm.envUint("TRADE_FEE_BPS"));
        uint16 drawBps = uint16(vm.envUint("DRAW_FEE_BPS"));

        // 不是真 EntryPoint 就别往下走 —— 字段写死之后改不了
        (bool ok,) = entryPoint.staticcall(abi.encodeWithSignature("getNonce(address,uint192)", address(1), uint192(0)));
        require(ok, unicode"ENTRY_POINT 不应答 getNonce，它不是 EntryPoint");

        vm.startBroadcast();
        AgentAccountFactory factory = new AgentAccountFactory(entryPoint, feeTo, tradeBps, drawBps);
        vm.stopBroadcast();

        address impl = factory.implementation();

        // 部署后自检：地址预计算必须和链上一致，否则「先接入、后开户」整条顺序不成立
        address probeKey = address(0xA1);
        address probeAid = address(0xA2);
        address predicted = factory.addressOf(probeKey, probeAid, "selftest");
        require(predicted.code.length == 0, unicode"预计算地址上不该有代码");
        require(address(AgentAccount(payable(impl)).entryPoint()) == entryPoint, unicode"实现里的 entryPoint 写错了");
        // 费率是 immutable，写错了只能重部署 —— 所以在这里核一遍，别等上线后才发现。
        require(AgentAccount(payable(impl)).feeTo() == feeTo, unicode"feeTo 写错了");
        require(AgentAccount(payable(impl)).tradeFeeBps() == tradeBps, unicode"tradeFeeBps 写错了");
        require(AgentAccount(payable(impl)).drawFeeBps() == drawBps, unicode"drawFeeBps 写错了");
        console.log(unicode"费率  交易 bps", tradeBps);
        console.log(unicode"费率  取用 bps", drawBps);

        console.log("chainId       ", block.chainid);
        console.log("entryPoint    ", entryPoint);
        console.log("factory       ", address(factory));
        console.log("implementation", impl);
        console.log("addressOf probe", predicted);
    }
}
