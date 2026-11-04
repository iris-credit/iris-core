// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.t.sol";

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {Blm} from "../../src/blm/Blm.sol";
import {WhitelistBlm} from "../../src/blm/WhitelistBlm.sol";
import {IBlm} from "../../src/interfaces/IBlm.sol";
import {IWhitelistBlm} from "../../src/interfaces/IWhitelistBlm.sol";
import {IrisTimelock} from "../../script/IrisTimelock.sol";

/// @dev Iris owned by an OZ TimelockController deployed by `IrisTimelock`, the same deploy the script sends.
/// `owner` (BaseTest) plays the deployer EOA that owns Iris at genesis and hands it off; `safe` is the
/// proposer; executors are open, so `keeper` (no role) executes.
contract GovernanceUnitTest is BaseTest {
    uint256 internal constant MIN_DELAY = 2 days;

    address internal immutable safe = makeAddr("safe");
    address internal immutable keeper = makeAddr("keeper");
    address internal immutable attacker = makeAddr("attacker");
    address internal immutable token = makeAddr("token");

    TimelockController internal timelock;
    WhitelistBlm internal whitelistBlm;
    IrisTimelock.Governance internal governance;

    function setUp() public virtual override {
        super.setUp();

        blm = new Blm(address(iris));
        whitelistBlm = new WhitelistBlm(address(iris));

        governance.proposer = safe;
        governance.executors.push(address(0));
        governance.minDelay = MIN_DELAY;

        vm.startPrank(owner);
        timelock = IrisTimelock.deploy(governance, owner);
        iris.setOwner(address(timelock));
        vm.stopPrank();

        vm.label(address(timelock), "Timelock");
        vm.label(address(blm), "Blm");
        vm.label(address(whitelistBlm), "WhitelistBlm");
    }

    /* SETUP */

    function testWiring() public view {
        IrisTimelock.check(timelock, governance, owner);
        assertEq(iris.owner(), address(timelock));
    }

    function testDeployRejectsUnsafeLayouts() public {
        IrisTimelock.Governance memory g = governance;

        g.proposer = address(0);
        vm.expectRevert(bytes("governance: proposer unset"));
        this.deployWith(g, owner);

        g = governance;
        vm.expectRevert(bytes("governance: proposer must not be the deployer"));
        this.deployWith(g, safe);

        g = governance;
        g.executors = new address[](0);
        vm.expectRevert(bytes("governance: no executor (use address(0) for anyone)"));
        this.deployWith(g, owner);

        g = governance;
        g.minDelay = 0;
        vm.expectRevert(bytes("governance: minDelay is zero"));
        this.deployWith(g, owner);
    }

    function testCheckCatchesDrift() public {
        _run(address(timelock), abi.encodeCall(TimelockController.updateDelay, (1 days)));

        vm.expectRevert(bytes("governance: minDelay mismatch"));
        this.checkWith(governance, owner);
    }

    /* OWNER CALLS */

    function testDirectOwnerCallsRevert() public {
        (address[] memory targets, bytes[] memory payloads) = _ownerCalls();
        address[3] memory senders = [owner, safe, keeper];
        for (uint256 s; s < senders.length; s++) {
            for (uint256 i; i < targets.length; i++) {
                vm.prank(senders[s]);
                (bool ok, bytes memory ret) = targets[i].call(payloads[i]);
                assertFalse(ok, "direct owner call succeeded");
                assertEq(bytes4(ret), IIris.Unauthorized.selector);
            }
        }
    }

    /// @dev Each of the ten owner functions: unscheduled and one second early fail, then anyone executes.
    function testEveryOwnerCallRunsThroughTheTimelock() public {
        (address[] memory targets, bytes[] memory payloads) = _ownerCalls();
        for (uint256 i; i < targets.length; i++) {
            _run(targets[i], payloads[i]);
        }

        assertEq(iris.venueAdapter(1), makeAddr("adapter"));
        assertTrue(iris.isDataEnabled(keccak256("market")));
        assertEq(uint256(iris.fee()) * BP, 0.05e18);
        assertEq(iris.feeRecipient(), makeAddr("newFeeRecipient"));
        assertTrue(iris.isBlmEnabled(makeAddr("newBlm")));
        assertTrue(iris.isBondLltvEnabled(0.5e18));
        assertEq(Blm(address(blm)).slope(token), 0.01e18);
        assertEq(whitelistBlm.intercept(token), 0.04e18);
        assertTrue(whitelistBlm.isWhitelisted(makeAddr("solver2")));
        assertEq(iris.owner(), makeAddr("newOwner"));
    }

    /// @dev One Safe transaction schedules several changes; one transaction from anyone executes them.
    function testBatch() public {
        address[] memory targets = new address[](3);
        bytes[] memory payloads = new bytes[](3);
        uint256[] memory values = new uint256[](3);
        targets[0] = address(iris);
        payloads[0] = abi.encodeCall(IIris.setFee, (0.05e18));
        targets[1] = address(blm);
        payloads[1] = abi.encodeCall(IBlm.setParams, (token, 0.01e18, 0.02e18));
        targets[2] = address(whitelistBlm);
        payloads[2] = abi.encodeCall(IWhitelistBlm.setIsWhitelisted, (attacker, true));

        vm.prank(safe);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), MIN_DELAY);
        skip(MIN_DELAY);
        vm.prank(keeper);
        timelock.executeBatch(targets, values, payloads, bytes32(0), bytes32(0));

        assertEq(uint256(iris.fee()) * BP, 0.05e18);
        assertEq(Blm(address(blm)).slope(token), 0.01e18);
        assertTrue(whitelistBlm.isWhitelisted(attacker));
    }

    function testOnlyProposerSchedules(address rdm) public {
        vm.assume(rdm != safe);
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        vm.prank(rdm);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, rdm, proposerRole)
        );
        timelock.schedule(address(iris), 0, abi.encodeCall(IIris.setFee, (0)), bytes32(0), bytes32(0), MIN_DELAY);
    }

    function testScheduleBelowMinDelayReverts() public {
        vm.prank(safe);
        vm.expectPartialRevert(TimelockController.TimelockInsufficientDelay.selector);
        timelock.schedule(address(iris), 0, abi.encodeCall(IIris.setFee, (0)), bytes32(0), bytes32(0), MIN_DELAY - 1);
    }

    /// @dev Documents OZ behavior: a ready operation stays executable until it is executed or cancelled.
    function testReadyOperationDoesNotExpire() public {
        bytes memory data = abi.encodeCall(IIris.setFee, (0.05e18));
        vm.prank(safe);
        timelock.schedule(address(iris), 0, data, bytes32(0), bytes32(0), MIN_DELAY);
        skip(365 days);
        vm.prank(keeper);
        timelock.execute(address(iris), 0, data, bytes32(0), bytes32(0));
        assertEq(uint256(iris.fee()) * BP, 0.05e18);
    }

    /* CANCEL */

    function testProposerCancels() public {
        bytes memory data = abi.encodeCall(IIris.setOwner, (attacker));
        bytes32 id = timelock.hashOperation(address(iris), 0, data, bytes32(0), bytes32(0));
        vm.prank(safe);
        timelock.schedule(address(iris), 0, data, bytes32(0), bytes32(0), MIN_DELAY);

        bytes32 cancellerRole = timelock.CANCELLER_ROLE();
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, keeper, cancellerRole)
        );
        timelock.cancel(id);

        vm.prank(safe);
        timelock.cancel(id);

        skip(MIN_DELAY);
        vm.prank(keeper);
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        timelock.execute(address(iris), 0, data, bytes32(0), bytes32(0));
        assertEq(iris.owner(), address(timelock));
    }

    /* SELF-ADMINISTRATION: role and delay changes wait minDelay too */

    function testRoleChangesWaitMinDelay() public {
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();
        vm.prank(safe);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, safe, adminRole)
        );
        timelock.grantRole(proposerRole, attacker);

        _run(address(timelock), abi.encodeCall(IAccessControl.grantRole, (proposerRole, attacker)));
        assertTrue(timelock.hasRole(proposerRole, attacker));
    }

    /// @dev Lowering the delay waits the current delay once, then applies to every later schedule at once.
    function testUpdateDelayWaitsCurrentDelay() public {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnauthorizedCaller.selector, safe));
        timelock.updateDelay(1 days);

        _run(address(timelock), abi.encodeCall(TimelockController.updateDelay, (1 days)));
        assertEq(timelock.getMinDelay(), 1 days);

        vm.prank(safe);
        timelock.schedule(address(iris), 0, abi.encodeCall(IIris.setFee, (0)), bytes32(0), bytes32(0), 1 days);
    }

    /* HELPERS */

    /// @dev The ten owner-gated calls, in an order that all succeed one after another (setOwner last).
    function _ownerCalls() internal returns (address[] memory targets, bytes[] memory payloads) {
        targets = new address[](10);
        payloads = new bytes[](10);
        targets[0] = address(iris);
        payloads[0] = abi.encodeCall(IIris.setVenueAdapter, (1, makeAddr("adapter")));
        targets[1] = address(iris);
        payloads[1] = abi.encodeCall(IIris.enableData, (keccak256("market")));
        targets[2] = address(iris);
        payloads[2] = abi.encodeCall(IIris.setFee, (0.05e18));
        targets[3] = address(iris);
        payloads[3] = abi.encodeCall(IIris.setFeeRecipient, (makeAddr("newFeeRecipient")));
        targets[4] = address(iris);
        payloads[4] = abi.encodeCall(IIris.enableBlm, (makeAddr("newBlm")));
        targets[5] = address(iris);
        payloads[5] = abi.encodeCall(IIris.enableBondLltv, (0.5e18));
        targets[6] = address(blm);
        payloads[6] = abi.encodeCall(IBlm.setParams, (token, 0.01e18, 0.02e18));
        targets[7] = address(whitelistBlm);
        payloads[7] = abi.encodeCall(IBlm.setParams, (token, 0.03e18, 0.04e18));
        targets[8] = address(whitelistBlm);
        payloads[8] = abi.encodeCall(IWhitelistBlm.setIsWhitelisted, (makeAddr("solver2"), true));
        targets[9] = address(iris);
        payloads[9] = abi.encodeCall(IIris.setOwner, (makeAddr("newOwner")));
    }

    /// @dev Asserts `data` on `target` cannot run unscheduled or one second early, then the proposer schedules
    /// it and `keeper` (no role) executes it.
    function _run(address target, bytes memory data) internal {
        vm.prank(keeper);
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        timelock.execute(target, 0, data, bytes32(0), bytes32(0));

        vm.prank(safe);
        timelock.schedule(target, 0, data, bytes32(0), bytes32(0), MIN_DELAY);

        skip(MIN_DELAY - 1);
        vm.prank(keeper);
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        timelock.execute(target, 0, data, bytes32(0), bytes32(0));

        skip(1);
        vm.prank(keeper);
        timelock.execute(target, 0, data, bytes32(0), bytes32(0));
        assertTrue(timelock.isOperationDone(timelock.hashOperation(target, 0, data, bytes32(0), bytes32(0))));
    }

    /// @dev External so `vm.expectRevert` can catch the library's reverts.
    function deployWith(IrisTimelock.Governance memory g, address deployer) external returns (address) {
        return address(IrisTimelock.deploy(g, deployer));
    }

    function checkWith(IrisTimelock.Governance memory g, address deployer) external view {
        IrisTimelock.check(timelock, g, deployer);
    }
}
