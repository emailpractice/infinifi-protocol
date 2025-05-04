// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {CoreControlled} from "@core/CoreControlled.sol";
import {UnwindingModule} from "@locking/UnwindingModule.sol";
import {LockedPositionToken} from "@tokens/LockedPositionToken.sol";

contract LockingController is CoreControlled {
    using FixedPointMathLib for uint256;

    /// @notice address of the locked token
    address public immutable receiptToken;

    /// @notice address of the unwinding module
    address public immutable unwindingModule;

    /// ----------------------------------------------------------------------------
    /// STRUCTS, ERRORS, AND EVENTS
    /// ----------------------------------------------------------------------------

    struct BucketData {
        address shareToken;
        uint256 totalReceiptTokens;
        uint256 multiplier;
    }

    error TransferFailed();
    error InvalidBucket(uint32 unwindingEpochs);
    error InvalidUnwindingEpochs(uint32 unwindingEpochs);
    error InvalidMultiplier(uint256 multiplier);
    error BucketMustBeLongerDuration(uint32 oldValue, uint32 newValue);
    error UnwindingInProgress();

    event PositionCreated(
        uint256 indexed timestamp,
        address indexed user,
        uint256 amount,
        uint32 indexed unwindingEpochs
    );
    event PositionRemoved(
        uint256 indexed timestamp,
        address indexed user,
        uint256 amount,
        uint32 indexed unwindingEpochs
    );
    event RewardsDeposited(uint256 indexed timestamp, uint256 amount);
    event LossesApplied(uint256 indexed timestamp, uint256 amount);
    event BucketEnabled(
        uint256 indexed timestamp,
        uint256 bucket,
        address shareToken,
        uint256 multiplier
    );
    event BucketMultiplierUpdated(
        uint256 indexed timestamp,
        uint256 bucket,
        uint256 multiplier
    );

    /// ----------------------------------------------------------------------------
    /// STATE
    /// ----------------------------------------------------------------------------

    /// @notice array of all enabled unwinding epochs
    /// @dev example, this array will contain [2, 4, 6] if users are allowed to
    /// lock for 2, 4 and 6 weeks respectively
    uint32[] public enabledBuckets;

    /// @notice mapping of unwinding epochs data
    mapping(uint32 _unwindingEpochs => BucketData data) public buckets;

    uint256 public globalReceiptToken;
    uint256 public globalRewardWeight;

    /// ----------------------------------------------------------------------------
    /// CONSTRUCTOR
    /// ----------------------------------------------------------------------------

    constructor(
        address _core,
        address _receiptToken,
        address _unwindingModule
    ) CoreControlled(_core) {
        receiptToken = _receiptToken;
        unwindingModule = _unwindingModule;
    }

    /// ----------------------------------------------------------------------------
    /// ADMINISTRATION METHODS
    /// ----------------------------------------------------------------------------

    /// @notice enable a new unwinding epochs duration
    function enableBucket(
        uint32 _unwindingEpochs,
        address _shareToken,
        uint256 _multiplier
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        require(
            buckets[_unwindingEpochs].shareToken == address(0),
            InvalidBucket(_unwindingEpochs)
        );
        require(_unwindingEpochs > 0, InvalidUnwindingEpochs(_unwindingEpochs));
        require(
            _unwindingEpochs <= 100,
            InvalidUnwindingEpochs(_unwindingEpochs)
        );
        require(
            _multiplier >= FixedPointMathLib.WAD,
            InvalidMultiplier(_multiplier)
        );
        require(
            _multiplier <= 2 * FixedPointMathLib.WAD,
            InvalidMultiplier(_multiplier)
        );

        buckets[_unwindingEpochs].shareToken = _shareToken;
        buckets[_unwindingEpochs].multiplier = _multiplier;
        enabledBuckets.push(_unwindingEpochs);
        emit BucketEnabled(
            block.timestamp,
            _unwindingEpochs,
            _shareToken,
            _multiplier
        );
    }

    /// @notice update the multiplier of a given bucket
    /// @dev note that this won't affect the unwinding users, unless they cancel their unwinding
    function setBucketMultiplier(
        uint32 _unwindingEpochs,
        uint256 _multiplier
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        BucketData memory data = buckets[_unwindingEpochs];
        require(data.shareToken != address(0), InvalidBucket(_unwindingEpochs));

        require(
            _multiplier >= FixedPointMathLib.WAD,
            InvalidMultiplier(_multiplier)
        );
        require(
            _multiplier <= 2 * FixedPointMathLib.WAD,
            InvalidMultiplier(_multiplier)
        );

        uint256 oldRewardWeight = data.totalReceiptTokens.mulWadDown(
            data.multiplier
        );
        uint256 newRewardWeight = data.totalReceiptTokens.mulWadDown(
            _multiplier
        );
        globalRewardWeight =
            globalRewardWeight +
            newRewardWeight -
            oldRewardWeight;
        buckets[_unwindingEpochs].multiplier = _multiplier;
        emit BucketMultiplierUpdated(
            block.timestamp,
            _unwindingEpochs,
            _multiplier
        );
    }

    /// ----------------------------------------------------------------------------
    /// READ METHODS
    /// ----------------------------------------------------------------------------

    /// @notice get the balance of a user by looping through all the enabled unwinding epochs
    /// and looking at how many share tokens the user has, then multiplying for each of them
    /// by the current share price.
    /// @dev Balance is expressed in receipt tokens.
    function balanceOf(address _user) external view returns (uint256) {
        return _userSumAcrossUnwindingEpochs(_user, _totalReceiptTokensGetter);
    }

    /// @notice get the reward weight of a user by looping through all the enabled unwinding epochs
    /// and looking at how many share tokens the user has, then multiplying for each of them
    /// by the current reward weight of these shares.
    /// @dev Reward weight is expressed in "virtual receipt tokens" and is used to compute the
    /// rewards earned during yield distribution.
    function rewardWeight(address _user) external view returns (uint256) {
        return _userSumAcrossUnwindingEpochs(_user, _totalRewardWeightGetter);
    }

    /// @notice get the reward weight of a user
    function rewardWeightForUnwindingEpochs(
        address _user,
        uint32 _unwindingEpochs
    ) external view returns (uint256) {
        BucketData memory data = buckets[_unwindingEpochs];

        uint256 userShares = IERC20(data.shareToken).balanceOf(_user);
        uint256 totalShares = IERC20(data.shareToken).totalSupply();
        if (totalShares == 0) return 0;
        uint256 totalRewardWeight = data.totalReceiptTokens.mulWadDown(
            data.multiplier
        );
        return userShares.mulDivDown(totalRewardWeight, totalShares);
    }

    /// @notice get the shares of a user for a given unwindingEpochs
    function shares(
        address _user,
        uint32 _unwindingEpochs
    ) external view returns (uint256) {
        BucketData memory data = buckets[_unwindingEpochs];
        if (data.shareToken == address(0)) return 0;
        return IERC20(data.shareToken).balanceOf(_user);
    }

    /// @notice get the shares token of a given unwindingEpochs, 0 if not enabled
    function shareToken(
        uint32 _unwindingEpochs
    ) external view returns (address) {
        return buckets[_unwindingEpochs].shareToken;
    }

    /// @notice get the current exchange rate between the receiptToken and a given shareToken.
    /// This function is here for convenience, to help share token holders estimate the value of their tokens.
    /// @dev returns 0 if the _unwindingEpochs is not valid or if there are no locks for this duration
    function exchangeRate(
        uint32 _unwindingEpochs
    ) external view returns (uint256) {
        BucketData memory data = buckets[_unwindingEpochs];
        if (data.shareToken == address(0)) return 0;
        uint256 totalShares = IERC20(data.shareToken).totalSupply();
        if (totalShares == 0) return 0;
        return data.totalReceiptTokens.divWadDown(totalShares);
    }

    /// @notice returns true if the given unwinding epochs is enabled for locking
    function unwindingEpochsEnabled(
        uint32 _unwindingEpochs
    ) external view returns (bool) {
        return buckets[_unwindingEpochs].shareToken != address(0);
    }

    /// @notice total balance of receipt tokens in the module
    /// @dev note that due to rounding down in the protocol's favor, this might be slightly
    /// above the sum of the balanceOf() of all users.
    function totalBalance() public view returns (uint256) {
        return
            globalReceiptToken +
            UnwindingModule(unwindingModule).totalReceiptTokens();
    }

    /// @notice multiplier to apply to totalBalance() for computing rewards in profit distribution,
    /// Expressed as a WAD (18 decimals). Should be between [1.0e18, 2.0e18] realistically.
    function rewardMultiplier() external view returns (uint256) {
        uint256 totalWeight = globalRewardWeight +
            UnwindingModule(unwindingModule).totalRewardWeight();
        if (totalWeight == 0) return FixedPointMathLib.WAD; // defaults to 1.0
        return totalWeight.divWadDown(totalBalance());
    }

    /// ----------------------------------------------------------------------------
    /// POSITION MANAGEMENT WRITE METHODS
    /// ----------------------------------------------------------------------------

    /// @notice Enter a locked position
    function createPosition(
        uint256 _amount,
        uint32 _unwindingEpochs,
        address _recipient
    ) external whenNotPaused {
        if (msg.sender != unwindingModule) {
            // special case for access control here, the unwindingModule can reenter createPosition()
            // after being called by this contract's cancelUnwinding() function.
            // this exception is preferable to granting ENTRY_POINT role to the unwindingModule.
            require(
                core().hasRole(CoreRoles.ENTRY_POINT, msg.sender),
                "UNAUTHORIZED"
            );
        }

        BucketData memory data = buckets[_unwindingEpochs];
        require(data.shareToken != address(0), InvalidBucket(_unwindingEpochs));
        require(
            IERC20(receiptToken).transferFrom(
                msg.sender,
                address(this),
                _amount
            ),
            TransferFailed()
        );

        uint256 totalShares = IERC20(data.shareToken).totalSupply();
        //    function totalSupply() external view returns (uint256);
        uint256 newShares = totalShares == 0
            ? _amount // shareToken (liusd?)總共有多少liusd ，總共有多少iusd
            : _amount.mulDivDown(totalShares, data.totalReceiptTokens);
        //( _amount * 總共有多少liusd ) / data.totalReceiptTokens)
        // 用冒號區隔 trur / false 的結果
        // totalReceiptToken (bucket struct 裡面的一個)的源頭:

        // function start unwinding
        //buckets[_unwindingEpochs].totalReceiptTokens =
        //data.totalReceiptTokens -
        //userReceiptToken;

        //    function increase unwinding epoch    newData.totalReceiptTokens += receiptTokens;
        uint256 newRewardWeight = _amount.mulWadDown(data.multiplier);
        data.totalReceiptTokens += _amount; //跟三差別? 為啥分開處理
        globalRewardWeight += newRewardWeight; //可能是每個人 share 占比 來判斷獎勵該領多少
        globalReceiptToken += _amount; //總iusd數量? 但為啥是+
        buckets[_unwindingEpochs] = data;

        LockedPositionToken(data.shareToken).mint(_recipient, newShares);
        emit PositionCreated(
            block.timestamp,
            _recipient,
            _amount,
            _unwindingEpochs
        );
    }

    /// @notice Start unwinding a locked position
    function startUnwinding(
        uint256 _shares,
        uint32 _unwindingEpochs,
        address _recipient
    ) external whenNotPaused onlyCoreRole(CoreRoles.ENTRY_POINT) {
        BucketData memory data = buckets[_unwindingEpochs];
        require(data.shareToken != address(0), InvalidBucket(_unwindingEpochs));

        uint256 totalShares = IERC20(data.shareToken).totalSupply();
        uint256 userReceiptToken = _shares.mulDivDown(
            data.totalReceiptTokens,
            totalShares
        );

        require(
            IERC20(data.shareToken).transferFrom(
                msg.sender,
                address(this),
                _shares
            ),
            TransferFailed()
        );
        LockedPositionToken(data.shareToken).burn(_shares);

        UnwindingModule(unwindingModule).startUnwinding(
            _recipient,
            userReceiptToken,
            _unwindingEpochs,
            userReceiptToken.mulWadDown(data.multiplier)
        );
        IERC20(receiptToken).transfer(unwindingModule, userReceiptToken);

        buckets[_unwindingEpochs].totalReceiptTokens =
            data.totalReceiptTokens -
            userReceiptToken;
        uint256 totalRewardWeight = data.totalReceiptTokens.mulWadDown(
            data.multiplier
        );
        uint256 rewardWeightDecrease = userReceiptToken.mulDivUp(
            totalRewardWeight,
            data.totalReceiptTokens
        );
        rewardWeightDecrease = _min(rewardWeightDecrease, totalRewardWeight); // up rounding could cause underflows
        globalRewardWeight -= rewardWeightDecrease;
        globalReceiptToken -= userReceiptToken;

        emit PositionRemoved(
            block.timestamp,
            _recipient,
            userReceiptToken,
            _unwindingEpochs
        );
    }

    /// @notice Increase the unwinding period of a position
    function increaseUnwindingEpochs(
        uint256 _shares,
        uint32 _oldUnwindingEpochs,
        uint32 _newUnwindingEpochs,
        address _recipient
    ) external whenNotPaused onlyCoreRole(CoreRoles.ENTRY_POINT) {
        require(
            _newUnwindingEpochs > _oldUnwindingEpochs,
            BucketMustBeLongerDuration(_oldUnwindingEpochs, _newUnwindingEpochs)
        );

        BucketData memory oldData = buckets[_oldUnwindingEpochs];
        BucketData memory newData = buckets[_newUnwindingEpochs];

        require(
            newData.shareToken != address(0),
            InvalidBucket(_newUnwindingEpochs)
        );

        // burn position in old share tokens
        if (_shares == 0) return;
        uint256 oldTotalSupply = IERC20(oldData.shareToken).totalSupply();
        uint256 receiptTokens = _shares.mulDivDown(
            oldData.totalReceiptTokens,
            oldTotalSupply
        );
        if (receiptTokens == 0) return;
        uint256 oldTotalRewardWeight = oldData.totalReceiptTokens.mulWadDown(
            oldData.multiplier
        );
        uint256 oldRewardWeight = receiptTokens.mulDivUp(
            oldTotalRewardWeight,
            oldData.totalReceiptTokens
        );
        oldRewardWeight = _min(oldRewardWeight, oldTotalRewardWeight); // up rounding could cause underflows
        ERC20Burnable(oldData.shareToken).burnFrom(msg.sender, _shares);
        oldData.totalReceiptTokens -= receiptTokens;
        buckets[_oldUnwindingEpochs] = oldData;

        // mint position in new share tokens
        uint256 newTotalSupply = IERC20(newData.shareToken).totalSupply();
        uint256 newShares = newTotalSupply == 0
            ? receiptTokens
            : receiptTokens.mulDivDown(
                newTotalSupply,
                newData.totalReceiptTokens
            );
        uint256 newRewardWeight = receiptTokens.mulWadDown(newData.multiplier);
        LockedPositionToken(newData.shareToken).mint(_recipient, newShares);
        newData.totalReceiptTokens += receiptTokens;
        buckets[_newUnwindingEpochs] = newData;

        // update global reward weight
        globalRewardWeight =
            globalRewardWeight +
            newRewardWeight -
            oldRewardWeight;

        emit PositionRemoved(
            block.timestamp,
            _recipient,
            receiptTokens,
            _oldUnwindingEpochs
        );
        emit PositionCreated(
            block.timestamp,
            _recipient,
            receiptTokens,
            _newUnwindingEpochs
        );
    }

    /// @notice Cancel an ongoing unwinding. All checks are performed by the Unwinding module.
    function cancelUnwinding(
        address _user,
        uint256 _unwindingTimestamp,
        uint32 _newUnwindingEpochs
    ) external whenNotPaused onlyCoreRole(CoreRoles.ENTRY_POINT) {
        UnwindingModule(unwindingModule).cancelUnwinding(
            _user,
            _unwindingTimestamp,
            _newUnwindingEpochs
        );
    }

    /// @notice Withdraw after an unwinding period has completed
    function withdraw(    //seashell 使用者沒有說要提多少 ，就是給一個時間 (說要解鎖的那個時間 ，而不是call withdraw的時間我猜。 中間應該有cool down)
        address _user,   
        uint256 _unwindingTimestamp
    ) external whenNotPaused onlyCoreRole(CoreRoles.ENTRY_POINT) {
        UnwindingModule(unwindingModule).withdraw(_unwindingTimestamp, _user);
    }

    /// ----------------------------------------------------------------------------
    /// INTERNAL UTILS
    /// ----------------------------------------------------------------------------

    function _userSumAcrossUnwindingEpochs(
        address _user,
        function(BucketData memory) view returns (uint256) _getter
    ) internal view returns (uint256) {
        uint256 weight;
        uint256 nBuckets = enabledBuckets.length;
        for (uint256 i = 0; i < nBuckets; i++) {
            uint32 unwindingEpochs = enabledBuckets[i];
            BucketData memory data = buckets[unwindingEpochs];

            uint256 userShares = IERC20(data.shareToken).balanceOf(_user);
            uint256 totalShares = IERC20(data.shareToken).totalSupply();
            if (totalShares == 0) continue;
            weight += userShares.mulDivDown(_getter(data), totalShares);
        }
        return weight;
    }

    function _totalRewardWeightGetter(
        BucketData memory data
    ) internal pure returns (uint256) {
        return data.totalReceiptTokens.mulWadDown(data.multiplier);
    }

    function _totalReceiptTokensGetter(
        BucketData memory data
    ) internal pure returns (uint256) {
        return data.totalReceiptTokens;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// ----------------------------------------------------------------------------
    /// REWARDS MANAGEMENT WRITE METHODS
    /// ----------------------------------------------------------------------------

    /// @notice Deposit rewards into the locking module
    function depositRewards(
        uint256 _amount
    ) external onlyCoreRole(CoreRoles.FINANCE_MANAGER) {
        if (_amount == 0) return;

        emit RewardsDeposited(block.timestamp, _amount);

        require(
            IERC20(receiptToken).transferFrom(
                msg.sender,
                address(this),
                _amount
            ),
            TransferFailed()
        );

        // compute split between locking users & unwinding users
        uint256 _globalRewardWeight = globalRewardWeight;
        uint256 unwindingRewardWeight = UnwindingModule(unwindingModule)
            .totalRewardWeight();
        uint256 unwindingRewards = _amount.mulDivDown(
            unwindingRewardWeight,
            _globalRewardWeight + unwindingRewardWeight
        );
        if (unwindingRewards > 0) {
            UnwindingModule(unwindingModule).depositRewards(unwindingRewards);
            require(
                IERC20(receiptToken).transfer(
                    unwindingModule,
                    unwindingRewards
                ),
                TransferFailed()
            );
            _amount -= unwindingRewards;

            // if there are no rewards to distribute, do nothing
            if (_amount == 0) return;
        }

        // if there are no recipients, receiptTokens are pulled to this contract
        // but won't be claimable by anyone
        // this happens only if the ProfitManager sends rewards to the locking module
        // even though no one is locked, which should never happen.
        if (_globalRewardWeight == 0) return;

        uint256 _rewardWeightIncrement = 0;
        uint256 _receiptTokensIncrement = 0;
        uint256 nBuckets = enabledBuckets.length;
        for (uint256 i = 0; i < nBuckets; i++) {
            BucketData storage data = buckets[enabledBuckets[i]];

            // increase total locked tokens
            uint256 epochTotalReceiptToken = data.totalReceiptTokens;
            uint256 totalRewardWeight = epochTotalReceiptToken.mulWadDown(
                data.multiplier
            );
            uint256 allocation = _amount.mulDivDown(
                totalRewardWeight,
                _globalRewardWeight
            );
            if (allocation == 0) continue;

            data.totalReceiptTokens = epochTotalReceiptToken + allocation;
            _receiptTokensIncrement += allocation;

            // increase reward weight proportionally
            uint256 newTotalRewardWeight = (epochTotalReceiptToken + allocation)
                .mulWadDown(data.multiplier);
            _rewardWeightIncrement += newTotalRewardWeight - totalRewardWeight;
        }

        globalReceiptToken += _receiptTokensIncrement;
        globalRewardWeight = _globalRewardWeight + _rewardWeightIncrement;
    }

    /// @notice Apply losses to the locking module
    function applyLosses(
        uint256 _amount
    ) external onlyCoreRole(CoreRoles.FINANCE_MANAGER) {
        if (_amount == 0) return;  //如果虧損 = 0 什麼都不做

        emit LossesApplied(block.timestamp, _amount);

        // compute split between locking users & unwinding users
        uint256 unwindingBalance = UnwindingModule(unwindingModule)
            .totalReceiptTokens();        //global receipt token 追蹤不到 不知道什麼時候改動他的
        uint256 _globalReceiptToken = globalReceiptToken; // 底線變數通常是表示要被傳入function的變數 但這邊就是用底線變數要拿來計算
        uint256 amountToUnwinding = _amount.mulDivDown(   //  沒底線變數就是狀態變數 
            unwindingBalance,
            unwindingBalance + _globalReceiptToken     // 雖然 global不知道啥意思 但這邊猜的到就是在解lock人的比例， 
        );                                              // 乘上negative yield (_amount) 就是解鎖人要虧的token數量 
                                                        // 看起來解鎖人要虧的錢沒有比較少 (沒有multipier)
        UnwindingModule(unwindingModule).applyLosses(amountToUnwinding);
        _amount -= amountToUnwinding; 

        if (_amount == 0) return;  //會變成0就是_amount = amountUnwinding 那就代表unwinding的人佔據locking人的100%
// 所以把loss分配給unwinding人之後 下面的把損失分給還在lock的人的程式碼就不用執行了 可以return
        ERC20Burnable(receiptToken).burn(_amount);

        uint256 nBuckets = enabledBuckets.length;
        uint256 _globalRewardWeight = globalRewardWeight;
        uint256 globalReceiptTokenDecrement = 0;
        for (uint256 i = 0; i < nBuckets; i++) {
            BucketData storage data = buckets[enabledBuckets[i]];

            // slash principal
            uint256 epochTotalReceiptToken = data.totalReceiptTokens;
            if (epochTotalReceiptToken == 0) continue;
            uint256 allocation = epochTotalReceiptToken.mulDivUp(
                _amount,
                _globalReceiptToken
            );
            allocation = _min(allocation, epochTotalReceiptToken); // up rounding could cause underflows
            data.totalReceiptTokens = epochTotalReceiptToken - allocation;
            globalReceiptTokenDecrement += allocation;

            // slash reward weight
            uint256 multiplier = data.multiplier;
            uint256 epochTotalRewardWeight = epochTotalReceiptToken.mulWadDown(
                multiplier
            );
            uint256 newEpochTotalRewardWeight = (epochTotalReceiptToken -
                allocation).mulWadDown(multiplier);
            uint256 rewardWeightDecrease = epochTotalRewardWeight -
                newEpochTotalRewardWeight;
            _globalRewardWeight -= rewardWeightDecrease;
        }

        globalReceiptToken = _globalReceiptToken - globalReceiptTokenDecrement;
        globalRewardWeight = _globalRewardWeight;

        // if a full slashing occurred either in the UnwindingModule or in the LockingController,
        // pause the contract to prevent any further operations.
        // Resolving the situation will require a protocol upgrade, as the share prices of the
        // circulating locked tokens are now 0, and/or the slashingIndex in the unwindingModule is 0.
        {
            bool unwindingWipedOut = amountToUnwinding > 0 &&
                amountToUnwinding == unwindingBalance;
            bool globalWipedOut = globalReceiptTokenDecrement > 0 &&
                globalReceiptTokenDecrement == _globalReceiptToken;

            if (unwindingWipedOut || globalWipedOut) _pause();
        }
    }
}
