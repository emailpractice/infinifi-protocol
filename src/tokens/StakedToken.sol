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
    error PendingLossesUnapplied();

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

    constructor(address _core, address _receiptToken)
        CoreControlled(_core)
        ERC20(string.concat("Savings ", ERC20(_receiptToken).name()), string.concat("s", ERC20(_receiptToken).symbol()))
        ERC4626(IERC20(_receiptToken))
    {}

    /// @notice allows governor to update the yieldSharing reference
    function setYieldSharing(address _yieldSharing) external onlyCoreRole(CoreRoles.GOVERNOR) {
        yieldSharing = _yieldSharing;
    }

    /// ---------------------------------------------------------------------------
    /// Pausability
    /// ---------------------------------------------------------------------------

    function mint(uint256 _shares, address _receiver) public override whenNotPaused returns (uint256) {
        return super.mint(_shares, _receiver);
    }

    function redeem(uint256 _amountIn, address _to, address _receiver)
        public
        override
        whenNotPaused
        returns (uint256)
    {
        _revertIfThereAreUnaccruedLosses();
        return super.redeem(_amountIn, _to, _receiver);
    }
//@seashell stake 代幣的話就會存款siusd。  要overide的原因是要加上when not paused
    function deposit(uint256 _amountIn, address _to) public override whenNotPaused returns (uint256) {
        return super.deposit(_amountIn, _to);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        whenNotPaused
        returns (uint256)
    {
        _revertIfThereAreUnaccruedLosses();
        return super.withdraw(assets, receiver, owner);
    }

    function maxMint(address _receiver) public view override returns (uint256) {
        if (paused()) {
            return 0;
        }
        return super.maxMint(_receiver);
    }

    function maxDeposit(address _receiver) public view override returns (uint256) {
        if (paused()) {
            return 0;
        }
        return super.maxDeposit(_receiver);
    }

    function maxRedeem(address _receiver) public view override returns (uint256) {
        if (paused()) {
            return 0;
        }
        _revertIfThereAreUnaccruedLosses();
        return super.maxRedeem(_receiver);
    }

    function maxWithdraw(address _receiver) public view override returns (uint256) {
        if (paused()) {
            return 0;
        }
        _revertIfThereAreUnaccruedLosses();
        return super.maxWithdraw(_receiver);
    }

    function _revertIfThereAreUnaccruedLosses() internal view {
        require(YieldSharing(yieldSharing).unaccruedYield() >= 0, PendingLossesUnapplied());
    }

    /// ---------------------------------------------------------------------------
    /// Loss Management
    /// ---------------------------------------------------------------------------

    function applyLosses(uint256 _amount) external onlyCoreRole(CoreRoles.FINANCE_MANAGER) {
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

    /// @notice Slash rewards for a given epoch
    function _slashEpochRewards(uint256 _epoch, uint256 _amount) internal returns (uint256) {
        uint256 _epochRewards = epochRewards[_epoch];
        if (_epochRewards >= _amount) {
            epochRewards[_epoch] = _epochRewards - _amount;
            ReceiptToken(asset()).burn(_amount);
            emit VaultLoss(block.timestamp, _epoch, _amount);
            _amount = 0;
        } else {
            epochRewards[_epoch] = 0;
            ReceiptToken(asset()).burn(_epochRewards);
            emit VaultLoss(block.timestamp, _epoch, _epochRewards);
            _amount -= _epochRewards;
        }
        return _amount;
    }

    /// ---------------------------------------------------------------------------
    /// Profit Smoothing
    /// ---------------------------------------------------------------------------

    function depositRewards(uint256 _amount) external onlyCoreRole(CoreRoles.FINANCE_MANAGER) {
        ERC20(asset()).transferFrom(msg.sender, address(this), _amount);
        uint256 epoch = block.timestamp.nextEpoch();
        epochRewards[epoch] += _amount;
        emit VaultProfit(block.timestamp, epoch, _amount);
    }

    /// @notice returns the amount of rewards for the current epoch minus the rewards that are already available
    function _unavailableCurrentEpochRewards() internal view returns (uint256) {
        uint256 currentEpoch = block.timestamp.epoch();
        uint256 currentEpochRewards = epochRewards[currentEpoch]; // safe upcast
        uint256 elapsed = block.timestamp - currentEpoch.epochToTimestamp();
        uint256 availableEpochRewards = (currentEpochRewards * elapsed) / EpochLib.EPOCH;
        return currentEpochRewards - availableEpochRewards;
    }

    /// @notice returns the total assets, excluding the rewards that are not available yet
    function totalAssets() public view override returns (uint256) {
        return super.totalAssets() - epochRewards[block.timestamp.nextEpoch()] - _unavailableCurrentEpochRewards();
    }
}
