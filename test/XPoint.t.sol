// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BaseTest, XPointV2Mock} from "./Base.t.sol";
import {XPoint} from "../src/XPoint.sol";

contract XPointTest is BaseTest {
    function test_init_assignsCoreRoles() public view {
        assertEq(xpoint.owner(), owner);
        assertTrue(xpoint.hasRole(xpoint.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(xpoint.hasRole(xpoint.OPERATOR_ROLE(), operator));
        assertTrue(xpoint.hasRole(xpoint.PAUSER_ROLE(), pauser));
    }

    function test_RevertWhen_init_OwnerZero() public {
        XPoint impl = new XPoint();
        vm.expectRevert(XPoint.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(XPoint.initialize, ("X Point", "XPT", address(0), operator, pauser, 0, false))
        );
    }

    function test_mint_byMinterRole() public {
        _grantMinter(owner);

        vm.prank(owner);
        xpoint.mint(alice, 100 ether);

        assertEq(xpoint.balanceOf(alice), 100 ether);
    }

    function test_RevertWhen_mint_NotMinter() public {
        vm.prank(alice);
        vm.expectRevert();
        xpoint.mint(alice, 1);
    }

    function test_RevertWhen_mint_ZeroAmount() public {
        _grantMinter(owner);

        vm.prank(owner);
        vm.expectRevert(XPoint.ZeroAmount.selector);
        xpoint.mint(alice, 0);
    }

    function test_RevertWhen_mint_ZeroAddress() public {
        _grantMinter(owner);

        vm.prank(owner);
        vm.expectRevert(XPoint.ZeroAddress.selector);
        xpoint.mint(address(0), 1);
    }

    function test_RevertWhen_mint_ExceedsCap() public {
        XPoint capped = _deployXPointProxy("X Point", "XPT", owner, operator, pauser, 100, false);
        bytes32 minterRole = capped.MINTER_ROLE();
        vm.prank(owner);
        capped.grantRole(minterRole, owner);

        vm.prank(owner);
        vm.expectRevert(XPoint.MaxSupplyExceeded.selector);
        capped.mint(alice, 101);
    }

    function test_mintBatch() public {
        _grantMinter(owner);

        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = bob;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10;
        amounts[1] = 20;

        vm.prank(owner);
        xpoint.mintBatch(recipients, amounts);

        assertEq(xpoint.balanceOf(alice), 10);
        assertEq(xpoint.balanceOf(bob), 20);
    }

    function test_RevertWhen_mintBatch_LengthMismatch() public {
        _grantMinter(owner);

        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = bob;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10;

        vm.prank(owner);
        vm.expectRevert(XPoint.LengthMismatch.selector);
        xpoint.mintBatch(recipients, amounts);
    }

    function test_setMaxSupply_RaiseCap() public {
        vm.prank(owner);
        xpoint.setMaxSupply(1000);
        assertEq(xpoint.maxSupply(), 1000);
    }

    function test_setMaxSupply_SetUncapped() public {
        vm.prank(owner);
        xpoint.setMaxSupply(500);
        vm.prank(owner);
        xpoint.setMaxSupply(0);
        assertEq(xpoint.maxSupply(), 0);
    }

    function test_RevertWhen_setMaxSupply_BelowCurrent() public {
        _grantMinter(owner);
        vm.prank(owner);
        xpoint.mint(alice, 100);

        vm.prank(owner);
        vm.expectRevert(XPoint.MaxSupplyBelowCurrent.selector);
        xpoint.setMaxSupply(99);
    }

    function test_RevertWhen_setMaxSupply_NotAdmin() public {
        bytes32 minterRole = xpoint.MINTER_ROLE();
        vm.prank(owner);
        xpoint.grantRole(minterRole, alice);

        vm.prank(alice);
        vm.expectRevert();
        xpoint.setMaxSupply(100);
    }

    function test_transfer_RevertWhen_WhitelistMode_NotInWhitelist() public {
        _grantMinter(owner);
        vm.prank(owner);
        xpoint.mint(alice, 100);

        vm.prank(operator);
        xpoint.setWhitelistMode(true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(XPoint.NotWhitelisted.selector, alice, bob));
        xpoint.transfer(bob, 1);
    }

    function test_transfer_whenEitherSideWhitelisted() public {
        _grantMinter(owner);
        vm.prank(owner);
        xpoint.mint(alice, 100);

        vm.prank(operator);
        xpoint.setWhitelistMode(true);
        vm.prank(operator);
        xpoint.addToWhitelist(bob);

        vm.prank(alice);
        xpoint.transfer(bob, 25);

        assertEq(xpoint.balanceOf(bob), 25);
    }

    function test_RevertWhen_addToWhitelist_ZeroAddress() public {
        vm.prank(operator);
        vm.expectRevert(XPoint.ZeroAddress.selector);
        xpoint.addToWhitelist(address(0));
    }

    function test_RevertWhen_addToWhitelist_NotOperator() public {
        vm.prank(alice);
        vm.expectRevert();
        xpoint.addToWhitelist(alice);
    }

    function test_transfer_RevertWhen_Blacklisted() public {
        _grantMinter(owner);
        vm.prank(owner);
        xpoint.mint(alice, 100);

        vm.prank(operator);
        xpoint.addToBlacklist(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(XPoint.Blacklisted.selector, alice));
        xpoint.transfer(bob, 1);
    }

    function test_mint_RevertWhen_Blacklisted_To() public {
        _grantMinter(owner);
        vm.prank(operator);
        xpoint.addToBlacklist(alice);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(XPoint.Blacklisted.selector, alice));
        xpoint.mint(alice, 1);
    }

    function test_RevertWhen_addToBlacklist_ZeroAddress() public {
        vm.prank(operator);
        vm.expectRevert(XPoint.ZeroAddress.selector);
        xpoint.addToBlacklist(address(0));
    }

    function test_RevertWhen_addToBlacklist_NotOperator() public {
        vm.prank(alice);
        vm.expectRevert();
        xpoint.addToBlacklist(alice);
    }

    function test_pause_OnlyPauserRole() public {
        vm.prank(owner);
        vm.expectRevert();
        xpoint.pause();
    }

    function test_unpause_OnlyPauserRole() public {
        vm.prank(pauser);
        xpoint.pause();

        vm.prank(owner);
        vm.expectRevert();
        xpoint.unpause();
    }

    function test_transfer_RevertWhen_Paused() public {
        _grantMinter(owner);
        vm.prank(owner);
        xpoint.mint(alice, 100);

        vm.prank(pauser);
        xpoint.pause();

        vm.prank(alice);
        vm.expectRevert();
        xpoint.transfer(bob, 1);
    }

    function test_mint_RevertWhen_Paused() public {
        _grantMinter(owner);
        vm.prank(pauser);
        xpoint.pause();

        vm.prank(owner);
        vm.expectRevert();
        xpoint.mint(alice, 1);
    }

    function test_acceptOwnership_TransfersDefaultAdminRole() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        xpoint.transferOwnership(newOwner);
        vm.prank(newOwner);
        xpoint.acceptOwnership();

        assertFalse(xpoint.hasRole(xpoint.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(xpoint.hasRole(xpoint.DEFAULT_ADMIN_ROLE(), newOwner));
        assertEq(xpoint.owner(), newOwner);
    }

    function test_permit_happyPath() public {
        uint256 value = 10 ether;
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(OWNER_PK, owner, alice, value, xpoint.nonces(owner), deadline);

        vm.prank(alice);
        xpoint.permit(owner, alice, value, deadline, v, r, s);

        assertEq(xpoint.allowance(owner, alice), value);
    }

    function test_RevertWhen_permit_Replay() public {
        uint256 value = 10 ether;
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(OWNER_PK, owner, alice, value, xpoint.nonces(owner), deadline);

        vm.prank(alice);
        xpoint.permit(owner, alice, value, deadline, v, r, s);

        vm.prank(alice);
        vm.expectRevert();
        xpoint.permit(owner, alice, value, deadline, v, r, s);
    }

    function test_RevertWhen_permit_ExpiredDeadline() public {
        uint256 value = 10 ether;
        uint256 deadline = block.timestamp + 1;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(OWNER_PK, owner, alice, value, xpoint.nonces(owner), deadline);

        vm.warp(deadline + 1);
        vm.prank(alice);
        vm.expectRevert();
        xpoint.permit(owner, alice, value, deadline, v, r, s);
    }

    function test_renounceOwnership_Reverts() public {
        vm.expectRevert(XPoint.RenounceDisabled.selector);
        xpoint.renounceOwnership();
    }

    function testFuzz_mint(
        uint256 amount
    ) public {
        amount = bound(amount, 1, type(uint96).max);

        _grantMinter(owner);
        vm.prank(owner);
        xpoint.mint(alice, amount);

        assertEq(xpoint.balanceOf(alice), amount);
    }

    function testFuzz_transfer(
        uint256 amount
    ) public {
        amount = bound(amount, 1, type(uint96).max);

        _grantMinter(owner);
        vm.prank(owner);
        xpoint.mint(alice, amount);

        vm.prank(alice);
        xpoint.transfer(bob, amount);

        assertEq(xpoint.balanceOf(bob), amount);
    }

    function test_upgrade_continuity() public {
        _grantMinter(owner);
        vm.prank(owner);
        xpoint.mint(alice, 42);
        vm.prank(operator);
        xpoint.setWhitelistMode(true);

        XPointV2Mock newImpl = new XPointV2Mock();

        vm.prank(owner);
        xpoint.upgradeToAndCall(address(newImpl), bytes(""));

        XPointV2Mock upgraded = XPointV2Mock(address(xpoint));
        assertEq(upgraded.version(), 2);
        assertEq(upgraded.balanceOf(alice), 42);
        assertTrue(upgraded.hasRole(upgraded.DEFAULT_ADMIN_ROLE(), owner));
        assertEq(upgraded.whitelistModeEnabled(), true);
    }
}
