// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.6.12;

import {SafeMath} from '../../dependencies/openzeppelin/contracts/SafeMath.sol';
import {IERC20} from "../../interfaces/IERC20.sol";
import {IXToken} from "../../interfaces/IXToken.sol";
import {IVariableDebtToken} from "../../interfaces/IVariableDebtToken.sol";
import {IPriceOracleGetter} from "../../interfaces/IPriceOracleGetter.sol";
import {IMarginPoolCollateralManager} from "../../interfaces/IMarginPoolCollateralManager.sol";
import {VersionedInitializable} from "../libraries/upgradeability/VersionedInitializable.sol";
import {GenericLogic} from "../libraries/logic/GenericLogic.sol";
import {Helpers} from "../libraries/helpers/Helpers.sol";
import {WadRayMath} from "../libraries/math/WadRayMath.sol";
import {PercentageMath} from "../libraries/math/PercentageMath.sol";
import {SafeERC20} from '../../dependencies/openzeppelin/contracts/SafeERC20.sol';
import {Errors} from "../libraries/helpers/Errors.sol";
// import {ValidationLogic} from "./ValidationLogic.sol";
import {DataTypes} from "../libraries/types/DataTypes.sol";
import {MarginPoolStorage} from "./MarginPoolStorage.sol";
import {IUniswapV2Router02} from "../../interfaces/IUniswapV2Router02.sol";

/**
 * @title MarginPoolCollateralManager contract
 * @author Lever
 * @dev Implements actions involving management of collateral in the protocol, the main one being the liquidations
 * IMPORTANT This contract will run always via DELEGATECALL, through the MarginPool, so the chain of inheritance
 * is the same as the MarginPool, to have compatible storage layouts
 **/
