// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.12;
pragma experimental ABIEncoderV2;

import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGearboxRootVault} from "@mellowvaults/contracts/interfaces/vaults/IGearboxRootVault.sol"; 

/// @title StrategyMellow-GearboxWETH
/// @notice Yearn strategy deploying wETH to Mellow Fearless Gearbox wETH strategy
/// @author @steve0xp.eth && Val John
/// @dev NOTE - contract is a wip still
contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    IGearboxRootVault internal constant gearboxRootVault = IGearboxRootVault(0xD3442BA55108d33FA1EB3F1a3C0876F892B01c44); // specific GearboxRootVault for Fearless Gearbox Strategies

    IERC20 internal constant mellowLPT = IERC20(0xD3442BA55108d33FA1EB3F1a3C0876F892B01c44); // specific mellowLPT for wETH Fearless Gearbox

    uint256 public constant D18 = 10 ** 18;

    /// @notice setup w/ wETH vault && baseStrategy details
    /// @dev optional override for initial addresses for: strategist, rewards, and keep3r which are default msg.sender
    /// @param _vault yearn v2 vault allocating collateral to this strategy
    constructor(address _vault) BaseStrategy(_vault) {}

    function name() external view override returns (string memory) {
        return string(
                abi.encodePacked(
                    "StrategyMellow-Gearbox",
                    IERC20Metadata(address(want)).symbol()
                )
            );
    }

    /// @notice returns sum of all assets, realized and unrealized
    /// @return The amount of assets this strategy manages that should not be included in Yearn's Total Value Locked (TVL) calculation across it's ecosystem.
    /// @dev Question - strategy should only have wantTokens and mellowLPTs, no other ERC20s from the strategy. Those strategies should have been converted. 
    // TODO - does `mellowStrategy.tvl()` include rewards converted to wantToken or not?
    function estimatedTotalAssets() public view override returns (uint256) {

        return balanceOfWant() + valueOfMellowLPT(); // TODO - may have to update helper functions to use gearboxRootVault.epochToPriceForLpTokenD18() for the price conversion.

        // return balanceOfWant() + ((mellowLPT.balanceOf(address(this)) * D18 / mellowLPT.totalSupply()) * mellowStrategy.tvl()) / D18;   // old no-helper function way
    }

    /// @notice called when preparing return to have proper accounting of losses and gains from the last time harvest() has been called. 
    /// @param debtOutstanding - how much want token does the vault want right now. You're preparing the return of the wantToken, liquidiating anything you can to get that amount back to the vault.
    /// @dev Part of Harvest "flow" - bot calls "harvest()", it calls this function && adjustPosition()
    /// Question - does this function only get called w/ harvest() or withdraw() sequences? If so, are there times when it is called w/ _debtOutstanding being 0?
    /// Question - can _debtOutstanding ever be bigger than what the vault actually allocated to the strategy? I assume this is defined in the vault logic / workflows
    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    // solhint-disable-next-line no-empty-blocks
    {
        // Run initial profit + loss calculations.

        uint256 _totalAssets = estimatedTotalAssets();
        uint256 _totalDebt = vault.strategies(address(this)).totalDebt;

        if (_totalAssets >= _totalDebt) {
            // Implicitly, _profit & _loss are 0 before we change them.
            _profit = _totalAssets - _totalDebt;
        } else {
            _loss = _totalDebt - _totalAssets;
        }

        // Free up _debtOutstanding + our profit, and make any necessary adjustments to the accounting.

        (uint256 _amountFreed, uint256 _liquidationLoss) =
            liquidatePosition(_debtOutstanding + _profit);

        _loss = _loss + _liquidationLoss;  

        _debtPayment = Math.min(_debtOutstanding, _amountFreed);

        // TODO - get referesher on this underflow math
        if (_loss > _profit) {
            _loss = _loss - _profit;
            _profit = 0;
        } else {
            _profit = _profit - _loss;
            _loss = 0;
        }
        
    }

    /// @notice investing excess want token into the strategy
    /// @dev Part of Harvest "flow" - bot calls "harvest()", it calls this function && prepareReturn()    
    /// @param _debtOutstanding amount of debt from Vault required at minimum
    /// @dev TODO - if we are claiming rewards that are still in CRV and CVX format from the strategy then we'll have to swap them. Right now it seems that Mellow Protocol will have them ready in wantToken. TBD from convos.
    function adjustPosition(uint256 _debtOutstanding) internal override {
        // TODO: Do something to invest excess `want` tokens (from the Vault) into your positions
        // NOTE: Try to adjust positions so that `_debtOutstanding` can be freed up on *next* harvest (not immediately)

        if (emergencyExit) {
            return;
        }

        // // from angle strategy: Claim rewards here so that we can chain tend() -> yswap sell -> harvest() in a single transaction
        // gearboxRootVault.invokeExecution(); // TODO - not sure if/what function is to be called to claim rewards for Gearbox strategy. The problem with doing this though is that we are paying the gas tx for claiming rewards. Probably should have some conditions in here to check that it's worth it.
    
        uint256 _WETHBal = balanceOfWant();

        // do not invest if we have more debt than want
        if (_debtOutstanding >= _WETHBal) {
            return;
        }

        // Invest the rest of the want

        uint256 _excessWETH = _WETHBal - _debtOutstanding;

        // TODO: do we want to define a minimum LP amount to receive based on the balance in the Mellow vault system?
        uint256 lptMinimum = 0;
        // TODO: write code connecting to mellow here. 

        uint256 lpAmount = gearboxRootVault.deposit(_excessWETH,lptMinimum,""); // TODO: What should we do with the vaultOptions param --> I see it in one of their test files for claimToken as "bytes[] memory vaultOptions = new bytes[](2);"
        assert(lpAmount >= lptMinimum);
        
    }

    /// @notice Liquidate up to `_amountNeeded` of `want` of this strategy's positions, irregardless of slippage. Any excess will be re-invested with `adjustPosition()`.
    /// @param _amountNeeded adsfasdf
    /// @return _liquidatedAmount amount of `want` tokens made available by the liquidation.
    /// @return _loss indicates whether the difference is due to a realized loss, or if there is some other sitution at play (e.g. locked funds) where the amount made available is less than what is needed.
    /// @dev NOTE: The invariant `_liquidatedAmount + _loss <= _amountNeeded` should always be maintained
    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`
        _amountNeeded = Math.min(_amountNeeded, estimatedTotalAssets()); // This makes it safe to request to liquidate more than we have

        uint256 _balanceOfWant = balanceOfWant();
        if (_balanceOfWant < _amountNeeded) {
            // We need to withdraw to get back more want
            _withdrawSome(_amountNeeded - _balanceOfWant);
            // reload balance of want after side effect
            _balanceOfWant = balanceOfWant();
        }

        if (_balanceOfWant >= _amountNeeded) {
            _liquidatedAmount = _amountNeeded;
        } else {
            _liquidatedAmount = _balanceOfWant;
            _loss = _amountNeeded - _balanceOfWant; // TODO - delete this-->  this loss is for the entire vault cause if this is happening, then the strategy doesn't have any more credit to pay the full outstanding debt. This happens even if the harvest() or liquidate() function was called for some user withdrawing funds.
        }
    }

    /// @notice Liquidate everything and returns the amount that got freed
    function liquidateAllPositions() internal override returns (uint256 _amountFreed) {
        (_amountFreed, ) = liquidatePosition(estimatedTotalAssets());
    }

    /// @notice withdraw specified amount of want from Mellow Protocol
    /// @param _amount needed to be withdrawn from underlying protocol
    /// @dev TODO - decide on how yearn is checking balance of wantTokens inside of strategy. 1. Use Mellow `tvl()` function for vaults, 2. query Gearbox for Mellow vault address and do the math based on yearn's LPT ratio vs rest of amount in Geearbox for Mellow. (1st is easier, 2nd is more to the source)
    function _withdrawSome(uint256 _amount) internal {

        uint256 _lptToBurn = Math.min(wantToMelloToken(_amount), balanceOfMellowToken()); // see dev comment above

        // TODO: write up an assertion to ensure that redemption was successfully transacted.
        // uint256 _status = cDAI.redeem(_cDaiToBurn);
        // assert(_status == 0)

        // TODO - consider having harvestTrigger() have conditional code checking that the `period` is close to elapsing.
        // TODO - NOTE: consider having bot not call `harvest()` w/ a nonzero `_debtOutstanding` unless vault really needs to access illiquid strategy assets. This is because of the partial illiquidity due to `period` duration for underlying Gearbox credit account lifespan. Thus, `harvest()` would be called to just get accounting, claim rewards, BUT NOT liquidate. OK, but if someone manually calls `harvest()` w/ a nonzero value for `_debtOutstanding`, then `withdrawSome()` would not actually successfully change the balance of wnat token, all it would do is queue up a withdraw. TODO - have talks with Mellow to have them auto-push yearn the withdrawal amount, otherwise we'll have to have a separate bot claim it or something. 
        
        gearboxRootVault.registerWithdrawal(_lptToBurn); // queues up withdrawals for current epoch. Also closes out any hanging withdrawals from before, so may have more wantToken in the strategy then we wanted from this.

    }

    /// @notice Transfer any non-`want` tokens to the new strategy
    /// @param _newStrategy where tokens will migrate to
    /// @dev - NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary
    function prepareMigration(address _newStrategy) internal override {
        // NOTE: `migrate` will automatically forward all `want` in this strategy to the new one
        // from angle strategy: wantToken is transferred by the base contract's migrate function

        // TODO - possibly transfer CRV
        // TODO - possibly transfer CVX
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    // solhint-disable-next-line no-empty-blocks
    {

    }

    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        return _amtInWei;
    }

// =================================================================================================================
    /// KEEP3RS TODO: EVERYTHING BELOW THIS LINE NEEDS TO BE LOOKED OVER BEFORE SUBMITTING THE DRAFT PR. Taken from angle strategy Val John passed to me as reference https://github.com/16slim/angle_protocol/blob/master/src/Strategy.sol 

    // use this to determine when to harvest
    function harvestTrigger(uint256 callCostinEth)
        public
        view
        override
        returns (bool)
    {
        // Should not trigger if strategy is not active (no assets and no debtRatio). This means we don't need to adjust keeper job.
        if (!isActive()) {
            return false;
        }

        // harvest if we have a profit to claim at our upper limit without considering gas price
        // TODO - if rewards / profit are in non-wantTokens then we will need to convert them -> see angle strategy and how it used uniswap routing depending on reward token it was dealing with
// NOTE - TODO: change next four lines to respect the mellow strategy (if needed at all). This whole function is from angle strategy.
        uint256 claimableProfit = claimableProfitInUsdt();
        if (claimableProfit > harvestProfitMax) {
            return true;
        }

        // check if the base fee gas price is higher than we allow. if it is, block harvests.
        if (!isBaseFeeAcceptable()) {
            return false;
        }

        // trigger if we want to manually harvest, but only if our gas price is acceptable
        if (forceHarvestTriggerOnce) {
            return true;
        }

        // harvest if we have a sufficient profit to claim, but only if our gas price is acceptable
        if (claimableProfit > harvestProfitMin) {
            return true;
        }

        StrategyParams memory params = vault.strategies(address(this));
        // harvest no matter what once we reach our maxDelay
        if (block.timestamp - params.lastReport > maxReportDelay) {
            return true;
        }

        // QUESTION WHY is this the case? Is it bc we might as well harvest if we have stuff to put in via adjustPosition? More credit means more debt allocated from the vault ready to invest into the strategy right? Or am I mistaken?
        if (vault.creditAvailable() > creditThreshold) {
            return true;
        }

        // otherwise, we don't harvest
        return false;
    }

    /// @notice The value in dollars that our claimable rewards are worth (in USDT, 6 decimals).
    /// @dev NOTE - TODO: change this to respect the mellow strategy (if needed at all). This whole function is from angle strategy.
    function claimableProfitInUsdt() public view returns (uint256) {
        address[] memory path = new address[](3);
        path[0] = address(angleToken);
        path[1] = weth;
        path[2] = address(usdt);

        uint256 _claimableRewards = sanTokenGauge.claimable_reward(address(this), address(angleToken));

        if (_claimableRewards < 1e18) { // Dust check
            return 0;
        }

        uint256[] memory amounts = IUniV2(unirouter).getAmountsOut(
            _claimableRewards,
            path
        );

        return amounts[amounts.length - 1];
    }

    // check if the current baseFee is below our external target
    // TODO: not sure if this address is the one to use still
    function isBaseFeeAcceptable() internal view returns (bool) {
        return
            IBaseFee(0xb5e1CAcB567d98faaDB60a1fD4820720141f064F)
                .isCurrentBaseFeeAcceptable();
    }


    // ---------------------- SETTERS -----------------------

    // This allows us to manually harvest with our keeper as needed
    function setForceHarvestTriggerOnce(bool _forceHarvestTriggerOnce)
        external
        onlyVaultManagers
    {
        forceHarvestTriggerOnce = _forceHarvestTriggerOnce;
    }

    // Min profit to start checking for harvests if gas is good, max will harvest no matter gas (both in USDT, 6 decimals). Credit threshold is in want token, and will trigger a harvest if credit is large enough. check earmark to look at convex's booster.
    function setHarvestTriggerParams(
        uint256 _harvestProfitMin,
        uint256 _harvestProfitMax,
        uint256 _creditThreshold
    ) external onlyVaultManagers {
        harvestProfitMin = _harvestProfitMin;
        harvestProfitMax = _harvestProfitMax;
        creditThreshold = _creditThreshold;
    }

    function setKeepInBips(uint256 _percentKeep) external onlyVaultManagers {
        require(
            _percentKeep <= MAX_BPS,
            "_percentKeep can't be larger than 10,000"
        );
        percentKeep = _percentKeep;
    }


    // ----------------- SUPPORT & UTILITY FUNCTIONS ----------

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfMellowLPT() public view returns (uint256) {
        return mellowLPT.balanceOf(address(this));
    }

    function valueOfMellowLPT() public view returns (uint256) {
        return mellowLPTToWant(balanceOfMellowLPT());
    }

    function mellowLPTToWant(uint256 _mellowTokenAmount)
        public
        view
        returns (uint256)
    {
        return (_mellowTokenAmount * getMellowLPTRate()) / 1e18; // normalize from D18 in getMellowLPTRate()
    }

    function getMellowLPTRate() public view returns (uint256) {
    
        // how much does 1 LPT equal in wantToken?
        uint256 _mellowLPTRate = mellowLPT.totalSupply() * D18 / gearboxRootVault.tvl();

        return _mellowLPTRate;
    }

    // ---------------------- YSWAPS FUNCTIONS ----------------------

    function setTradeFactory(address _tradeFactory) external onlyGovernance {
        if (tradeFactory != address(0)) {
            _removeTradeFactoryPermissions();
        }
        angleToken.safeApprove(_tradeFactory, type(uint256).max);
        ITradeFactory tf = ITradeFactory(_tradeFactory);
        tf.enable(address(angleToken), address(want));
        tradeFactory = _tradeFactory;
    }

    function removeTradeFactoryPermissions() external onlyEmergencyAuthorized {
        _removeTradeFactoryPermissions();
    }

    function _removeTradeFactoryPermissions() internal {
        angleToken.safeApprove(tradeFactory, 0);
        tradeFactory = address(0);
    }
}
