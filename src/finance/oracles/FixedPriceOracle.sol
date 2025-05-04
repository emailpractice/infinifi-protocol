// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOracle} from "@interfaces/IOracle.sol";
import {CoreControlled, CoreRoles} from "@core/CoreControlled.sol";

contract FixedPriceOracle is IOracle, CoreControlled {
    uint256 public price;

    event PriceSet(uint256 indexed timestamp, uint256 price);

    constructor(address _core, uint256 _price) CoreControlled(_core) {
        price = _price;
    }

    function setPrice(uint256 _price) external onlyCoreRole(CoreRoles.ORACLE_MANAGER) {
        price = _price;
        emit PriceSet(block.timestamp, _price);
    }
}
// 不是去讀取iusd 或是 accounting裡面 oracle [iusd] 的值。 他就是把價格存在price。 我猜是其他地方決定價格 然後呼叫setPrice把價格存好
// acounting可查 setprice和setoracle