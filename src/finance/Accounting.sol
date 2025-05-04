// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {IFarm} from "@interfaces/IFarm.sol";
import {IOracle} from "@interfaces/IOracle.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {FarmRegistry} from "@integrations/FarmRegistry.sol";
import {CoreControlled} from "@core/CoreControlled.sol";
import {FixedPriceOracle} from "@finance/oracles/FixedPriceOracle.sol";

/// @notice InfiniFi Accounting contract
contract Accounting is CoreControlled {
    using FixedPointMathLib for uint256;

    event PriceSet(uint256 indexed timestamp, address indexed asset, uint256 price);
    event OracleSet(uint256 indexed timestamp, address indexed asset, address oracle);

    /// @notice reference to the farm registry
    address public immutable farmRegistry;

    constructor(address _core, address _farmRegistry) CoreControlled(_core) {
        farmRegistry = _farmRegistry;
    }

    /// @notice mapping from asset to oracle
    mapping(address => address) public oracle;

    /// @notice returns the price of an asset
    function price(address _asset) external view returns (uint256) {
        return IOracle(oracle[_asset]).price(); //用asset地址 查詢任何asset 的價格。  但會先指定asset地址是一個Ioracle(裡面的f-price 一定要有
                                            //function price() external view returns (uint256);)  改任何一點都不行
    }

    /// @notice set the oracle for an asset
    function setOracle(address _asset, address _oracle) external onlyCoreRole(CoreRoles.ORACLE_MANAGER) {
        oracle[_asset] = _oracle;              //把資產地址 = _oracle地址
        emit OracleSet(block.timestamp, _asset, _oracle);
    }

    /// @notice set the price of an asset
    function setPrice(address _asset, uint256 _price) external onlyCoreRole(CoreRoles.ORACLE_MANAGER) {
        FixedPriceOracle(oracle[_asset]).setPrice(_price);
        emit PriceSet(block.timestamp, _asset, _price);
    }

    /// -------------------------------------------------------------------------------------------
    /// Reference token getters (e.g. USD for iUSD, ETH for iETH, ...)
    /// @dev note that the "USD" token does not exist, it is just an abstract unit of account
    /// used in the protocol to represent stablecoins pegged to USD, that allows to uniformly
    /// account for a diverse reserve composed of USDC, DAI, FRAX, etc.
    /// -------------------------------------------------------------------------------------------

    /// @notice returns the sum of the value of all assets held on protocol contracts listed in the farm registry.
    function totalAssetsValue() external view returns (uint256 _totalValue) {
        address[] memory assets = FarmRegistry(farmRegistry).getEnabledAssets();
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 assetPrice = IOracle(oracle[assets[i]]).price(); //每個farm都有跟Ioracle定義的一魔一樣的price函數方便這邊查詢
            uint256 _assets = _calculateTotalAssets(FarmRegistry(farmRegistry).getAssetFarms(assets[i])); //上面的Ioracle有明確interface 但這邊的FarmRegistry沒有，這是可以的。因為solidity合約本身
            _totalValue += _assets.mulWadDown(assetPrice);                                                 //就隱含著"我自己就是interface"的功能。 所以只要地址合約有跟farmResgitry裡面f-getAssetfarm開頭部分一模一樣的
                                                                                                            //函數，執行的時候就也不會出錯 (沒有的話，編譯還是會通過(它會假設ABI相符)，但是執行環節會出錯)
        }
    }

    /// @notice returns the sum of the value of all liquid assets held on protocol contracts listed in the farm registry.
    /// @dev see totalAssetsValue()
    function totalAssetsValueOf(uint256 _type) external view returns (uint256 _totalValue) {
        address[] memory assets = FarmRegistry(farmRegistry).getEnabledAssets();
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 assetPrice = IOracle(oracle[assets[i]]).price();
            address[] memory assetFarms = FarmRegistry(farmRegistry).getAssetTypeFarms(assets[i], uint256(_type));
            uint256 _assets = _calculateTotalAssets(assetFarms);
            _totalValue += _assets.mulWadDown(assetPrice);
        }
    }

    /// -------------------------------------------------------------------------------------------
    /// Specific asset getters (e.g. USDC, DAI, ...)
    /// -------------------------------------------------------------------------------------------

    /// @notice returns the sum of the balance of all farms of a given asset.  上面兩個是算價值，這邊下面兩個是算數量的吧
    function totalAssets(address _asset) external view returns (uint256) {
        return _calculateTotalAssets(FarmRegistry(farmRegistry).getAssetFarms(_asset));
    }

    function totalAssetsOf(address _asset, uint256 _type) external view returns (uint256) {
        return _calculateTotalAssets(FarmRegistry(farmRegistry).getAssetTypeFarms(_asset, uint256(_type)));
    }

    /// -------------------------------------------------------------------------------------------
    /// Internal helpers
    /// -------------------------------------------------------------------------------------------

    function _calculateTotalAssets(address[] memory _farms) internal view returns (uint256 _totalAssets) {
        uint256 length = _farms.length;
        for (uint256 index = 0; index < length; index++) {
            _totalAssets += IFarm(_farms[index]).assets();       //.asset方法的實作應該是會在 _farm地址的合約裡面有定義，因為ifarm只是interface 。 但所以目前我就看不到asset函數是幹嘛的
            //
        }
    }
}
