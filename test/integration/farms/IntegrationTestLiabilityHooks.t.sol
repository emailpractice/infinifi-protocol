// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Fixture} from "@test/Fixture.t.sol";
import {console} from "@forge-std/console.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {FarmTypes} from "@libraries/FarmTypes.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {InfiniFiCore} from "@core/InfiniFiCore.sol";
import {AllocationVoting} from "@governance/AllocationVoting.sol";

import {AfterMintHook} from "@integrations/farms/movement/AfterMintHook.sol";
import {BeforeRedeemHook} from "@integrations/farms/movement/BeforeRedeemHook.sol";

/// Actors in this test are:
/// Alice -> Ordinary end user that is minting and redeeming
/// Danny -> An existing user with capabilities of voting for farm allocation
contract IntegrationTestLiabilityHooks is Fixture {
    AfterMintHook afterMintHook;
    BeforeRedeemHook beforeRedeemHook;

    uint256 aliceAssetAmount = 100e18;
    uint256 dannyAssetAmount = 100e18;
    AllocationVoting.AllocationVote[] liquidVotes;
    AllocationVoting.AllocationVote[] illiquidVotes;

    function setUp() public override {
        super.setUp();

        afterMintHook = new AfterMintHook(address(core), address(accounting), address(allocationVoting));
        beforeRedeemHook = new BeforeRedeemHook(address(core), address(accounting), address(allocationVoting));

        _initializeHooks();
        _prepareScenario();
    }

    /// ============================
    /// Configuration & Voting Setup
    /// ============================

    function _initializeHooks() internal {
        vm.startPrank(governorAddress);
        {
            core.grantRole(CoreRoles.FARM_MANAGER, address(afterMintHook));
            core.grantRole(CoreRoles.FARM_MANAGER, address(beforeRedeemHook));
            mintController.setAfterMintHook(address(afterMintHook));
            redeemController.setBeforeRedeemHook(address(beforeRedeemHook));
        }
        vm.stopPrank();
    }

    function _preparePosition() internal {
        deal(address(iusd), danny, dannyAssetAmount);

        // open position and wait for user to gain some power
        vm.startPrank(danny);
        {
            ERC20(iusd).approve(address(gateway), dannyAssetAmount);
            gateway.createPosition(dannyAssetAmount, 5, danny);
        }
        vm.stopPrank();
    }

    // Helper to prepare 50-50 votes
    function _prepareVote() internal {
        uint256 totalPower = lockingController.rewardWeight(danny);
        uint96 totalPowerHalf = uint96(totalPower / 2);

        liquidVotes.push(AllocationVoting.AllocationVote({farm: address(farm1), weight: totalPowerHalf}));
        liquidVotes.push(AllocationVoting.AllocationVote({farm: address(farm2), weight: totalPowerHalf}));

        illiquidVotes.push(AllocationVoting.AllocationVote({farm: address(illiquidFarm1), weight: totalPowerHalf}));
        illiquidVotes.push(AllocationVoting.AllocationVote({farm: address(illiquidFarm2), weight: totalPowerHalf}));

        vm.prank(danny);
        gateway.vote(address(usdc), 5, liquidVotes, illiquidVotes);

        skip(1 weeks);

        (,, uint256 totalPowerVoted) = allocationVoting.getVoteWeights(FarmTypes.LIQUID);
        (,, totalPowerVoted) = allocationVoting.getVoteWeights(FarmTypes.MATURITY);

        assertEq(totalPower, totalPowerVoted, "Total power voted must equal individual power");
    }

    function _prepareScenario() internal {
        // Danny is going to be a voter
        _preparePosition();
        _prepareVote();
    }

    /// ============================
    /// Tests
    /// ============================

    function testAfterMintAuthorization() public {
        vm.startPrank(carol);
        {
            deal(address(usdc), carol, aliceAssetAmount);
            ERC20(usdc).approve(address(afterMintHook), type(uint256).max);
            try afterMintHook.afterMint(address(0), aliceAssetAmount) {
                assertTrue(true, "Failed to perform proper role check on afterMint hook");
                // noop
            } catch {
                assertTrue(true, "Unauthorized access to afterMint");
            }
        }
        vm.stopPrank();
    }

    function testBeforeRedeemAuthorization() public {
        vm.startPrank(carol);
        {
            deal(address(usdc), carol, aliceAssetAmount);
            ERC20(usdc).approve(address(beforeRedeemHook), type(uint256).max);
            try beforeRedeemHook.beforeRedeem(address(0), 0, aliceAssetAmount) {
                assertTrue(true, "Failed to perform proper role check on beforeRedeem hook");
                // noop
            } catch {
                assertTrue(true, "Unauthorized access to beforeRedeem");
            }
        }
        vm.stopPrank();
    }

    /// Tests mint operation when there is 50-50 allocation with two farms
    function testAfterMintIntegrationEvenSplit() public {
        vm.startPrank(alice);
        {
            deal(address(usdc), alice, aliceAssetAmount);
            ERC20(usdc).approve(address(gateway), type(uint256).max);

            gateway.mint(alice, (aliceAssetAmount / 2));
            gateway.mint(alice, (aliceAssetAmount / 2));

            // need to upscale since usdc has 6 decimals
            assertEq(iusd.balanceOf(alice), aliceAssetAmount * 1e12, "Should receive 1-1 iUSD for same amount of USDC");
            assertEq(farm1.assets(), aliceAssetAmount / 2, "Half should be in farm 1");
            assertEq(farm2.assets(), aliceAssetAmount / 2, "Half should be in farm 2");
        }
        vm.stopPrank();
        // skip some time to avoid transfer restriction
        vm.warp(block.timestamp + 10);
    }

    /// Redeems entire liquid TVL
    function testBeforeRedeemIntegrationFullRedeem() public {
        testAfterMintIntegrationEvenSplit();

        vm.startPrank(alice);
        {
            ERC20(iusd).approve(address(gateway), type(uint256).max);
            uint256 aliceBalance = ERC20(iusd).balanceOf(alice);

            gateway.redeem(alice, aliceBalance);

            assertEq(farm1.assets(), 0, "Farm 1 should be empty");
            assertEq(farm2.assets(), 0, "Farm 2 should be empty");
            assertEq(iusd.balanceOf(alice), 0, "Alice should no longer have iUSD");
            assertEq(accounting.totalAssets(address(usdc)), 0, "Liquid TVL should be zero");
        }
        vm.stopPrank();
    }

    /// Redeems 25% of iUSD holdings
    function testBeforeRedeemIntegrationPartialRedeem() public {
        testAfterMintIntegrationEvenSplit();

        vm.startPrank(alice);
        {
            ERC20(iusd).approve(address(gateway), type(uint256).max);
            uint256 aliceBalance = ERC20(iusd).balanceOf(alice);

            gateway.redeem(alice, aliceBalance / 4);

            assertEq(farm1.assets(), aliceAssetAmount / 4, "Farm 1 should be used for redemption");
            assertEq(farm2.assets(), aliceAssetAmount / 2, "Farm 2 should not be affected");
            assertEq(iusd.balanceOf(alice), (aliceBalance / 4) * 3, "Alice iUSD amount must be reduced to 75%");
        }
        vm.stopPrank();
    }

    /// Redeems 75% of iUSD holdings, meaning there is no farm good enough to satisfy the request
    /// In turn, all money will be pulled out proportionally according to the actual ratio within the farms
    function testBeforeRedeemIntegrationExcesiveRedeem() public {
        testAfterMintIntegrationEvenSplit();

        vm.startPrank(alice);
        {
            ERC20(iusd).approve(address(gateway), type(uint256).max);
            uint256 aliceBalance = ERC20(iusd).balanceOf(alice);

            gateway.redeem(alice, (aliceBalance / 4) * 3);

            assertEq(farm1.assets(), aliceAssetAmount / 8, "Farm 1 should provide 50% of the total redemption");
            assertEq(farm2.assets(), aliceAssetAmount / 8, "Farm 2 should provide 50% of the total redemption");
            assertEq(iusd.balanceOf(alice), (aliceBalance / 4), "Alice iUSD amount must be reduced to 25%");
        }
        vm.stopPrank();
    }

    /// This case does four partial redeems, each by 25% percent of iUSD holdings
    function testBeforeRedeemIntegrationSequentialFullRedeem() public {
        testAfterMintIntegrationEvenSplit();

        vm.startPrank(alice);
        {
            ERC20(iusd).approve(address(gateway), type(uint256).max);
            uint256 aliceBalance = ERC20(iusd).balanceOf(alice);

            gateway.redeem(alice, (aliceBalance / 4));
            gateway.redeem(alice, (aliceBalance / 4));
            gateway.redeem(alice, (aliceBalance / 4));
            gateway.redeem(alice, (aliceBalance / 4));

            assertEq(farm1.assets(), 0, "Farm 1 should be empty after multiple redeems");
            assertEq(farm2.assets(), 0, "Farm 2 should be empty after multiple redeems");
            assertEq(iusd.balanceOf(alice), 0, "Alice iUSD amount must be 0");
        }
        vm.stopPrank();
    }
}
