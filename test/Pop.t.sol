// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "src/pop.sol";
import "src/CustomToken.sol";

contract PopTest is Test {
    CustomToken token;
    PoP pop;

    function setUp() public {
        token = new CustomToken("USDT", "USDT", 6);
    }

    function testExample() public {
        assertTrue(true);
    }
}
