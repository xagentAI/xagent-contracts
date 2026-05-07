// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseTest, CheckInV2Mock} from "./Base.t.sol";
import {CheckIn} from "../src/CheckIn.sol";
import {XPoint} from "../src/XPoint.sol";
import {IXPoint} from "../src/interfaces/IXPoint.sol";

contract ReenteringXPointMock is IXPoint {
    address public target;
    bytes public payload;
    bool public attempted;
    bool public nestedSucceeded;

    function setReentry(
        address target_,
        bytes calldata payload_
    ) external {
        target = target_;
        payload = payload_;
    }

    function mint(
        address,
        uint256
    ) external override {
        if (!attempted && target != address(0)) {
            attempted = true;
            (nestedSucceeded,) = target.call(payload);
        }
    }
}

contract CheckInTest is BaseTest {
    function test_checkIn_happyPath() public {
        uint256 amount = 25 ether;
        uint256 claimId = 1;
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signCheckIn(SIGNER_PK, alice, amount, claimId, deadline);

        vm.prank(alice);
        checkIn.checkIn(amount, claimId, deadline, signature);

        assertEq(xpoint.balanceOf(alice), amount);
        assertTrue(checkIn.isClaimed(claimId));
    }

    function test_RevertWhen_checkIn_InvalidSigner() public {
        uint256 amount = 10;
        uint256 claimId = 2;
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signCheckIn(OTHER_SIGNER_PK, alice, amount, claimId, deadline);

        vm.prank(alice);
        vm.expectRevert(CheckIn.InvalidSignature.selector);
        checkIn.checkIn(amount, claimId, deadline, signature);
    }

    function test_RevertWhen_checkIn_WrongCaller() public {
        uint256 amount = 10;
        uint256 claimId = 3;
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signCheckIn(SIGNER_PK, alice, amount, claimId, deadline);

        vm.prank(bob);
        vm.expectRevert(CheckIn.InvalidSignature.selector);
        checkIn.checkIn(amount, claimId, deadline, signature);
    }

    function test_RevertWhen_checkIn_WrongAmount() public {
        uint256 amount = 10;
        uint256 claimId = 4;
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signCheckIn(SIGNER_PK, alice, amount, claimId, deadline);

        vm.prank(alice);
        vm.expectRevert(CheckIn.InvalidSignature.selector);
        checkIn.checkIn(amount + 1, claimId, deadline, signature);
    }

    function test_RevertWhen_checkIn_WrongClaimId() public {
        uint256 amount = 10;
        uint256 claimId = 5;
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signCheckIn(SIGNER_PK, alice, amount, claimId, deadline);

        vm.prank(alice);
        vm.expectRevert(CheckIn.InvalidSignature.selector);
        checkIn.checkIn(amount, claimId + 1, deadline, signature);
    }

    function test_RevertWhen_checkIn_MalformedSignatureLength() public {
        uint256 amount = 10;
        uint256 claimId = 6;
        uint256 deadline = block.timestamp + 1 days;

        vm.prank(alice);
        vm.expectRevert();
        checkIn.checkIn(amount, claimId, deadline, hex"1234");
    }

    function test_RevertWhen_checkIn_AlreadyCheckedIn() public {
        uint256 amount = 10;
        uint256 claimId = 7;
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signCheckIn(SIGNER_PK, alice, amount, claimId, deadline);

        vm.prank(alice);
        checkIn.checkIn(amount, claimId, deadline, signature);

        vm.prank(alice);
        vm.expectRevert(CheckIn.AlreadyCheckedIn.selector);
        checkIn.checkIn(amount, claimId, deadline, signature);
    }

    function test_RevertWhen_checkIn_Expired() public {
        uint256 amount = 10;
        uint256 claimId = 8;
        uint256 deadline = block.timestamp + 10;
        bytes memory signature = _signCheckIn(SIGNER_PK, alice, amount, claimId, deadline);

        vm.warp(deadline + 1);
        vm.prank(alice);
        vm.expectRevert(CheckIn.CheckInExpired.selector);
        checkIn.checkIn(amount, claimId, deadline, signature);
    }

    function test_RevertWhen_checkIn_ZeroAmount() public {
        uint256 claimId = 9;
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signCheckIn(SIGNER_PK, alice, 0, claimId, deadline);

        vm.prank(alice);
        vm.expectRevert(CheckIn.ZeroAmount.selector);
        checkIn.checkIn(0, claimId, deadline, signature);
    }

    function test_signerRotation_oldSignerFails_newSignerSucceeds() public {
        uint256 amount = 10;
        uint256 deadline = block.timestamp + 1 days;

        vm.prank(owner);
        checkIn.setSigner(vm.addr(OTHER_SIGNER_PK));

        bytes memory oldSig = _signCheckIn(SIGNER_PK, alice, amount, 10, deadline);
        vm.prank(alice);
        vm.expectRevert(CheckIn.InvalidSignature.selector);
        checkIn.checkIn(amount, 10, deadline, oldSig);

        bytes memory newSig = _signCheckIn(OTHER_SIGNER_PK, alice, amount, 11, deadline);
        vm.prank(alice);
        checkIn.checkIn(amount, 11, deadline, newSig);
        assertEq(xpoint.balanceOf(alice), amount);
    }

    function test_pause_and_unpause() public {
        vm.prank(owner);
        checkIn.pause();
        assertTrue(checkIn.paused());

        vm.prank(owner);
        checkIn.unpause();
        assertFalse(checkIn.paused());
    }

    function test_RevertWhen_pause_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        checkIn.pause();
    }

    function test_setSigner_and_setXPoint_and_rescue() public {
        vm.prank(owner);
        checkIn.setSigner(vm.addr(OTHER_SIGNER_PK));
        assertEq(checkIn.signer(), vm.addr(OTHER_SIGNER_PK));

        XPoint another = _deployXPointProxy("XP2", "XP2", owner, operator, pauser, 0, false);
        vm.prank(owner);
        checkIn.setXPoint(address(another));
        assertEq(address(checkIn.xpoint()), address(another));

        deal(address(this), 1 ether);
        (bool sent,) = address(checkIn).call{value: 1 ether}("");
        assertTrue(sent);

        uint256 ownerEthBefore = owner.balance;
        vm.prank(owner);
        checkIn.rescueETH(payable(owner));
        assertEq(owner.balance, ownerEthBefore + 1 ether);
    }

    function test_xPointSwitch_requiresMinterRoleWiring() public {
        XPoint next = _deployXPointProxy("X Point 2", "XP2", owner, operator, pauser, 0, false);
        vm.prank(owner);
        checkIn.setXPoint(address(next));

        uint256 amount = 12;
        uint256 claimId = 12;
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signCheckIn(SIGNER_PK, alice, amount, claimId, deadline);

        vm.prank(alice);
        vm.expectRevert();
        checkIn.checkIn(amount, claimId, deadline, sig);

        bytes32 minterRole = next.MINTER_ROLE();
        vm.prank(owner);
        next.grantRole(minterRole, address(checkIn));

        vm.prank(alice);
        checkIn.checkIn(amount, claimId + 1, deadline, _signCheckIn(SIGNER_PK, alice, amount, claimId + 1, deadline));
        assertEq(next.balanceOf(alice), amount);
    }

    function test_nonReentrant_blocksNestedEntry() public {
        ReenteringXPointMock mock = new ReenteringXPointMock();
        vm.prank(owner);
        checkIn.setXPoint(address(mock));

        uint256 amount = 5;
        uint256 claimId = 100;
        uint256 deadline = block.timestamp + 1 days;
        bytes memory outerSig = _signCheckIn(SIGNER_PK, alice, amount, claimId, deadline);

        bytes memory nestedSig = _signCheckIn(SIGNER_PK, alice, amount, claimId + 1, deadline);
        bytes memory nestedCall = abi.encodeCall(CheckIn.checkIn, (amount, claimId + 1, deadline, nestedSig));
        mock.setReentry(address(checkIn), nestedCall);

        vm.prank(alice);
        checkIn.checkIn(amount, claimId, deadline, outerSig);

        assertTrue(mock.attempted());
        assertFalse(mock.nestedSucceeded());
        assertTrue(checkIn.isClaimed(claimId));
        assertFalse(checkIn.isClaimed(claimId + 1));
    }

    function test_upgrade_continuity() public {
        uint256 amount = 13;
        uint256 claimId = 77;
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signCheckIn(SIGNER_PK, alice, amount, claimId, deadline);

        vm.prank(alice);
        checkIn.checkIn(amount, claimId, deadline, sig);

        CheckInV2Mock impl = new CheckInV2Mock();
        vm.prank(owner);
        checkIn.upgradeToAndCall(address(impl), bytes(""));

        CheckInV2Mock upgraded = CheckInV2Mock(payable(address(checkIn)));
        assertEq(upgraded.version(), 2);
        assertEq(address(upgraded.xpoint()), address(xpoint));
        assertEq(upgraded.signer(), signer);
        assertTrue(upgraded.isClaimed(claimId));
    }
}
