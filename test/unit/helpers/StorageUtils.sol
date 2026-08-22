// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Vm} from "forge-std/Vm.sol";

/// @dev Test-only storage manipulation helpers for the Iris contract.
/// @dev Layout source of truth: `forge inspect Iris storage-layout`.
library StorageUtils {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /* TOP-LEVEL STORAGE SLOTS */

    uint256 internal constant LOAN_MAPPING_SLOT = 0;
    uint256 internal constant POSITION_MAPPING_SLOT = 1;
    uint256 internal constant VENUE_ADAPTER_MAPPING_SLOT = 2;
    uint256 internal constant CLAIMABLE_MAPPING_SLOT = 3;
    uint256 internal constant IS_BLM_ENABLED_MAPPING_SLOT = 4;
    uint256 internal constant IS_BOND_LLTV_ENABLED_MAPPING_SLOT = 5;
    uint256 internal constant IS_DATA_ENABLED_MAPPING_SLOT = 6;
    uint256 internal constant IS_AUTHORIZED_MAPPING_SLOT = 7;
    uint256 internal constant IS_NONCE_USED_MAPPING_SLOT = 8;
    uint256 internal constant OWNER_SLOT = 9;
    uint256 internal constant FEE_RECIPIENT_AND_FEE_SLOT = 10;

    /* BASE SLOTS FOR LOAN[pod] AND POSITION[pod] */

    function loanSlot(address pod) internal pure returns (bytes32) {
        return keccak256(abi.encode(pod, LOAN_MAPPING_SLOT));
    }

    function positionSlot(address pod) internal pure returns (bytes32) {
        return keccak256(abi.encode(pod, POSITION_MAPPING_SLOT));
    }

    /* TOP-LEVEL FIELD SETTERS */

    function setOwner(address iris, address newOwner) internal {
        vm.store(iris, bytes32(OWNER_SLOT), bytes32(uint256(uint160(newOwner))));
    }

    function setFeeRecipient(address iris, address newRecipient) internal {
        _writePacked(iris, bytes32(FEE_RECIPIENT_AND_FEE_SLOT), 0, 160, uint160(newRecipient));
    }

    function setFee(address iris, uint16 newFee) internal {
        _writePacked(iris, bytes32(FEE_RECIPIENT_AND_FEE_SLOT), 160, 16, newFee);
    }

    /* MAPPING SETTERS */

    function setIsNonceUsed(address iris, address authorizer, uint256 nonce, bool value) internal {
        bytes32 slot = keccak256(abi.encode(nonce, keccak256(abi.encode(authorizer, IS_NONCE_USED_MAPPING_SLOT))));
        vm.store(iris, slot, value ? bytes32(uint256(1)) : bytes32(0));
    }

    function setIsAuthorized(address iris, address authorizer, address authorized, bool value) internal {
        bytes32 slot = keccak256(abi.encode(authorized, keccak256(abi.encode(authorizer, IS_AUTHORIZED_MAPPING_SLOT))));
        vm.store(iris, slot, value ? bytes32(uint256(1)) : bytes32(0));
    }

    function setIsBlmEnabled(address iris, address blm, bool value) internal {
        vm.store(
            iris, keccak256(abi.encode(blm, IS_BLM_ENABLED_MAPPING_SLOT)), value ? bytes32(uint256(1)) : bytes32(0)
        );
    }

    function setIsBondLltvEnabled(address iris, uint256 lltv, bool value) internal {
        vm.store(
            iris,
            keccak256(abi.encode(lltv, IS_BOND_LLTV_ENABLED_MAPPING_SLOT)),
            value ? bytes32(uint256(1)) : bytes32(0)
        );
    }

    function setIsDataEnabled(address iris, bytes32 data, bool value) internal {
        vm.store(
            iris, keccak256(abi.encode(data, IS_DATA_ENABLED_MAPPING_SLOT)), value ? bytes32(uint256(1)) : bytes32(0)
        );
    }

    function setVenueAdapter(address iris, uint256 venueId, address adapter) internal {
        vm.store(iris, keccak256(abi.encode(venueId, VENUE_ADAPTER_MAPPING_SLOT)), bytes32(uint256(uint160(adapter))));
    }

    function setClaimable(address iris, address token, address account, uint256 amount) internal {
        bytes32 slot = keccak256(abi.encode(account, keccak256(abi.encode(token, CLAIMABLE_MAPPING_SLOT))));
        vm.store(iris, slot, bytes32(amount));
    }

    /* LOAN STRUCT FIELD SETTERS */
    /// @dev Packed slot layout for `_loan[pod]` (offsets relative to `loanSlot(pod)`):
    ///   +0: borrower (bit 0, 160)
    ///   +1: solver (bit 0, 160)
    ///   +2: collateralToken (bit 0, 160)
    ///   +3: debtToken (bit 0, 160)
    ///   +4: venueBitmap (bit 0, 128) + maturity (128, 32) + overduePeriod (160, 32)
    ///       + fixedRate (192, 16) + overdueRate (208, 16) + bondLltv (224, 16) + fee (240, 16)

    function setLoanBorrower(address iris, address pod, address borrower) internal {
        vm.store(iris, bytes32(uint256(loanSlot(pod)) + 0), bytes32(uint256(uint160(borrower))));
    }

    function setLoanSolver(address iris, address pod, address solver) internal {
        vm.store(iris, bytes32(uint256(loanSlot(pod)) + 1), bytes32(uint256(uint160(solver))));
    }

    function setLoanCollateralToken(address iris, address pod, address token) internal {
        vm.store(iris, bytes32(uint256(loanSlot(pod)) + 2), bytes32(uint256(uint160(token))));
    }

    function setLoanDebtToken(address iris, address pod, address token) internal {
        vm.store(iris, bytes32(uint256(loanSlot(pod)) + 3), bytes32(uint256(uint160(token))));
    }

    function setLoanVenueBitmap(address iris, address pod, uint256 bitmap) internal {
        _writePacked(iris, bytes32(uint256(loanSlot(pod)) + 4), 0, 128, bitmap);
    }

    function setLoanMaturity(address iris, address pod, uint32 maturity) internal {
        _writePacked(iris, bytes32(uint256(loanSlot(pod)) + 4), 128, 32, maturity);
    }

    function setLoanOverduePeriod(address iris, address pod, uint32 overduePeriod) internal {
        _writePacked(iris, bytes32(uint256(loanSlot(pod)) + 4), 160, 32, overduePeriod);
    }

    function setLoanFixedRate(address iris, address pod, uint16 fixedRate) internal {
        _writePacked(iris, bytes32(uint256(loanSlot(pod)) + 4), 192, 16, fixedRate);
    }

    function setLoanOverdueRate(address iris, address pod, uint16 overdueRate) internal {
        _writePacked(iris, bytes32(uint256(loanSlot(pod)) + 4), 208, 16, overdueRate);
    }

    function setLoanBondLltv(address iris, address pod, uint16 bondLltv) internal {
        _writePacked(iris, bytes32(uint256(loanSlot(pod)) + 4), 224, 16, bondLltv);
    }

    function setLoanFee(address iris, address pod, uint16 fee_) internal {
        _writePacked(iris, bytes32(uint256(loanSlot(pod)) + 4), 240, 16, fee_);
    }

    /* POSITION STRUCT FIELD SETTERS */
    /// @dev Packed slot layout for `_position[pod]` (offsets relative to `positionSlot(pod)`):
    ///   +0: collateral (bit 0, 128) + debt (128, 128)
    ///   +1: bond (bit 0, 128) + bondRequirement (128, 128)
    ///   +2: collateralIndex (bit 0, 128) + debtIndex (128, 128)
    ///   +3: fixedLeg (bit 0, 128) + floatingLeg (128, 128)
    ///   +4: surplus (bit 0, 128) + lastUpdate (128, 32) + venueId (160, 8)
    ///   +5: data (bytes)

    function setPositionCollateral(address iris, address pod, uint128 collateral) internal {
        _writePacked(iris, bytes32(uint256(positionSlot(pod)) + 0), 0, 128, collateral);
    }

    function setPositionDebt(address iris, address pod, uint128 debt) internal {
        _writePacked(iris, bytes32(uint256(positionSlot(pod)) + 0), 128, 128, debt);
    }

    function setPositionBond(address iris, address pod, uint128 bond) internal {
        _writePacked(iris, bytes32(uint256(positionSlot(pod)) + 1), 0, 128, bond);
    }

    function setPositionBondRequirement(address iris, address pod, uint128 bondRequirement) internal {
        _writePacked(iris, bytes32(uint256(positionSlot(pod)) + 1), 128, 128, bondRequirement);
    }

    function setPositionCollateralIndex(address iris, address pod, uint128 collateralIndex) internal {
        _writePacked(iris, bytes32(uint256(positionSlot(pod)) + 2), 0, 128, collateralIndex);
    }

    function setPositionDebtIndex(address iris, address pod, uint128 debtIndex) internal {
        _writePacked(iris, bytes32(uint256(positionSlot(pod)) + 2), 128, 128, debtIndex);
    }

    function setPositionFixedLeg(address iris, address pod, uint128 fixedLeg) internal {
        _writePacked(iris, bytes32(uint256(positionSlot(pod)) + 3), 0, 128, fixedLeg);
    }

    function setPositionFloatingLeg(address iris, address pod, uint128 floatingLeg) internal {
        _writePacked(iris, bytes32(uint256(positionSlot(pod)) + 3), 128, 128, floatingLeg);
    }

    function setPositionSurplus(address iris, address pod, uint128 surplus) internal {
        _writePacked(iris, bytes32(uint256(positionSlot(pod)) + 4), 0, 128, surplus);
    }

    function setPositionLastUpdate(address iris, address pod, uint32 lastUpdate) internal {
        _writePacked(iris, bytes32(uint256(positionSlot(pod)) + 4), 128, 32, lastUpdate);
    }

    function setPositionVenueId(address iris, address pod, uint8 venueId) internal {
        _writePacked(iris, bytes32(uint256(positionSlot(pod)) + 4), 160, 8, venueId);
    }

    function setPositionData(address iris, address pod, bytes memory data) internal {
        bytes32 headerSlot = bytes32(uint256(positionSlot(pod)) + 5);
        uint256 length = data.length;

        if (length == 0) {
            vm.store(iris, headerSlot, 0);
            return;
        }

        if (length < 32) {
            bytes32 packed;
            assembly {
                packed := mload(add(data, 32))
            }
            bytes32 contentMask = ~bytes32((uint256(1) << ((32 - length) * 8)) - 1);
            vm.store(iris, headerSlot, (packed & contentMask) | bytes32(length * 2));
        } else {
            vm.store(iris, headerSlot, bytes32(length * 2 + 1));
            bytes32 contentSlot = keccak256(abi.encode(headerSlot));
            uint256 chunks = (length + 31) / 32;
            for (uint256 i = 0; i < chunks; i++) {
                bytes32 chunk;
                assembly {
                    chunk := mload(add(add(data, 32), mul(i, 32)))
                }
                vm.store(iris, bytes32(uint256(contentSlot) + i), chunk);
            }
        }
    }

    /* INTERNAL */

    function _writePacked(address iris, bytes32 slot, uint256 bitOffset, uint256 bitWidth, uint256 value) private {
        bytes32 current = vm.load(iris, slot);
        uint256 mask = ((uint256(1) << bitWidth) - 1) << bitOffset;
        vm.store(iris, slot, bytes32((uint256(current) & ~mask) | ((value << bitOffset) & mask)));
    }
}
