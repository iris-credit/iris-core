// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @notice Library exposing error messages.
library ErrorsLib {
    /* STANDARD ADAPTERS */

    /// @dev Thrown when a multicall is attempted while a bundle is already initiated.
    error AlreadyInitiated();

    /// @dev Thrown when a call is attempted from an unauthorized sender.
    error UnauthorizedSender();

    /// @dev Thrown when a reenter is attempted but the concatenation of the sender and bundle does not hash to the
    /// pre-recorded `reenterHash`.
    error IncorrectReenterHash();

    /// @dev Thrown when a multicall is attempted with an empty bundle.
    error EmptyBundle();

    /// @dev Thrown when a reenter was expected but did not happen.
    error MissingExpectedReenter();

    /// @dev Thrown when a call is attempted with a zero address as input.
    error ZeroAddress();

    /// @dev Thrown when a call is attempted with the adapter address as input.
    error AdapterAddress();

    /// @dev Thrown when a call is attempted with a zero amount as input.
    error ZeroAmount();

    /// @dev Thrown when a call is attempted with a zero shares as input.
    error ZeroShares();

    /// @dev Thrown when the given owner is unexpected.
    error UnexpectedOwner();

    /// @dev Thrown when an action ends up minting/burning more shares than a given slippage.
    error SlippageExceeded();

    /* IRIS ADAPTER */

    /// @dev Thrown when the initiator is not authorized to act on a loan.
    error UnauthorizedInitiator();
}
