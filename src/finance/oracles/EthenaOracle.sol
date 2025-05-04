// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOracle} from "@interfaces/IOracle.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/// @notice Returns the price of sUSDe, looking only at the exchange rate of the vault,
/// and hardcoding the value of USDC & USDe to 1$.
contract EthenaOracle is IOracle {
    address public constant sUSDe = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;   //usde 是一種穩定幣 sUSDe好像是他的質押代幣，所以這個協議應該是把用戶的錢拿去susde賺錢了我猜 可能susde也有lock或stake兩種
                                                    //還有另外一個oracle 我搜尋.price 看看程式碼 判斷出另一個oracle是iusd 他的.price不像這邊是函數 而是public variable
                                                
    function price() external view override returns (uint256) {
        return 1e36 / ERC4626(sUSDe).convertToAssets(1e6);
    }
}
