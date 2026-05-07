// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {XPoint} from "../src/XPoint.sol";
import {CheckIn} from "../src/CheckIn.sol";

abstract contract BaseTest is Test {
    uint256 internal constant OWNER_PK = 0xA11CE;
    uint256 internal constant SIGNER_PK = 0xB0B;
    uint256 internal constant OTHER_SIGNER_PK = 0xC0B;

    bytes32 internal constant CHECKIN_TYPEHASH =
        keccak256("CheckIn(address account,uint256 amount,uint256 claimId,uint256 deadline)");
    bytes32 internal constant CHECKIN_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    XPoint internal xpoint;
    CheckIn internal checkIn;

    address internal owner;
    address internal operator;
    address internal pauser;
    address internal signer;
    address internal alice;
    address internal bob;

    function setUp() public virtual {
        owner = vm.addr(OWNER_PK);
        operator = makeAddr("operator");
        pauser = makeAddr("pauser");
        signer = vm.addr(SIGNER_PK);
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        xpoint = _deployXPointProxy("X Point", "XPT", owner, operator, pauser, 0, false);
        checkIn = _deployCheckInProxy(address(xpoint), signer, owner);

        bytes32 minterRole = xpoint.MINTER_ROLE();
        vm.prank(owner);
        xpoint.grantRole(minterRole, address(checkIn));
    }

    function _deployXPointProxy(
        string memory name_,
        string memory symbol_,
        address owner_,
        address operator_,
        address pauser_,
        uint256 maxSupply_,
        bool whitelistModeEnabled_
    ) internal returns (XPoint) {
        XPoint impl = new XPoint();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                XPoint.initialize, (name_, symbol_, owner_, operator_, pauser_, maxSupply_, whitelistModeEnabled_)
            )
        );
        return XPoint(address(proxy));
    }

    function _deployCheckInProxy(
        address xpoint_,
        address signer_,
        address owner_
    ) internal returns (CheckIn) {
        CheckIn impl = new CheckIn();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeCall(CheckIn.initialize, (xpoint_, signer_, owner_)));
        return CheckIn(payable(address(proxy)));
    }

    function _grantMinter(
        address account
    ) internal {
        bytes32 minterRole = xpoint.MINTER_ROLE();
        vm.prank(owner);
        xpoint.grantRole(minterRole, account);
    }

    function _signCheckIn(
        uint256 privateKey,
        address account,
        uint256 amount,
        uint256 claimId,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(CHECKIN_TYPEHASH, account, amount, claimId, deadline));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", _checkInDomainSeparator(address(checkIn)), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return bytes.concat(r, s, bytes1(v));
    }

    function _checkInDomainSeparator(
        address verifyingContract
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                CHECKIN_DOMAIN_TYPEHASH, keccak256("XAgentCheckIn"), keccak256("1"), block.chainid, verifyingContract
            )
        );
    }

    function _signPermit(
        uint256 privateKey,
        address owner_,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner_, spender, value, nonce, deadline));
        bytes32 domainSeparator = keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, keccak256("X Point"), keccak256("1"), block.chainid, address(xpoint))
        );
        bytes32 digest = keccak256(bytes.concat("\x19\x01", domainSeparator, structHash));
        (v, r, s) = vm.sign(privateKey, digest);
    }
}

contract XPointV2Mock is XPoint {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract CheckInV2Mock is CheckIn {
    function version() external pure returns (uint256) {
        return 2;
    }
}