contract MarginPoolCollateralManager is IMarginPoolCollateralManager, VersionedInitializable, MarginPoolStorage{
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using WadRayMath for uint256;
    using PercentageMath for uint256;

    uint256 internal constant LIQUIDATION_CLOSE_FACTOR_PERCENT = 5000;
    IUniswapV2Router02 public uniswaper;
    address public wethAddress;

    struct LiquidationCallLocalVars {
        uint256 variableDebt;
        uint256 userCollateralBalance;
        uint256 healthFactor;
        uint256 maxCollateralToLiquidate;
        uint256 collateralToSell;
        uint256 liquidatorPreviousXTokenBalance;
    }

    function initialize(IUniswapV2Router02 _uniswaper, address _weth) public initializer{
        uniswaper = _uniswaper;
        wethAddress = _weth;
    }

    /**
     * @dev As thIS contract extends the VersionedInitializable contract to match the state
     * of the LendingPool contract, the getRevision() function is needed, but the value is not
     * important, as the initialize() function will never be called here
     */
    function getRevision() internal pure override returns (uint256) {
        return 0;
    }

    /**
     * @dev Function to liquidate a position if its Health Factor drops below 1
     * - The caller (liquidator) covers `debtToCover` amount of debt of the user getting liquidated, and receives
     *   a proportionally amount of the `collateralAsset` plus a bonus to cover market risk
     * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of the liquidation
     * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
     * @param user The address of the borrower getting liquidated
     * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
     **/
    function liquidationCall( address collateralAsset, address debtAsset, address user, uint256 debtToCover) external override returns (uint256, string memory) {
        DataTypes.ReserveData storage collateralReserve = _reserves[collateralAsset];
        DataTypes.ReserveData storage debtReserve = _reserves[debtAsset];
        DataTypes.UserConfigurationMap storage userConfig = _usersConfig[user];
        LiquidationCallLocalVars memory vars;
        (, , , , vars.healthFactor) = GenericLogic.calculateUserAccountData(user, _reserves,  _usersConfig[user],  _reservesList,  _reservesCount, _addressesProvider.getPriceOracle());
        vars.variableDebt = Helpers.getUserCurrentDebt(user, debtReserve).percentMul(LIQUIDATION_CLOSE_FACTOR_PERCENT);
       _validateLiquidation(collateralReserve, debtReserve, userConfig, vars.healthFactor, vars.variableDebt);

        vars.variableDebt = vars.variableDebt > debtToCover ? debtToCover : vars.variableDebt;

        vars.userCollateralBalance = IERC20(collateralReserve.xTokenAddress).balanceOf(user);

        (vars.maxCollateralToLiquidate, vars.collateralToSell) = GenericLogic.calculateAvailableCollateralToLiquidate(collateralReserve, debtReserve, collateralAsset, debtAsset, vars.variableDebt, vars.userCollateralBalance,  _addressesProvider.getPriceOracle());

        collateralReserve.updateState();

        vars.liquidatorPreviousXTokenBalance = IERC20(collateralReserve.xTokenAddress).balanceOf(msg.sender);

        IXToken(collateralReserve.xTokenAddress).transferOnLiquidation(user, msg.sender, (vars.maxCollateralToLiquidate.sub(vars.collateralToSell)));

        if (vars.liquidatorPreviousXTokenBalance == 0) {
            DataTypes.UserConfigurationMap storage liquidatorConfig = _usersConfig[msg.sender];
            liquidatorConfig.setUsingAsCollateral(collateralReserve.id, true);
            emit ReserveUsedAsCollateralEnabled(collateralAsset, msg.sender);
        }

        if (vars.maxCollateralToLiquidate == vars.userCollateralBalance) {
            userConfig.setUsingAsCollateral(collateralReserve.id, false);
            emit ReserveUsedAsCollateralDisabled(collateralAsset, user);
        }

        if (collateralAsset == debtAsset) {
            IVariableDebtToken(collateralReserve.variableDebtTokenAddress).burn(user, vars.collateralToSell, collateralReserve.variableBorrowIndex);

            collateralReserve.updateInterestRates(collateralAsset, collateralReserve.xTokenAddress, 0, 0);

            IXToken(collateralReserve.xTokenAddress).burn(user, collateralReserve.xTokenAddress, vars.collateralToSell, collateralReserve.liquidityIndex);

            emit LiquidationCall(collateralAsset, debtAsset, user, vars.collateralToSell, vars.collateralToSell,msg.sender);
            return (uint256(0), Errors.MPCM_NO_ERRORS);
        }

        collateralReserve.updateInterestRates(
            collateralAsset,
            collateralReserve.xTokenAddress,
            0,
            vars.collateralToSell
        );

        IXToken(collateralReserve.xTokenAddress).burn(user, address(this), vars.collateralToSell, collateralReserve.liquidityIndex);

        IERC20(collateralAsset).safeApprove(address(uniswaper), 0);
        IERC20(collateralAsset).safeApprove(address(uniswaper), vars.collateralToSell);
        address[] memory path;
        if (collateralAsset != wethAddress && debtAsset != wethAddress) {
            path = new address[](3);
            path[0] = collateralAsset;
            path[1] = wethAddress;
            path[2] = debtAsset;
        } else {
            path = new address[](2);
            path[0] = collateralAsset;
            path[1] = debtAsset;
        }
        uint256[] memory awards = uniswaper.swapExactTokensForTokens(vars.collateralToSell, vars.variableDebt.mul(90).div(100), path, address(this), block.timestamp);
        uint256 amountToDeposit = awards[awards.length - 1];
        address ddebtAssetXToken = debtReserve.xTokenAddress;
        debtReserve.updateState();
        debtReserve.updateInterestRates(debtAsset, ddebtAssetXToken, amountToDeposit,0 );
        IERC20(debtAsset).safeTransfer(ddebtAssetXToken, amountToDeposit);
        IVariableDebtToken(debtReserve.variableDebtTokenAddress).burn(user, amountToDeposit, debtReserve.variableBorrowIndex);

        emit LiquidationCall(collateralAsset, debtAsset, user, awards[awards.length - 1], vars.collateralToSell, msg.sender);

        return (uint256(0), Errors.MPCM_NO_ERRORS);
    }
    
    
      /**
     * @dev Validates the liquidation action
     * @param collateralReserve The reserve data of the collateral
     * @param principalReserve The reserve data of the principal
     * @param userConfig The user configuration
     * @param userHealthFactor The user's health factor
     * @param userVariableDebt Total variable debt balance of the user
     **/
    function _validateLiquidation(
        DataTypes.ReserveData storage collateralReserve,
        DataTypes.ReserveData storage principalReserve,
        DataTypes.UserConfigurationMap storage userConfig,
        uint256 userHealthFactor,
        uint256 userVariableDebt
    ) internal view {
        require(collateralReserve.configuration.getActive() && principalReserve.configuration.getActive(), Errors.VL_NO_ACTIVE_RESERVE);
        require(userHealthFactor < GenericLogic.HEALTH_FACTOR_LIQUIDATION_THRESHOLD, Errors.MPCM_HEALTH_FACTOR_NOT_BELOW_THRESHOLD);
        bool isCollateralEnabled = collateralReserve.configuration.getLiquidationThreshold() > 0 && userConfig.isUsingAsCollateral(collateralReserve.id);
        //if collateral isn't enabled as collateral by user, it cannot be liquidated
        require(isCollateralEnabled,  Errors.MPCM_COLLATERAL_CANNOT_BE_LIQUIDATED);
        require(userVariableDebt > 0, Errors.MPCM_SPECIFIED_CURRENCY_NOT_BORROWED_BY_USER);
    }
}
