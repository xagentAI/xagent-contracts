// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {UsageAttestation} from "../src/UsageAttestation.sol";

/// @custom:oz-upgrades-from src/UsageAttestation.sol:UsageAttestation
/// @custom:oz-upgrades-unsafe-allow missing-initializer
contract UsageAttestationV2Mock is UsageAttestation {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}

contract UsageAttestationTest is Test {
    bytes32 internal constant AGENT_ID = bytes32("x-agent");
    bytes32 internal constant MODEL_ID = bytes32("x-agent-llm");
    bytes32 internal constant REF_1 = bytes32("ref-1");
    bytes32 internal constant REF_2 = bytes32("ref-2");

    event UsageAttested(
        address indexed account,
        bytes32 indexed usageRef,
        bytes32 agentId,
        bytes32 modelId,
        uint256 inputTokens,
        uint256 outputTokens,
        uint8 basis
    );
    event ETHRescued(address indexed to, uint256 amount);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    struct Snapshot {
        uint256 count;
        uint256 input;
        uint256 output;
        uint256 lastAt;
    }

    UsageAttestation internal registry;

    address internal owner;
    address internal alice;
    address internal bob;

    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        UsageAttestation impl = new UsageAttestation();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(UsageAttestation.initialize, (owner)));
        registry = UsageAttestation(address(proxy));
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _attest(
        address account,
        uint256 inputTokens,
        uint256 outputTokens,
        bytes32 usageRef
    ) internal {
        vm.prank(account);
        registry.attestUsage(AGENT_ID, MODEL_ID, inputTokens, outputTokens, usageRef);
    }

    function _snapshot(
        address account
    ) internal view returns (Snapshot memory) {
        return Snapshot({
            count: registry.attestationCount(account),
            input: registry.totalInputTokens(account),
            output: registry.totalOutputTokens(account),
            lastAt: registry.lastAttestedAt(account)
        });
    }

    function _assertUnchanged(
        address account,
        Snapshot memory before
    ) internal view {
        Snapshot memory current = _snapshot(account);
        assertEq(current.count, before.count, "attestationCount changed");
        assertEq(current.input, before.input, "totalInputTokens changed");
        assertEq(current.output, before.output, "totalOutputTokens changed");
        assertEq(current.lastAt, before.lastAt, "lastAttestedAt changed");
    }

    // ---------------------------------------------------------------------
    // Initialization
    // ---------------------------------------------------------------------

    function test_initialize_setsOwnerAndUnpaused() public view {
        assertEq(registry.owner(), owner);
        assertEq(registry.pendingOwner(), address(0));
        assertFalse(registry.paused());
        assertEq(registry.BASIS_ESTIMATED(), 1);
    }

    function test_RevertWhen_initialize_Twice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        registry.initialize(alice);
    }

    function test_RevertWhen_initialize_Implementation() public {
        UsageAttestation impl = new UsageAttestation();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(alice);
    }

    function test_RevertWhen_initialize_ZeroOwner() public {
        UsageAttestation impl = new UsageAttestation();
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableInvalidOwner.selector, address(0)));
        new ERC1967Proxy(address(impl), abi.encodeCall(UsageAttestation.initialize, (address(0))));
    }

    // ---------------------------------------------------------------------
    // attestUsage: success
    // ---------------------------------------------------------------------

    function test_attestUsage_emitsEventWithEstimatedBasis() public {
        vm.expectEmit(true, true, true, true, address(registry));
        emit UsageAttested(alice, REF_1, AGENT_ID, MODEL_ID, 429, 860, 1);

        _attest(alice, 429, 860, REF_1);
    }

    function test_attestUsage_eventBasisIsAlwaysEstimated() public {
        vm.recordLogs();
        _attest(alice, 100, 200, REF_1);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(registry));
        assertEq(logs[0].topics[0], UsageAttestation.UsageAttested.selector);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(alice))));
        assertEq(logs[0].topics[2], REF_1);

        (bytes32 agentId, bytes32 modelId, uint256 inputTokens, uint256 outputTokens, uint8 basis) =
            abi.decode(logs[0].data, (bytes32, bytes32, uint256, uint256, uint8));
        assertEq(agentId, AGENT_ID);
        assertEq(modelId, MODEL_ID);
        assertEq(inputTokens, 100);
        assertEq(outputTokens, 200);
        assertEq(basis, registry.BASIS_ESTIMATED());
        assertEq(basis, 1);
    }

    function test_attestUsage_advancesCountersForSender() public {
        vm.warp(1_000_000);
        _attest(alice, 300, 70, REF_1);

        assertEq(registry.attestationCount(alice), 1);
        assertEq(registry.totalInputTokens(alice), 300);
        assertEq(registry.totalOutputTokens(alice), 70);
        assertEq(registry.lastAttestedAt(alice), 1_000_000);
        assertTrue(registry.isUsageRefUsed(alice, REF_1));

        vm.warp(1_000_500);
        _attest(alice, 1000, 1500, REF_2);

        assertEq(registry.attestationCount(alice), 2);
        assertEq(registry.totalInputTokens(alice), 1300);
        assertEq(registry.totalOutputTokens(alice), 1570);
        assertEq(registry.lastAttestedAt(alice), 1_000_500);
        assertTrue(registry.isUsageRefUsed(alice, REF_2));

        _assertUnchanged(bob, Snapshot(0, 0, 0, 0));
        assertFalse(registry.isUsageRefUsed(bob, REF_1));
    }

    function test_attestUsage_acceptsZeroInputTokens() public {
        _attest(alice, 0, 64, REF_1);

        assertEq(registry.attestationCount(alice), 1);
        assertEq(registry.totalInputTokens(alice), 0);
        assertEq(registry.totalOutputTokens(alice), 64);
    }

    function test_attestUsage_acceptsZeroOutputTokens() public {
        _attest(alice, 256, 0, REF_1);

        assertEq(registry.attestationCount(alice), 1);
        assertEq(registry.totalInputTokens(alice), 256);
        assertEq(registry.totalOutputTokens(alice), 0);
    }

    function test_attestUsage_acceptsIdenticalCountsWithDifferentRefs() public {
        _attest(alice, 500, 500, REF_1);
        _attest(alice, 500, 500, REF_2);

        assertEq(registry.attestationCount(alice), 2);
        assertEq(registry.totalInputTokens(alice), 1000);
        assertEq(registry.totalOutputTokens(alice), 1000);
    }

    function test_attestUsage_otherAccountMayReuseRef() public {
        _attest(alice, 400, 100, REF_1);

        vm.expectEmit(true, true, true, true, address(registry));
        emit UsageAttested(bob, REF_1, AGENT_ID, MODEL_ID, 900, 300, 1);
        _attest(bob, 900, 300, REF_1);

        assertEq(registry.attestationCount(bob), 1);
        assertEq(registry.totalInputTokens(bob), 900);
        assertTrue(registry.isUsageRefUsed(bob, REF_1));
        assertEq(registry.attestationCount(alice), 1);
        assertEq(registry.totalInputTokens(alice), 400);
    }

    // ---------------------------------------------------------------------
    // attestUsage: refusals leave counters unchanged
    // ---------------------------------------------------------------------

    function test_RevertWhen_attestUsage_SameAccountReusesRef() public {
        vm.warp(2_000_000);
        _attest(alice, 400, 100, REF_1);
        Snapshot memory before = _snapshot(alice);

        vm.warp(2_000_100);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UsageAttestation.UsageRefAlreadyUsed.selector, alice, REF_1));
        registry.attestUsage(AGENT_ID, MODEL_ID, 999, 999, REF_1);

        _assertUnchanged(alice, before);
    }

    function test_RevertWhen_attestUsage_ZeroUsageRef() public {
        _attest(alice, 400, 100, REF_1);
        Snapshot memory before = _snapshot(alice);

        vm.prank(alice);
        vm.expectRevert(UsageAttestation.ZeroUsageRef.selector);
        registry.attestUsage(AGENT_ID, MODEL_ID, 400, 100, bytes32(0));

        _assertUnchanged(alice, before);
        assertFalse(registry.isUsageRefUsed(alice, bytes32(0)));
    }

    function test_RevertWhen_attestUsage_BothTokenCountsZero() public {
        _attest(alice, 400, 100, REF_1);
        Snapshot memory before = _snapshot(alice);

        vm.prank(alice);
        vm.expectRevert(UsageAttestation.ZeroTokenCounts.selector);
        registry.attestUsage(AGENT_ID, MODEL_ID, 0, 0, REF_2);

        _assertUnchanged(alice, before);
        assertFalse(registry.isUsageRefUsed(alice, REF_2));
    }

    function test_RevertWhen_attestUsage_ZeroAgentId() public {
        _attest(alice, 400, 100, REF_1);
        Snapshot memory before = _snapshot(alice);

        vm.prank(alice);
        vm.expectRevert(UsageAttestation.ZeroAgentId.selector);
        registry.attestUsage(bytes32(0), MODEL_ID, 400, 100, REF_2);

        _assertUnchanged(alice, before);
        assertFalse(registry.isUsageRefUsed(alice, REF_2));
    }

    function test_RevertWhen_attestUsage_ZeroModelId() public {
        _attest(alice, 400, 100, REF_1);
        Snapshot memory before = _snapshot(alice);

        vm.prank(alice);
        vm.expectRevert(UsageAttestation.ZeroModelId.selector);
        registry.attestUsage(AGENT_ID, bytes32(0), 400, 100, REF_2);

        _assertUnchanged(alice, before);
        assertFalse(registry.isUsageRefUsed(alice, REF_2));
    }

    function test_RevertWhen_attestUsage_Paused() public {
        _attest(alice, 400, 100, REF_1);
        Snapshot memory before = _snapshot(alice);

        vm.prank(owner);
        registry.pause();

        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        registry.attestUsage(AGENT_ID, MODEL_ID, 400, 100, REF_2);

        _assertUnchanged(alice, before);
        assertFalse(registry.isUsageRefUsed(alice, REF_2));
    }

    // ---------------------------------------------------------------------
    // Pause
    // ---------------------------------------------------------------------

    function test_pause_and_unpause_restoresAttestations() public {
        vm.prank(owner);
        registry.pause();
        assertTrue(registry.paused());

        vm.prank(owner);
        registry.unpause();
        assertFalse(registry.paused());

        _attest(alice, 400, 100, REF_1);
        assertEq(registry.attestationCount(alice), 1);
    }

    function test_RevertWhen_pause_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        registry.pause();
    }

    function test_RevertWhen_unpause_NotOwner() public {
        vm.prank(owner);
        registry.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        registry.unpause();
    }

    // ---------------------------------------------------------------------
    // Ownership
    // ---------------------------------------------------------------------

    function test_transferOwnership_twoStep() public {
        vm.prank(owner);
        registry.transferOwnership(bob);
        assertEq(registry.owner(), owner);
        assertEq(registry.pendingOwner(), bob);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        registry.acceptOwnership();

        vm.prank(bob);
        registry.acceptOwnership();
        assertEq(registry.owner(), bob);
        assertEq(registry.pendingOwner(), address(0));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner));
        registry.pause();

        vm.prank(bob);
        registry.pause();
        assertTrue(registry.paused());
    }

    function test_RevertWhen_transferOwnership_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        registry.transferOwnership(alice);
    }

    function test_RevertWhen_renounceOwnership() public {
        vm.prank(owner);
        vm.expectRevert(UsageAttestation.RenounceDisabled.selector);
        registry.renounceOwnership();

        assertEq(registry.owner(), owner);
    }

    // ---------------------------------------------------------------------
    // Rescue
    // ---------------------------------------------------------------------

    function test_rejectsPlainETHTransfer() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool sent,) = address(registry).call{value: 1 ether}("");
        assertFalse(sent);
    }

    function test_rescueETH() public {
        vm.deal(address(registry), 1 ether);
        address payable to = payable(makeAddr("treasury"));

        vm.expectEmit(true, true, true, true, address(registry));
        emit ETHRescued(to, 0.4 ether);
        vm.prank(owner);
        registry.rescueETH(to, 0.4 ether);

        assertEq(to.balance, 0.4 ether);
        assertEq(address(registry).balance, 0.6 ether);
    }

    function test_RevertWhen_rescueETH_NotOwner() public {
        vm.deal(address(registry), 1 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        registry.rescueETH(payable(alice), 1 ether);
    }

    function test_RevertWhen_rescueETH_ZeroAddress() public {
        vm.deal(address(registry), 1 ether);

        vm.prank(owner);
        vm.expectRevert(UsageAttestation.ZeroAddress.selector);
        registry.rescueETH(payable(address(0)), 1 ether);
    }

    function test_RevertWhen_rescueETH_ExceedsBalance() public {
        vm.deal(address(registry), 1 ether);

        vm.prank(owner);
        vm.expectRevert();
        registry.rescueETH(payable(owner), 2 ether);
    }

    function test_rescueERC20() public {
        MockERC20 token = new MockERC20();
        token.mint(address(registry), 1000);
        address to = makeAddr("treasury");

        vm.expectEmit(true, true, true, true, address(registry));
        emit ERC20Rescued(address(token), to, 250);
        vm.prank(owner);
        registry.rescueERC20(address(token), to, 250);

        assertEq(token.balanceOf(to), 250);
        assertEq(token.balanceOf(address(registry)), 750);
    }

    function test_RevertWhen_rescueERC20_NotOwner() public {
        MockERC20 token = new MockERC20();
        token.mint(address(registry), 1000);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        registry.rescueERC20(address(token), alice, 1000);
    }

    function test_RevertWhen_rescueERC20_ZeroAddress() public {
        MockERC20 token = new MockERC20();
        token.mint(address(registry), 1000);

        vm.startPrank(owner);
        vm.expectRevert(UsageAttestation.ZeroAddress.selector);
        registry.rescueERC20(address(0), owner, 1000);

        vm.expectRevert(UsageAttestation.ZeroAddress.selector);
        registry.rescueERC20(address(token), address(0), 1000);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Upgrade
    // ---------------------------------------------------------------------

    function test_upgrade_byOwner_preservesState() public {
        vm.warp(3_000_000);
        _attest(alice, 400, 100, REF_1);
        _attest(bob, 900, 300, REF_1);
        vm.prank(owner);
        registry.transferOwnership(bob);

        UsageAttestationV2Mock impl = new UsageAttestationV2Mock();
        vm.prank(owner);
        registry.upgradeToAndCall(address(impl), bytes(""));

        UsageAttestationV2Mock upgraded = UsageAttestationV2Mock(address(registry));
        assertEq(upgraded.version(), 2);
        assertEq(upgraded.owner(), owner);
        assertEq(upgraded.pendingOwner(), bob);
        assertEq(upgraded.attestationCount(alice), 1);
        assertEq(upgraded.totalInputTokens(alice), 400);
        assertEq(upgraded.totalOutputTokens(alice), 100);
        assertEq(upgraded.lastAttestedAt(alice), 3_000_000);
        assertTrue(upgraded.isUsageRefUsed(alice, REF_1));
        assertEq(upgraded.totalInputTokens(bob), 900);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UsageAttestation.UsageRefAlreadyUsed.selector, alice, REF_1));
        upgraded.attestUsage(AGENT_ID, MODEL_ID, 1, 1, REF_1);

        _attest(alice, 1, 1, REF_2);
        assertEq(upgraded.attestationCount(alice), 2);
    }

    function test_RevertWhen_upgrade_NotOwner() public {
        UsageAttestationV2Mock impl = new UsageAttestationV2Mock();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        registry.upgradeToAndCall(address(impl), bytes(""));
    }

    // ---------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------

    function testFuzz_attestUsage_accumulatesAndRefusesReplay(
        address account,
        bytes32 agentId,
        bytes32 modelId,
        uint128 input1,
        uint128 output1,
        uint128 input2,
        uint128 output2,
        bytes32 ref1,
        bytes32 ref2
    ) public {
        vm.assume(agentId != bytes32(0) && modelId != bytes32(0));
        vm.assume(ref1 != bytes32(0) && ref2 != bytes32(0) && ref1 != ref2);
        if (input1 == 0 && output1 == 0) output1 = 1;
        if (input2 == 0 && output2 == 0) input2 = 1;

        vm.expectEmit(true, true, true, true, address(registry));
        emit UsageAttested(account, ref1, agentId, modelId, input1, output1, 1);
        vm.prank(account);
        registry.attestUsage(agentId, modelId, input1, output1, ref1);

        vm.prank(account);
        registry.attestUsage(agentId, modelId, input2, output2, ref2);

        assertEq(registry.attestationCount(account), 2);
        assertEq(registry.totalInputTokens(account), uint256(input1) + input2);
        assertEq(registry.totalOutputTokens(account), uint256(output1) + output2);
        assertEq(registry.lastAttestedAt(account), block.timestamp);
        assertTrue(registry.isUsageRefUsed(account, ref1));
        assertTrue(registry.isUsageRefUsed(account, ref2));

        Snapshot memory before = _snapshot(account);
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(UsageAttestation.UsageRefAlreadyUsed.selector, account, ref1));
        registry.attestUsage(agentId, modelId, input1, output1, ref1);
        _assertUnchanged(account, before);
    }

    function testFuzz_RevertWhen_attestUsage_BothTokenCountsZero(
        address account,
        bytes32 usageRef
    ) public {
        vm.assume(usageRef != bytes32(0));

        vm.prank(account);
        vm.expectRevert(UsageAttestation.ZeroTokenCounts.selector);
        registry.attestUsage(AGENT_ID, MODEL_ID, 0, 0, usageRef);

        _assertUnchanged(account, Snapshot(0, 0, 0, 0));
        assertFalse(registry.isUsageRefUsed(account, usageRef));
    }
}
