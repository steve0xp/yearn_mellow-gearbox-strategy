// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.12;

import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGearboxRootVault} from "./interfaces/Mellow/IGearboxRootVault.sol"; // specific GearboxRootVault for Fearless Gearbox Strategies

/// @title StrategyMellow-Gearbox_wETH
/// @notice Yearn strategy deploying wETH to Mellow Fearless Gearbox wETH strategy
/// @author @steve0xp && @0xValJohn
/// @dev NOTE - contract is a wip still. See PR comments && open issues, && TODOs in this file
contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    IGearboxRootVault public gearboxRootVault;
    IERC20 public mellowLPT;
    bool internal isOriginal = true;

    /// EVENTS

    event Cloned(address indexed clone);

    /// GETTERS

    /// @inheritdoc BaseStrategy
    function name() external view override returns (string memory) {
        return
            string(
                abi.encodePacked(
                    "StrategyMellow-Gearbox",
                    IERC20Metadata(address(want)).symbol()
                )
            );
    }

    /// @inheritdoc BaseStrategy
    /// @dev this is the sum of (wantBalance() + (claimableTokens * claimRateForRespectiveEpoch)+ (inStrategyTokens * currentRateForCurrentEpoch))
    function estimatedTotalAssets() public view override returns (uint256) {
        return wantBalance() + valueOfMellowLPT();
    }

    /// CONSTRUCTOR

    /// @notice setup w/ wETH vault, baseStrategy && Yearn Mellow Strategy
    /// @param _vault Yearn v2 vault allocating collateral to this strategy
    /// @param _mellowRootVault specific root vault for Mellow-Gearbox strategies, specific to wantToken. ex.) wETH: 0xD3442BA55108d33FA1EB3F1a3C0876F892B01c44
    constructor(address _vault, address _mellowRootVault)
        public
        BaseStrategy(_vault)
    {
        _initializeStrategy(__mellowRootVault);
    }

    /// SETTERS

    /// @notice initialize Yearn-Mellow-Gearbox strategy clones for new wantTokens
    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _mellowRootVault
    ) public override {
        require(address(gearboxRootVault) == address(0)); // @note Only initialize once

        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrategy(_mellowRootVault);
    }

    /// @notice create and initialize new Yearn-Mellow-Gearbox strategy for different wantToken
    function clone(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _mellowRootVault
    ) external override returns (address payable newStrategy) {
        require(isOriginal);

        bytes20 addressBytes = bytes20(address(this));

        assembly {
            let clone_code := mload(0x40)
            mstore(
                clone_code,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(
                add(clone_code, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            newStrategy := create(0, clone_code, 0x37)
        }

        Strategy(newStrategy).initialize(
            _vault,
            _strategist,
            _rewards,
            _keeper,
            _mellowRootVault
        );

        emit Cloned(newStrategy);
    }

    /// @notice permissioned manual withdrawal from Yearn-Mellow-Gearbox strategy
    function manualWithdraw()
        external
        onlyVaultManagers
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        // TODO - when are we using manualWithdraw()? Are we still carrying out accounting tasks when using this? If so, this can use similar logic to liquidatePosition().
        // TODO - Do we have two manual functions: `manualRegisterWithdraw()` & `manualWithdraw()`?
    }

    /// INTERNAL FUNCTIONS

    /// @notice initialize Yearn strategy by setting Mellow root vault
    function _initializeStrategy(address _mellowRootVault) internal {
        gearboxRootVault = IGearboxRootVault(_mellowRootVault);
        mellowLPT = IERC20(_mellowRootVault);
    }

    /// @notice called when preparing return to have accounting of losses & gains from the last harvest(), and liquidates positions if rqd
    /// @dev Part of Harvest 'workflow' - bot calls `harvest()`, it calls this function && `adjustPosition()`
    /// @param debtOutstanding how much wantToken the vault requests
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

        uint256 _totalAssets = estimatedTotalAssets(); // STEVE calculating based on gearbox values, good.
        uint256 _totalDebt = vault.strategies(address(this)).totalDebt;

        if (_totalAssets >= _totalDebt) {
            _profit = _totalAssets - _totalDebt;
        } else {
            _loss = _totalDebt - _totalAssets;
        }

        // TODO - Confirm that this 2nd param is liquidationLoss and if it's needed
        // TODO - I think that the function will revert in the mellow contracts if we attempt to liquidate more than we have in there.
        (uint256 _amountFreed, uint256 _liquidationLoss) = liquidatePosition(
            _debtOutstanding + _profit
        );

        _loss = _loss + _liquidationLoss;

        _debtPayment = Math.min(_debtOutstanding, _amountFreed); // Question - we report _debtPayments even during times when we call on harvest() where _debtOutstanding param is zero?

        if (_loss > _profit) {
            _loss = _loss - _profit;
            _profit = 0;
        } else {
            _profit = _profit - _loss;
            _loss = 0;
        }
    }

    /// @notice investing excess want token into the strategy
    /// @dev Part of Harvest 'workflow' - bot calls `harvest()`, it calls this function && `prepareReturn()`
    /// @param _debtOutstanding amount of debt from Vault required at minimum
    function adjustPosition(uint256 _debtOutstanding) internal override {
        // NOTE: Try to adjust positions so that `_debtOutstanding` can be freed up on *next* harvest (not immediately)

        if (emergencyExit) {
            return;
        }

        // TODO Question - not sure about what to do with this: from angle strategy: Claim rewards here so that we can chain tend() -> yswap sell -> harvest() in a single transaction

        uint256 _WETHBal = wantBalance();

        // do not invest if we have more debt than want
        if (_debtOutstanding >= _WETHBal) {
            return;
        }

        // Invest the rest of the want
        uint256 _excessWETH = _WETHBal - _debtOutstanding;
        uint256 lptMinimum = 0; // TODO - add minimum LP amount to receive

        uint256 lpAmount = gearboxRootVault.deposit(
            _excessWETH,
            lptMinimum,
            ""
        ); // TODO - instill checks to ensure we get at least a certain amount of LPTs back

        assert(lpAmount >= lptMinimum);
    }

    /// @notice Liquidate / Withdraw up to `_amountNeeded` of `want` of this strategy's positions, irregardless of slippage. Mellow Fearless Gearbox strategies have `periods` where wantTokens are locked up. If the Yearn strategy's tokens exist but are locked up, this function registers a withdraw to be called after `period` elapses and wantTokens from Gearbox credit account are freed up.
    /// @dev NOTE: The invariant `_liquidatedAmount + _loss <= _amountNeeded` should always be maintained
    /// @param _amountNeeded amount of `want` tokens needed from external call
    /// @return _liquidatedAmount amount of `want` tokens made available by the liquidation
    /// @return _loss indicates whether the difference is due to a realized loss, or if there is some other sitution at play (e.g. locked funds) where the amount made available is less than what is needed.
    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        _amountNeeded = Math.min(_amountNeeded, estimatedTotalAssets()); // This makes it safe to request to liquidate more than we have

        uint256 _existingLiquidAssets = wantBalance();

        if (_existingLiquidAssets >= _amountNeeded) {
            return (_amountNeeded, 0);
        }

        uint256 _primaryTokensToClaim = gearboxRootVault.primaryTokensToClaim(
            address(this)
        );
        uint256 _currentEpoch = gearboxRootVault.currentEpoch();
        uint256 _currentEpochToPriceForLpTokenD18 = gearboxRootVault
            .epochToPriceForLpTokenD18(_currentEpoch);
        uint256 _amountToWithdraw = _amountNeeded - _existingLiquidAssets;
        uint256 _newLPTRegisterWithdraw;

        // nothing to claim
        if (_primaryTokensToClaim == 0) {
            _newLPTRegisterWithdraw =
                ((_amountToWithdraw) * 1e18) /
                _currentEpochToPriceForLpTokenD18; // LPTs to burn = wantToken * d18 / price rate [want/lpt] where usually we go --> wantToken = lpt * price rate [want/lpt] / d18
            gearboxRootVault.registerWithdrawal(_newLPTRegisterWithdraw);
            return (_existingLiquidAssets, 0);
        }

        // Cannot withdraw more than withdrawable
        _amountToWithdraw = Math.min(_primaryTokensToClaim, _amountToWithdraw);

        if (_primaryTokensToClaim > 0) {
            // gearboxRootVault doesn't allow amount specified for withdrawal
            // TODO - put checks here to ensure we are getting a minimal slippage, if any upon redemption
            try gearboxRootVault.withdraw(address(this), "") {
                uint256 _newLiquidAssets = wantBalance();
                _liquidatedAmount = Math.min(_newLiquidAssets, _amountNeeded);

                if (_liquidatedAmount < _amountNeeded) {
                    // If we couldn't liquidate the full amount needed, start the withdrawal process for the remaining
                    _newLPTRegisterWithdraw =
                        ((_amountNeeded - _liquidatedAmount) * 1e18) /
                        _currentEpochToPriceForLpTokenD18; // LPTs to burn = wantToken * d18 / price rate [want/lpt] where usually we go --> wantToken = lpt * price rate [want/lpt] / d18
                    gearboxRootVault.registerWithdrawal(
                        _newLPTRegisterWithdraw
                    );
                }
            } catch {
                // If someone tries to call more than we have, the function simply returns (existingLiquidAssets, 0)
                return (_existingLiquidAssets, 0);
            }
        }
    }

    /// @inheritdoc BaseStrategy
    function liquidateAllPositions()
        internal
        override
        returns (uint256 _amountFreed)
    {
        (_amountFreed, ) = liquidatePosition(estimatedTotalAssets());
    }

    /// @inheritdoc BaseStrategy
    /// NOTE - does this transfer want and non-want tokens? I've read different things throughout my research
    function prepareMigration(address _newStrategy) internal override {
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

    /// @inheritdoc BaseStrategy
    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        return _amtInWei;
    }

    /// KEEP3RS

    /// @inheritdoc BaseStrategy
    /// @dev mellow fearless gearbox strategies have `periods` where wantToken is locked up in the strategy. Custom logic is required to check if there are `wantTokens` available to claim, or if totalPosition is locked up but has increased enough since initial `deposit`
    /// TODO - Question - where does callCostinETH get used? How is it used to check that the gas cost of the call won't be too much?
    function harvestTrigger(uint256 callCostinEth)
        public
        view
        override
        returns (bool)
    {
        // harvest if we have a profit to claim at our upper limit without considering gas price
        uint256 claimableProfit = claimableProfit();

        if (claimableProfit > harvestProfitMax) {
            return true;
        }

        // harvest if we have a sufficient profit to claim, but only if our gas price is acceptable
        if (claimableProfit > harvestProfitMin) {
            return true;
        }

        return super.harvestTrigger(callCostInWei);
    }

    /// @inheritdoc BaseStrategy
    /// TODO: not sure if this address is the one to use still
    function isBaseFeeAcceptable() internal view returns (bool) {
        return
            IBaseFee(0xb5e1CAcB567d98faaDB60a1fD4820720141f064F)
                .isCurrentBaseFeeAcceptable();
    }

    /// @notice The value in wETH that our claimable rewards are worth (18 decimals)
    function claimableProfit() public view returns (uint256) {
        uint256 _totalAssets = estimatedTotalAssets();
        uint256 _totalDebt = vault.strategies(address(this)).totalDebt;
        uint256 _claimableProfit = _totalAssets - _totalDebt;

        if (_claimableProfit < 1e18) {
            // Dust check
            return 0;
        }

        return _claimableProfit; // returns ready-to-claim rewards
    }

    /// HARVEST SETTERS

    /// TODO - change this to respect the mellow strategy (if adjustments needed at all). This was copied from angle protocol strategy
    function setHarvestTriggerParams(
        uint256 _harvestProfitMin,
        uint256 _harvestProfitMax,
        uint256 _creditThreshold
    ) external onlyVaultManagers {
        harvestProfitMin = _harvestProfitMin;
        harvestProfitMax = _harvestProfitMax;
        creditThreshold = _creditThreshold;
    }

    /* ========== SUPPORT & UTILITY FUNCTIONS ========== */

    /// @notice returns amount of wantToken belonging to this contract directly
    /// @return amount of wantToken owned by this contract (not including amounts in underlying strategy)
    function wantBalance() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    /// @notice reports balance of mellow LPTs, for this strategy, that this contract owns
    /// @return amount of mellow LPTs owned by this strategy (including those waiting to be redemed/burnt)
    function balanceOfMellowLPT() public view returns (uint256) {
        return mellowLPT.balanceOf(address(this));
    }

    /// @notice gets this contract's approximate value of Mellow LPTs in `want` token denomination
    /// @dev each epoch in mellow gearbox vault has a different price per LPT. This is used to calculate respective `want` token amounts in yearn strategy's posession
    /// @return this contract's Mellow LPTs in `want` token denomination
    function valueOfMellowLPT() public view returns (uint256) {
        // calculate mellowLPTs waiting for claim * their epochRate
        uint256 claimableLPT = gearboxRootVault.lpTokensWaitingForClaim[
            address(this)
        ]; // when no withdrawal registered, this will be 0.

        // calculate mellowLPTs in the strategy still
        uint256 inStrategyLPT = balanceOfMellowLPT() - claimableLPT; // when no withdrawal registered, this will be all of our position.

        // multiply both above vars by respective epochToPriceForLPT
        return
            ((inStrategyLPT *
                gearboxRootVault.epochToPriceForLpTokenD18(
                    gearboxRootVault.currentEpoch()
                )) +
                claimableLPT *
                gearboxRootVault.epochToPriceForLpTokenD18(
                    gearboxRootVault.currentEpoch()
                )) / 1e18; // TODO - double check that this needs to be normalized from 1e18
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
