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

    /// @notice error thrown when a swap fails
    error SwapFailed();

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
    function setAddress(string memory _name, address _address) external onlyCoreRole(CoreRoles.GOVERNOR) {
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

    function mint(address _to, uint256 _amount) external whenNotPaused returns (uint256) {
        ERC20 usdc = ERC20(getAddress("USDC"));
        MintController mintController = MintController(getAddress("mintController"));

        usdc.safeTransferFrom(msg.sender, address(this), _amount);
        usdc.approve(address(mintController), _amount);
        return mintController.mint(_to, _amount);
    }

    function mintAndStake(address _to, uint256 _amount) external whenNotPaused returns (uint256) {
        MintController mintController = MintController(getAddress("mintController"));
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

    function zapInAndLock(
        address _token,
        uint256 _amount,
        bytes calldata _routerData,
        uint32 _unwindingEpochs,
        address _to
    ) external payable whenNotPaused returns (uint256) {
        // pull in the tokens and approve the router if not using native ETH
        address _router = getAddress("zapRouter");
        if (_token != address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)) {
            ERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
            ERC20(_token).forceApprove(address(_router), _amount);
        }

        // perform swap to USDC
        (bool swapSuccess,) = _router.call{value: msg.value}(_routerData);
        require(swapSuccess, SwapFailed());

        // read the protocol addresses from storage
        MintController mintController = MintController(getAddress("mintController"));
        LockingController lockingController = LockingController(getAddress("lockingController"));
        ReceiptToken iusd = ReceiptToken(getAddress("receiptToken"));
        ERC20 usdc = ERC20(getAddress("USDC"));

        // mint iUSD
        uint256 usdcReceived = usdc.balanceOf(address(this));
        usdc.approve(address(mintController), usdcReceived);
        uint256 receiptTokens = mintController.mint(address(this), usdcReceived);

        // lock the iUSD
        iusd.approve(address(lockingController), receiptTokens);
        lockingController.createPosition(receiptTokens, _unwindingEpochs, _to);
        return receiptTokens;
    }

    function mintAndLock(address _to, uint256 _amount, uint32 _unwindingEpochs)
        external
        whenNotPaused
        returns (uint256)
    {
        MintController mintController = MintController(getAddress("mintController"));
        ReceiptToken iusd = ReceiptToken(getAddress("receiptToken"));
        LockingController lockingController = LockingController(getAddress("lockingController"));
        ERC20 usdc = ERC20(getAddress("USDC"));

        usdc.safeTransferFrom(msg.sender, address(this), _amount);
        usdc.approve(address(mintController), _amount);
        uint256 receiptTokens = mintController.mint(address(this), _amount);

        iusd.approve(address(lockingController), receiptTokens);
        lockingController.createPosition(receiptTokens, _unwindingEpochs, _to);
        return receiptTokens;
    }

    function unstakeAndLock(address _to, uint256 _amount, uint32 _unwindingEpochs)
        external
        whenNotPaused
        returns (uint256)
    {
        ReceiptToken iusd = ReceiptToken(getAddress("receiptToken"));
        StakedToken siusd = StakedToken(getAddress("stakedToken"));
        LockingController lockingController = LockingController(getAddress("lockingController"));

        siusd.transferFrom(msg.sender, address(this), _amount);
        uint256 receiptTokens = siusd.redeem(_amount, address(this), address(this));

        iusd.approve(address(lockingController), receiptTokens);
        lockingController.createPosition(receiptTokens, _unwindingEpochs, _to);
        return receiptTokens;
    }

    function createPosition(uint256 _amount, uint32 _unwindingEpochs, address _recipient) external whenNotPaused {
        ReceiptToken iusd = ReceiptToken(getAddress("receiptToken"));
        LockingController lockingController = LockingController(getAddress("lockingController"));

        iusd.transferFrom(msg.sender, address(this), _amount);
        iusd.approve(address(lockingController), _amount);
        lockingController.createPosition(_amount, _unwindingEpochs, _recipient);
    }

    function startUnwinding(uint256 _shares, uint32 _unwindingEpochs) external whenNotPaused {
        LockingController lockingController = LockingController(getAddress("lockingController"));
        LockedPositionToken liusd = LockedPositionToken(lockingController.shareToken(_unwindingEpochs));

        liusd.transferFrom(msg.sender, address(this), _shares);
        liusd.approve(address(lockingController), _shares);
        lockingController.startUnwinding(_shares, _unwindingEpochs, msg.sender);
    }

    function increaseUnwindingEpochs(uint32 _oldUnwindingEpochs, uint32 _newUnwindingEpochs) external whenNotPaused {
        LockingController lockingController = LockingController(getAddress("lockingController"));
        LockedPositionToken liusd = LockedPositionToken(lockingController.shareToken(_oldUnwindingEpochs));

        uint256 shares = liusd.balanceOf(msg.sender);
        liusd.transferFrom(msg.sender, address(this), shares);
        liusd.approve(address(lockingController), shares);
        lockingController.increaseUnwindingEpochs(shares, _oldUnwindingEpochs, _newUnwindingEpochs, msg.sender);
    }

    function cancelUnwinding(uint256 _unwindingTimestamp, uint32 _newUnwindingEpochs) external whenNotPaused {
        LockingController(getAddress("lockingController")).cancelUnwinding(
            msg.sender, _unwindingTimestamp, _newUnwindingEpochs
        );
    }

    function withdraw(uint256 _unwindingTimestamp) external whenNotPaused {
        _revertIfThereAreUnaccruedLosses();
        LockingController(getAddress("lockingController")).withdraw(msg.sender, _unwindingTimestamp);
    }

    function redeem(address _to, uint256 _amount) external whenNotPaused returns (uint256) {
        _revertIfThereAreUnaccruedLosses();
        ReceiptToken iusd = ReceiptToken(getAddress("receiptToken"));
        RedeemController redeemController = RedeemController(getAddress("redeemController"));

        iusd.transferFrom(msg.sender, address(this), _amount);
        iusd.approve(address(redeemController), _amount);
        return redeemController.redeem(_to, _amount);
    }

    function claimRedemption() external whenNotPaused {
        RedeemController(getAddress("redeemController")).claimRedemption(msg.sender);
    }

    function vote(
        address _asset,
        uint32 _unwindingEpochs,
        AllocationVoting.AllocationVote[] calldata _liquidVotes,
        AllocationVoting.AllocationVote[] calldata _illiquidVotes
    ) external whenNotPaused {
        AllocationVoting(getAddress("allocationVoting")).vote(
            msg.sender, _asset, _unwindingEpochs, _liquidVotes, _illiquidVotes
        );
    }

    function multiVote(
        address[] calldata _assets,
        uint32[] calldata _unwindingEpochs,
        AllocationVoting.AllocationVote[][] calldata _liquidVotes,
        AllocationVoting.AllocationVote[][] calldata _illiquidVotes
    ) external whenNotPaused {
        AllocationVoting allocationVoting = AllocationVoting(getAddress("allocationVoting"));

        for (uint256 i = 0; i < _assets.length; i++) {
            allocationVoting.vote(msg.sender, _assets[i], _unwindingEpochs[i], _liquidVotes[i], _illiquidVotes[i]);
        }
    }

    function _revertIfThereAreUnaccruedLosses() internal view {
        YieldSharing yieldSharing = YieldSharing(getAddress("yieldSharing"));
        require(yieldSharing.unaccruedYield() >= 0, PendingLossesUnapplied());
    }
}
