// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../BaseTest.t.sol";

import {Bundler3} from "../../../src/periphery/Bundler3.sol";
import {IBundler3, Call} from "../../../src/periphery/interfaces/IBundler3.sol";
import {CoreAdapter} from "../../../src/periphery/adapters/CoreAdapter.sol";
import {GeneralAdapter1} from "../../../src/periphery/adapters/GeneralAdapter1.sol";
import {FunctionMocker} from "./FunctionMocker.sol";
import {Permit, SigUtils} from "../../unit/helpers/SigUtils.sol";
import {IPermit2, PermitUtils, PermitSingle, PermitDetails} from "../../fork/helpers/PermitUtils.sol";

uint256 constant SIGNATURE_DEADLINE = type(uint32).max;

/// @dev Bundle-building machinery shared by the periphery unit and fork environments, forked from
/// bundler3's CommonTest. The environment (unit or fork) deploys `generalAdapter1` since its
/// constructor arguments (venue, wrapped native) depend on the environment.
abstract contract PeripheryTest is BaseTest {
    Bundler3 internal bundler3;
    GeneralAdapter1 internal generalAdapter1;

    Call[] internal bundle;
    Call[] internal callbackBundle;

    FunctionMocker internal functionMocker;

    function setUp() public virtual override {
        super.setUp();

        functionMocker = new FunctionMocker();
        bundler3 = new Bundler3();

        vm.label(address(bundler3), "Bundler3");
    }

    function _boundPrivateKey(uint256 privateKey) internal returns (uint256) {
        privateKey = bound(privateKey, 1, type(uint160).max);

        address user = vm.addr(privateKey);
        vm.label(user, "address of generated private key");

        return privateKey;
    }

    function _delegatePrank(address to, bytes memory callData) internal {
        vm.mockFunction(to, address(functionMocker), callData);
        (bool success,) = to.call(callData);
        require(success, "Function mocker call failed");
    }

    /// @dev Picks a uint stable by timestamp. The environment variable PICK_UINT can be used to force a
    /// specific uint. Used to make fork tests faster.
    function pickUint() internal view returns (uint256) {
        bytes32 _hash = keccak256(bytes.concat("pickUint", bytes32(block.timestamp)));
        uint256 num = uint256(_hash);
        return vm.envOr("PICK_UINT", num);
    }

    /* GENERAL ADAPTER CALL */

    function _call(CoreAdapter to, bytes memory data) internal pure returns (Call memory) {
        return _call(address(to), data, 0, false);
    }

    function _call(address to, bytes memory data) internal pure returns (Call memory) {
        return _call(to, data, 0, false);
    }

    function _call(CoreAdapter to, bytes memory data, uint256 value) internal pure returns (Call memory) {
        return _call(address(to), data, value, false);
    }

    function _call(address to, bytes memory data, uint256 value) internal pure returns (Call memory) {
        return _call(to, data, value, false);
    }

    function _call(CoreAdapter to, bytes memory data, bool skipRevert) internal pure returns (Call memory) {
        return _call(address(to), data, 0, skipRevert);
    }

    function _call(address to, bytes memory data, bool skipRevert) internal pure returns (Call memory) {
        return _call(to, data, 0, skipRevert);
    }

    function _call(CoreAdapter to, bytes memory data, bytes32 callbackHash) internal pure returns (Call memory) {
        return _call(address(to), data, 0, false, callbackHash);
    }

    function _call(CoreAdapter to, bytes memory data, uint256 value, bool skipRevert, bytes32 callbackHash)
        internal
        pure
        returns (Call memory)
    {
        return _call(address(to), data, value, skipRevert, callbackHash);
    }

    function _call(CoreAdapter to, bytes memory data, uint256 value, bool skipRevert)
        internal
        pure
        returns (Call memory)
    {
        return _call(address(to), data, value, skipRevert);
    }

    function _call(address to, bytes memory data, uint256 value, bool skipRevert) internal pure returns (Call memory) {
        return _call(to, data, value, skipRevert, bytes32(0));
    }

    function _call(address to, bytes memory data, uint256 value, bool skipRevert, bytes32 callbackHash)
        internal
        pure
        returns (Call memory)
    {
        require(to != address(0), "Adapter address is zero");
        return Call({to: to, data: data, value: value, skipRevert: skipRevert, callbackHash: callbackHash});
    }

    /* CALL WITH VALUE */

    function _transferNativeToAdapter(address adapter, uint256 amount) internal pure returns (Call memory) {
        return _call(adapter, hex"", amount);
    }

    /* TRANSFER */

    function _nativeTransfer(address recipient, uint256 amount, CoreAdapter adapter)
        internal
        pure
        returns (Call memory)
    {
        return _call(adapter, abi.encodeCall(adapter.nativeTransfer, (recipient, amount)));
    }

    function _nativeTransferNoFunding(address recipient, uint256 amount, CoreAdapter adapter)
        internal
        pure
        returns (Call memory)
    {
        return _call(adapter, abi.encodeCall(adapter.nativeTransfer, (recipient, amount)), uint256(0));
    }

    /* ERC20 ACTIONS */

    function _erc20Transfer(address token, address recipient, uint256 amount, CoreAdapter adapter)
        internal
        pure
        returns (Call memory)
    {
        return _call(adapter, abi.encodeCall(adapter.erc20Transfer, (token, recipient, amount)));
    }

    function _erc20TransferFrom(address token, address recipient, uint256 amount) internal view returns (Call memory) {
        return _call(generalAdapter1, abi.encodeCall(GeneralAdapter1.erc20TransferFrom, (token, recipient, amount)));
    }

    function _erc20TransferFrom(address token, uint256 amount) internal view returns (Call memory) {
        return _erc20TransferFrom(token, address(generalAdapter1), amount);
    }

    /* PERMIT */

    function _permit(
        address token,
        uint256 privateKey,
        address spender,
        uint256 amount,
        uint256 deadline,
        bool skipRevert
    ) internal view returns (Call memory) {
        address user = vm.addr(privateKey);

        Permit memory permit = Permit(user, spender, amount, ERC20(token).nonces(user), deadline);

        bytes32 digest = SigUtils.getTypedDataHash(ERC20(token).DOMAIN_SEPARATOR(), permit);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        bytes memory callData = abi.encodeCall(ERC20.permit, (user, spender, amount, deadline, v, r, s));

        return _call(token, callData, 0, skipRevert);
    }

    /* PERMIT2 ACTIONS */

    /// @dev Grants a canonical Permit2 allowance to `generalAdapter1` by signature.
    function _approve2(uint256 privateKey, address token, uint256 amount, uint256 nonce, bool skipRevert)
        internal
        view
        returns (Call memory)
    {
        address user = vm.addr(privateKey);

        PermitSingle memory permitSingle = PermitSingle({
            details: PermitDetails({
                token: token, amount: uint160(amount), expiration: uint48(SIGNATURE_DEADLINE), nonce: uint48(nonce)
            }),
            spender: address(generalAdapter1),
            sigDeadline: SIGNATURE_DEADLINE
        });

        bytes32 digest = PermitUtils.getTypedDataHash(
            IPermit2(PermitUtils.PERMIT2).DOMAIN_SEPARATOR(),
            token,
            uint160(amount),
            uint48(SIGNATURE_DEADLINE),
            uint48(nonce),
            address(generalAdapter1),
            SIGNATURE_DEADLINE
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        return _call(
            PermitUtils.PERMIT2,
            abi.encodeCall(IPermit2.permit, (user, permitSingle, abi.encodePacked(r, s, v))),
            0,
            skipRevert
        );
    }

    function _permit2TransferFrom(address token, address receiver, uint256 amount) internal view returns (Call memory) {
        return _call(generalAdapter1, abi.encodeCall(GeneralAdapter1.permit2TransferFrom, (token, receiver, amount)));
    }

    function _permit2TransferFrom(address token, uint256 amount) internal view returns (Call memory) {
        return _permit2TransferFrom(token, address(generalAdapter1), amount);
    }

    /* ERC4626 ACTIONS */

    function _erc4626Mint(address vault, uint256 shares, uint256 maxSharePriceE27, address receiver)
        internal
        view
        returns (Call memory)
    {
        return _call(
            generalAdapter1, abi.encodeCall(GeneralAdapter1.erc4626Mint, (vault, shares, maxSharePriceE27, receiver))
        );
    }

    function _erc4626Deposit(address vault, uint256 assets, uint256 maxSharePriceE27, address receiver)
        internal
        view
        returns (Call memory)
    {
        return _call(
            generalAdapter1, abi.encodeCall(GeneralAdapter1.erc4626Deposit, (vault, assets, maxSharePriceE27, receiver))
        );
    }

    function _erc4626Withdraw(address vault, uint256 assets, uint256 minSharePriceE27, address receiver, address owner)
        internal
        view
        returns (Call memory)
    {
        return _call(
            generalAdapter1,
            abi.encodeCall(GeneralAdapter1.erc4626Withdraw, (vault, assets, minSharePriceE27, receiver, owner))
        );
    }

    function _erc4626Redeem(address vault, uint256 shares, uint256 minSharePriceE27, address receiver, address owner)
        internal
        view
        returns (Call memory)
    {
        return _call(
            generalAdapter1,
            abi.encodeCall(GeneralAdapter1.erc4626Redeem, (vault, shares, minSharePriceE27, receiver, owner))
        );
    }

    /* WRAPPED NATIVE ACTIONS */

    function _wrapNative(uint256 amount, address receiver) internal view returns (Call memory) {
        return _call(generalAdapter1, abi.encodeCall(GeneralAdapter1.wrapNative, (amount, receiver)));
    }

    function _unwrapNative(uint256 amount, address receiver) internal view returns (Call memory) {
        return _call(generalAdapter1, abi.encodeCall(GeneralAdapter1.unwrapNative, (amount, receiver)));
    }

    /* MORPHO ACTIONS */

    function _morphoFlashLoan(address token, uint256 amount) internal view returns (Call memory) {
        bytes memory data = abi.encode(callbackBundle);
        return
            _call(
                generalAdapter1, abi.encodeCall(GeneralAdapter1.morphoFlashLoan, (token, amount, data)), keccak256(data)
            );
    }

    /* IRIS ACTIONS */

    function _irisSetAuthorizationWithSig(uint256 privateKey, bool isAuthorized, uint256 nonce, bool skipRevert)
        internal
        view
        returns (Call memory)
    {
        address user = vm.addr(privateKey);

        Authorization memory authorization = Authorization({
            authorizer: user,
            authorized: address(generalAdapter1),
            isAuthorized: isAuthorized,
            nonce: nonce,
            deadline: SIGNATURE_DEADLINE
        });

        bytes32 digest = SigUtils.getTypedDataHash(iris.DOMAIN_SEPARATOR(), authorization);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        return _call(
            address(iris),
            abi.encodeCall(iris.setAuthorizationWithSig, (authorization, abi.encodePacked(r, s, v))),
            0,
            skipRevert
        );
    }

    function _irisTake(Quote memory quote, bytes memory signature) internal view returns (Call memory) {
        return _call(generalAdapter1, abi.encodeCall(GeneralAdapter1.irisTake, (quote, signature)));
    }

    function _irisRepay(address pod, address token) internal view returns (Call memory) {
        return _call(generalAdapter1, abi.encodeCall(GeneralAdapter1.irisRepay, (pod, token)));
    }

    function _irisSupplyCollateral(address pod, address token, uint256 amount) internal view returns (Call memory) {
        return _call(generalAdapter1, abi.encodeCall(GeneralAdapter1.irisSupplyCollateral, (pod, token, amount)));
    }

    function _irisSupplyBond(address pod, address token, uint256 amount) internal view returns (Call memory) {
        return _call(generalAdapter1, abi.encodeCall(GeneralAdapter1.irisSupplyBond, (pod, token, amount)));
    }

    function _irisWithdrawCollateral(address pod, uint256 amount, address receiver)
        internal
        view
        returns (Call memory)
    {
        return _call(generalAdapter1, abi.encodeCall(GeneralAdapter1.irisWithdrawCollateral, (pod, amount, receiver)));
    }

    function _irisWithdrawBond(address pod, uint256 amount, address receiver) internal view returns (Call memory) {
        return _call(generalAdapter1, abi.encodeCall(GeneralAdapter1.irisWithdrawBond, (pod, amount, receiver)));
    }

    function _irisClaim(address token, uint256 amount, address receiver) internal view returns (Call memory) {
        return _call(generalAdapter1, abi.encodeCall(GeneralAdapter1.irisClaim, (token, amount, receiver)));
    }

    function _irisEscape(address pod, address receiver) internal view returns (Call memory) {
        return _call(generalAdapter1, abi.encodeCall(GeneralAdapter1.irisEscape, (pod, receiver)));
    }

    function _irisRefinance(address pod, address receiver, uint256 newVenueId, bytes memory data)
        internal
        view
        returns (Call memory)
    {
        return _call(generalAdapter1, abi.encodeCall(GeneralAdapter1.irisRefinance, (pod, receiver, newVenueId, data)));
    }
}
