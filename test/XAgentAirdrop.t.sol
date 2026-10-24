// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {XAgentAirdrop} from "../src/XAgentAirdrop.sol";
import {IAllowanceModule} from "../src/interfaces/IAllowanceModule.sol";
import {SafeMainnetArtifacts} from "./helpers/SafeMainnetArtifacts.sol";

interface ISafeProxyFactory {
    function createProxyWithNonce(
        address singleton,
        bytes memory initializer,
        uint256 saltNonce
    ) external returns (address proxy);
}

interface ISafe150 {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;

    function nonce() external view returns (uint256);

    function isModuleEnabled(
        address module
    ) external view returns (bool);

    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 nonce_
    ) external view returns (bytes32);

    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool success);
}

interface IAllowanceModuleAdmin is IAllowanceModule {
    function addDelegate(
        address delegate
    ) external;

    function setAllowance(
        address delegate,
        address token,
        uint96 allowanceAmount,
        uint16 resetTimeMin,
        uint32 resetBaseMin
    ) external;
}

interface IMultiSendCallOnly {
    function multiSend(
        bytes memory transactions
    ) external payable;
}

contract MockAirdropERC20 is ERC20 {
    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}

/// @dev USDT-style token whose `transfer` does not return a boolean.
contract NoBoolERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(
        address to,
        uint256 amount
    ) external {
        balanceOf[to] += amount;
    }

    function transfer(
        address to,
        uint256 amount
    ) external {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev Stateful handler that drives `XAgentAirdrop` through real `Safe` + `AllowanceModule` bytecode
/// across multiple allowance windows for invariant testing: Claims (with automatic refills), permissionless
/// refills, and Treasury Safe float returns.
contract AirdropHandler is Test {
    XAgentAirdrop public immutable AIRDROP;
    address public immutable SAFE;
    IERC20 public immutable TOKEN;
    uint256 public immutable SIGNER_PK;
    uint256 public immutable PERIOD_SECONDS;
    uint256 public immutable BASE_TIMESTAMP;

    uint256 public nextClaimId = 1;
    uint256 public currentWindowIndex;
    uint256 public currentWindowPulled;
    uint256 public currentWindowPaid;
    uint256 public maxWindowPulled;
    uint256 public maxWindowPaid;
    uint256 public totalPulled;
    uint256 public totalPaid;
    uint256 public totalReturned;
    uint256 public claimsSucceeded;
    uint256 public refillsSucceeded;

    constructor(
        XAgentAirdrop airdrop_,
        address safe_,
        IERC20 token_,
        uint256 signerPk_,
        uint256 periodSeconds_,
        uint256 initialPulled_
    ) {
        AIRDROP = airdrop_;
        SAFE = safe_;
        TOKEN = token_;
        SIGNER_PK = signerPk_;
        PERIOD_SECONDS = periodSeconds_;
        BASE_TIMESTAMP = vm.getBlockTimestamp();
        currentWindowPulled = initialPulled_;
        maxWindowPulled = initialPulled_;
        totalPulled = initialPulled_;
    }

    function claim(
        uint256 claimantSeed,
        uint256 grossRaw
    ) external {
        _rollWindowIfNeeded();

        address claimant = vm.addr((claimantSeed % 50) + 100);
        uint256 gross = bound(grossRaw, 1000, AIRDROP.maxClaimAmount(address(TOKEN)));
        (uint256 fee, uint256 net) = AIRDROP.quoteFee(address(TOKEN), gross);
        uint256 claimId = nextClaimId++;
        uint256 deadline = vm.getBlockTimestamp() + 30 minutes;

        bytes32 digest = AIRDROP.hashClaim(claimant, address(TOKEN), gross, fee, claimId, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        uint256 safeBefore = TOKEN.balanceOf(SAFE);
        uint256 claimantBefore = TOKEN.balanceOf(claimant);
        vm.prank(claimant);
        try AIRDROP.claim(address(TOKEN), gross, fee, claimId, deadline, payable(claimant), sig) {
            assertEq(TOKEN.balanceOf(claimant) - claimantBefore, net);
            _recordPull(safeBefore - TOKEN.balanceOf(SAFE));
            _recordPaid(net);
            claimsSucceeded++;
        } catch {}
    }

    function refill(
        uint256 callerSeed
    ) external {
        _rollWindowIfNeeded();

        uint256 safeBefore = TOKEN.balanceOf(SAFE);
        vm.prank(vm.addr((callerSeed % 50) + 100));
        try AIRDROP.refill(address(TOKEN)) returns (uint256 pulled) {
            assertEq(safeBefore - TOKEN.balanceOf(SAFE), pulled);
            _recordPull(pulled);
            refillsSucceeded++;
        } catch {}
    }

    function returnToSafe(
        uint256 amountRaw
    ) external {
        uint256 balance = TOKEN.balanceOf(address(AIRDROP));
        if (balance == 0) return;
        uint256 amount = bound(amountRaw, 1, balance);
        vm.prank(SAFE);
        AIRDROP.returnToSafe(address(TOKEN), amount);
        totalReturned += amount;
    }

    function warpMinutes(
        uint256 minutesRaw
    ) external {
        uint256 delta = bound(minutesRaw, 1, 3000) * 1 minutes;
        // Keep `block.timestamp / 60` well within AllowanceModule's `uint32` minute counter (~8,171 years).
        if (vm.getBlockTimestamp() + delta < 200_000_000_000) {
            vm.warp(vm.getBlockTimestamp() + delta);
        }
        _rollWindowIfNeeded();
    }

    function _recordPull(
        uint256 amount
    ) private {
        totalPulled += amount;
        currentWindowPulled += amount;
        if (currentWindowPulled > maxWindowPulled) maxWindowPulled = currentWindowPulled;
    }

    function _recordPaid(
        uint256 amount
    ) private {
        totalPaid += amount;
        currentWindowPaid += amount;
        if (currentWindowPaid > maxWindowPaid) maxWindowPaid = currentWindowPaid;
    }

    function _rollWindowIfNeeded() private {
        uint256 idx = (vm.getBlockTimestamp() - BASE_TIMESTAMP) / PERIOD_SECONDS;
        if (idx != currentWindowIndex) {
            currentWindowIndex = idx;
            currentWindowPulled = 0;
            currentWindowPaid = 0;
        }
    }
}

contract XAgentAirdropTest is Test {
    uint8 internal constant SAFE_OP_CALL = 0;
    uint8 internal constant SAFE_OP_DELEGATECALL = 1;

    uint256 internal constant OWNER1_PK = 0xA11CE01;
    uint256 internal constant OWNER2_PK = 0xA11CE02;
    uint256 internal constant OWNER3_PK = 0xA11CE03;
    uint256 internal constant SIGNER_PK = 0xB0B01;
    uint256 internal constant ROTATED_SIGNER_PK = 0xB0B02;

    uint256 internal constant FEE_BPS = 100; // 1%
    uint256 internal constant PER_CLAIM_CAP = 5000 ether;
    uint256 internal constant FLOAT_TARGET = 10_000 ether;
    uint96 internal constant PERIOD_ALLOWANCE = 20_000 ether;
    uint16 internal constant RESET_TIME_MIN = 1440; // 24 hours
    uint256 internal constant INITIAL_TREASURY = 1_000_000 ether;

    address internal owner1;
    address internal owner2;
    address internal owner3;
    address internal signer;
    address internal rotatedSigner;
    address internal guardian;
    address internal alice;
    address internal bob;

    ISafe150 internal safe;
    IAllowanceModuleAdmin internal allowanceModule;
    MockAirdropERC20 internal uxlink;
    MockAirdropERC20 internal usdc;
    XAgentAirdrop internal airdrop;
    AirdropHandler internal handler;

    function setUp() public {
        // Align timestamp to an exact 24h boundary so AllowanceModule reset windows are deterministic.
        vm.warp(1_760_000_640); // divisible by 86,400 (29,333,344 minutes)

        owner1 = vm.addr(OWNER1_PK);
        owner2 = vm.addr(OWNER2_PK);
        owner3 = vm.addr(OWNER3_PK);
        signer = vm.addr(SIGNER_PK);
        rotatedSigner = vm.addr(ROTATED_SIGNER_PK);
        guardian = makeAddr("guardian");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Etch canonical Safe v1.5.0 and AllowanceModule v1.0.0 runtime bytecodes at their real mainnet addresses.
        vm.etch(SafeMainnetArtifacts.SAFE_SINGLETON, SafeMainnetArtifacts.SAFE_SINGLETON_CODE);
        vm.etch(SafeMainnetArtifacts.SAFE_PROXY_FACTORY, SafeMainnetArtifacts.SAFE_PROXY_FACTORY_CODE);
        vm.etch(SafeMainnetArtifacts.MULTI_SEND_CALL_ONLY, SafeMainnetArtifacts.MULTI_SEND_CALL_ONLY_CODE);
        vm.etch(SafeMainnetArtifacts.ALLOWANCE_MODULE, SafeMainnetArtifacts.ALLOWANCE_MODULE_CODE);

        allowanceModule = IAllowanceModuleAdmin(SafeMainnetArtifacts.ALLOWANCE_MODULE);
        safe = _deploy2Of3Safe();

        uxlink = new MockAirdropERC20("UXLINK", "UXLINK");
        usdc = new MockAirdropERC20("USD Coin", "USDC");
        uxlink.mint(address(safe), INITIAL_TREASURY);
        usdc.mint(address(safe), INITIAL_TREASURY);

        airdrop = new XAgentAirdrop(address(safe), address(allowanceModule), signer, guardian);

        // Configure Safe + AllowanceModule + XAgentAirdrop via a single MultiSendCallOnly Safe transaction.
        _execSafeMultiSend(
            _tokenSetupBatch(address(uxlink), PERIOD_ALLOWANCE, PER_CLAIM_CAP, FEE_BPS, FLOAT_TARGET, true)
        );

        // Seed the Claim Float (first AllowanceModule transfer: nonce 1 -> 2).
        assertEq(airdrop.refill(address(uxlink)), FLOAT_TARGET);

        handler =
            new AirdropHandler(airdrop, address(safe), uxlink, SIGNER_PK, uint256(RESET_TIME_MIN) * 60, FLOAT_TARGET);
        targetContract(address(handler));
    }

    // ---------------------------------------------------------------------
    // Constructor & EIP-712 metadata
    // ---------------------------------------------------------------------

    function test_constructor_setsImmutablesAndInitialState() public view {
        assertEq(airdrop.SAFE(), address(safe));
        assertEq(address(airdrop.ALLOWANCE_MODULE()), address(allowanceModule));
        assertEq(airdrop.FEE_BPS_LIMIT(), 2000);
        assertEq(airdrop.signer(), signer);
        assertEq(airdrop.guardian(), guardian);
        assertEq(airdrop.epoch(), 0);
        assertEq(airdrop.maxClaimAmount(address(uxlink)), PER_CLAIM_CAP);
        assertEq(airdrop.feeBps(address(uxlink)), FEE_BPS);
        assertEq(airdrop.floatTarget(address(uxlink)), FLOAT_TARGET);
        assertTrue(safe.isModuleEnabled(address(allowanceModule)));
        assertFalse(safe.isModuleEnabled(address(airdrop)));

        assertEq(uxlink.balanceOf(address(airdrop)), FLOAT_TARGET);
        assertEq(uxlink.balanceOf(address(safe)), INITIAL_TREASURY - FLOAT_TARGET);
        uint256[5] memory allowance = _allowance(address(uxlink));
        assertEq(allowance[1], FLOAT_TARGET);
        assertEq(allowance[4], 2);

        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            airdrop.eip712Domain();
        assertEq(name, "XAgentAirdrop");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(airdrop));
    }

    function test_hashClaim_matchesIndependentEip712Encoding() public view {
        bytes32 typehash = keccak256(
            "Claim(address claimant,address token,uint256 amount,uint256 fee,uint256 claimId,uint256 epoch,uint256 deadline)"
        );
        assertEq(airdrop.CLAIM_TYPEHASH(), typehash);

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("XAgentAirdrop"),
                keccak256("1"),
                block.chainid,
                address(airdrop)
            )
        );
        bytes32 structHash =
            keccak256(abi.encode(typehash, alice, address(uxlink), 7 ether, 1 ether, 42, 0, 1_900_000_000));
        assertEq(
            airdrop.hashClaim(alice, address(uxlink), 7 ether, 1 ether, 42, 1_900_000_000),
            keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash))
        );
    }

    /// Must stay identical to xerpaai-go `TestClaimDigestMatchesSepoliaHashClaim`.
    function test_hashClaim_matchesBackendGoldenVector() public {
        address verifyingContract = 0xC06f2e4757c3298BDFd929d25773D3c9Dd62F216;
        vm.chainId(11_155_111);
        vm.etch(verifyingContract, address(airdrop).code);

        bytes32 digest = XAgentAirdrop(verifyingContract)
            .hashClaim(
                0x1111111111111111111111111111111111111111,
                0xe2D6b2366733CcA24355e91e0679F0988D410f52,
                1_234_500_000_000_000_000_000,
                12_345_000_000_000_000_000,
                18_446_744_073_709_551_621, // ClaimId(round 1, seq 5)
                1_800_000_000
            );
        assertEq(digest, 0xb695eddb584c86747a2f99c3d0b0f20d774f5c413391a53dff8a5787d5a058f1);
    }

    function test_RevertWhen_constructor_InvalidArgs() public {
        vm.expectRevert(XAgentAirdrop.ZeroAddress.selector);
        new XAgentAirdrop(address(0), address(allowanceModule), signer, guardian);

        vm.expectRevert(XAgentAirdrop.ZeroAddress.selector);
        new XAgentAirdrop(address(safe), address(0), signer, guardian);

        vm.expectRevert(XAgentAirdrop.ZeroAddress.selector);
        new XAgentAirdrop(address(safe), address(allowanceModule), address(0), guardian);

        // Guardian may be address(0).
        vm.expectEmit(true, true, true, true);
        emit XAgentAirdrop.SignerUpdated(address(0), signer);
        vm.expectEmit(true, true, true, true);
        emit XAgentAirdrop.GuardianUpdated(address(0), address(0));
        XAgentAirdrop noGuardian = new XAgentAirdrop(address(safe), address(allowanceModule), signer, address(0));
        assertEq(noGuardian.guardian(), address(0));
    }

    // ---------------------------------------------------------------------
    // Self-service claims: float payouts, automatic refill, multi-token
    // ---------------------------------------------------------------------

    function test_claim_paysFromFloat_withoutAllowanceTransfer() public {
        uint256 gross = 1000 ether;
        uint256 fee = 10 ether; // 1%
        uint256 net = gross - fee;
        uint256 deadline = vm.getBlockTimestamp() + 30 minutes;
        bytes memory sig = _signClaim(SIGNER_PK, alice, address(uxlink), gross, fee, 101, deadline);

        vm.expectEmit(true, true, true, true, address(airdrop));
        emit XAgentAirdrop.Claimed(101, alice, alice, address(uxlink), gross, fee, net);

        vm.prank(alice);
        airdrop.claim(address(uxlink), gross, fee, 101, deadline, payable(alice), sig);

        assertTrue(airdrop.isClaimed(101));
        assertEq(uxlink.balanceOf(alice), net);
        assertEq(uxlink.balanceOf(address(airdrop)), FLOAT_TARGET - net);
        // The fee never leaves the Treasury Safe and the claim consumed no AllowanceModule transfer.
        assertEq(uxlink.balanceOf(address(safe)), INITIAL_TREASURY - FLOAT_TARGET);
        uint256[5] memory allowance = _allowance(address(uxlink));
        assertEq(allowance[1], FLOAT_TARGET);
        assertEq(allowance[4], 2);
    }

    function test_claim_toCustomRecipient_andZeroFeeRate() public {
        _execSafeCall(
            address(airdrop),
            abi.encodeCall(XAgentAirdrop.configureToken, (address(uxlink), PER_CLAIM_CAP, 0, FLOAT_TARGET))
        );

        uint256 gross = 500 ether;
        uint256 deadline = vm.getBlockTimestamp() + 30 minutes;
        bytes memory sig = _signClaim(SIGNER_PK, alice, address(uxlink), gross, 0, 102, deadline);

        // Signature binds `alice` as claimant; `alice` chooses `bob` as recipient at call time.
        vm.prank(alice);
        airdrop.claim(address(uxlink), gross, 0, 102, deadline, payable(bob), sig);

        assertEq(uxlink.balanceOf(alice), 0);
        assertEq(uxlink.balanceOf(bob), gross);
    }

    function test_claim_succeedsAtExactDeadline() public {
        uint256 deadline = vm.getBlockTimestamp();
        bytes memory sig = _signClaim(SIGNER_PK, alice, address(uxlink), 1000 ether, 10 ether, 103, deadline);
        vm.prank(alice);
        airdrop.claim(address(uxlink), 1000 ether, 10 ether, 103, deadline, payable(alice), sig);
        assertEq(uxlink.balanceOf(alice), 990 ether);
    }

    function test_claim_autoRefillsWhenFloatCannotCover() public {
        uint256 deadline = vm.getBlockTimestamp() + 30 minutes;
        _claimAs(alice, PER_CLAIM_CAP, 111, deadline);
        _claimAs(alice, PER_CLAIM_CAP, 112, deadline);
        assertEq(uxlink.balanceOf(address(airdrop)), 100 ether);

        // 100 left < 990 net: the claim tops the float back up to its target (9,900 pulled), then pays.
        bytes memory sig = _signClaim(SIGNER_PK, alice, address(uxlink), 1000 ether, 10 ether, 113, deadline);
        vm.expectEmit(true, true, true, true, address(airdrop));
        emit XAgentAirdrop.FloatRefilled(address(uxlink), 9900 ether, FLOAT_TARGET, alice);
        vm.prank(alice);
        airdrop.claim(address(uxlink), 1000 ether, 10 ether, 113, deadline, payable(alice), sig);

        assertEq(uxlink.balanceOf(address(airdrop)), FLOAT_TARGET - 990 ether);
        uint256[5] memory allowance = _allowance(address(uxlink));
        assertEq(allowance[1], FLOAT_TARGET + 9900 ether);
        assertEq(allowance[4], 3);
    }

    function test_claim_whenFloatPlusCappedRefillExactlyCoversNet() public {
        _execSafeCall(address(airdrop), abi.encodeCall(XAgentAirdrop.returnToSafe, (address(uxlink), 9050 ether)));
        _execSafeCall(
            address(allowanceModule),
            abi.encodeCall(
                IAllowanceModuleAdmin.setAllowance, (address(airdrop), address(uxlink), 14_000 ether, RESET_TIME_MIN, 0)
            )
        );

        // Float 950 + remaining allowance 4,000 == net 4,950: the claim empties the float exactly.
        bytes memory sig = _signClaim(
            SIGNER_PK, alice, address(uxlink), PER_CLAIM_CAP, 50 ether, 114, vm.getBlockTimestamp() + 30 minutes
        );
        vm.expectEmit(true, true, true, true, address(airdrop));
        emit XAgentAirdrop.FloatRefilled(address(uxlink), 4000 ether, 4950 ether, alice);
        vm.prank(alice);
        airdrop.claim(
            address(uxlink), PER_CLAIM_CAP, 50 ether, 114, vm.getBlockTimestamp() + 30 minutes, payable(alice), sig
        );

        assertEq(uxlink.balanceOf(alice), 4950 ether);
        assertEq(uxlink.balanceOf(address(airdrop)), 0);
        assertEq(_allowance(address(uxlink))[1], 14_000 ether);
    }

    function test_RevertWhen_claim_floatAndAllowanceExhausted_thenResetsNextPeriod() public {
        uint256 deadline = vm.getBlockTimestamp() + 2 days;
        // 4 claims of 5,000 (net 4,950) drain the 10,000 float plus the remaining 10,000 of the Period Allowance.
        for (uint256 i = 1; i <= 4; i++) {
            _claimAs(alice, PER_CLAIM_CAP, 500 + i, deadline);
        }
        assertEq(uxlink.balanceOf(alice), 19_800 ether);
        assertEq(uxlink.balanceOf(address(airdrop)), 100 ether);
        assertEq(_allowance(address(uxlink))[1], PERIOD_ALLOWANCE - 100 ether);

        // 5th claim: the float (100) plus what is left of the allowance (100) cannot cover 4,950.
        bytes memory sig5 = _signClaim(SIGNER_PK, alice, address(uxlink), PER_CLAIM_CAP, 50 ether, 505, deadline);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(XAgentAirdrop.InsufficientFloat.selector, 4950 ether, 200 ether));
        airdrop.claim(address(uxlink), PER_CLAIM_CAP, 50 ether, 505, deadline, payable(alice), sig5);
        assertFalse(airdrop.isClaimed(505));

        // Warp 24 hours: AllowanceModule resets `spent` and the same signature succeeds.
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.prank(alice);
        airdrop.claim(address(uxlink), PER_CLAIM_CAP, 50 ether, 505, deadline, payable(alice), sig5);
        assertTrue(airdrop.isClaimed(505));
        assertEq(uxlink.balanceOf(alice), 24_750 ether);
        assertEq(uxlink.balanceOf(address(airdrop)), FLOAT_TARGET - 4950 ether);
    }

    function test_RevertWhen_claim_treasurySafeUnderfunded_rollsBackNonce() public {
        MockAirdropERC20 low = new MockAirdropERC20("Low", "LOW");
        low.mint(address(safe), 300 ether);
        _execSafeMultiSend(_tokenSetupBatch(address(low), PERIOD_ALLOWANCE, 1000 ether, FEE_BPS, 5000 ether, false));

        // The automatic refill asks for 5,000 but the Safe holds 300: the module transfer and the claim revert.
        uint256 deadline = vm.getBlockTimestamp() + 30 minutes;
        bytes memory sig = _signClaim(SIGNER_PK, alice, address(low), 200 ether, 2 ether, 801, deadline);
        vm.prank(alice);
        vm.expectRevert(bytes("Could not execute token transfer"));
        airdrop.claim(address(low), 200 ether, 2 ether, 801, deadline, payable(alice), sig);

        assertFalse(airdrop.isClaimed(801));
        uint256[5] memory allowance = _allowance(address(low));
        assertEq(allowance[1], 0);
        assertEq(allowance[4], 1);

        // Tail-end handling: lowering the Float Target to the remaining Safe balance lets the same claim through.
        _execSafeCall(
            address(airdrop),
            abi.encodeCall(XAgentAirdrop.configureToken, (address(low), 300 ether, FEE_BPS, 300 ether))
        );
        vm.prank(alice);
        airdrop.claim(address(low), 200 ether, 2 ether, 801, deadline, payable(alice), sig);
        assertEq(low.balanceOf(alice), 198 ether);
        assertEq(low.balanceOf(address(airdrop)), 102 ether);
        assertEq(low.balanceOf(address(safe)), 0);
    }

    function test_claim_supportsSecondTokenAndNoBoolToken() public {
        NoBoolERC20 usdt = new NoBoolERC20();
        usdt.mint(address(safe), 50_000 ether);

        bytes memory batch = abi.encodePacked(
            _tokenSetupBatch(address(usdc), 5000 ether, 1000 ether, FEE_BPS, 2000 ether, false),
            _tokenSetupBatch(address(usdt), 5000 ether, 1000 ether, FEE_BPS, 2000 ether, false)
        );
        _execSafeMultiSend(batch);

        // Each token's first claim seeds its float through an automatic refill.
        uint256 deadline = vm.getBlockTimestamp() + 30 minutes;
        bytes memory sigUsdc = _signClaim(SIGNER_PK, alice, address(usdc), 200 ether, 2 ether, 201, deadline);
        vm.prank(alice);
        airdrop.claim(address(usdc), 200 ether, 2 ether, 201, deadline, payable(alice), sigUsdc);
        assertEq(usdc.balanceOf(alice), 198 ether);
        assertEq(usdc.balanceOf(address(airdrop)), 1802 ether);
        assertEq(_allowance(address(usdc))[4], 2);

        bytes memory sigUsdt = _signClaim(SIGNER_PK, alice, address(usdt), 300 ether, 3 ether, 202, deadline);
        vm.prank(alice);
        airdrop.claim(address(usdt), 300 ether, 3 ether, 202, deadline, payable(alice), sigUsdt);
        assertEq(usdt.balanceOf(alice), 297 ether);
        assertEq(usdt.balanceOf(address(airdrop)), 1703 ether);
    }

    // ---------------------------------------------------------------------
    // Fee Rate
    // ---------------------------------------------------------------------

    function test_RevertWhen_claim_FeeMismatch() public {
        uint256 deadline = vm.getBlockTimestamp() + 30 minutes;

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(XAgentAirdrop.FeeMismatch.selector, 10 ether - 1, 10 ether));
        airdrop.claim(address(uxlink), 1000 ether, 10 ether - 1, 401, deadline, payable(alice), "");

        vm.expectRevert(abi.encodeWithSelector(XAgentAirdrop.FeeMismatch.selector, 10 ether + 1, 10 ether));
        airdrop.claim(address(uxlink), 1000 ether, 10 ether + 1, 401, deadline, payable(alice), "");

        // The fee rounds down: 99 wei at 1% carries no fee.
        vm.expectRevert(abi.encodeWithSelector(XAgentAirdrop.FeeMismatch.selector, 1, 0));
        airdrop.claim(address(uxlink), 99, 1, 401, deadline, payable(alice), "");
        vm.stopPrank();
    }

    function test_feeRateChange_invalidatesOutstandingSignature() public {
        uint256 deadline = vm.getBlockTimestamp() + 30 minutes;
        bytes memory oldSig = _signClaim(SIGNER_PK, alice, address(uxlink), 1000 ether, 10 ether, 402, deadline);

        _execSafeCall(
            address(airdrop),
            abi.encodeCall(XAgentAirdrop.configureToken, (address(uxlink), PER_CLAIM_CAP, 200, FLOAT_TARGET))
        );

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(XAgentAirdrop.FeeMismatch.selector, 10 ether, 20 ether));
        airdrop.claim(address(uxlink), 1000 ether, 10 ether, 402, deadline, payable(alice), oldSig);

        bytes memory newSig = _signClaim(SIGNER_PK, alice, address(uxlink), 1000 ether, 20 ether, 402, deadline);
        vm.prank(alice);
        airdrop.claim(address(uxlink), 1000 ether, 20 ether, 402, deadline, payable(alice), newSig);
        assertEq(uxlink.balanceOf(alice), 980 ether);
    }

    function test_configureToken_feeBpsBounds() public {
        vm.startPrank(address(safe));

        airdrop.configureToken(address(uxlink), PER_CLAIM_CAP, 0, FLOAT_TARGET);
        assertEq(airdrop.feeBps(address(uxlink)), 0);

        vm.expectEmit(true, true, true, true, address(airdrop));
        emit XAgentAirdrop.TokenConfigured(address(uxlink), PER_CLAIM_CAP, 2000, FLOAT_TARGET);
        airdrop.configureToken(address(uxlink), PER_CLAIM_CAP, 2000, FLOAT_TARGET);
        assertEq(airdrop.feeBps(address(uxlink)), 2000);

        vm.expectRevert(abi.encodeWithSelector(XAgentAirdrop.FeeBpsTooHigh.selector, 2001, 2000));
        airdrop.configureToken(address(uxlink), PER_CLAIM_CAP, 2001, FLOAT_TARGET);

        vm.stopPrank();

        // The 20% ceiling applies end to end.
        uint256 deadline = vm.getBlockTimestamp() + 30 minutes;
        bytes memory sig = _signClaim(SIGNER_PK, alice, address(uxlink), 1000 ether, 200 ether, 403, deadline);
        vm.prank(alice);
        airdrop.claim(address(uxlink), 1000 ether, 200 ether, 403, deadline, payable(alice), sig);
        assertEq(uxlink.balanceOf(alice), 800 ether);
    }

    function test_quoteFee() public view {
        (uint256 fee, uint256 net) = airdrop.quoteFee(address(uxlink), 1000 ether);
        assertEq(fee, 10 ether);
        assertEq(net, 990 ether);

        (fee, net) = airdrop.quoteFee(address(uxlink), 99);
        assertEq(fee, 0);
        assertEq(net, 99);

        // Unconfigured tokens carry no fee.
        (fee, net) = airdrop.quoteFee(address(usdc), 1000 ether);
        assertEq(fee, 0);
        assertEq(net, 1000 ether);
    }

    function testFuzz_quoteFee_feePlusNetEqualsAmount(
        uint96 amount,
        uint16 bpsRaw
    ) public {
        uint256 bps = bound(uint256(bpsRaw), 0, airdrop.FEE_BPS_LIMIT());
        vm.prank(address(safe));
        airdrop.configureToken(address(uxlink), PER_CLAIM_CAP, bps, FLOAT_TARGET);

        (uint256 fee, uint256 net) = airdrop.quoteFee(address(uxlink), amount);
        assertEq(fee, (uint256(amount) * bps) / 10_000);
        assertEq(fee + net, amount);
        if (amount > 0) assertGt(net, 0);
    }

    // ---------------------------------------------------------------------
    // configureToken bounds
    // ---------------------------------------------------------------------

    function test_RevertWhen_configureToken_InvalidArgs() public {
        vm.startPrank(address(safe));

        vm.expectRevert(XAgentAirdrop.ZeroAddress.selector);
        airdrop.configureToken(address(0), PER_CLAIM_CAP, FEE_BPS, FLOAT_TARGET);

        // A disabled token cannot keep a Float Target.
        vm.expectRevert(abi.encodeWithSelector(XAgentAirdrop.InvalidFloatTarget.selector, 1, 0));
        airdrop.configureToken(address(uxlink), 0, FEE_BPS, 1);

        // The float must cover at least one maximum Claim.
        vm.expectRevert(
            abi.encodeWithSelector(XAgentAirdrop.InvalidFloatTarget.selector, PER_CLAIM_CAP - 1, PER_CLAIM_CAP)
        );
        airdrop.configureToken(address(uxlink), PER_CLAIM_CAP, FEE_BPS, PER_CLAIM_CAP - 1);

        // A refill must fit a single AllowanceModule `uint96` transfer.
        uint256 huge = uint256(type(uint96).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(XAgentAirdrop.InvalidFloatTarget.selector, huge, PER_CLAIM_CAP));
        airdrop.configureToken(address(uxlink), PER_CLAIM_CAP, FEE_BPS, huge);

        // Boundary values are accepted.
        airdrop.configureToken(address(uxlink), PER_CLAIM_CAP, FEE_BPS, PER_CLAIM_CAP);
        airdrop.configureToken(address(uxlink), PER_CLAIM_CAP, FEE_BPS, type(uint96).max);

        vm.stopPrank();

        vm.prank(guardian);
        vm.expectRevert(XAgentAirdrop.OnlySafe.selector);
        airdrop.configureToken(address(uxlink), PER_CLAIM_CAP, FEE_BPS, FLOAT_TARGET);

        vm.prank(alice);
        vm.expectRevert(XAgentAirdrop.OnlySafe.selector);
        airdrop.configureToken(address(uxlink), PER_CLAIM_CAP, FEE_BPS, FLOAT_TARGET);
    }

    function test_configureToken_disableKeepsFeeRateForManualSettlement() public {
        _execSafeCall(address(airdrop), abi.encodeCall(XAgentAirdrop.configureToken, (address(uxlink), 0, FEE_BPS, 0)));

        uint256 deadline = vm.getBlockTimestamp() + 30 minutes;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(XAgentAirdrop.TokenNotEnabled.selector, address(uxlink)));
        airdrop.claim(address(uxlink), 100 ether, 1 ether, 404, deadline, payable(alice), "");

        vm.expectRevert(abi.encodeWithSelector(XAgentAirdrop.TokenNotEnabled.selector, address(uxlink)));
        airdrop.refill(address(uxlink));

        vm.startPrank(address(safe));
        vm.expectRevert(abi.encodeWithSelector(XAgentAirdrop.FeeExceedsMax.selector, 501 ether, 500 ether));
        airdrop.settleManualClaim(404, alice, bob, address(uxlink), 50_000 ether, 501 ether);
        airdrop.settleManualClaim(404, alice, bob, address(uxlink), 50_000 ether, 500 ether);
        vm.stopPrank();
        assertTrue(airdrop.isClaimed(404));
    }

    // ---------------------------------------------------------------------
    // refill
    // ---------------------------------------------------------------------

    function test_refill_onlyAtOrBelowHalfTarget() public {
        vm.expectRevert(
            abi.encodeWithSelector(XAgentAirdrop.FloatAboveRefillThreshold.selector, FLOAT_TARGET, 5000 ether)
        );
        airdrop.refill(address(uxlink));

        _execSafeCall(address(airdrop), abi.encodeCall(XAgentAirdrop.returnToSafe, (address(uxlink), 4999 ether)));
        vm.expectRevert(
            abi.encodeWithSelector(XAgentAirdrop.FloatAboveRefillThreshold.selector, 5001 ether, 5000 ether)
        );
        airdrop.refill(address(uxlink));

        _execSafeCall(address(airdrop), abi.encodeCall(XAgentAirdrop.returnToSafe, (address(uxlink), 1 ether)));

        // Anyone may trigger a refill once the float is at the threshold.
        vm.expectEmit(true, true, true, true, address(airdrop));
        emit XAgentAirdrop.FloatRefilled(address(uxlink), 5000 ether, FLOAT_TARGET, bob);
        vm.prank(bob);
        assertEq(airdrop.refill(address(uxlink)), 5000 ether);

        assertEq(uxlink.balanceOf(address(airdrop)), FLOAT_TARGET);
        assertEq(_allowance(address(uxlink))[4], 3);
    }

    function test_refill_cappedByPeriodAllowance_andSurvivesAllowanceBelowSpent() public {
        _execSafeCall(address(airdrop), abi.encodeCall(XAgentAirdrop.returnToSafe, (address(uxlink), FLOAT_TARGET)));

        // Lower the Period Allowance to 15,000 with 10,000 already spent: only 5,000 can be pulled.
        _execSafeCall(
            address(allowanceModule),
            abi.encodeCall(
                IAllowanceModuleAdmin.setAllowance, (address(airdrop), address(uxlink), 15_000 ether, RESET_TIME_MIN, 0)
            )
        );
        assertEq(airdrop.refill(address(uxlink)), 5000 ether);
        assertEq(uxlink.balanceOf(address(airdrop)), 5000 ether);

        vm.expectRevert(XAgentAirdrop.NothingToRefill.selector);
        airdrop.refill(address(uxlink));

        // `setAllowance` keeps `spent`, so the allowance can drop below what was already spent this period.
        _execSafeCall(
            address(allowanceModule),
            abi.encodeCall(
                IAllowanceModuleAdmin.setAllowance, (address(airdrop), address(uxlink), 5000 ether, RESET_TIME_MIN, 0)
            )
        );
        _execSafeCall(address(airdrop), abi.encodeCall(XAgentAirdrop.returnToSafe, (address(uxlink), 5000 ether)));
        uint256[5] memory allowance = _allowance(address(uxlink));
        assertLt(allowance[0], allowance[1]);

        vm.expectRevert(XAgentAirdrop.NothingToRefill.selector);
        airdrop.refill(address(uxlink));

        uint256 deadline = vm.getBlockTimestamp() + 2 days;
        bytes memory sig = _signClaim(SIGNER_PK, alice, address(uxlink), 1000 ether, 10 ether, 451, deadline);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(XAgentAirdrop.InsufficientFloat.selector, 990 ether, 0));
        airdrop.claim(address(uxlink), 1000 ether, 10 ether, 451, deadline, payable(alice), sig);

        // Next period: `spent` resets and the new 5,000 allowance is available.
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        assertEq(airdrop.refill(address(uxlink)), 5000 ether);
        vm.prank(alice);
        airdrop.claim(address(uxlink), 1000 ether, 10 ether, 451, deadline, payable(alice), sig);
        assertEq(uxlink.balanceOf(alice), 990 ether);
    }

    function test_RevertWhen_refill_PausedOrNotEnabled() public {
        vm.expectRevert(abi.encodeWithSelector(XAgentAirdrop.TokenNotEnabled.selector, address(usdc)));
        airdrop.refill(address(usdc));

        _execSafeCall(address(airdrop), abi.encodeCall(XAgentAirdrop.returnToSafe, (address(uxlink), FLOAT_TARGET)));
        vm.prank(guardian);
        airdrop.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        airdrop.refill(address(uxlink));
    }

    // ---------------------------------------------------------------------
    // Signature, replay, epoch & domain protections
    // ---------------------------------------------------------------------

    function test_RevertWhen_claim_ReplayedOrWrongCallerOrTampered() public {
        uint256 deadline = vm.getBlockTimestamp() + 30 minutes;
        bytes memory sig = _signClaim(SIGNER_PK, alice, address(uxlink), 100 ether, 1 ether, 301, deadline);

        // Wrong caller (`bob` tries to use `alice`'s signature).
        vm.prank(bob);
        vm.expectRevert(XAgentAirdrop.InvalidSignature.selector);
        airdrop.claim(address(uxlink), 100 ether, 1 ether, 301, deadline, payable(bob), sig);

        // Tampered deadline.
        vm.prank(alice);
        vm.expectRevert(XAgentAirdrop.InvalidSignature.selector);
        airdrop.claim(address(uxlink), 100 ether, 1 ether, 301, deadline + 1, payable(alice), sig);

        // Tampered fee no longer matches the Fee Rate.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(XAgentAirdrop.FeeMismatch.selector, 0, 1 ether));
        airdrop.claim(address(uxlink), 100 ether, 0, 301, deadline, payable(alice), sig);

        // Honest claim succeeds once, then reverts on replay.
        vm.prank(alice);
        airdrop.claim(address(uxlink), 100 ether, 1 ether, 301, deadline, payable(alice), sig);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(XAgentAirdrop.AlreadyClaimed.selector, 301));
        airdrop.claim(address(uxlink), 100 ether, 1 ether, 301, deadline, payable(alice), sig);
    }

    function test_RevertWhen_claim_ExpiredOrCrossChainOrRotatedSignerOrAdvancedEpoch() public {
        uint256 nowTs = vm.getBlockTimestamp();
        uint256 deadline = nowTs + 10 minutes;
        bytes memory sig = _signClaim(SIGNER_PK, alice, address(uxlink), 100 ether, 1 ether, 302, deadline);

        // Cross-chain replay fails.
        vm.chainId(42_161);
        vm.prank(alice);
        vm.expectRevert(XAgentAirdrop.InvalidSignature.selector);
        airdrop.claim(address(uxlink), 100 ether, 1 ether, 302, deadline, payable(alice), sig);
        vm.chainId(1);

        // Expiry fails.
        vm.warp(deadline + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(XAgentAirdrop.ClaimExpired.selector, deadline, deadline + 1));
        airdrop.claim(address(uxlink), 100 ether, 1 ether, 302, deadline, payable(alice), sig);

        // Advance epoch invalidates unexpired signatures from epoch 0.
        uint256 nextDeadline = vm.getBlockTimestamp() + 30 minutes;
        bytes memory epoch0Sig = _signClaim(SIGNER_PK, alice, address(uxlink), 100 ether, 1 ether, 303, nextDeadline);
        vm.prank(guardian);
        uint256 newEpoch = airdrop.advanceEpoch();
        assertEq(newEpoch, 1);

        vm.prank(alice);
        vm.expectRevert(XAgentAirdrop.InvalidSignature.selector);
        airdrop.claim(address(uxlink), 100 ether, 1 ether, 303, nextDeadline, payable(alice), epoch0Sig);

        // Signature signed for epoch 1 works until signer is rotated.
        bytes memory epoch1Sig = _signClaim(SIGNER_PK, alice, address(uxlink), 100 ether, 1 ether, 303, nextDeadline);
        vm.expectEmit(true, true, true, true, address(airdrop));
        emit XAgentAirdrop.SignerUpdated(signer, rotatedSigner);
        _execSafeCall(address(airdrop), abi.encodeCall(XAgentAirdrop.setSigner, (rotatedSigner)));

        vm.prank(alice);
        vm.expectRevert(XAgentAirdrop.InvalidSignature.selector);
        airdrop.claim(address(uxlink), 100 ether, 1 ether, 303, nextDeadline, payable(alice), epoch1Sig);

        bytes memory rotatedSig =
            _signClaim(ROTATED_SIGNER_PK, alice, address(uxlink), 100 ether, 1 ether, 303, nextDeadline);
        vm.prank(alice);
        airdrop.claim(address(uxlink), 100 ether, 1 ether, 303, nextDeadline, payable(alice), rotatedSig);
        assertEq(uxlink.balanceOf(alice), 99 ether);
    }

    function test_RevertWhen_claim_InvalidAmountsOrCaps() public {
        uint256 deadline = vm.getBlockTimestamp() + 30 minutes;

        vm.startPrank(alice);
        vm.expectRevert(XAgentAirdrop.ZeroAddress.selector);
        airdrop.claim(address(uxlink), 100 ether, 1 ether, 401, deadline, payable(address(0)), "");

        vm.expectRevert(XAgentAirdrop.ZeroAddress.selector);
        airdrop.claim(address(0), 100 ether, 1 ether, 401, deadline, payable(alice), "");

        vm.expectRevert(XAgentAirdrop.ZeroAmount.selector);
        airdrop.claim(address(uxlink), 0, 0, 401, deadline, payable(alice), "");

        // Token not enabled (`usdc` cap is 0).
        vm.expectRevert(abi.encodeWithSelector(XAgentAirdrop.TokenNotEnabled.selector, address(usdc)));
        airdrop.claim(address(usdc), 100 ether, 0, 401, deadline, payable(alice), "");

        // Above per-claim cap.
        vm.expectRevert(
            abi.encodeWithSelector(XAgentAirdrop.ExceedsMaxClaimAmount.selector, PER_CLAIM_CAP + 1, PER_CLAIM_CAP)
        );
        airdrop.claim(address(uxlink), PER_CLAIM_CAP + 1, 0, 401, deadline, payable(alice), "");
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Guardian & Safe permissions + manual settlement
    // ---------------------------------------------------------------------

    function test_guardianCanOnlyPauseAndAdvanceEpoch() public {
        // Unauthorized caller cannot pause.
        vm.prank(alice);
        vm.expectRevert(XAgentAirdrop.OnlySafeOrGuardian.selector);
        airdrop.pause();

        // Guardian pauses.
        vm.prank(guardian);
        airdrop.pause();
        assertTrue(airdrop.paused());

        // Claims revert while paused.
        uint256 deadline = vm.getBlockTimestamp() + 30 minutes;
        bytes memory sig = _signClaim(SIGNER_PK, alice, address(uxlink), 100 ether, 1 ether, 601, deadline);
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        airdrop.claim(address(uxlink), 100 ether, 1 ether, 601, deadline, payable(alice), sig);

        // Guardian advances the epoch, also while paused.
        vm.startPrank(guardian);
        vm.expectEmit(true, true, true, true, address(airdrop));
        emit XAgentAirdrop.EpochAdvanced(0, 1, guardian);
        airdrop.advanceEpoch();
        vm.expectEmit(true, true, true, true, address(airdrop));
        emit XAgentAirdrop.EpochAdvanced(1, 2, guardian);
        assertEq(airdrop.advanceEpoch(), 2);

        // Guardian cannot unpause or change settings.
        vm.expectRevert(XAgentAirdrop.OnlySafe.selector);
        airdrop.unpause();
        vm.expectRevert(XAgentAirdrop.OnlySafe.selector);
        airdrop.setSigner(rotatedSigner);
        vm.expectRevert(XAgentAirdrop.OnlySafe.selector);
        airdrop.setGuardian(alice);
        vm.expectRevert(XAgentAirdrop.OnlySafe.selector);
        airdrop.configureToken(address(uxlink), 1, 0, 1);
        vm.expectRevert(XAgentAirdrop.OnlySafe.selector);
        airdrop.rescueETH(1);
        vm.expectRevert(XAgentAirdrop.OnlySafe.selector);
        airdrop.settleManualClaim(601, alice, alice, address(uxlink), 100 ether, 0);
        vm.stopPrank();

        // Only Safe can unpause.
        _execSafeCall(address(airdrop), abi.encodeCall(XAgentAirdrop.unpause, ()));
        assertFalse(airdrop.paused());
    }

    function test_settleManualClaim_atomicMultiSendAndWorksWhilePaused() public {
        vm.prank(guardian);
        airdrop.pause();

        uint256 claimId = 701;
        uint256 gross = 50_000 ether; // 10x Per-Claim Cap
        uint256 fee = 500 ether; // 1%
        uint256 net = gross - fee;

        bytes memory settlementBatch = abi.encodePacked(
            _encodeMultiSendStep(address(uxlink), abi.encodeCall(IERC20.transfer, (bob, net))),
            _encodeMultiSendStep(
                address(airdrop),
                abi.encodeCall(XAgentAirdrop.settleManualClaim, (claimId, alice, bob, address(uxlink), gross, fee))
            )
        );

        vm.expectEmit(true, true, true, true, address(airdrop));
        emit XAgentAirdrop.ManualClaimSettled(claimId, alice, bob, address(uxlink), gross, fee, net);
        _execSafeMultiSend(settlementBatch);

        assertTrue(airdrop.isClaimed(claimId));
        assertEq(uxlink.balanceOf(bob), net);
        // Manual Settlement pays from the Treasury Safe, never from the Claim Float.
        assertEq(uxlink.balanceOf(address(safe)), INITIAL_TREASURY - FLOAT_TARGET - net);
        assertEq(uxlink.balanceOf(address(airdrop)), FLOAT_TARGET);

        // Re-executing the same manual settlement batch rolls back the token transfer as well.
        bytes memory sigs = _signSafeTx(
            SafeMainnetArtifacts.MULTI_SEND_CALL_ONLY,
            0,
            abi.encodeCall(IMultiSendCallOnly.multiSend, (settlementBatch)),
            SAFE_OP_DELEGATECALL
        );
        vm.expectRevert();
        safe.execTransaction(
            SafeMainnetArtifacts.MULTI_SEND_CALL_ONLY,
            0,
            abi.encodeCall(IMultiSendCallOnly.multiSend, (settlementBatch)),
            SAFE_OP_DELEGATECALL,
            0,
            0,
            0,
            address(0),
            payable(address(0)),
            sigs
        );
        assertEq(uxlink.balanceOf(bob), net);

        // Once unpaused, the settled claimId cannot be re-claimed via self-service either.
        _execSafeCall(address(airdrop), abi.encodeCall(XAgentAirdrop.unpause, ()));
        uint256 deadline = vm.getBlockTimestamp() + 30 minutes;
        bytes memory userSig = _signClaim(SIGNER_PK, alice, address(uxlink), 100 ether, 1 ether, claimId, deadline);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(XAgentAirdrop.AlreadyClaimed.selector, claimId));
        airdrop.claim(address(uxlink), 100 ether, 1 ether, claimId, deadline, payable(alice), userSig);
    }

    function test_RevertWhen_settleManualClaim_InvalidArgs() public {
        uint256 claimId = 702;

        // Pranked as the Safe: a failing inner call inside `execTransaction` collapses into GS013.
        vm.startPrank(address(safe));

        vm.expectRevert(XAgentAirdrop.ZeroAddress.selector);
        airdrop.settleManualClaim(claimId, address(0), bob, address(uxlink), 50_000 ether, 0);

        vm.expectRevert(XAgentAirdrop.ZeroAddress.selector);
        airdrop.settleManualClaim(claimId, alice, address(0), address(uxlink), 50_000 ether, 0);

        vm.expectRevert(XAgentAirdrop.ZeroAddress.selector);
        airdrop.settleManualClaim(claimId, alice, bob, address(0), 50_000 ether, 0);

        vm.expectRevert(XAgentAirdrop.ZeroAmount.selector);
        airdrop.settleManualClaim(claimId, alice, bob, address(uxlink), 0, 0);

        // Fee above the token's Fee Rate (1%) is rejected on the manual path too.
        vm.expectRevert(abi.encodeWithSelector(XAgentAirdrop.FeeExceedsMax.selector, 501 ether, 500 ether));
        airdrop.settleManualClaim(claimId, alice, bob, address(uxlink), 50_000 ether, 501 ether);

        // Unconfigured tokens (Fee Rate 0) only settle fee-free.
        vm.expectRevert(abi.encodeWithSelector(XAgentAirdrop.FeeExceedsMax.selector, 1, 0));
        airdrop.settleManualClaim(claimId, alice, bob, address(usdc), 50_000 ether, 1);

        vm.stopPrank();
        assertFalse(airdrop.isClaimed(claimId));
    }

    function test_settleManualClaim_allowsFeeBelowFeeRate() public {
        vm.expectEmit(true, true, true, true, address(airdrop));
        emit XAgentAirdrop.ManualClaimSettled(703, alice, bob, address(uxlink), 1000 ether, 0, 1000 ether);
        _execSafeCall(
            address(airdrop),
            abi.encodeCall(XAgentAirdrop.settleManualClaim, (703, alice, bob, address(uxlink), 1000 ether, 0))
        );
        assertTrue(airdrop.isClaimed(703));
    }

    function test_setGuardian_rotatesAndClearsGuardian() public {
        vm.expectEmit(true, true, true, true, address(airdrop));
        emit XAgentAirdrop.GuardianUpdated(guardian, alice);
        _execSafeCall(address(airdrop), abi.encodeCall(XAgentAirdrop.setGuardian, (alice)));
        assertEq(airdrop.guardian(), alice);

        // The previous guardian loses its emergency powers; the new guardian gains them.
        vm.prank(guardian);
        vm.expectRevert(XAgentAirdrop.OnlySafeOrGuardian.selector);
        airdrop.pause();

        vm.prank(alice);
        airdrop.advanceEpoch();
        assertEq(airdrop.epoch(), 1);

        // Clearing the guardian leaves the Safe as the only emergency actor.
        vm.expectEmit(true, true, true, true, address(airdrop));
        emit XAgentAirdrop.GuardianUpdated(alice, address(0));
        _execSafeCall(address(airdrop), abi.encodeCall(XAgentAirdrop.setGuardian, (address(0))));
        assertEq(airdrop.guardian(), address(0));

        vm.prank(alice);
        vm.expectRevert(XAgentAirdrop.OnlySafeOrGuardian.selector);
        airdrop.pause();

        _execSafeCall(address(airdrop), abi.encodeCall(XAgentAirdrop.pause, ()));
        assertTrue(airdrop.paused());
    }

    // ---------------------------------------------------------------------
    // returnToSafe, ETH rescue & ETH rejection
    // ---------------------------------------------------------------------

    function test_returnToSafe_permissions() public {
        vm.prank(alice);
        vm.expectRevert(XAgentAirdrop.OnlySafeOrGuardian.selector);
        airdrop.returnToSafe(address(uxlink), 1);

        // The guardian can only drain the float during an emergency pause.
        vm.prank(guardian);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        airdrop.returnToSafe(address(uxlink), 1);

        // The Safe can recall float at any time.
        vm.expectEmit(true, true, true, true, address(airdrop));
        emit XAgentAirdrop.FloatReturned(address(uxlink), 1000 ether, address(safe));
        _execSafeCall(address(airdrop), abi.encodeCall(XAgentAirdrop.returnToSafe, (address(uxlink), 1000 ether)));
        assertEq(uxlink.balanceOf(address(airdrop)), FLOAT_TARGET - 1000 ether);

        vm.startPrank(guardian);
        airdrop.pause();
        vm.expectEmit(true, true, true, true, address(airdrop));
        emit XAgentAirdrop.FloatReturned(address(uxlink), FLOAT_TARGET - 1000 ether, guardian);
        airdrop.returnToSafe(address(uxlink), FLOAT_TARGET - 1000 ether);

        // Mistaken transfers of any ERC-20 also only go back to the Safe.
        usdc.mint(address(airdrop), 250 ether);
        airdrop.returnToSafe(address(usdc), 250 ether);
        vm.stopPrank();

        assertEq(uxlink.balanceOf(address(airdrop)), 0);
        assertEq(uxlink.balanceOf(address(safe)), INITIAL_TREASURY);
        assertEq(usdc.balanceOf(address(safe)), INITIAL_TREASURY + 250 ether);
    }

    function test_rescueETH_alwaysGoesToSafe() public {
        // Direct ETH transfer is rejected (no receive/fallback).
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(airdrop).call{value: 1 ether}("");
        assertFalse(ok);

        // Forced ETH (e.g. via selfdestruct) is swept back to `safe`.
        vm.deal(address(airdrop), 3 ether);
        vm.expectEmit(true, true, true, true, address(airdrop));
        emit XAgentAirdrop.ETHRescued(3 ether);
        _execSafeCall(address(airdrop), abi.encodeCall(XAgentAirdrop.rescueETH, (3 ether)));
        assertEq(address(airdrop).balance, 0);
        assertEq(address(safe).balance, 3 ether);
    }

    function test_RevertWhen_adminFunctions_ZeroArgs() public {
        vm.startPrank(address(safe));

        vm.expectRevert(XAgentAirdrop.ZeroAddress.selector);
        airdrop.setSigner(address(0));

        vm.expectRevert(XAgentAirdrop.ZeroAddress.selector);
        airdrop.returnToSafe(address(0), 1);

        vm.expectRevert(XAgentAirdrop.ZeroAmount.selector);
        airdrop.returnToSafe(address(uxlink), 0);

        vm.expectRevert(XAgentAirdrop.ZeroAmount.selector);
        airdrop.rescueETH(0);

        vm.stopPrank();
        assertEq(airdrop.signer(), signer);
    }

    // ---------------------------------------------------------------------
    // Fuzz & invariant tests
    // ---------------------------------------------------------------------

    function testFuzz_claim_enforcesCapAndExactFee(
        uint96 grossRaw,
        uint8 feeMode
    ) public {
        uint256 gross = bound(uint256(grossRaw), 1, PER_CLAIM_CAP * 2);
        (uint256 expectedFee,) = airdrop.quoteFee(address(uxlink), gross);
        uint256 fee = expectedFee;
        if (feeMode % 3 == 1) fee = expectedFee + 1;
        else if (feeMode % 3 == 2) fee = expectedFee == 0 ? gross : expectedFee - 1;

        uint256 deadline = vm.getBlockTimestamp() + 30 minutes;
        bytes memory sig = _signClaim(SIGNER_PK, alice, address(uxlink), gross, fee, 901, deadline);
        bool shouldSucceed = gross <= PER_CLAIM_CAP && fee == expectedFee;

        vm.prank(alice);
        if (shouldSucceed) {
            airdrop.claim(address(uxlink), gross, fee, 901, deadline, payable(bob), sig);
            assertEq(uxlink.balanceOf(bob), gross - fee);
            assertEq(uxlink.balanceOf(address(airdrop)), FLOAT_TARGET - (gross - fee));
            assertEq(uxlink.balanceOf(address(safe)), INITIAL_TREASURY - FLOAT_TARGET);
            assertTrue(airdrop.isClaimed(901));
        } else {
            vm.expectRevert();
            airdrop.claim(address(uxlink), gross, fee, 901, deadline, payable(bob), sig);
            assertFalse(airdrop.isClaimed(901));
        }
    }

    /// Per allowance window, the Safe never releases more than the Period Allowance and recipients never receive
    /// more than the Period Allowance plus one Float Target.
    function invariant_windowOutflowBoundedByAllowanceAndFloat() public view {
        assertLe(handler.maxWindowPulled(), PERIOD_ALLOWANCE);
        assertLe(handler.maxWindowPaid(), uint256(PERIOD_ALLOWANCE) + FLOAT_TARGET);
        assertLe(uxlink.balanceOf(address(airdrop)), FLOAT_TARGET);
    }

    /// The float holds exactly what was pulled minus what was paid out and returned; fees never leave the Safe.
    function invariant_floatBalanceMatchesPulledMinusPaidAndReturned() public view {
        assertEq(
            uxlink.balanceOf(address(airdrop)), handler.totalPulled() - handler.totalPaid() - handler.totalReturned()
        );
        assertEq(
            uxlink.balanceOf(address(safe)) + uxlink.balanceOf(address(airdrop)) + handler.totalPaid(), INITIAL_TREASURY
        );
    }

    function afterInvariant() public view {
        assertGt(handler.claimsSucceeded(), 0);
        assertGt(handler.refillsSucceeded(), 0);
    }

    // ---------------------------------------------------------------------
    // Optional live mainnet fork smoke test
    // ---------------------------------------------------------------------

    function testFork_mainnetUXLinkLiveSmoke() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;

        vm.createSelectFork(rpc);
        address mainnetUXLink = 0x3991B07b2951a4300Da8c76e7d2c7eddE861Fef3;
        address legacyAirdrop = 0xC2aE5507720CaC7C5E82349e93379768cB19545b;

        ISafe150 forkSafe = _deploy2Of3Safe();
        airdrop = new XAgentAirdrop(address(forkSafe), SafeMainnetArtifacts.ALLOWANCE_MODULE, signer, guardian);

        // Simulate migrating the legacy contract's UXLINK balance into the new Treasury Safe.
        uint256 legacyBal = IERC20(mainnetUXLink).balanceOf(legacyAirdrop);
        assertGe(legacyBal, FLOAT_TARGET);
        vm.prank(legacyAirdrop);
        IERC20(mainnetUXLink).transfer(address(forkSafe), legacyBal);

        bytes memory batch = abi.encodePacked(
            _encodeMultiSendStep(
                address(forkSafe),
                abi.encodeWithSignature("enableModule(address)", SafeMainnetArtifacts.ALLOWANCE_MODULE)
            ),
            _encodeMultiSendStep(
                SafeMainnetArtifacts.ALLOWANCE_MODULE,
                abi.encodeCall(IAllowanceModuleAdmin.addDelegate, (address(airdrop)))
            ),
            _tokenSetupBatch(mainnetUXLink, PERIOD_ALLOWANCE, PER_CLAIM_CAP, FEE_BPS, FLOAT_TARGET, false)
        );
        _execSafeMultiSendOn(forkSafe, batch);

        uint256 deadline = vm.getBlockTimestamp() + 30 minutes;
        bytes memory sig = _signClaim(SIGNER_PK, alice, mainnetUXLink, 1000 ether, 10 ether, 1, deadline);
        vm.prank(alice);
        airdrop.claim(mainnetUXLink, 1000 ether, 10 ether, 1, deadline, payable(alice), sig);

        assertEq(IERC20(mainnetUXLink).balanceOf(alice), 990 ether);
        assertEq(IERC20(mainnetUXLink).balanceOf(address(airdrop)), FLOAT_TARGET - 990 ether);
    }

    // ---------------------------------------------------------------------
    // Safe, AllowanceModule & EIP-712 helpers
    // ---------------------------------------------------------------------

    /// @dev MultiSend steps that give `airdrop` a Period Allowance for `token` and configure it on the airdrop.
    /// `withModuleAndDelegate` prepends `enableModule` + `addDelegate` for the first token on the Safe.
    function _tokenSetupBatch(
        address token,
        uint96 periodAllowance,
        uint256 cap,
        uint256 feeBps,
        uint256 target,
        bool withModuleAndDelegate
    ) internal view returns (bytes memory batch) {
        if (withModuleAndDelegate) {
            batch = abi.encodePacked(
                _encodeMultiSendStep(
                    address(safe), abi.encodeWithSignature("enableModule(address)", address(allowanceModule))
                ),
                _encodeMultiSendStep(
                    address(allowanceModule), abi.encodeCall(IAllowanceModuleAdmin.addDelegate, (address(airdrop)))
                )
            );
        }
        batch = abi.encodePacked(
            batch,
            _encodeMultiSendStep(
                address(allowanceModule),
                abi.encodeCall(
                    IAllowanceModuleAdmin.setAllowance, (address(airdrop), token, periodAllowance, RESET_TIME_MIN, 0)
                )
            ),
            _encodeMultiSendStep(
                address(airdrop), abi.encodeCall(XAgentAirdrop.configureToken, (token, cap, feeBps, target))
            )
        );
    }

    function _allowance(
        address token
    ) internal view returns (uint256[5] memory) {
        return allowanceModule.getTokenAllowance(address(safe), address(airdrop), token);
    }

    function _claimAs(
        address claimant,
        uint256 gross,
        uint256 claimId,
        uint256 deadline
    ) internal {
        (uint256 fee,) = airdrop.quoteFee(address(uxlink), gross);
        bytes memory sig = _signClaim(SIGNER_PK, claimant, address(uxlink), gross, fee, claimId, deadline);
        vm.prank(claimant);
        airdrop.claim(address(uxlink), gross, fee, claimId, deadline, payable(claimant), sig);
    }

    function _deploy2Of3Safe() internal returns (ISafe150) {
        address[] memory owners = new address[](3);
        owners[0] = owner1;
        owners[1] = owner2;
        owners[2] = owner3;

        bytes memory initializer =
            abi.encodeCall(ISafe150.setup, (owners, 2, address(0), "", address(0), address(0), 0, payable(address(0))));
        address proxy = ISafeProxyFactory(SafeMainnetArtifacts.SAFE_PROXY_FACTORY)
            .createProxyWithNonce(SafeMainnetArtifacts.SAFE_SINGLETON, initializer, 1);
        return ISafe150(proxy);
    }

    function _encodeMultiSendStep(
        address to,
        bytes memory data
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(SAFE_OP_CALL), to, uint256(0), data.length, data);
    }

    function _execSafeCall(
        address to,
        bytes memory data
    ) internal {
        _execSafeCallOn(safe, to, data);
    }

    function _execSafeCallOn(
        ISafe150 targetSafe,
        address to,
        bytes memory data
    ) internal {
        bytes memory sigs = _signSafeTxOn(targetSafe, to, 0, data, SAFE_OP_CALL);
        bool ok = targetSafe.execTransaction(to, 0, data, SAFE_OP_CALL, 0, 0, 0, address(0), payable(address(0)), sigs);
        assertTrue(ok);
    }

    function _execSafeMultiSend(
        bytes memory packedTransactions
    ) internal {
        _execSafeMultiSendOn(safe, packedTransactions);
    }

    function _execSafeMultiSendOn(
        ISafe150 targetSafe,
        bytes memory packedTransactions
    ) internal {
        bytes memory data = abi.encodeCall(IMultiSendCallOnly.multiSend, (packedTransactions));
        bytes memory sigs =
            _signSafeTxOn(targetSafe, SafeMainnetArtifacts.MULTI_SEND_CALL_ONLY, 0, data, SAFE_OP_DELEGATECALL);
        bool ok = targetSafe.execTransaction(
            SafeMainnetArtifacts.MULTI_SEND_CALL_ONLY,
            0,
            data,
            SAFE_OP_DELEGATECALL,
            0,
            0,
            0,
            address(0),
            payable(address(0)),
            sigs
        );
        assertTrue(ok);
    }

    function _signSafeTx(
        address to,
        uint256 value,
        bytes memory data,
        uint8 operation
    ) internal view returns (bytes memory) {
        return _signSafeTxOn(safe, to, value, data, operation);
    }

    function _signSafeTxOn(
        ISafe150 targetSafe,
        address to,
        uint256 value,
        bytes memory data,
        uint8 operation
    ) internal view returns (bytes memory) {
        bytes32 txHash = targetSafe.getTransactionHash(
            to, value, data, operation, 0, 0, 0, address(0), address(0), targetSafe.nonce()
        );
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(OWNER1_PK, txHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(OWNER2_PK, txHash);
        if (owner1 < owner2) {
            return abi.encodePacked(r1, s1, v1, r2, s2, v2);
        }
        return abi.encodePacked(r2, s2, v2, r1, s1, v1);
    }

    function _signClaim(
        uint256 pk,
        address claimant,
        address token,
        uint256 amount,
        uint256 fee,
        uint256 claimId,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 digest = airdrop.hashClaim(claimant, token, amount, fee, claimId, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
