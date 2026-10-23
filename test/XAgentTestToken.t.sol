// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";

import {XAgentTestToken} from "../src/XAgentTestToken.sol";

contract XAgentTestTokenTest is Test {
    XAgentTestToken internal token;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        token = new XAgentTestToken("XAgent Test Token", "tXAGENT", 18);
    }

    function test_constructor_setsMetadataAndMintCap() public {
        assertEq(token.name(), "XAgent Test Token");
        assertEq(token.symbol(), "tXAGENT");
        assertEq(token.decimals(), 18);
        assertEq(token.MAX_MINT_PER_CALL(), 1_000_000_000 ether);
        assertEq(token.totalSupply(), 0);

        XAgentTestToken usdt = new XAgentTestToken("XAgent Test USDT", "tUSDT", 6);
        assertEq(usdt.decimals(), 6);
        assertEq(usdt.MAX_MINT_PER_CALL(), 1_000_000_000 * 1e6);
    }

    function test_mint_anyoneCanMintUpToCapToAnyAddress() public {
        uint256 cap = token.MAX_MINT_PER_CALL();

        vm.prank(alice);
        token.mint(bob, cap);
        vm.prank(alice);
        token.mint(bob, 1);

        assertEq(token.balanceOf(bob), cap + 1);
        assertEq(token.totalSupply(), cap + 1);
    }

    function test_RevertWhen_mint_AboveCap() public {
        uint256 cap = token.MAX_MINT_PER_CALL();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(XAgentTestToken.MintAmountTooLarge.selector, cap + 1, cap));
        token.mint(bob, cap + 1);
    }

    function test_RevertWhen_constructor_MainnetOrInvalidDecimals() public {
        uint256[3] memory mainnets = [uint256(1), 196, 42_161];
        for (uint256 i; i < mainnets.length; ++i) {
            vm.chainId(mainnets[i]);
            vm.expectRevert(abi.encodeWithSelector(XAgentTestToken.UnsupportedChain.selector, mainnets[i]));
            new XAgentTestToken("XAgent Test Token", "tXAGENT", 18);
        }

        vm.chainId(11_155_111);
        vm.expectRevert(abi.encodeWithSelector(XAgentTestToken.InvalidDecimals.selector, uint8(19)));
        new XAgentTestToken("XAgent Test Token", "tXAGENT", 19);
    }

    function testFuzz_mint_withinCapAccumulates(
        uint256 first,
        uint256 second
    ) public {
        uint256 cap = token.MAX_MINT_PER_CALL();
        first = bound(first, 0, cap);
        second = bound(second, 0, cap);

        token.mint(alice, first);
        token.mint(alice, second);

        assertEq(token.balanceOf(alice), first + second);
    }
}
