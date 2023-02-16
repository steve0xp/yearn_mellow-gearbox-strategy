// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;

import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20MetaData.sol";
import {IGearboxRootVault} from "./interfaces/Mellow/IGearboxRootVault.sol";
import {IERC20RootVaultGovernance} from "./interfaces/Mellow/IERC20RootVaultGovernance.sol";
import "./utils/Mellow/ExceptionsLibrary.sol";
import "./utils/Mellow/CommonLibrary.sol";
import "./utils/Mellow/FullMath.sol";
import "forge-std/console.sol";

/// @title StrategyMellow-Gearbox_wETH: Yearn strategy for Mellow Fearless Gearboxstrategy
/// @author @steve0xp && @0xValJohn

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    IGearboxRootVault public gearboxRootVault;
    IERC20 public mellowLPT;
    bool internal isOriginal = true;
    uint256 private constant max = type(uint256).max;
    uint256 public harvestProfitMin;
    uint256 internal wantDecimals;

    event Cloned(address indexed clone);

    constructor(address _vault, address _mellowRootVault) BaseStrategy(_vault) {
        _initializeStrategy(_mellowRootVault);
    }

    uint256 public lpPriceHighWaterMarkD18; // from IGearboxRootVault

    function _initializeStrategy(address _mellowRootVault) internal {
        gearboxRootVault = IGearboxRootVault(_mellowRootVault);
        mellowLPT = IERC20(_mellowRootVault);
        IERC20(want).safeApprove(address(gearboxRootVault), max);
        wantDecimals = IERC20Metadata(address(want)).decimals();
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _mellowRootVault
    ) public {
        require(address(gearboxRootVault) == address(0)); // @note only initialize once

        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrategy(_mellowRootVault);
    }

    function clone(address _vault, address _strategist, address _rewards, address _keeper, address _mellowRootVault)
        external
        returns (address newStrategy)
    {
        require(isOriginal, "!clone");
        bytes20 addressBytes = bytes20(address(this));
        assembly {
            let clone_code := mload(0x40)
            mstore(clone_code, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(add(clone_code, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            newStrategy := create(0, clone_code, 0x37)
        }

        Strategy(newStrategy).initialize(_vault, _strategist, _rewards, _keeper, _mellowRootVault);

        emit Cloned(newStrategy);
    }

    function name() external view override returns (string memory) {
        return string(abi.encodePacked("StrategyMellow-Gearbox", IERC20Metadata(address(want)).symbol()));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return wantBalance() + valueOfMellowLPT();
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (uint256 _profit, uint256 _loss, uint256 _debtPayment)
    {
        uint256 _totalAssets = estimatedTotalAssets();
        uint256 _totalDebt = vault.strategies(address(this)).totalDebt;

        if (_totalAssets >= _totalDebt) {
            _profit = _totalAssets - _totalDebt;
        } else {
            _loss = _totalDebt - _totalAssets;
        }

        (uint256 _liquidatedAmount,) = liquidatePosition(_debtOutstanding);

        _debtPayment = Math.min(_debtOutstanding, _liquidatedAmount);
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 newWantBalance = wantBalance();

        if (newWantBalance > _debtOutstanding) {
            uint256[] memory _amountToInvest = new uint256[](1);
            _amountToInvest[0] = newWantBalance - _debtOutstanding;
            uint256 _minLpToMint = 0; // @todo add minimum LP amount to receive

            uint256 thisNFT = gearboxRootVault.nft();

            address vaultGovernance = address(gearboxRootVault.vaultGovernance());
            IERC20RootVaultGovernance.StrategyParams memory params =
                (IERC20RootVaultGovernance(vaultGovernance)).strategyParams(thisNFT);

            (uint256[] memory minTvl,) = gearboxRootVault.tvl();

            uint256 LP_CHECK_totalSupplyTEST = gearboxRootVault.totalSupply();
            uint256 LP_CHECK_totalLpTokensWaitingWithdrawal = gearboxRootVault.totalLpTokensWaitingWithdrawal();
            uint256 LP_CHECK_chargeFees = _chargeFees(thisNFT, minTvl[0], gearboxRootVault.totalSupply());

            console.log(
                "MARKER #1 CHECKING VARS VALUES: LP_CHECK_totalSupplyTEST: %s, LP_CHECK_chargeFees: %s, LP_CHECK_totalLpTokensWaitingWithdrawal: %s",
                LP_CHECK_totalSupplyTEST,
                LP_CHECK_totalLpTokensWaitingWithdrawal,
                LP_CHECK_chargeFees
            );

            uint256 lpSupply = (
                gearboxRootVault.totalSupply() - gearboxRootVault.totalLpTokensWaitingWithdrawal() + LP_CHECK_chargeFees
            );

            uint256[] memory totalWantCapacityRemaining = new uint256[](1);

            console.log(
                "MARKER #2 CHECKING VARS VALUES: minTVL: %s, tokenLimit(amount able to be invested in mellow vault): %s, lpSupply: %s",
                minTvl[0],
                params.tokenLimit,
                lpSupply
            );

            // TODO - BELOW IS THE LOC THAT IS CAUSING UNDERFLOW ERRORS
            totalWantCapacityRemaining[0] = (minTvl[0] * ((params.tokenLimit - lpSupply) * 1e18 / lpSupply)) / 1e18;

            require(totalWantCapacityRemaining[0] == 0, "Vault want capacity at max");

            if (totalWantCapacityRemaining[0] > _amountToInvest[0]) {
                gearboxRootVault.deposit(_amountToInvest, _minLpToMint, ""); // @todo investigate vaultOptions
            } else {
                gearboxRootVault.deposit(totalWantCapacityRemaining, _minLpToMint, ""); // @todo investigate vaultOptions
                    // @todo emit event showcasing that not entire excess was deposited because of vault hitting its max?
            }
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        _amountNeeded = Math.min(_amountNeeded, estimatedTotalAssets());

        uint256 _existingLiquidAssets = wantBalance();

        if (_existingLiquidAssets >= _amountNeeded) {
            return (_amountNeeded, 0);
        }

        uint256 _primaryTokensToClaim = gearboxRootVault.primaryTokensToClaim(address(this));
        uint256 _currentEpochToPriceForLpTokenD18 =
            gearboxRootVault.epochToPriceForLpTokenD18(gearboxRootVault.currentEpoch());
        uint256 _amountToWithdraw = _amountNeeded - _existingLiquidAssets;
        uint256 _newLPTRegisterWithdraw;

        /// @dev nothing to claim, register a withdraw for next harvest
        if (_primaryTokensToClaim == 0) {
            _newLPTRegisterWithdraw = ((_amountToWithdraw) * 1e18) / _currentEpochToPriceForLpTokenD18;
            /// @dev LPTs to burn = wantToken * d18 / price rate [want/lpt] where usually we go --> wantToken = lpt * price rate [want/lpt] / d18
            gearboxRootVault.registerWithdrawal(_newLPTRegisterWithdraw);
            return (_existingLiquidAssets, 0);
        }

        /// @dev cannot withdraw more than withdrawable
        _amountToWithdraw = Math.min(_primaryTokensToClaim, _amountToWithdraw);

        // @todo sort out what to put for vaultOptions
        bytes[] memory vaultOptions = new bytes[](2);

        if (_primaryTokensToClaim > 0) {
            // gearboxRootVault doesn't allow amount specified for withdrawal
            // @todo put checks here to ensure we are getting a minimal slippage, if any upon redemption
            try gearboxRootVault.withdraw(address(this), vaultOptions) {
                uint256 _newLiquidAssets = wantBalance();
                _liquidatedAmount = Math.min(_newLiquidAssets, _amountNeeded);

                if (_liquidatedAmount < _amountNeeded) {
                    // If we couldn't liquidate the full amount needed, start the withdrawal process for the remaining
                    _newLPTRegisterWithdraw =
                        ((_amountNeeded - _liquidatedAmount) * 1e18) / _currentEpochToPriceForLpTokenD18; // LPTs to burn = wantToken * d18 / price rate [want/lpt] where usually we go --> wantToken = lpt * price rate [want/lpt] / d18
                    gearboxRootVault.registerWithdrawal(_newLPTRegisterWithdraw);
                }
            } catch {
                // If someone tries to call more than we have, the function simply returns (existingLiquidAssets, 0)
                return (_existingLiquidAssets, 0);
            }
        }
    }

    function liquidateAllPositions() internal override returns (uint256 _amountFreed) {
        (_amountFreed,) = liquidatePosition(estimatedTotalAssets());
    }

    function prepareMigration(address _newStrategy) internal override {
        mellowLPT.safeTransfer(_newStrategy, balanceOfMellowLPT());
    }

    function protectedTokens() internal view override returns (address[] memory) {}

    function ethToWant(uint256 _amtInWei) public view virtual override returns (uint256) {
        return _amtInWei;
    }

    /* ========== SETTERS AND MANUAL FUNCTIONS ========== */

    function manualRegisterWithdrawal(uint256 _lpTokenAmount) external onlyVaultManagers {
        gearboxRootVault.registerWithdrawal(_lpTokenAmount);
    }

    function manualCancelWithdrawal(uint256 _lpTokenAmount) external onlyVaultManagers {
        gearboxRootVault.cancelWithdrawal(_lpTokenAmount);
    }

    function manualWithdraw() external onlyVaultManagers {
        bytes[] memory vaultOptions = new bytes[](2); // @todo investigate vaultOptions
        gearboxRootVault.withdraw(address(this), vaultOptions);
    }

    function setHarvestProfitMin(uint256 _harvestProfitMin) external onlyVaultManagers {
        require(_harvestProfitMin < 10 ** wantDecimals);
        harvestProfitMin = _harvestProfitMin;
    }

    /* ========== KEEPERS ========== */

    function harvestTrigger(uint256 callCostInWei) public view override returns (bool) {
        if (!isBaseFeeAcceptable()) {
            return false;
        }

        if (forceHarvestTriggerOnce) {
            return true;
        }

        if (claimableProfit() > harvestProfitMin) {
            return true;
        }

        StrategyParams memory params = vault.strategies(address(this));
        if ((block.timestamp - params.lastReport) >= maxReportDelay) return true;

        return (vault.creditAvailable() > creditThreshold);
    }

    /* ========== SUPPORT & UTILITY FUNCTIONS ========== */

    function wantBalance() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    // @note amount of mellow LPTs owned by this strategy (including those waiting to be redemed/burnt)
    function balanceOfMellowLPT() public view returns (uint256) {
        return mellowLPT.balanceOf(address(this));
    }

    /// @notice gets this contract's approximate value of Mellow LPTs in `want` token denomination
    /// @dev each epoch in mellow gearbox vault has a different price per LPT. This is used to calculate respective `want` token amounts in yearn strategy's possession
    function valueOfMellowLPT() public view returns (uint256) {
        // calculate mellowLPTs waiting for claim * their epochRate
        uint256 claimableLPT = gearboxRootVault.lpTokensWaitingForClaim(address(this)); // when no withdrawal registered, this will be 0.

        // calculate mellowLPTs in the strategy still
        uint256 inStrategyLPT = balanceOfMellowLPT() - claimableLPT; // when no withdrawal registered, this will be all of our position.

        // multiply both above vars by respective epochToPriceForLPT
        return (
            (inStrategyLPT * gearboxRootVault.epochToPriceForLpTokenD18(gearboxRootVault.currentEpoch()))
                + claimableLPT * gearboxRootVault.epochToPriceForLpTokenD18(gearboxRootVault.currentEpoch())
        ) / 1e18; // @todo double check that this needs to be normalized from 1e18 (i.e. for USDC)
    }

    /// @dev returns ready-to-claim rewards
    function claimableProfit() public view returns (uint256) {
        uint256 _totalAssets = estimatedTotalAssets();
        uint256 _totalDebt = vault.strategies(address(this)).totalDebt;
        uint256 _claimableProfit = _totalAssets - _totalDebt;

        if (_claimableProfit < 10 ** wantDecimals) {
            // @note dust check
            return 0;
        }
        return _claimableProfit;
    }

    /* ========== MELLOW INTERNAL FUNCTIONS ========== */

    /// @dev we are charging fees on the deposit / withdrawal. fees are charged before the tokens transfer and change the balance of the lp tokens.
    /// I modified these copied functions, from mellow (incl. libraries), so there is a return amount that instead of minting more tokens (in LPTokens). I modified _chargeManagementFees() & _chargePerformanceFees() accordingly too
    function _chargeFees(uint256 thisNFT, uint256 tvl, uint256 supply) internal view returns (uint256) {
        IERC20RootVaultGovernance vg = IERC20RootVaultGovernance(address(gearboxRootVault.vaultGovernance()));
        uint256 elapsed = block.timestamp - uint256(gearboxRootVault.lastFeeCharge());
        IERC20RootVaultGovernance.DelayedProtocolParams memory delayedProtocolParams = vg.delayedProtocolParams();
        if (elapsed < delayedProtocolParams.managementFeeChargeDelay || supply == 0) {
            return 0;
        }

        IERC20RootVaultGovernance.DelayedStrategyParams memory strategyParams = vg.delayedStrategyParams(thisNFT);
        uint256 protocolFee = vg.delayedProtocolPerVaultParams(thisNFT).protocolFee;
        address protocolTreasury = vg.internalParams().protocolGovernance.protocolTreasury();

        // as per convo w/ Dmitriy
        (uint256 _mgmtFeesToBeImposed, uint256 protocolFeeToBeImposed) =
            _chargeManagementFees(strategyParams.managementFee, protocolFee, elapsed, supply);

        uint256 _perfFeesToBeImposed = _chargePerformanceFees(supply, tvl, strategyParams.performanceFee);

        uint256 totalFees = _mgmtFeesToBeImposed + protocolFeeToBeImposed + _perfFeesToBeImposed;

        return totalFees;
    }

    function _chargeManagementFees(uint256 managementFee, uint256 protocolFee, uint256 elapsed, uint256 lpSupply)
        internal
        view
        returns (uint256 mgmtFee, uint256 newProtocolFee)
    {
        mgmtFee = 0;
        newProtocolFee = 0;

        if (managementFee > 0) {
            mgmtFee = FullMath.mulDiv(managementFee * elapsed, lpSupply, CommonLibrary.YEAR * CommonLibrary.DENOMINATOR);
        }
        if (protocolFee > 0) {
            newProtocolFee =
                FullMath.mulDiv(protocolFee * elapsed, lpSupply, CommonLibrary.YEAR * CommonLibrary.DENOMINATOR);
        }
    }

    function _chargePerformanceFees(uint256 baseSupply, uint256 tvl, uint256 performanceFee)
        internal
        view
        returns (uint256)
    {
        if (performanceFee == 0) {
            return 0;
        }

        uint256 lpPriceD18 = FullMath.mulDiv(tvl, CommonLibrary.D18, baseSupply);
        uint256 hwmsD18 = lpPriceHighWaterMarkD18;
        if (lpPriceD18 <= hwmsD18) {
            return 0;
        }

        uint256 toMint;
        if (hwmsD18 > 0) {
            toMint = FullMath.mulDiv(baseSupply, lpPriceD18 - hwmsD18, hwmsD18);
            toMint = FullMath.mulDiv(toMint, performanceFee, CommonLibrary.DENOMINATOR);
            return (toMint);
        }
    }
}
