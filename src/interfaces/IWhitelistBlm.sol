// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {IBlm} from "./IBlm.sol";

interface IWhitelistBlm is IBlm {
    // Events
    event SetIsWhitelisted(address indexed account, bool isWhitelisted);

    // Functions
    function setIsWhitelisted(address account, bool newIsWhitelisted) external;
}
