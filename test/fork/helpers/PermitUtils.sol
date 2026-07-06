// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

struct PermitDetails {
    address token;
    uint160 amount;
    uint48 expiration;
    uint48 nonce;
}

struct PermitSingle {
    PermitDetails details;
    address spender;
    uint256 sigDeadline;
}

interface IPermit2 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
    function permit(address owner, PermitSingle memory permitSingle, bytes calldata signature) external;
}

library PermitUtils {
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    bytes32 internal constant PERMIT_DETAILS_TYPEHASH =
        keccak256("PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)");
    bytes32 internal constant PERMIT_SINGLE_TYPEHASH = keccak256(
        "PermitSingle(PermitDetails details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
    );

    /// @dev Computes the hash of the Permit2 EIP-712 encoded data.
    function getTypedDataHash(
        bytes32 domainSeparator,
        address token,
        uint160 amount,
        uint48 expiration,
        uint48 nonce,
        address spender,
        uint256 sigDeadline
    ) internal pure returns (bytes32) {
        bytes32 detailsHash = keccak256(abi.encode(PERMIT_DETAILS_TYPEHASH, token, amount, expiration, nonce));
        bytes32 permitHash = keccak256(abi.encode(PERMIT_SINGLE_TYPEHASH, detailsHash, spender, sigDeadline));

        return keccak256(bytes.concat("\x19\x01", domainSeparator, permitHash));
    }
}
