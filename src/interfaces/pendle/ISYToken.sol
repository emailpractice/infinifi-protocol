// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ISYToken {
    function getAbsoluteSupplyCap() external view returns (uint256);

    function getAbsoluteTotalSupply() external view returns (uint256);
}
