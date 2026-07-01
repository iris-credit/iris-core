// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IWhitelistBlm} from "../interfaces/IWhitelistBlm.sol";
import {IIris, Quote} from "../interfaces/IIris.sol";
import {WAD} from "../libraries/ConstantsLib.sol";
import {MathLib} from "../libraries/MathLib.sol";

contract WhitelistBlm is IWhitelistBlm {
    using MathLib for uint256;

    /* IMMUTABLES */

    IIris public immutable IRIS;

    /* STORAGE */

    mapping(address => bool) public isWhitelisted;
    mapping(address => uint256) public slope;
    mapping(address => uint256) public intercept;

    /* CONSTRUCTOR */

    constructor(address iris) {
        require(iris != address(0), ZeroAddress());
        IRIS = IIris(iris);
    }

    /* SETTER */

    function setParams(address token, uint256 newSlope, uint256 newIntercept) external {
        require(msg.sender == IRIS.owner(), Unauthorized());
        require(token != address(0), ZeroAddress());
        require(newSlope != 0, ZeroAmount());
        require(newSlope < WAD && newIntercept < WAD, ParamsTooHigh());
        slope[token] = newSlope;
        intercept[token] = newIntercept;
        emit SetParams(token, newSlope, newIntercept);
    }

    function setIsWhitelisted(address account, bool newIsWhitelisted) external {
        require(msg.sender == IRIS.owner(), Unauthorized());
        isWhitelisted[account] = newIsWhitelisted;
        emit SetIsWhitelisted(account, newIsWhitelisted);
    }

    /* BOND REQUIREMENT */

    function bondRequirement(Quote calldata quote) external view returns (uint256) {
        require(isWhitelisted[quote.solver], Unauthorized());
        uint256 ratio = slope[quote.debtToken].mulDivDown(quote.duration, 1 days) + intercept[quote.debtToken];
        return quote.debt.mulDivDown(ratio, WAD);
    }
}
