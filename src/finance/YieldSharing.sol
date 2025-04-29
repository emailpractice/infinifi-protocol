// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {Accounting} from "@finance/Accounting.sol";
import {StakedToken} from "@tokens/StakedToken.sol";
import {ReceiptToken} from "@tokens/ReceiptToken.sol";
import {CoreControlled} from "@core/CoreControlled.sol";
import {LockingController} from "@locking/LockingController.sol";

/// @notice InfiniFi YieldSharing contract
/// @dev This contract is used to distribute yield between iUSD locking users and siUSD holders.
/// @dev It also holds idle iUSD that can be used to slash losses or distribute profits.
contract YieldSharing is
    CoreControlled //@seashell 繼承modifier
{
    using FixedPointMathLib for uint256;

    error PerformanceFeeTooHigh(uint256 _percent);
    error PerformanceFeeRecipientIsZeroAddress(address _recipient);
    error TargetIlliquidRatioTooHigh(uint256 _ratio);

    /// @notice Fired when yield is accrued from frarms
    /// @param timestamp block timestamp of the accrual
    /// @param yield profit or loss in farms since last accrual
    event YieldAccrued(uint256 indexed timestamp, int256 yield);
    event TargetIlliquidRatioUpdated(
        uint256 indexed timestamp,
        uint256 multiplier
    );
    event SafetyBufferSizeUpdated(uint256 indexed timestamp, uint256 value);
    event LiquidMultiplierUpdated(
        uint256 indexed timestamp,
        uint256 multiplier
    );
    event PerformanceFeeSettingsUpdated(
        uint256 indexed timestamp,
        uint256 percentage,
        address recipient
    );

    uint256 public constant MAX_PERFORMANCE_FEE = 0.2e18; // 20%

    /// @notice reference to farm accounting contract
    address public immutable accounting;

    /// @notice reference to receipt token
    address public immutable receiptToken;

    /// @notice reference to staked token
    address public immutable stakedToken;

    /// @notice reference to locking module
    address public immutable lockingModule;

    /// @notice safety buffer amount.
    /// This amount of iUSD is held on the contract and consumed first in case of losses smaller
    /// than the safety buffer. It is also replenished first in case of profit, up to the buffer size.
    /// The buffer held could exceed safetyBufferSize if there are donations to this contract, or if
    /// the buffer size has been reduced since last profit distribution, or if there are no other
    /// users to distribute to.
    /// The safety buffer is meant to absorb small losses such as slippage or fees when
    /// deploying capital to productive farms.
    /// safety buffer can be emptied by governance through the use of emergencyAction().
    uint256 public safetyBufferSize;

    /// @notice optional performance fee, expressed as a percentage with 18 decimals.
    uint256 public performanceFee; // default to 0%

    /// @notice optional performance fee recipient
    address public performanceFeeRecipient;

    /// @notice multiplier for the liquid return, expressed as a percentage with 18 decimals.
    uint256 public liquidReturnMultiplier = FixedPointMathLib.WAD; // default to 1.0

    /// @notice target illiquid ratio, expressed as a percentage with 18 decimals.
    /// This ratio is the minimum percent of illiquid holdings the protocol is targetting, and
    /// if there is a percentage of illiquid users lower than the targetIlliquidRatio, the protocol
    /// wil distribute additional rewards to the illiquid users until targetIlliquidRatio is reached.
    uint256 public targetIlliquidRatio; // default to 0

    // 賺錢了之後先扣平台費  然後補到準備金 (存在這合約)
    constructor(
        address _core,
        address _accounting,
        address _receiptToken,
        address _stakedToken,
        address _lockingModule
    ) CoreControlled(_core) {
        accounting = _accounting;
        receiptToken = _receiptToken;
        stakedToken = _stakedToken;
        lockingModule = _lockingModule;

        ReceiptToken(receiptToken).approve(_stakedToken, type(uint256).max); // seashell hardcoded
        ReceiptToken(receiptToken).approve(_lockingModule, type(uint256).max);
    } //receiptToken ()可以填 iusd 也可 siusd liusd。  統一模組去分成收據 質押  lock 代幣 @seashell

    /// @notice set the safety buffer size
    /// @param _safetyBufferSize the new safety buffer size
    function setSafetyBufferSize(
        uint256 _safetyBufferSize
    ) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        safetyBufferSize = _safetyBufferSize;
        emit SafetyBufferSizeUpdated(block.timestamp, _safetyBufferSize);
    }

    /// @notice set the performance fee and recipient
    function setPerformanceFeeAndRecipient(
        uint256 _percent,
        address _recipient
    ) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        require(
            _percent < MAX_PERFORMANCE_FEE,
            PerformanceFeeTooHigh(_percent)
        );
        if (_percent > 0) {
            require(
                _recipient != address(0),
                PerformanceFeeRecipientIsZeroAddress(_recipient)
            );
        }

        performanceFee = _percent;
        performanceFeeRecipient = _recipient;
        emit PerformanceFeeSettingsUpdated(
            block.timestamp,
            _percent,
            _recipient
        );
    }

    /// @notice set the liquid return multiplier
    function setLiquidReturnMultiplier(
        //流動性資產的報酬分配 控制權重要調多或調少的的
        uint256 _multiplier
    ) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        liquidReturnMultiplier = _multiplier;
        emit LiquidMultiplierUpdated(block.timestamp, _multiplier);
    }

    /// @notice set the target illiquid ratio
    function setTargetIlliquidRatio(
        //多少資產分配到非流動農場 f-handle positive yield
        uint256 _ratio
    ) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        require(
            _ratio <= FixedPointMathLib.WAD,
            TargetIlliquidRatioTooHigh(_ratio)
        );
        targetIlliquidRatio = _ratio;
        emit TargetIlliquidRatioUpdated(block.timestamp, _ratio);
    }

    /// @notice returns the yield earned by the protocol since the last accrue() call.
    /// @return yield as an amount of receiptTokens.
    /// @dev Note that yield can be negative if the protocol farms have lost value, or if the
    /// oracle price of assets held in the protocol has decreased since last accrue() call,
    /// or if more ReceiptTokens entered circulation than assets entered the protocol.
    function unaccruedYield() public view returns (int256) {
        uint256 receiptTokenPrice = Accounting(accounting).price(
            receiptToken
        ); /*iusd價格怎變動:iUSD 代表的是資產加上累積收益
一開始，你可能用 1 USDC 換到 1 iUSD（假設初始匯率是 1:1）。
隨著時間推移，你的存款開始產生利息，例如協議去借貸、流動性挖礦賺到利息。
收益會回流進池子，所以池子的總資產增加了。
但是 iUSD 的數量固定（除非有人新增或贖回資金）。
所以每一顆 iUSD 代表更多的資產，它的價值就上升了。
簡單說：iUSD 背後的資產變多了，所以 iUSD 價格變高。
這跟 Aave 的 aToken、Compound 的 cToken 的邏輯是一樣的，只是不同協議、不同名字。 */
        uint256 assets = Accounting(accounting).totalAssetsValue(); // returns assets in USD

        uint256 assetsInReceiptTokens = assets.divWadDown(receiptTokenPrice);

        return
            int256(assetsInReceiptTokens) -
            int256(ReceiptToken(receiptToken).totalSupply());
    }

    /// @notice accrue yield and handle profits & losses
    /// This function should bring back unaccruedYield() to 0 by minting receiptTokens into circulation (profit distribution)
    /// or burning receipt tokens (slashing) or updating the oracle price of the receiptToken if there
    /// are not enough first-loss capital stakers to slash.
    function accrue() external whenNotPaused {
        int256 yield = unaccruedYield(); //public view
        if (yield > 0) _handlePositiveYield(uint256(yield));
        else if (yield < 0) _handleNegativeYield(uint256(-yield));

        emit YieldAccrued(block.timestamp, yield); //seashell 有可能emit一個 yield 0
    }

    /// @notice Yield sharing: split between iUSD lockin users & siUSD holders.
    /// If no users are locking or saving, the profit is minted on this contract and
    /// held idle so that the accrue() expected behavior of restoring protocol equity to 0
    /// is maintained. Funds minted on this contract in such a way can be unstuck by governance
    /// through the use of emergencyAction().
    function _handlePositiveYield(uint256 _positiveYield) internal {
        uint256 stakedReceiptTokens = ReceiptToken(receiptToken) //Seashell 為甚麼這邊還是receipt token 不是在處理stake token嗎
            .balanceOf(stakedToken)
            .mulWadDown(liquidReturnMultiplier); //調高或調降 流動農場報酬比例 的乘數
        uint256 receiptTokenTotalSupply = ReceiptToken(receiptToken)
            .totalSupply();
        uint256 targetIlliquidMinimum = receiptTokenTotalSupply.mulWadDown(
            targetIlliquidRatio //總iusd X 分配到lock農場的比例
        );
        uint256 lockingReceiptTokens = LockingController(lockingModule)
            .totalBalance(); //locking token (liusd)好像儲存在locking controller?
        if (lockingReceiptTokens < targetIlliquidMinimum) {
            //seashell 這個protocol 有設計最小鎖倉
            // 反正他有什麼演算法之類的，覺得多移動一點用戶的錢去鎖倉也不會爆炸。
            lockingReceiptTokens = targetIlliquidMinimum; // 所以用戶實際沒鎖那麼多iusd時
            // protocol 會假裝 liusd 就是有很多， 這樣等等計算獎勵時，L代幣應分得的正報酬就會更多
            // 類似( L / S+L )  應把L 的比例調高，那有L代幣的用戶就會分到比較多錢
        }
        uint256 bondingMultiplier = LockingController(lockingModule)
            .rewardMultiplier();
        /*    function rewardMultiplier() external view returns (uint256) {
        uint256 totalWeight = globalRewardWeight +
            UnwindingModule(unwindingModule).totalRewardWeight();
        if (totalWeight == 0) return FixedPointMathLib.WAD; // defaults to 1.0
        return totalWeight.divWadDown(totalBalance());
    } */
        lockingReceiptTokens = lockingReceiptTokens.mulWadDown(
            bondingMultiplier
        );
        uint256 totalReceiptTokens = stakedReceiptTokens + lockingReceiptTokens;
        //receiptTokenTotalSupply 是 iusd總量  這邊的卻是 s + L 代幣的總量
        //seashell 等等會用 s代幣 / S+L總量 來計算 staking 佔據這次收益的多少賺錢比例

        // mint yield
        ReceiptToken(receiptToken).mint(address(this), _positiveYield);

        // performance fee
        //seashell 平台費先轉給自己
        uint256 _performanceFee = performanceFee;
        if (_performanceFee > 0) {
            uint256 fee = _positiveYield.mulWadDown(_performanceFee); //正收益*平台費比例=平台費
            ReceiptToken(receiptToken).transfer(performanceFeeRecipient, fee);
            _positiveYield -= fee; //轉了錢才更新。  @seashell 但是是轉給內部合約就是了
        }

        // fill safety buffer first
        uint256 _safetyBufferSize = safetyBufferSize;
        if (_safetyBufferSize > 0) {
            uint256 safetyBuffer = ReceiptToken(receiptToken).balanceOf(
                address(this)
            ) - _positiveYield;
            if (safetyBuffer < _safetyBufferSize) {
                if (safetyBuffer + _positiveYield > _safetyBufferSize) {
                    // there will be a leftover profit after filling the safety buffer, so we
                    // deduct the safety buffer contribution from the profits and continue
                    _positiveYield -= _safetyBufferSize - safetyBuffer; //差多少才滿足 準備金，
                    //我這次的正收益就扣掉多少 (保留起來要轉給準備金帳戶)
                } else {
                    // do not do any further distribution and only replenish the safety buffer
                    return;
                }
            }
        }

        // compute splits
        if (totalReceiptTokens == 0) {
            // nobody to distribute to, do nothing and hold the tokens
            return;
        }

        // yield split to staked users
        uint256 stakingProfit = _positiveYield.mulDivDown(
            stakedReceiptTokens,
            totalReceiptTokens
        );
        if (stakingProfit > 0) {
            StakedToken(stakedToken).depositRewards(stakingProfit);
        }

        // yield split to locking users
        uint256 lockingProfit = _positiveYield - stakingProfit;
        if (lockingProfit > 0) {
            LockingController(lockingModule).depositRewards(lockingProfit);
        }
    }

    /// @notice Loss propagation: iUSD locking users -> siUSD holders -> iUSD holders
    function _handleNegativeYield(uint256 _negativeYield) internal {
        // if there is a safety buffer, and the loss is smaller than the safety buffer,
        // consume it and do not apply any losses to users.
        uint256 safetyBuffer = ReceiptToken(receiptToken).balanceOf(
            address(this)
        );
        if (safetyBuffer >= _negativeYield) {
            ReceiptToken(receiptToken).burn(_negativeYield);
            return;
        }

        // first, apply losses to locking users
        uint256 lockingReceiptTokens = LockingController(lockingModule)
            .totalBalance();
        if (_negativeYield <= lockingReceiptTokens) {
            LockingController(lockingModule).applyLosses(_negativeYield);
            return;
        }
        LockingController(lockingModule).applyLosses(lockingReceiptTokens);
        _negativeYield -= lockingReceiptTokens;

        // second, apply negativeYield to siUSD holders
        uint256 stakedReceiptTokens = ReceiptToken(receiptToken).balanceOf(
            stakedToken
        );
        if (_negativeYield <= stakedReceiptTokens) {
            StakedToken(stakedToken).applyLosses(_negativeYield);
            return;
        }
        StakedToken(stakedToken).applyLosses(stakedReceiptTokens);
        _negativeYield -= stakedReceiptTokens;

        // lastly, apply losses to all iUSD in circulation
        uint256 totalSupply = ReceiptToken(receiptToken).totalSupply();
        uint256 price = Accounting(accounting).price(receiptToken);
        uint256 newPrice = price.mulDivDown(
            totalSupply - _negativeYield,
            totalSupply
        );
        Accounting(accounting).setPrice(receiptToken, newPrice);
    }
}
