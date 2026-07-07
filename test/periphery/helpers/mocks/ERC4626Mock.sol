// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {ERC4626} from "@solady/tokens/ERC4626.sol";

contract ERC4626Mock is ERC4626 {
    address internal immutable _ASSET;
    string internal _name;
    string internal _symbol;

    constructor(address asset_, string memory name_, string memory symbol_) {
        _ASSET = asset_;
        _name = name_;
        _symbol = symbol_;
    }

    function asset() public view override returns (address) {
        return _ASSET;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }
}
