// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {TestStaking} from "../src/TestStaking.sol";

contract LaunchProbe {
    function deploy(address owner) external returns (LaunchToken token, TestStaking staking) {
        token = new LaunchToken();
        staking = new TestStaking(address(token), owner);
        require(token.balanceOf(address(this)) == 1e27, "launch supply moved");
    }
}

contract LaunchTokenTest is Test {
    LaunchToken internal token;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        token = new LaunchToken();
    }

    function test_metadataAndFixedSupply() public view {
        assertEq(token.name(), "Test");
        assertEq(token.symbol(), "TEST");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function test_factoryDeploymentPreservesSupplyAndUsesExplicitOwner() public {
        LaunchProbe factory = new LaunchProbe();
        (LaunchToken launched, TestStaking staking) = factory.deploy(alice);
        assertEq(launched.balanceOf(address(factory)), 1e27);
        assertEq(launched.balanceOf(address(staking)), 0);
        assertEq(address(staking.token()), address(launched));
        assertEq(staking.owner(), alice);
        assertEq(staking.totalStaked(), 0);
    }

    function testFuzz_transferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_approveAndTransferFromSpendExactAllowance() public {
        token.approve(alice, 10 ether);
        vm.prank(alice);
        assertTrue(token.transferFrom(address(this), bob, 4 ether));
        assertEq(token.balanceOf(bob), 4 ether);
        assertEq(token.allowance(address(this), alice), 6 ether);
    }

    function test_infiniteAllowanceKeepsErc20Semantics() public {
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 1 ether);
        assertEq(token.allowance(address(this), alice), type(uint256).max);
    }

    function test_transferFromWithoutApprovalReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(address(this), alice, 1);
    }

    function test_insufficientBalanceReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_zeroReceiverReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_zeroSpenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_zeroAndSelfTransfers() public {
        token.transfer(alice, 0);
        token.transfer(address(this), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_noAdminMintOrUpgradeEntryPoints() public {
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "setMinter(address)",
            "burn(uint256)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], alice, type(uint128).max);
            (bool deployerSuccess,) = address(token).call(data);
            assertFalse(deployerSuccess, signatures[i]);
            vm.prank(alice);
            (bool strangerSuccess,) = address(token).call(data);
            assertFalse(strangerSuccess, signatures[i]);
        }
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_runtimeBoundsAndForbiddenOpcodes() public {
        TestStaking staking = new TestStaking(address(token), alice);
        _checkRuntime(address(token));
        _checkRuntime(address(staking));
    }

    function _checkRuntime(address target) internal view {
        bytes memory code = target.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        bool reachable = true;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            if (reachable) assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) reachable = false;
        }
    }
}
