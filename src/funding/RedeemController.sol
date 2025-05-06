// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {Farm} from "@integrations/Farm.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {Accounting} from "@finance/Accounting.sol";
import {ReceiptToken} from "@tokens/ReceiptToken.sol";
import {RedemptionPool} from "@funding/RedemptionPool.sol";
import {IRedeemController, IBeforeRedeemHook} from "@interfaces/IRedeemController.sol";

/// @notice Idle Farm that allows users to withdraw from the system.
/// This contract acts as a Redemption Pool & a Redemption Queue, and reports
/// assets like a Farm for standardized accounting.
contract RedeemController is Farm, RedemptionPool, IRedeemController {
    using SafeERC20 for ERC20;
    using FixedPointMathLib for uint256;

    /// @notice reference to the ReceiptToken contract
    address public immutable receiptToken;

    /// @notice reference to the Accounting contract
    address public immutable accounting;

    /// @notice minimum redemption amount
    /// @dev can be set to a different number by GOVERNOR role
    uint256 public minRedemptionAmount = 1;

    /// @notice address to call in the beforeRedeem hook
    address public beforeRedeemHook;

    constructor(
        address _core,
        address _assetToken,
        address _receiptToken,
        address _accounting
    ) Farm(_core, _assetToken) {
        receiptToken = _receiptToken;
        accounting = _accounting;
    }

    /// @notice sets the minimum redemption amount
    /// @dev we can set this value to a higher number if we want to prevent griefing
    /// @dev as users could enqueue thousands of small amounts to "stuff" the redemption queue
    /// @param _minRedemptionAmount the minimum redemption amount
    function setMinRedemptionAmount(
        uint256 _minRedemptionAmount
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        require(
            _minRedemptionAmount > 0,
            RedeemAmountTooLow(_minRedemptionAmount, 1)
        );
        minRedemptionAmount = _minRedemptionAmount;
        emit MinRedemptionAmountUpdated(block.timestamp, _minRedemptionAmount);
    }

    /// @notice sets the beforeRedeemHook
    function setBeforeRedeemHook(
        address _beforeRedeemHook
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        beforeRedeemHook = _beforeRedeemHook;
        emit BeforeRedeemHookChanged(block.timestamp, _beforeRedeemHook);
    }

    /// @notice calculate the amount of assetToken() out for a given `amountIn` of receiptToken()
    function receiptToAsset(
        uint256 _receiptAmount
    ) external view returns (uint256) {
        uint256 convertRatio = _getReceiptToAssetConvertRatio();
        return _convertReceiptToAsset(_receiptAmount, convertRatio);
    }

    /// @notice returns the total assets of the redeem controller
    /// @dev the total assets is the sum of the assets minus the total pending claims
    function assets() public view override returns (uint256) {
        return super.assets() - totalPendingClaims; //overide了farm的asset 我不知道為甚麼ctrl click追溯不到
    }

    /// @notice returns the liquidity of the redeem controller
    function liquidity() public view override returns (uint256) {
        return assets();
    }

    /// @notice redeem receiptTokens out of circulation in exchange of assetTokens
    function redeem(
        address _to,
        uint256 _receiptAmountIn
    )
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.ENTRY_POINT)
        returns (uint256)
    {
        require(
            _receiptAmountIn >= minRedemptionAmount,
            RedeemAmountTooLow(_receiptAmountIn, minRedemptionAmount)
        );

        // get the convert ratio between receiptToken and assetToken
        // to be used in both way:
        //  - when enough liquidity available: compute how much asset tokens you get by redeeming receipt tokens
        //  - when enqueuing: compute how much receipt tokens to burn for the amount of directly available liquidity
        uint256 convertRatio = _getReceiptToAssetConvertRatio();
        /*    function _getReceiptToAssetConvertRatio() internal view returns (uint256) {
        uint256 _assetTokenPrice = Accounting(accounting).price(assetToken);
        uint256 _receiptTokenPrice = Accounting(accounting).price(receiptToken);
  @seashell跟mint 的轉換是一樣的嗎 怎麼覺得mint的沒那麼單純*/
        uint256 assetAmountOut = _convertReceiptToAsset(
            _receiptAmountIn,
            convertRatio
        ); //@Seashell方法應該沒問題 但可以檢查傳入的被除的對象對不對

        address _beforeRedeemHook = beforeRedeemHook;
        if (_beforeRedeemHook != address(0)) {
            IBeforeRedeemHook(_beforeRedeemHook).beforeRedeem(
                _to,
                _receiptAmountIn,
                assetAmountOut
            );
        }

        uint256 availableAssetAmount = liquidity();
        /*    function liquidity() public view override returns (uint256) {
        return assets();
    } */
        /*    function assets() public view override returns (uint256) {
        return super.assets() - totalPendingClaims;    //@seashell super.asset找不到人欸 會不會這邊的overide是多餘的
    }
 */
        //@todo 會不會有小數點問題。 燒太多或太少?   conversion rate也是 會不會轉換中損失掉一點東西會不會轉換中損失掉一點東西
        if (assetAmountOut <= availableAssetAmount) {
            // if the amount to redeem is less than the available liquidity, we can send it directly,
            // no need for the redemption queue
            ReceiptToken(receiptToken).burnFrom(msg.sender, _receiptAmountIn);
            ERC20(assetToken).safeTransfer(_to, assetAmountOut);
            emit Redeem(
                block.timestamp,
                _to,
                assetToken,
                _receiptAmountIn,
                assetAmountOut
            );
            return assetAmountOut; //@seashell 轉給用戶多少usdt
        } else {
            // send available liquidity to the recipient
            // (by computing how much receiptToken to burn for that amount of liquidity)
            uint256 amountReceiptToBurn = _convertAssetToReceipt(
                availableAssetAmount, //@seashell 在流動性不足時 用liquidity全部 然後轉成share去燒 去換usdt
                convertRatio //todo @seashell  但問題是前面扣錢的時候扣的是amount-in 但這邊卻只燒liquidity 有可能有漏洞
            );
            ReceiptToken(receiptToken).burnFrom( //@seashell 這裡只burn部分  但gate approve全額。
                    //@ 我可以先趁流動性不足的時候呼叫一下redeem 然後redeem controller就會有多的 來自gate的 approve額度沒消耗完
                    // 如果redeemController 還有其他函數有漏洞 就可以利用那個函數 A Gate的錢

                    // 1. 這個函數得要自己從gatE多拿錢 而且還要有額外的漏洞可以洩漏自己的錢給外部 難度有點高
                    // 2. function claimRedemption   transferto
                    // 3.
                    msg.sender,
                    amountReceiptToBurn
                );
            ERC20(assetToken).safeTransfer(_to, availableAssetAmount); //僅剩的asset都轉使用者
            //還欠user 一些receipt
            // then enqueue the remaining amount in the redemption queue
            uint256 remainingReceiptToQueue = _receiptAmountIn -
                amountReceiptToBurn;
            ReceiptToken(receiptToken).transferFrom( //gate approve過 但這裡還沒拿錢，所以這裡補寫
                    msg.sender,
                    address(this),
                    remainingReceiptToQueue
                );
            _enqueue(_to, remainingReceiptToQueue); //@seashell前面有跟合約拿錢了嗎 此處該拿多少?
            //@seashell qunes是array 每次付完一筆 就index ++ 這樣quene[index]就知道要處理哪一筆還沒付款的單
            // emit the redeem event for the amount of liquidity available
            emit Redeem(
                block.timestamp,
                _to,
                assetToken,
                amountReceiptToBurn,
                availableAssetAmount
            );
            return availableAssetAmount;
        }
    }

    /// @notice Claim a redemption for a given recipient
    /// @dev can be called by anyone.
    function claimRedemption(
        address _recipient
    ) external whenNotPaused onlyCoreRole(CoreRoles.ENTRY_POINT) {
        uint256 assetsToSend = _claimRedemption(_recipient);
        ERC20(assetToken).safeTransfer(_recipient, assetsToSend);
    }

    /// @notice When depositing funds to the redeem controller, we fund the redemption queue
    /// and burn the corresponding receipt tokens.
    function _deposit() internal override {
        uint256 totalAssets = liquidity();
        if (totalAssets > 0) {
            (, uint256 receiptAmountToBurn) = _fundRedemptionQueue(
                totalAssets,
                _getReceiptToAssetConvertRatio()
            );
            ReceiptToken(receiptToken).burn(receiptAmountToBurn);
        }
    }

    function _withdraw(uint256 _amount, address _to) internal override {
        ERC20(assetToken).safeTransfer(_to, _amount);
    }

    /// @notice returns the convert ratio between receiptToken and assetToken
    /// @dev for iUSD/USDC, 1 iUSD = 1e18, receiptToken price is for example 0.8e18, USDC token price is 1e(18 + 18 - USDC decimals) = 1e30
    /// @dev then convert ratio is 1e18 * 0.8e18 / 1e30 = 0.8e36 / 1e30 = 0.8e6
    /// @dev so 1e18 iUSD is worth 0.8e6 USDC
    // todo @seashell 我可以用 external函數 function receiptToAsset
    // 瘋狂call 這個internal函數 這樣會造成read only reenterency嗎
    function _getReceiptToAssetConvertRatio() internal view returns (uint256) {
        uint256 _assetTokenPrice = Accounting(accounting).price(assetToken);
        uint256 _receiptTokenPrice = Accounting(accounting).price(receiptToken);

        return _receiptTokenPrice.divWadDown(_assetTokenPrice);
    }

    /// @notice convert an amount of receiptToken to assetToken
    /// @param _amountReceipt the amount of receiptToken to convert
    /// @param _convertRatio the convert ratio between receiptToken and assetToken
    /// @dev if the convertRatio is 0.8e18, then 1 receipt token is worth 1e18 * 0.8e18 / 1e18 = 0.8e18 asset tokens
    function _convertReceiptToAsset(
        uint256 _amountReceipt,
        uint256 _convertRatio
    ) internal pure returns (uint256) {
        return _amountReceipt.mulWadDown(_convertRatio);
    }

    /// @notice convert an amount of assetToken to receiptToken
    /// @param _amountAsset the amount of assetToken to convert
    /// @param _convertRatio the convert ratio between receiptToken and assetToken
    /// @dev if the convertRatio is 0.8e18, then 1 asset token is worth 1e18 * 1e18 / 0.8e18 = 1.25e18 receipt tokens
    function _convertAssetToReceipt(
        uint256 _amountAsset,
        uint256 _convertRatio
    ) internal pure returns (uint256) {
        return _amountAsset.divWadUp(_convertRatio);
    }
}
