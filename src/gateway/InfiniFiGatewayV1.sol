// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {StakedToken} from "@tokens/StakedToken.sol";
import {ReceiptToken} from "@tokens/ReceiptToken.sol";
import {CoreControlled} from "@core/CoreControlled.sol";
import {MintController} from "@funding/MintController.sol";
import {RedeemController} from "@funding/RedeemController.sol";
import {AllocationVoting} from "@governance/AllocationVoting.sol";
import {LockingController} from "@locking/LockingController.sol";
import {LockedPositionToken} from "@tokens/LockedPositionToken.sol";
import {YieldSharing} from "@finance/YieldSharing.sol";

/// @notice Gateway to interact with the InfiniFi protocol
contract InfiniFiGatewayV1 is CoreControlled {
    using SafeERC20 for ERC20;

    /// @notice error thrown when there are pending losses unapplied
    /// if you observe this error as a user, call YieldSharing.accrue() before
    /// attempting a withdrawal from the vault.
    error PendingLossesUnapplied();

    event AddressSet(uint256 timestamp, string indexed name, address _address);

    /// @notice address registry of the gateway
    mapping(bytes32 => address) public addresses;

    constructor() CoreControlled(address(1)) {}

    /// @notice initializer for the proxy storage
    function init(address _core) external {
        assert(address(core()) == address(0));
        _setCore(_core);
    }

    /// -------------------------------------------------------------------------------------
    /// Configuration
    /// -------------------------------------------------------------------------------------

    /// @notice set an address for a given name
    function setAddress(
        string memory _name,
        address _address
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        addresses[keccak256(abi.encode(_name))] = _address;
        emit AddressSet(block.timestamp, _name, _address);
    }

    /// @notice get an address for a given name
    function getAddress(string memory _name) public view returns (address) {
        return addresses[keccak256(abi.encode(_name))];
    }

    /// -------------------------------------------------------------------------------------
    /// User interactions
    /// -------------------------------------------------------------------------------------

    //@seashell 用到 erc20的usdc   然後自己寫的 funding/ mintcontroller  授權給它使用用戶存起來的錢，然後計算出要給的share 並且發share

    function mint(
        address _to,
        uint256 _amount
    ) external whenNotPaused returns (uint256) {
        ERC20 usdc = ERC20(getAddress("USDC"));
        MintController mintController = MintController(
            getAddress("mintController")
        );

        usdc.safeTransferFrom(msg.sender, address(this), _amount); //@seashell 它有檢查使用者有沒有approve 讓這行能轉錢嗎。
        usdc.approve(address(mintController), _amount);
        return mintController.mint(_to, _amount);
    }

    // @ seashell mint 是直接回傳 mintController的 mint函數的share 這邊則是用變數存起來，
    // @ 然後用iusd(stake代幣)的方法去額外計算。  根據doc 把 usdc存進去換到iusd後，stake iusd 就會讓使用者最後得到siusd存進它戶頭
    // @ _to應該是使用者自己的戶頭 最後deposit 也會把siusd存進_to

    function mintAndStake(
        address _to,
        uint256 _amount
    ) external whenNotPaused returns (uint256) {
        MintController mintController = MintController(
            getAddress("mintController")
        );
        StakedToken siusd = StakedToken(getAddress("stakedToken"));
        ReceiptToken iusd = ReceiptToken(getAddress("receiptToken"));
        ERC20 usdc = ERC20(getAddress("USDC"));

        usdc.safeTransferFrom(msg.sender, address(this), _amount);
        usdc.approve(address(mintController), _amount);
        uint256 receiptTokens = mintController.mint(address(this), _amount);

        iusd.approve(address(siusd), receiptTokens);
        siusd.deposit(receiptTokens, _to);
        return receiptTokens;
    }

    // @seashell 上面是stake iusd 得到 siusd。這邊lock 則是要lock iusd 然後 create position。 最後應該要得到liusd -1w之類的
    // 但我這邊結尾好像只看到 receipt token 也就是iusd?
    function mintAndLock(
        address _to,
        uint256 _amount,
        uint32 _unwindingEpochs
    ) external whenNotPaused returns (uint256) {
        MintController mintController = MintController(
            getAddress("mintController")
        );
        ReceiptToken iusd = ReceiptToken(getAddress("receiptToken"));
        LockingController lockingController = LockingController(
            getAddress("lockingController")
        );
        ERC20 usdc = ERC20(getAddress("USDC"));

        usdc.safeTransferFrom(msg.sender, address(this), _amount);
        usdc.approve(address(mintController), _amount);
        uint256 receiptTokens = mintController.mint(address(this), _amount);

        iusd.approve(address(lockingController), receiptTokens);
        lockingController.createPosition(receiptTokens, _unwindingEpochs, _to);
        return receiptTokens;
    }

    function unstakeAndLock(
        address _to,
        uint256 _amount,
        uint32 _unwindingEpochs
    ) external whenNotPaused returns (uint256) {
        ReceiptToken iusd = ReceiptToken(getAddress("receiptToken"));
        StakedToken siusd = StakedToken(getAddress("stakedToken"));
        LockingController lockingController = LockingController(
            getAddress("lockingController")
        );

        siusd.transferFrom(msg.sender, address(this), _amount);
        uint256 receiptTokens = siusd.redeem(
            _amount,
            address(this),
            address(this)
        );

        iusd.approve(address(lockingController), receiptTokens);
        lockingController.createPosition(receiptTokens, _unwindingEpochs, _to);
        return receiptTokens;
    }

    function createPosition(
        uint256 _amount,
        uint32 _unwindingEpochs,
        address _recipient
    ) external whenNotPaused {
        ReceiptToken iusd = ReceiptToken(getAddress("receiptToken"));
        LockingController lockingController = LockingController(
            getAddress("lockingController")
        );

        iusd.transferFrom(msg.sender, address(this), _amount);
        iusd.approve(address(lockingController), _amount);
        lockingController.createPosition(_amount, _unwindingEpochs, _recipient);
    }

    function startUnwinding(
        uint256 _shares,
        uint32 _unwindingEpochs
    ) external whenNotPaused {
        LockingController lockingController = LockingController(
            getAddress("lockingController")
        );
        LockedPositionToken liusd = LockedPositionToken(
            lockingController.shareToken(_unwindingEpochs)
        );

        liusd.transferFrom(msg.sender, address(this), _shares);
        liusd.approve(address(lockingController), _shares);
        lockingController.startUnwinding(_shares, _unwindingEpochs, msg.sender);
    }

    function increaseUnwindingEpochs(
        uint32 _oldUnwindingEpochs,
        uint32 _newUnwindingEpochs
    ) external whenNotPaused {
        LockingController lockingController = LockingController(
            getAddress("lockingController")
        );
        LockedPositionToken liusd = LockedPositionToken(
            lockingController.shareToken(_oldUnwindingEpochs)
        );

        uint256 shares = liusd.balanceOf(msg.sender);
        liusd.transferFrom(msg.sender, address(this), shares);
        liusd.approve(address(lockingController), shares);
        lockingController.increaseUnwindingEpochs(
            shares,
            _oldUnwindingEpochs,
            _newUnwindingEpochs,
            msg.sender
        );
    }

    function cancelUnwinding(
        uint256 _unwindingTimestamp,
        uint32 _newUnwindingEpochs
    ) external whenNotPaused {
        LockingController(getAddress("lockingController")).cancelUnwinding(
            msg.sender,
            _unwindingTimestamp,
            _newUnwindingEpochs
        );
    }

    function withdraw(uint256 _unwindingTimestamp) external whenNotPaused {
        _revertIfThereAreUnaccruedLosses(); // 農場裡的總資產跌價了之後，應該要收回一些使用者的 shar
        LockingController(getAddress("lockingController")).withdraw(
            msg.sender,
            _unwindingTimestamp
        );
    }
    // 為甚麼這邊是用get address 不是預先寫好實體 lockingController

    /*    function _revertIfThereAreUnaccruedLosses() internal view {
        YieldSharing yieldSharing = YieldSharing(getAddress("yieldSharing"));
        require(yieldSharing.unaccruedYield() >= 0, PendingLossesUnapplied());
    }

        function unaccruedYield() public view returns (int256) {
        uint256 receiptTokenPrice = Accounting(accounting).price(receiptToken);
        uint256 assets = Accounting(accounting).totalAssetsValue(); // returns assets in USD

        uint256 assetsInReceiptTokens = assets.divWadDown(receiptTokenPrice);          //todo 檢查asset算法 除法

        return int256(assetsInReceiptTokens) - int256(ReceiptToken(receiptToken).totalSupply());
    }
}
 */
    /*   __________________
  /// @notice Withdraw after an unwinding period has completed
    function withdraw(address _user, uint256 _unwindingTimestamp)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.ENTRY_POINT)
    {
        UnwindingModule(unwindingModule).withdraw(_unwindingTimestamp, _user);
    }
     */

    /*  /// @notice Withdraw after an unwinding period has completed
    function withdraw(uint256 _startUnwindingTimestamp, address _owner)
        external
        onlyCoreRole(CoreRoles.LOCKED_TOKEN_MANAGER)
    {
        uint32 currentEpoch = uint32(block.timestamp.epoch());
        bytes32 id = _unwindingId(_owner, _startUnwindingTimestamp);
        UnwindingPosition memory position = positions[id];
        require(position.toEpoch > 0, UserNotUnwinding());
        require(currentEpoch >= position.toEpoch, UserUnwindingInprogress());

        uint256 userBalance = balanceOf(_owner, _startUnwindingTimestamp);
        uint256 userRewardWeight =
            position.fromRewardWeight - (position.toEpoch - position.fromEpoch) * position.rewardWeightDecrease;
        delete positions[id];

        GlobalPoint memory point = _getLastGlobalPoint();
        point.totalRewardWeight -= userRewardWeight;
        _updateGlobalPoint(point);

        totalShares -= position.shares;
        totalReceiptTokens -= userBalance;

        require(IERC20(receiptToken).transfer(_owner, userBalance), TransferFailed());
        emit Withdrawal(block.timestamp, _startUnwindingTimestamp, _owner);
    } */

    //@seashell 不用等unwinding 也不用算yield (withdraw才要)   是吃使用者的iusd然後還給他asset token ( 但我還不知道是什麼 可能是穩定幣或是uth吧) 但大概不會是直接能換回usd defi協議好像不太處理法幣
    function redeem(
        address _to,
        uint256 _amount
    ) external whenNotPaused returns (uint256) {
        _revertIfThereAreUnaccruedLosses();
        ReceiptToken iusd = ReceiptToken(getAddress("receiptToken"));
        RedeemController redeemController = RedeemController(
            getAddress("redeemController")
        );

        iusd.transferFrom(msg.sender, address(this), _amount);
        iusd.approve(address(redeemController), _amount);
        return redeemController.redeem(_to, _amount); //@todo 回傳的東西對嗎
    } //@seashell _amount 就是 amount-in   。 這邊跟使用者收amount in 但是

    function claimRedemption() external whenNotPaused {
        RedeemController(getAddress("redeemController")).claimRedemption(
            msg.sender
        );
    }

    // seashell 投票的主要邏輯是在 allocatingVoting 這邊只是接收使用者傳進來的參數，不太危險。
    // asset 聽說是選擇代幣  unwinding是「要投的是第幾周的farm」
    // 兩個calldata是使用者的票，一個投流動farm 一個投非流動farm。 calldata好像就是使用者傳進來的參數。
    // asset我不太確定的原因就是因為，代幣不是就三種嗎 iusd  siusd liusd 第一個是基本代幣 第二第三就代表的是流動 非流動
    // 那不就跟call data重疊了。

    function vote(
        address _asset,
        uint32 _unwindingEpochs,
        AllocationVoting.AllocationVote[] calldata _liquidVotes,
        AllocationVoting.AllocationVote[] calldata _illiquidVotes
    ) external whenNotPaused {
        AllocationVoting(getAddress("allocationVoting")).vote(
            msg.sender,
            _asset,
            _unwindingEpochs,
            _liquidVotes,
            _illiquidVotes
        );
    }

    //seashell 跟vote一樣，只是傳了多張票 ，用loop遍歷。 會有多張票應該是因為有1w 2w之分 因為如果是要投多個farm。
    // farm 的 array 結構應該本來就支持直接投多個
    function multiVote(
        address[] calldata _assets,
        uint32[] calldata _unwindingEpochs,
        AllocationVoting.AllocationVote[][] calldata _liquidVotes,
        AllocationVoting.AllocationVote[][] calldata _illiquidVotes
    ) external whenNotPaused {
        AllocationVoting allocationVoting = AllocationVoting(
            getAddress("allocationVoting")
        );

        for (uint256 i = 0; i < _assets.length; i++) {
            allocationVoting.vote(
                msg.sender,
                _assets[i],
                _unwindingEpochs[i],
                _liquidVotes[i],
                _illiquidVotes[i]
            );
        }
    }

    function _revertIfThereAreUnaccruedLosses() internal view {
        YieldSharing yieldSharing = YieldSharing(getAddress("yieldSharing"));
        require(yieldSharing.unaccruedYield() >= 0, PendingLossesUnapplied());
    }
}
