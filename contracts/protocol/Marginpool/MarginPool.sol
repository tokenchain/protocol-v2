// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {SafeMath} from '../../dependencies/openzeppelin/contracts/SafeMath.sol';
import {IERC20} from "../../interfaces/IERC20.sol";
import {SafeERC20} from '../../dependencies/openzeppelin/contracts/SafeERC20.sol';
import {Address} from '../../dependencies/openzeppelin/contracts/Address.sol';
import {IMarginPoolAddressesProvider} from "../../interfaces/IMarginPoolAddressesProvider.sol";
import {IXToken} from "../../interfaces/IXToken.sol";
import {IVariableDebtToken} from "../../interfaces/IVariableDebtToken.sol";
import {IPriceOracleGetter} from "../../interfaces/IPriceOracleGetter.sol";
import {IMarginPool} from "../../interfaces/IMarginPool.sol";
import {VersionedInitializable} from "../libraries/upgradeability/VersionedInitializable.sol";
import {Helpers} from "../libraries/helpers/Helpers.sol";
import {Errors} from "../libraries/helpers/Errors.sol";
import {WadRayMath} from "../libraries/math/WadRayMath.sol";
import {PercentageMath} from "../libraries/math/PercentageMath.sol";
import {ReserveLogic} from "../libraries/logic/ReserveLogic.sol";
import {GenericLogic} from "../libraries/logic/GenericLogic.sol";
import {ValidationLogic} from "../libraries/logic/ValidationLogic.sol";
import {ReserveConfiguration} from "../libraries/configuration/ReserveConfiguration.sol";
import {UserConfiguration} from "../libraries/configuration/UserConfiguration.sol";
import {DataTypes} from "../libraries/types/DataTypes.sol";
import {MarginPoolStorage} from "./MarginPoolStorage.sol";
import {IUniswapV2Router02} from "../../interfaces/IUniswapV2Router02.sol";

/**
 * @title MarginPool contract
 * @dev Main point of interaction with an Lever protocol's market
 * - Users can:
 *   # Deposit
 *   # Withdraw
 *   # Borrow
 *   # swap
 *   # maker order
 *   # Repay
 *   # Liquidate positions
 * - To be covered by a proxy contract, owned by the MarginPoolAddressesProvider of the specific market
 * - All admin functions are callable by the MarginPoolConfigurator contract defined also in the
 *   MarginPoolAddressesProvider
 * @author Lever
 **/
