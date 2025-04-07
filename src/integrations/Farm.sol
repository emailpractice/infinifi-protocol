// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IFarm} from "@interfaces/IFarm.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {CoreControlled} from "@core/CoreControlled.sol";

/// @notice InfiniFi Farm base contract
abstract contract Farm is CoreControlled, IFarm {
    address public immutable assetToken;
    uint256 public cap;

    error CapExceeded(uint256 newAmount, uint256 cap);

    event CapUpdated(uint256 newCap);

    constructor(address _core, address _assetToken) CoreControlled(_core) {
        assetToken = _assetToken;
        cap = type(uint256).max;
    }

    // Add cap setter function
    function setCap(uint256 _newCap) external onlyCoreRole(CoreRoles.FARM_MANAGER) {
        cap = _newCap;
        emit CapUpdated(_newCap);
    }

    // --------------------------------------------------------------------
    // Accounting
    // --------------------------------------------------------------------

    function assets() public view virtual returns (uint256) {
        return ERC20(assetToken).balanceOf(address(this));
    }

    // --------------------------------------------------------------------
    // Adapter logic
    // --------------------------------------------------------------------

    function maxDeposit() external view virtual returns (uint256) {
        uint256 currentAssets = assets();
        if (currentAssets >= cap) {
            return 0;
        }
        // If the underlying protocol has a max deposit, use that instead of the cap
        uint256 underlyingProtocolMaxDeposit = _underlyingProtocolMaxDeposit();
        uint256 defaultMaxDeposit = cap - currentAssets;
        return underlyingProtocolMaxDeposit < defaultMaxDeposit ? underlyingProtocolMaxDeposit : defaultMaxDeposit;
    }

    function deposit() external onlyCoreRole(CoreRoles.FARM_MANAGER) whenNotPaused {
        uint256 currentAssets = assets();

        if (currentAssets > cap) {
            revert CapExceeded(currentAssets, cap);
        }

        _deposit();
    }

    function _deposit() internal virtual;

    function _underlyingProtocolMaxDeposit() internal view virtual returns (uint256) {
        return type(uint256).max;
    }

    function withdraw(uint256 amount, address to) external onlyCoreRole(CoreRoles.FARM_MANAGER) whenNotPaused {
        _withdraw(amount, to);
    }

    function _withdraw(uint256, address) internal virtual;
}
