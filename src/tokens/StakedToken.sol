// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EpochLib} from "@libraries/EpochLib.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {ReceiptToken} from "@tokens/ReceiptToken.sol";
import {YieldSharing} from "@finance/YieldSharing.sol";
import {CoreControlled} from "@core/CoreControlled.sol";
import {ERC20, IERC20, ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/// @notice InfiniFi Staked Token.
/// @dev be carefull, as this contract is an ERC4626, the "assets" keyword is used to refer to the underlying token
/// in this case, it's the ReceiptToken. It's a bit confusing because "asset" is the word we use to refer to the backing token (USDC)
/// everywhere else in the code
contract StakedToken is ERC4626, CoreControlled {
    using EpochLib for uint256;

    /// @notice error thrown when there are pending losses unapplied
    /// if you observe this error as a user, call YieldSharing.accrue() before
    /// attempting a withdrawal from the vault.
    error PendingLossesUnapplied(); //沒有給它任何參數，所以它報錯的時候真的就是
    //報一個名字而已 PendingLossesUnapplied

    /// @notice emitted when a loss is applied to the vault
    /// @dev epoch could be 0 if the principal of the vault has to be slashed
    event VaultLoss(uint256 indexed timestamp, uint256 epoch, uint256 assets);
    /// @notice emitted when a profit is applied to the vault
    event VaultProfit(uint256 indexed timestamp, uint256 epoch, uint256 assets);

    /// @notice reference to the YieldSharing contract
    address public yieldSharing;

    /// @notice rewards to distribute per epoch
    /// @dev epochRewards can only contain future rewards in the next epoch,
    /// and not further in the future - see `depositRewards()`.
    mapping(uint256 epoch => uint256 rewards) public epochRewards;

    constructor(
        address _core,
        address _receiptToken
    )
        CoreControlled(_core)
        ERC20(
            string.concat("Savings ", ERC20(_receiptToken).name()),
            string.concat("s", ERC20(_receiptToken).symbol())
        )
        ERC4626(IERC20(_receiptToken))
    {}

    /// @notice allows governor to update the yieldSharing reference
    //seashell 也算一種升級策略，但不是傳統的proxy升級
    //因為 storage 不共享，所以更換後的合約也要自己確保兼容性（
    function setYieldSharing(
        address _yieldSharing
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        yieldSharing = _yieldSharing;
    }

    /// ---------------------------------------------------------------------------
    /// Pausability
    /// ---------------------------------------------------------------------------

    function mint(
        uint256 _shares,
        address _receiver
    ) public override whenNotPaused returns (uint256) {
        return super.mint(_shares, _receiver);
        //這裡溯源super.mint又指向自己了，不知道是不是協議的bug @seashell
    }

    function redeem(
        uint256 _amountIn,
        address _to,
        address _receiver
    ) public override whenNotPaused returns (uint256) {
        _revertIfThereAreUnaccruedLosses();
        return super.redeem(_amountIn, _to, _receiver); //@todo super.redeem指向自己
    } //所以不知道redeem的實作是什麼。 也不了解為甚麼有_to了還要有_receiver 不是給用戶就好了嗎

    //@seashell stake 代幣的話就會存款siusd。  要overide的原因是要加上when not paused
    function deposit(
        uint256 _amountIn,
        address _to
    ) public override whenNotPaused returns (uint256) {
        return super.deposit(_amountIn, _to);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override whenNotPaused returns (uint256) {
        _revertIfThereAreUnaccruedLosses();
        return super.withdraw(assets, receiver, owner);
    } //todo 不確定siusd到底存在哪合約 這邊又說提款要從owner提。
    //withdraw 跟 redeem都是讓用戶把錢拿走，但是redeem多了一個用收據來換錢的步驟

    function maxMint(address _receiver) public view override returns (uint256) {
        if (paused()) {
            return 0;
        }
        return super.maxMint(_receiver);
    }

    function maxDeposit(
        address _receiver
    ) public view override returns (uint256) {
        if (paused()) {
            return 0;
        }
        return super.maxDeposit(_receiver);
    }

    function maxRedeem(
        address _receiver
    ) public view override returns (uint256) {
        if (paused()) {
            return 0;
        }
        _revertIfThereAreUnaccruedLosses();
        return super.maxRedeem(_receiver);
    }

    function maxWithdraw(
        address _receiver
    ) public view override returns (uint256) {
        if (paused()) {
            return 0;
        }
        _revertIfThereAreUnaccruedLosses();
        return super.maxWithdraw(_receiver);
    }

    function _revertIfThereAreUnaccruedLosses() internal view {
        require(
            YieldSharing(yieldSharing).unaccruedYield() >= 0,
            PendingLossesUnapplied()
        );
    }

    /// ---------------------------------------------------------------------------
    /// Loss Management
    /// ---------------------------------------------------------------------------

    function applyLosses(
        uint256 _amount
    ) external onlyCoreRole(CoreRoles.FINANCE_MANAGER) {
        // any future rewards are slashed first
        // first, slash next epoch rewards
        _amount = _slashEpochRewards(block.timestamp.nextEpoch(), _amount);
        if (_amount == 0) return;
        // second, slash current epoch rewards
        _amount = _slashEpochRewards(block.timestamp.epoch(), _amount);
        if (_amount == 0) return;
        // lastly, slash the principal of the vault
        ReceiptToken(asset()).burn(_amount);
        emit VaultLoss(block.timestamp, 0, _amount);
    }

    /// @notice Slash rewards for a given epoch   @seashell slash是處罰意味 扣掉一些用戶的資產
    function _slashEpochRewards(
        uint256 _epoch,
        uint256 _amount
    ) internal returns (uint256) {
        uint256 _epochRewards = epochRewards[_epoch];
        if (_epochRewards >= _amount) {
            epochRewards[_epoch] = _epochRewards - _amount; //沒有使用-= 來減去只是風格差異，沒實際效果
            ReceiptToken(asset()).burn(_amount);
            emit VaultLoss(block.timestamp, _epoch, _amount);
            _amount = 0;
        } else {
            //本epoch的reward不夠扣，只好全部都扣掉，然後剩下的loss再返回外層處理
            epochRewards[_epoch] = 0;
            ReceiptToken(asset()).burn(_epochRewards);
            emit VaultLoss(block.timestamp, _epoch, _epochRewards);
            _amount -= _epochRewards; //loss-本期全部reward
        }
        return _amount;
    }

    /// ---------------------------------------------------------------------------
    /// Profit Smoothing
    /// ---------------------------------------------------------------------------

    function depositRewards(
        uint256 _amount
    ) external onlyCoreRole(CoreRoles.FINANCE_MANAGER) {
        ERC20(asset()).transferFrom(msg.sender, address(this), _amount); //從Yield sharing 的 handle positive yield拿錢
        uint256 epoch = block.timestamp.nextEpoch(); // 會有一個起始時間 然後定義一個epoch是一週，
        // nextEpch會算那下一週的開始時間點是多少  2025050317:30之類的，
        epochRewards[epoch] += _amount; //把獎勵加到下一個時間段，不可以馬上給的樣子
        // 獎勵跟時間配對在一起， 但沒指定用戶。  所以這些獎勵全部用戶都可以去爭取?
        emit VaultProfit(block.timestamp, epoch, _amount);
    }

    /// @notice returns the amount of rewards for the current epoch minus the rewards that are already available
    function _unavailableCurrentEpochRewards() internal view returns (uint256) {
        uint256 currentEpoch = block.timestamp.epoch();
        uint256 currentEpochRewards = epochRewards[currentEpoch]; // safe upcast
        uint256 elapsed = block.timestamp - currentEpoch.epochToTimestamp(); //現秒數-此epoch開始的秒數
        uint256 availableEpochRewards = (currentEpochRewards * elapsed) / //此週期已經過幾秒 / 此週期時間 = 過的比例
            EpochLib.EPOCH; //epoch是內部函數，這樣理論上呼叫不到。可以epochLib是 library
        //所以就可以這樣用的樣子
        // 這段的意思就是 這段的意思就是此週期獎勵乘上此周期已經過的比例，這些獎勵就available
        //但怎麼分發這些獎勵還是沒找到相關程式碼 @todo
        return currentEpochRewards - availableEpochRewards;
    }

    //我搜尋了.totalAssets 發現這個函數好像只有在 test用的合約裡用到，跟協議的邏輯沒關係。
    // 他應該是拿來做invarient 的。   真的要取totalAssets的時候好像都是用accounting裡面的totalAssetsValue
    /// @notice returns the total assets, excluding the rewards that are not available yet
    function totalAssets() public view override returns (uint256) {
        return
            super.totalAssets() -
            epochRewards[block.timestamp.nextEpoch()] -
            _unavailableCurrentEpochRewards();
    }
}