contract MarginPool is VersionedInitializable, IMarginPool, MarginPoolStorage {
    using SafeMath for uint256;
    using WadRayMath for uint256;
    using PercentageMath for uint256;
    using SafeERC20 for IERC20;

    //main configuration parameters
    uint256 public constant MAX_NUMBER_RESERVES = 128;
    uint256 public constant MARGINPOOL_REVISION = 0x2;
    IUniswapV2Router02 public uniswaper;
    IUniswapV2Router02 public sushiSwaper;
    address public wethAddress;
    uint8 borrowFee = 0;
    uint8 withdrawFee = 10;
    address public constant inchor = 0x11111112542D85B3EF69AE05771c2dCCff4fAa26;
    address public collateralManager;

    modifier whenNotPaused() {
        _whenNotPaused();
        _;
    }

    modifier onlyMarginPoolConfigurator() {
        _onlyMarginPoolConfigurator();
        _;
    }

    modifier onlyOrderBook() {
        _onlyOrderBook();
        _;
    }

    function _whenNotPaused() internal view {
        require(!_paused, Errors.MP_IS_PAUSED);
    }

    function _onlyMarginPoolConfigurator() internal view {
        require(_addressesProvider.getMarginPoolConfigurator() == msg.sender, Errors.MP_CALLER_NOT_MARGIN_POOL_CONFIGURATOR);
    }

    function _onlyOrderBook() internal view {
        require(_addressesProvider.getOrderBook() == msg.sender, Errors.OB_CALLER_NOT_ORDER_BOOK);
    }

    function getRevision() internal pure override returns (uint256) {
        return MARGINPOOL_REVISION;
    }

    /**
     * @dev Function is invoked by the proxy contract when the MarginPool contract is added to the
     * MarginPoolAddressesProvider of the market.
     * - Caching the address of the MarginPoolAddressesProvider in order to reduce gas consumption
     *   on subsequent operations
     * @param provider The address of the MarginPoolAddressesProvider
     **/
    function initialize(IMarginPoolAddressesProvider provider, IUniswapV2Router02 _uniswaper, IUniswapV2Router02 _sushiSwaper, address _weth) public initializer {
        _addressesProvider = provider;
        uniswaper = _uniswaper;
        sushiSwaper = _sushiSwaper;
        wethAddress = _weth;
    }

    function releaseStuckAssets(address _reserve, address _to, uint256 amount) external {
        require(msg.sender == _addressesProvider.getPoolAdmin());
        IERC20(_reserve).safeTransfer(_to, amount);
    }
    
    function setCollateralManager(address _collateralManager) override external onlyMarginPoolConfigurator {
       require(_collateralManager != address(0), "ERR_ZERO_ADDRESS");
       collateralManager = _collateralManager;
    }
    
    function setBorrowFee(uint8 _fee) override external onlyMarginPoolConfigurator {
        require(_fee <= 100, "fee must be less than 1%");
        borrowFee = _fee;
    }

    function setWithdrawFee(uint8 _fee) override external onlyMarginPoolConfigurator {
        require(_fee <= 100, "fee must be less than 1%");
        withdrawFee = _fee;
    }
    

    /**
     * @dev Deposits an `amount` of underlying asset into the reserve, receiving in return overlying xTokens.
     * - E.g. User deposits 100 USDC and gets in return 100 xUSDC
     * @param asset The address of the underlying asset to deposit
     * @param amount The amount to be deposited
     * @param onBehalfOf The address that will receive the xTokens, same as msg.sender if the user
     *   wants to receive them on his own wallet, or a different address if the beneficiary of xTokens
     *   is a different wallet
     **/
    function deposit(address asset, uint256 amount, address onBehalfOf) external override whenNotPaused {
        DataTypes.ReserveData storage reserve = _reserves[asset];
        ValidationLogic.validateDeposit(reserve, amount);
        address xToken = reserve.xTokenAddress;
        reserve.updateState();
        reserve.updateInterestRates(asset, xToken, amount, 0);
        IERC20(asset).safeTransferFrom(msg.sender, xToken, amount);
        _depositLogic(asset, amount, onBehalfOf, xToken, reserve);
    }

    function reDeposit(address asset, uint256 amount, address onBehalfOf) internal whenNotPaused {
        DataTypes.ReserveData storage reserve = _reserves[asset];

        ValidationLogic.validateDeposit(reserve, amount);

        address xToken = reserve.xTokenAddress;

        reserve.updateState();
        reserve.updateInterestRates(asset, xToken, amount, 0);

        IERC20(asset).safeTransfer(xToken, amount);
        _depositLogic(asset, amount, onBehalfOf, xToken, reserve);
    }

    function _depositLogic(address asset, uint256 amount, address onBehalfOf, address xToken, DataTypes.ReserveData storage reserve) internal {
        uint256 variableDebt = Helpers.getUserCurrentDebt(onBehalfOf, reserve);
        if (variableDebt > 0) {
            uint256 paybackAmount = variableDebt;
            if (amount < paybackAmount) {
                paybackAmount = amount;
            }
            IVariableDebtToken(reserve.variableDebtTokenAddress).burn(onBehalfOf, paybackAmount, reserve.variableBorrowIndex);

            emit Repay(asset, onBehalfOf, msg.sender, paybackAmount);

            if (variableDebt == paybackAmount) {
                _usersConfig[onBehalfOf].setBorrowing(reserve.id, false);
            }

            if (amount > paybackAmount) {
                bool isFirstDeposit =IXToken(xToken).mint(onBehalfOf, amount.sub(paybackAmount), reserve.liquidityIndex);

                if (isFirstDeposit) {
                    _usersConfig[onBehalfOf].setUsingAsCollateral(reserve.id, true);
                    emit ReserveUsedAsCollateralEnabled(asset, onBehalfOf);
                }

                emit Deposit(asset, msg.sender, onBehalfOf, amount.sub(paybackAmount));
            }
        } else {
            bool isFirstDeposit =IXToken(xToken).mint(onBehalfOf, amount, reserve.liquidityIndex);

            if (isFirstDeposit) {
                _usersConfig[onBehalfOf].setUsingAsCollateral(reserve.id, true);
                emit ReserveUsedAsCollateralEnabled(asset, onBehalfOf);
            }

            emit Deposit(asset, msg.sender, onBehalfOf, amount);
        }
    }

    /**
     * @dev Withdraws an `amount` of underlying asset from the reserve, burning the equivalent xTokens owned
     * E.g. User has 100 xUSDC, calls withdraw() and receives 100 USDC, burning the 100 xUSDC
     * @param asset The address of the underlying asset to withdraw
     * @param amount The underlying amount to be withdrawn
     *   - Send the value type(uint256).max in order to withdraw the whole xToken balance
     * @param to Address that will receive the underlying, same as msg.sender if the user
     *   wants to receive it on his own wallet, or a different address if the beneficiary is a
     *   different wallet
     * @return The final amount withdrawn
     **/
    function withdraw(address asset, uint256 amount,  address to) external override whenNotPaused returns (uint256) {
        DataTypes.ReserveData storage reserve = _reserves[asset];

        address xToken = reserve.xTokenAddress;

        uint256 userBalance = IXToken(xToken).balanceOf(msg.sender);

        uint256 amountToWithdraw = amount;

        if (amount == type(uint256).max) {
            amountToWithdraw = userBalance;
        }

        ValidationLogic.validateWithdraw(asset, amountToWithdraw, userBalance, _reserves, _usersConfig[msg.sender], _reservesList, _reservesCount, _addressesProvider.getPriceOracle());
        reserve.updateState();
        reserve.updateInterestRates(asset, xToken, 0, amountToWithdraw);
        if (amountToWithdraw == userBalance) {
            _usersConfig[msg.sender].setUsingAsCollateral(reserve.id, false);
            emit ReserveUsedAsCollateralDisabled(asset, msg.sender);
        }
        uint256 fee =  amountToWithdraw.mul(uint256(withdrawFee)).div(10000);
        IXToken(xToken).burn(msg.sender, to, amountToWithdraw.sub(fee), reserve.liquidityIndex);

        if(fee > 0){
            IXToken(xToken).burn(msg.sender, _addressesProvider.getTreasuryAddress(), fee, reserve.liquidityIndex);
        }

        emit Withdraw(asset, msg.sender, to, amountToWithdraw.sub(fee));

        return amountToWithdraw;
    }

    /**
     * @dev Allows users to borrow a specific `amount` of the reserve underlying asset, provided that the borrower
     * already deposited enough collateral, or he was given enough allowance by a credit delegator on the
     * corresponding debt token ( VariableDebtToken)
     * - E.g. User borrows 100 USDC passing as `onBehalfOf` his own address, receiving the 100 USDC in his wallet
     *   and 100 variable debt tokens
     * @param asset The address of the underlying asset to borrow
     * @param amount The amount to be borrowed
     * @param onBehalfOf Address of the user who will receive the debt. Should be the address of the borrower itself
     * calling the function if he wants to borrow against his own collateral, or the address of the credit delegator
     * if he has been given credit delegation allowance
     **/
    function borrow(address asset, uint256 amount, address onBehalfOf) external override whenNotPaused {
        DataTypes.ReserveData storage reserve = _reserves[asset];
        _executeBorrow(ExecuteBorrowParams(asset, msg.sender, onBehalfOf, amount, reserve.xTokenAddress, true));
    }
    
      /**
   * @dev Function to liquidate a non-healthy position collateral-wise, with Health Factor below 1
   * - The caller (liquidator) covers `debtToCover` amount of debt of the user getting liquidated, and receives
   *   a proportionally amount of the `collateralAsset` plus a bonus to cover market risk
   * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of the liquidation
   * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
   * @param user The address of the borrower getting liquidated
   * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
   **/
  function liquidationCall(address collateralAsset, address debtAsset, address user, uint256 debtToCover) external override whenNotPaused {

    //solium-disable-next-line
    (bool success, bytes memory result) =
      collateralManager.delegatecall(abi.encodeWithSignature('liquidationCall(address,address,address,uint256)', collateralAsset, debtAsset, user, debtToCover));

    require(success, Errors.MP_LIQUIDATION_CALL_FAILED);

    (uint256 returnCode, string memory returnMessage) = abi.decode(result, (uint256, string));

    require(returnCode == 0, string(abi.encodePacked(returnMessage)));
  }

    function swapTokensForTokens(uint256 amountIn, uint256 amountOut, address[] calldata path, bool isExactIn, bool isOpenPosition, bool isUni) external override whenNotPaused {
        if (isOpenPosition) {
            _beforeSwap(msg.sender, path[0], amountIn);
        } else {
            _beforeClose(msg.sender, path[0], amountIn);
        }

        _simpleSwapLogic(msg.sender, amountIn, amountOut, path, isExactIn, isUni);
    }

    function swapOrderWithUni(address user, uint256 amountIn, uint256 amountOut, address[] calldata path, bool isOpenPosition,  bool isUni ) external onlyOrderBook whenNotPaused returns (bool) {
        if (isOpenPosition) {
            _beforeSwap(user, path[0], amountIn);
        } else {
            _beforeClose(user, path[0], amountIn);
        }

        _simpleSwapLogic(user, amountIn, amountOut, path, true, isUni);
        return true;
    }

    function _simpleSwapLogic(address _user, uint256 amountIn, uint256 amountOut, address[] calldata path, bool isExactIn, bool isUni) private {
        IUniswapV2Router02 swaper = isUni ? uniswaper : sushiSwaper;
        // Approves the transfer for the swap. Approves for 0 first to comply with tokens that implement the anti frontrunning approval fix.
        IERC20(path[0]).safeApprove(address(swaper), 0);
        IERC20(path[0]).safeApprove(address(swaper), amountIn);

        uint256[] memory awards;
        if (isExactIn) {
            awards = swaper.swapExactTokensForTokens(amountIn, amountOut, path, address(this), block.timestamp);
        } else {
            awards = swaper.swapTokensForExactTokens( amountOut, amountIn, path, address(this), block.timestamp);
        }

        reDeposit(path[path.length - 1], awards[awards.length - 1], _user);

        if (amountIn > awards[0]) {
            reDeposit(path[0], amountIn.sub(awards[0]), _user);
        }

        ValidationLogic.validateSwap(_user, _reserves, _usersConfig[_user], _reservesList, _reservesCount, _addressesProvider.getPriceOracle());
        emit Swap(msg.sender, path[0], path[path.length - 1], awards[0], awards[awards.length - 1]);
    }

    function swapWithAggregation(address _reserve, uint256 amount, address _reserveTo, uint256 amountOut, bytes memory codes, uint256 gas, uint8 swapType, bool isOpenPosition) external {
        if (isOpenPosition) {
            _beforeSwap(msg.sender, _reserve, amount);
        } else {
            _beforeClose(msg.sender, _reserve, amount);
        }

        IERC20(_reserve).safeApprove(inchor, 0);
        IERC20(_reserve).safeApprove(inchor, amount);

        (bool success, bytes memory result) = inchor.call{gas: gas}(codes);

        require(success, "swap failed");

        uint256 award;

        if (swapType == 1) {
            award = abi.decode(result, (uint256));
        }

        if (swapType == 2) {
            (award, ) = abi.decode(result, (uint256, uint256));
        }

        if (swapType == 3) {
            (award, , ) = abi.decode(result, (uint256, uint256, uint256));
        }

        require(award >= amountOut, "The trade doesn't live up with expectations");

        reDeposit(_reserveTo, award, msg.sender);

        ValidationLogic.validateSwap(msg.sender, _reserves, _usersConfig[msg.sender],  _reservesList, _reservesCount,_addressesProvider.getPriceOracle());
        emit Swap(msg.sender, _reserve, _reserveTo, amount, award);
    }

    struct OrderExecute {
        address maker;
        address reserve;
        address reserveTo;
        uint256 amountIn;
        uint256 amountOut;
        bytes codes;
        uint256 gas;
        uint8 swapType;
        bool isOpenPosition;
    }

    function swapOrderWithAggregation(OrderExecute memory order) external onlyOrderBook whenNotPaused returns (bool){
        if (order.isOpenPosition) {
            _beforeSwap(order.maker, order.reserve, order.amountIn);
        } else {
            _beforeClose(order.maker, order.reserve, order.amountIn);
        }

        IERC20(order.reserve).safeApprove(inchor, 0);
        IERC20(order.reserve).safeApprove(inchor, order.amountIn);

        (bool success, bytes memory result) = inchor.call{gas: order.gas}(order.codes);

        require(success, "Aggregation swap failed");

        uint256 award;

        if (order.swapType == 1) {
            award = abi.decode(result, (uint256));
        }

        if (order.swapType == 2) {
            (award, ) = abi.decode(result, (uint256, uint256));
        }

        if (order.swapType == 3) {
            (award, , ) = abi.decode(result, (uint256, uint256, uint256));
        }

        require(award >= order.amountOut, "The trade doesn't live up with expectations");

        reDeposit(order.reserveTo, award, order.maker);

        ValidationLogic.validateSwap(order.maker, _reserves, _usersConfig[order.maker], _reservesList, _reservesCount, _addressesProvider.getPriceOracle());
        emit Swap(msg.sender, order.reserve, order.reserveTo, order.amountIn, award);
        return true;
    }

    function _beforeClose(address _user, address _reserve, uint256 amountIn) private {
        DataTypes.ReserveData storage reserve = _reserves[_reserve];
        ValidationLogic.validateDeposit(reserve, amountIn);
        reserve.updateState();

        uint256 userBalance = IXToken(reserve.xTokenAddress).balanceOf(_user);

        reserve.updateInterestRates(_reserve, reserve.xTokenAddress, 0, amountIn);

        IXToken(reserve.xTokenAddress).burn(_user, address(this), amountIn,reserve.liquidityIndex);

        if (amountIn == userBalance) {
            _usersConfig[_user].setUsingAsCollateral(reserve.id, false);
            emit ReserveUsedAsCollateralDisabled(_reserve, _user);
        }
    }

    function _beforeSwap(address _user, address _reserve, uint256 amountIn) private {
        uint256 amountToBorrow = amountIn.mul(uint256(borrowFee).add(10000)).div(10000);
        DataTypes.ReserveData storage reserve = _reserves[_reserve];
        ValidationLogic.validateDeposit(reserve, amountToBorrow);
        DataTypes.UserConfigurationMap storage userConfig = _usersConfig[_user];

        reserve.updateState();
        bool isFirstBorrowing = false;
        isFirstBorrowing = IVariableDebtToken(reserve.variableDebtTokenAddress).mint(_user, _user, amountToBorrow, reserve.variableBorrowIndex);
        emit Borrow(_reserve,  _user, _user, amountToBorrow, reserve.currentVariableBorrowRate);

        if (isFirstBorrowing) {
            userConfig.setBorrowing(reserve.id, true);
        }

        reserve.updateInterestRates( _reserve, reserve.xTokenAddress, 0, amountToBorrow);

        IXToken(reserve.xTokenAddress).transferUnderlyingTo(address(this), amountToBorrow);
    }

    /**
     * @notice Repays a borrowed `amount` on a specific reserve, burning the equivalent debt tokens owned
     * - E.g. User repays 100 USDC, burning 100 variable debt tokens of the `onBehalfOf` address
     * @param asset The address of the borrowed underlying asset previously borrowed
     * @param amount The amount to repay
     * - Send the value type(uint256).max in order to repay the whole debt for `asset` on the specific `debtMode`
     * @param onBehalfOf Address of the user who will get his debt reduced/removed. Should be the address of the
     * user calling the function if he wants to reduce/remove his own debt, or the address of any other
     * other borrower whose debt should be removed
     * @return The final amount repaid
     **/
    function repay(address asset, uint256 amount, address onBehalfOf) external override whenNotPaused returns (uint256) {
        DataTypes.ReserveData storage reserve = _reserves[asset];

        uint256 variableDebt = Helpers.getUserCurrentDebt(onBehalfOf, reserve);
        address xToken = reserve.xTokenAddress;
        uint256 userBalance = IERC20(xToken).balanceOf(msg.sender);

        ValidationLogic.validateRepay(reserve, amount, onBehalfOf, variableDebt, userBalance);

        uint256 paybackAmount = variableDebt;

        if (amount < paybackAmount) {
            paybackAmount = amount;
        }

        reserve.updateState();

        IVariableDebtToken(reserve.variableDebtTokenAddress).burn(onBehalfOf, paybackAmount, reserve.variableBorrowIndex);

        reserve.updateInterestRates(asset, xToken, 0, 0);

        if (variableDebt.sub(paybackAmount) == 0) {
            _usersConfig[onBehalfOf].setBorrowing(reserve.id, false);
        }

        if (paybackAmount == userBalance) {
            _usersConfig[msg.sender].setUsingAsCollateral(reserve.id, false);
            emit ReserveUsedAsCollateralDisabled(asset, msg.sender);
        }

        IXToken(xToken).burn(msg.sender, xToken, paybackAmount, reserve.liquidityIndex);

        emit Repay(asset, onBehalfOf, msg.sender, paybackAmount);

        return paybackAmount;
    }

    /**
     * @dev Allows depositors to enable/disable a specific deposited asset as collateral
     * @param asset The address of the underlying asset deposited
     * @param useAsCollateral `true` if the user wants to use the deposit as collateral, `false` otherwise
     **/
    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external override whenNotPaused{
        DataTypes.ReserveData storage reserve = _reserves[asset];

        ValidationLogic.validateSetUseReserveAsCollateral(reserve, asset, useAsCollateral, _reserves, _usersConfig[msg.sender], _reservesList, _reservesCount, _addressesProvider.getPriceOracle());

        _usersConfig[msg.sender].setUsingAsCollateral(reserve.id, useAsCollateral);

        if (useAsCollateral) {
            emit ReserveUsedAsCollateralEnabled(asset, msg.sender);
        } else {
            emit ReserveUsedAsCollateralDisabled(asset, msg.sender);
        }
    }

    /**
     * @dev Returns the state and configuration of the reserve
     * @param asset The address of the underlying asset of the reserve
     * @return The state of the reserve
     **/
    function getReserveData(address asset) external view override returns (DataTypes.ReserveData memory){
        return _reserves[asset];
    }

    /**
     * @dev Returns the user account data across all the reserves
     * @param user The address of the user
     * @return totalCollateralETH the total collateral in ETH of the user
     * @return totalDebtETH the total debt in ETH of the user
     * @return availableBorrowsETH the borrowing power left of the user
     * @return currentLiquidationThreshold the liquidation threshold of the user
     * @return ltv the loan to value of the user
     * @return healthFactor the current health factor of the user
     **/
    function getUserAccountData(address user) external view override returns (uint256 totalCollateralETH, uint256 totalDebtETH, uint256 availableBorrowsETH, uint256 currentLiquidationThreshold, uint256 ltv, uint256 healthFactor){
        (totalCollateralETH, totalDebtETH, ltv, currentLiquidationThreshold, healthFactor) = GenericLogic.calculateUserAccountData(user, _reserves, _usersConfig[user], _reservesList, _reservesCount, _addressesProvider.getPriceOracle());
        availableBorrowsETH = GenericLogic.calculateAvailableBorrowsETH(totalCollateralETH, totalDebtETH, ltv);
    }

    /**
     * @dev Returns the configuration of the reserve
     * @param asset The address of the underlying asset of the reserve
     * @return The configuration of the reserve
     **/
    function getConfiguration(address asset) external view override  returns (DataTypes.ReserveConfigurationMap memory){
        return _reserves[asset].configuration;
    }

    /**
     * @dev Returns the configuration of the user across all the reserves
     * @param user The user address
     * @return The configuration of the user
     **/
    function getUserConfiguration(address user) external view override returns (DataTypes.UserConfigurationMap memory){
        return _usersConfig[user];
    }

    /**
     * @dev Returns the normalized income per unit of asset
     * @param asset The address of the underlying asset of the reserve
     * @return The reserve's normalized income
     */
    function getReserveNormalizedIncome(address asset)external view virtual override returns (uint256){
        return _reserves[asset].getNormalizedIncome();
    }

    /**
     * @dev Returns the normalized variable debt per unit of asset
     * @param asset The address of the underlying asset of the reserve
     * @return The reserve normalized variable debt
     */
    function getReserveNormalizedVariableDebt(address asset) external view override returns (uint256){
        return _reserves[asset].getNormalizedDebt();
    }

    /**
     * @dev Returns if the MarginPool is paused
     */
    function paused() external view override returns (bool) {
        return _paused;
    }

    /**
     * @dev Returns the list of the initialized reserves
     **/
    function getReservesList() external view override returns (address[] memory) {
        address[] memory _activeReserves = new address[](_reservesCount);

        for (uint256 i = 0; i < _reservesCount; i++) {
            _activeReserves[i] = _reservesList[i];
        }
        return _activeReserves;
    }

    /**
     * @dev Returns the cached MarginPoolAddressesProvider connected to this contract
     **/
    function getAddressesProvider() external view override returns (IMarginPoolAddressesProvider){
        return _addressesProvider;
    }

    /**
     * @dev Validates and finalizes an xToken transfer
     * - Only callable by the overlying xToken of the `asset`
     * @param asset The address of the underlying asset of the xToken
     * @param from The user from which the xTokens are transferred
     * @param to The user receiving the xTokens
     * @param amount The amount being transferred/withdrawn
     * @param balanceFromBefore The xToken balance of the `from` user before the transfer
     * @param balanceToBefore The xToken balance of the `to` user before the transfer
     */
    function finalizeTransfer(address asset, address from, address to, uint256 amount, uint256 balanceFromBefore, uint256 balanceToBefore) external override whenNotPaused {
        require(msg.sender == _reserves[asset].xTokenAddress, Errors.MP_CALLER_MUST_BE_AN_XTOKEN);

        ValidationLogic.validateTransfer(from, _reserves, _usersConfig[from], _reservesList, _reservesCount, _addressesProvider.getPriceOracle());

        uint256 reserveId = _reserves[asset].id;

        if (from != to) {
            if (balanceFromBefore.sub(amount) == 0) {
                DataTypes.UserConfigurationMap storage fromConfig = _usersConfig[from];
                fromConfig.setUsingAsCollateral(reserveId, false);
                emit ReserveUsedAsCollateralDisabled(asset, from);
            }

            if (balanceToBefore == 0 && amount != 0) {
                DataTypes.UserConfigurationMap storage toConfig = _usersConfig[to];
                toConfig.setUsingAsCollateral(reserveId, true);
                emit ReserveUsedAsCollateralEnabled(asset, to);
            }
        }
    }

    /**
     * @dev Initializes a reserve, activating it, assigning an xToken and debt tokens and an
     * interest rate strategy
     * - Only callable by the MarginPoolConfigurator contract
     * @param asset The address of the underlying asset of the reserve
     * @param xTokenAddress The address of the xToken that will be assigned to the reserve
     * @param xTokenAddress The address of the VariableDebtToken that will be assigned to the reserve
     * @param interestRateStrategyAddress The address of the interest rate strategy contract
     **/
    function initReserve(address asset, address xTokenAddress, address variableDebtAddress, address interestRateStrategyAddress) external override onlyMarginPoolConfigurator {
        require(Address.isContract(asset), Errors.MP_NOT_CONTRACT);
        _reserves[asset].init(xTokenAddress, variableDebtAddress, interestRateStrategyAddress);
        _addReserveToList(asset);
    }

    /**
     * @dev Updates the address of the interest rate strategy contract
     * - Only callable by the MarginPoolConfigurator contract
     * @param asset The address of the underlying asset of the reserve
     * @param rateStrategyAddress The address of the interest rate strategy contract
     **/
    function setReserveInterestRateStrategyAddress(address asset, address rateStrategyAddress) external override onlyMarginPoolConfigurator {
        _reserves[asset].interestRateStrategyAddress = rateStrategyAddress;
    }

    /**
     * @dev Sets the configuration bitmap of the reserve as a whole
     * - Only callable by the MarginPoolConfigurator contract
     * @param asset The address of the underlying asset of the reserve
     * @param configuration The new configuration bitmap
     **/
    function setConfiguration(address asset, uint256 configuration) external override onlyMarginPoolConfigurator{
        _reserves[asset].configuration.data = configuration;
    }

    /**
     * @dev Set the _pause state of a reserve
     * - Only callable by the MarginPoolConfigurator contract
     * @param val `true` to pause the reserve, `false` to un-pause it
     */
    function setPause(bool val) external override onlyMarginPoolConfigurator {
        _paused = val;
        if (_paused) {
            emit Paused();
        } else {
            emit Unpaused();
        }
    }

    struct ExecuteBorrowParams {
        address asset;
        address user;
        address onBehalfOf;
        uint256 amount;
        address xTokenAddress;
        bool releaseUnderlying;
    }

    function _executeBorrow(ExecuteBorrowParams memory vars) internal {
        DataTypes.ReserveData storage reserve = _reserves[vars.asset];
        DataTypes.UserConfigurationMap storage userConfig = _usersConfig[vars.onBehalfOf];
        address oracle = _addressesProvider.getPriceOracle();
        uint256 amountInETH = IPriceOracleGetter(oracle).getAssetPrice(vars.asset).mul(vars.amount).div(10**reserve.configuration.getDecimals());
        ValidationLogic.validateBorrow(reserve, vars.onBehalfOf, vars.amount, amountInETH, _reserves, userConfig, _reservesList, _reservesCount, oracle);
        reserve.updateState();
        bool isFirstBorrowing = false;
        isFirstBorrowing = IVariableDebtToken(reserve.variableDebtTokenAddress).mint( vars.user, vars.onBehalfOf, vars.amount, reserve.variableBorrowIndex);
        if (isFirstBorrowing) {
            userConfig.setBorrowing(reserve.id, true);
        }
        reserve.updateInterestRates(vars.asset, vars.xTokenAddress, 0, vars.releaseUnderlying ? vars.amount : 0);
        if (vars.releaseUnderlying) {
            IXToken(vars.xTokenAddress).transferUnderlyingTo(vars.user, vars.amount.mul(10000-borrowFee).div(10000));
            if(borrowFee>0){
                 IXToken(vars.xTokenAddress).transferUnderlyingTo(_addressesProvider.getTreasuryAddress(), vars.amount.mul(borrowFee).div(10000));
            }
           
        }

        emit Borrow(vars.asset, vars.user, vars.onBehalfOf, vars.amount, reserve.currentVariableBorrowRate);
    }

    function _addReserveToList(address asset) internal {
        uint256 reservesCount = _reservesCount;

        require(reservesCount < MAX_NUMBER_RESERVES, Errors.MP_NO_MORE_RESERVES_ALLOWED);

        bool reserveAlreadyAdded = _reserves[asset].id != 0 || _reservesList[0] == asset;

        if (!reserveAlreadyAdded) {
            _reserves[asset].id = uint8(reservesCount);
            _reservesList[reservesCount] = asset;
            _reservesCount = reservesCount + 1;
        }
    }
}
