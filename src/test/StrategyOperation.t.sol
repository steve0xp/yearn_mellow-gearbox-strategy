// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;

import "forge-std/console.sol";

import {StrategyFixture} from "./utils/StrategyFixture.sol";
import {StrategyParams} from "../interfaces/Vault.sol";

contract StrategyOperationsTest is StrategyFixture {
    // setup is run on before each test
    function setUp() public override {
        // setup vault
        super.setUp();
    }

    function testSetupVaultOK() public {
        console.log("address of vault", address(vault));
        assertTrue(address(0) != address(vault));
        assertEq(vault.token(), address(want));
        assertEq(vault.depositLimit(), type(uint256).max);
    }

    // @todo add additional check on strat params
    function testSetupStrategyOK() public {
        console.log("address of strategy", address(strategy));
        assertTrue(address(0) != address(strategy));
        assertEq(address(strategy.vault()), address(vault));
    }

    /// Test Operations

    /// @dev unique mellow-strategy add-ons: Ensure initial harvest() leads to investing into Mellow vault (MV) && check LPT redemption pricing getters/calcs equates to correct amount of wantToken.
    /// @todo Needs helper that calculates wantTokenPrice from LPT && Epoch price
    function testStrategyOperation(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), user, _amount);

        uint256 balanceBefore = want.balanceOf(address(user));
        vm.prank(user);
        want.approve(address(vault), _amount);
        vm.prank(user);
        vault.deposit(_amount);
        assertRelApproxEq(want.balanceOf(address(vault)), _amount, DELTA);

        skip(3 minutes); // why 3 minutes? Is there something specific with this small timespan?
        vm.prank(strategist);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

        // @todo Check LP balance for mellow tokens has changed for yearn strategy. NOTE - wantTokens will be in MV, but not necessarily in gearbox credit account (CA).
        // @todo Check that wantToken for yearn vault has equates to the appropriate amounts sum(mellowLP * wantEpochPrice_respective).

        // tend
        vm.prank(strategist);
        strategy.tend();

        // TODO - check if we invest into mellow vault, and the amount hasn't been input to the CA yet, is it readyToWithdraw()?
        // if yes, continue w/ below code.abi

        vm.prank(user);
        vault.withdraw();

        assertRelApproxEq(want.balanceOf(user), balanceBefore, DELTA);
    }

    function testEmergencyExit(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), user, _amount);

        // Deposit to the vault
        vm.prank(user);
        want.approve(address(vault), _amount);
        vm.prank(user);
        vault.deposit(_amount);
        skip(1);
        vm.prank(strategist);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

        // set emergency and exit
        vm.prank(gov);
        strategy.setEmergencyExit();
        skip(1); // TODO - again, check if we invest into mellow vault, and the amount hasn't been input to the CA yet, is it readyToWithdraw()? If yes, then continue w/ code below
        vm.prank(strategist);
        strategy.harvest();
        assertLt(strategy.estimatedTotalAssets(), _amount);
    }

    /// @dev unique mellow-strategy add-ons:
    /// NewTest1: Ensure initial harvest() && investing newly transferred amount in pre-existing CA is done correctly (through using prank(MellowSUDO) or prank.(mellowBot)).
    // NewTest2: Ensure yearn amounts are earning correct strategy yield.
    function testProfitableHarvest(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), user, _amount);

        // Deposit to the vault
        vm.prank(user);
        want.approve(address(vault), _amount);
        vm.prank(user);
        vault.deposit(_amount);
        assertRelApproxEq(want.balanceOf(address(vault)), _amount, DELTA);

        uint256 beforePps = vault.pricePerShare();

        // Harvest 1: Send funds through the strategy
        skip(1);
        vm.prank(strategist);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

        // @todo Add some code before harvest #2 to simulate earning yield
        // @todo Ensure initial harvest() && investing newly transferred amount in pre-existing CA is done correctly (through using prank(MellowSUDO) or prank.(mellowBot)).
        // @todo Check that CA has increased the proper amount (in this simulation, we're the only one depositing).
        // @todo Check for any emitted events - though this isn't our code at this point.

        // Harvest 2: Realize profit
        skip(1);
        vm.prank(strategist);
        strategy.harvest(); // NOTE - this calls prepareReturn() && liquidatePosition(). Taking what it needs from mellow if possible or registering a withdrawal.
        // @todo registerWithrawal here bc we haven't registered it before yet. Check for events emitted, check for gearboxRootVault.lpTokensWaitingForClaim() that it is what it should be.
        // @todo check that gearboxRootVault.primaryTokensToClaim(address(this)) hasn't changed.
        skip(6 hours); // @todo roll to block where epoch is done and CA is closed. @todo may need a helper function for this.

        // @todo call strategy.harvest() again and now the right amount of wantTokens should be withdrawn to the strategy.sol
        // @todo Uncomment the lines below
        // uint256 profit = want.balanceOf(address(vault));
        // assertGt(want.balanceOf(address(strategy)) + profit, _amount);
        // assertGt(vault.pricePerShare(), beforePps)
    }

    // @todo repeat testProfitableHarvest() test but registerWithdraw() via harvest() call right before the epoch ends. This shows that it doesn't matter when we call harvest().
    function testProfitableHarvestDuringEpoch(uint256 _amount) public {}

    // @todo do we want to do more specific tests to make sure we are getting a correct APY? If so, see below TODO
    // @todo NewTest3: Ensure yearn amounts are earning correct strategy yield. Do this by first: registerWithdraw(_amount) && checking proper amount of LPTs in withdrawQueue. THEN roll blocks forward until CA is closed. Check epochPriceToLP * LP_toWithdraw, and compare that against the nominal APY % from the last epoch - QUESTION: is this available somehow? There's ways about this, but good to know how mellow calculates their APYs they show on their UI. FINALLY: withdraw(amount) and compare the original amount deposited vs the new amount withdrawn. Make sure it's grown by the APY reported by Mellow (or APY that we are referencing) --> NOTE when calling registerWithdraw --> check that nothing has been withdrawn, check that nothing is claimable, check that LPtoken balance hasn't changed, check that amount in CA hasn't changed.

    // @todo NewTest4: Same as above test but keep amount in there for 5 epochs. @todo going to need a helper function that starts new CAs, invests mellow vault totals, and rolls forwards enough blocks to close an epoch, and repeats a set number of times (based on an input param). Check that total withdrawn is the correct APY compared to our reference guideline.

    // @todo NewTest5: Same as above test, but deposit another lumpsum during second epoch. Maybe fuzz to enter amounts during different epochs & same epoch as initial deposit

    // @todo NewTest6: Same as Test #4 / #5 but withdraw an amount < amount invested, and then withdraw it --> check that balances are correct. Then roll forward some blocks and check that remaining active capital has grown the proper amount despite the earlier withdraw.

    // @todo NewTest7: deposit, invest, registerWithdraw(smallAmount), roll to next epoch, check if it's withdrawable --> it shouldn't be at some point and just be back in the CA.

    // @todo NewTest8: deposit, invest, roll forward time so rewards accrue to whatever the MellowBot deems interesting for autocompound. prank(mellowBot) & call autocompound. Check that new amount invested & active in CA is originalAmount + swapped rewards to wantToken.

    /// @dev NOTE - tests after this line are unfinished. They are subject to the several helper functions and methods that will be decided upon as discussed/presented in comments above this one.
    function testChangeDebt(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), user, _amount);

        // Deposit to the vault and harvest
        vm.prank(user);
        want.approve(address(vault), _amount);
        vm.prank(user);
        vault.deposit(_amount);
        vm.prank(gov);
        vault.updateStrategyDebtRatio(address(strategy), 5_000);
        skip(1);
        vm.prank(strategist);
        strategy.harvest();
        uint256 half = uint256(_amount / 2);
        assertRelApproxEq(strategy.estimatedTotalAssets(), half, DELTA);

        vm.prank(gov);
        vault.updateStrategyDebtRatio(address(strategy), 10_000);
        skip(1);
        vm.prank(strategist);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

        // In order to pass these tests, you will need to implement prepareReturn.
        // @todo uncomment the following lines.
        // vm.prank(gov);
        // vault.updateStrategyDebtRatio(address(strategy), 5_000);
        // skip(1);
        // vm.prank(strategist);
        // strategy.harvest();
        // assertRelApproxEq(strategy.estimatedTotalAssets(), half, DELTA);
    }

    function testProfitableHarvestOnDebtChange(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), user, _amount);

        // Deposit to the vault
        vm.prank(user);
        want.approve(address(vault), _amount);
        vm.prank(user);
        vault.deposit(_amount);
        assertRelApproxEq(want.balanceOf(address(vault)), _amount, DELTA);

        uint256 beforePps = vault.pricePerShare();

        // Harvest 1: Send funds through the strategy
        skip(1);
        vm.prank(strategist);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

        // @todo Add some code before harvest #2 to simulate earning yield

        vm.prank(gov);
        vault.updateStrategyDebtRatio(address(strategy), 5_000);

        // In order to pass these tests, you will need to implement prepareReturn.
        // @todo uncomment the following lines.
        /*
        // Harvest 2: Realize profit
        skip(1);
        vm.prank(strategist);
        strategy.harvest();
        //Make sure we have updated the debt ratio of the strategy
        assertRelApproxEq(
            strategy.estimatedTotalAssets(), 
            _amount / 2, 
            DELTA
        );
        skip(6 hours);

        //Make sure we have updated the debt and made a profit
        uint256 vaultBalance = want.balanceOf(address(vault));
        StrategyParams memory params = vault.strategies(address(strategy));
        //Make sure we got back profit + half the deposit
        assertRelApproxEq(
            _amount / 2 + params.totalGain, 
            vaultBalance, 
            DELTA
        );
        assertGe(vault.pricePerShare(), beforePps);
        */
    }

    function testSweep(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), user, _amount);

        // Strategy want token doesn't work
        vm.prank(user);
        want.transfer(address(strategy), _amount);
        assertEq(address(want), address(strategy.want()));
        assertGt(want.balanceOf(address(strategy)), 0);

        vm.prank(gov);
        vm.expectRevert("!want");
        strategy.sweep(address(want));

        // Vault share token doesn't work
        vm.prank(gov);
        vm.expectRevert("!shares");
        strategy.sweep(address(vault));

        // @todo If you add protected tokens to the strategy.
        // Protected token doesn't work
        // vm.prank(gov);
        // vm.expectRevert("!protected");
        // strategy.sweep(strategy.protectedToken());

        uint256 beforeBalance = weth.balanceOf(gov);
        uint256 wethAmount = 1 ether;
        deal(address(weth), user, wethAmount);
        vm.prank(user);
        weth.transfer(address(strategy), wethAmount);
        assertNeq(address(weth), address(strategy.want()));
        assertEq(weth.balanceOf(user), 0);
        vm.prank(gov);
        strategy.sweep(address(weth));
        assertRelApproxEq(weth.balanceOf(gov), wethAmount + beforeBalance, DELTA);
    }

    function testTriggers(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), user, _amount);

        // Deposit to the vault and harvest
        vm.prank(user);
        want.approve(address(vault), _amount);
        vm.prank(user);
        vault.deposit(_amount);
        vm.prank(gov);
        vault.updateStrategyDebtRatio(address(strategy), 5_000);
        skip(1);
        vm.prank(strategist);
        strategy.harvest();

        strategy.harvestTrigger(0);
        strategy.tendTrigger(0);
    }
}
