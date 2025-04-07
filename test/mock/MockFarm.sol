// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Farm} from "@integrations/Farm.sol";

contract MockFarm is Farm {
    // this function is required to ignore this file from coverage
    function test() public pure {}

    uint256 public liquidityPercentage = 1e18; // default = 100% liquid
    uint256 public _maturity = 0;

    constructor(address _core, address _assetToken) Farm(_core, _assetToken) {}

    function liquidity() external view override returns (uint256) {
        return assets() * liquidityPercentage / 1e18;
    }

    function setLiquidityPercentage(uint256 _liquidityPercentage) external {
        liquidityPercentage = _liquidityPercentage;
    }

    function _deposit() internal override {} // noop

    function _withdraw(uint256 amount, address to) internal override {
        require(ERC20(assetToken).transfer(to, amount), "MockFarm: transfer failed");
    }

    function maturity() public view returns (uint256) {
        return _maturity == 0 ? block.timestamp : _maturity;
    }

    function mockSetMaturity(uint256 __maturity) external {
        _maturity = __maturity;
    }
}
