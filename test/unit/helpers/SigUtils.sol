// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {AUTHORIZATION_TYPEHASH, QUOTE_TYPEHASH} from "../../../src/libraries/ConstantsLib.sol";
import {Authorization, Quote} from "../../../src/interfaces/IIris.sol";

library SigUtils {
    /// @dev Computes the hash of the EIP-712 encoded data.
    function getTypedDataHash(bytes32 domainSeparator, Authorization memory authorization)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(bytes.concat("\x19\x01", domainSeparator, hashStruct(authorization)));
    }

    /// @dev Computes the hash of the EIP-712 encoded data.
    function getTypedDataHash(bytes32 domainSeparator, Quote memory quote) internal pure returns (bytes32) {
        return keccak256(bytes.concat("\x19\x01", domainSeparator, hashStruct(quote)));
    }

    function hashStruct(Authorization memory authorization) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                AUTHORIZATION_TYPEHASH,
                authorization.authorizer,
                authorization.authorized,
                authorization.isAuthorized,
                authorization.nonce,
                authorization.deadline
            )
        );
    }

    function hashStruct(Quote memory quote) internal pure returns (bytes32) {
        // Split into two abi.encode calls joined with bytes.concat to stay under the via-IR stack limit.
        // Every field is a static one-word type, so the concatenation is byte-identical to a single
        // abi.encode of all 20 elements, and therefore produces the same EIP-712 hash.
        return keccak256(
            bytes.concat(
                abi.encode(
                    QUOTE_TYPEHASH,
                    quote.borrower,
                    quote.solver,
                    quote.receiver,
                    quote.blm,
                    quote.collateralToken,
                    quote.debtToken,
                    quote.collateral,
                    quote.debt,
                    quote.fixedRate
                ),
                abi.encode(
                    quote.duration,
                    quote.overdueRate,
                    quote.overduePeriod,
                    quote.bond,
                    quote.bondLltv,
                    quote.venueBitmap,
                    quote.venueId,
                    quote.deadline,
                    quote.nonce,
                    keccak256(quote.data)
                )
            )
        );
    }
}
