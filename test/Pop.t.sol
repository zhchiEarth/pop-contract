// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "src/pop.sol";
import "src/CustomToken.sol";

contract PopTest is Test {
    CustomToken token;
    PoP pop;
    string protocol = "0";

    address alice = address(0xa);
    address bob = address(0xb);

    function setUp() public {
        token = new CustomToken("USDT", "USDT", 6);
        pop = new PoP();
        pop.initialize();

        pop.setAsk(address(token), 0);
        pop.addProtocol(protocol, address(token));
        pop.setMinAdd(protocol, address(token), 100);
    }

    function testExample() public {
        // client 提交任务
        //
        pop.submitTask();

        // 获取奖励
        pop.ClaimCompensation();

        // 矿工质押
        pop.Stake();
        // Unstake(string memory _proto, uint256 _amount)
    }
}
