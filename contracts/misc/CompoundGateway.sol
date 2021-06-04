// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {Ownable} from "./Ownable.sol";
import {IERC20} from "./IERC20.sol";
import {IMarginPool} from "./IMarginPool.sol";
import {ICErc20} from "./ICErc20.sol";
import {DataTypes} from "./DataTypes.sol";
import {SafeERC20} from "./SafeERC20.sol";
import {IWETHGateway} from "./IWETHGateway.sol";
import {SafeMath} from "./SafeMath.sol";

contract CompoundGateway is Ownable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    IWETHGateway internal WETHGateway;
    IMarginPool internal immutable POOL;
    address public WETH;
    address public cETH;

    constructor(address _pool, address _weth, address _ceth, address _wethGateway) public {
        POOL = IMarginPool(_pool);
        WETH = _weth;
        cETH = _ceth;
        WETHGateway = IWETHGateway(_wethGateway);
    }

    function approveAsset(address asset, address CToken) public {
        IERC20(asset).approve(CToken, uint256(-1));
        IERC20(asset).approve(address(POOL), uint256(-1));
    }

    /**
     * @dev Get MarginPool address used by WETHGateway
     */
    function getMarginPoolAddress() external view returns (address) {
        return address(POOL);
    }


    function depositCToken(address CToken, uint256 amount) external returns (uint256 ret) {
        ret = 0;
        uint256 cTokenBalance = ICErc20(CToken).balanceOf(msg.sender);
        uint256 underlyingBalance = ICErc20(CToken).balanceOfUnderlying(msg.sender);
        uint256 transferTokenAmount = cTokenBalance.mul(amount).div(underlyingBalance);
        if (amount >= underlyingBalance) {
            amount = underlyingBalance;
            transferTokenAmount = cTokenBalance;
        }
        bool success = ICErc20(CToken).transferFrom(msg.sender, address(this), transferTokenAmount);
        require(success, "Transfer CToken failed!");
        if (CToken == cETH) {
            ret = ICErc20(CToken).redeemUnderlying(amount);
            require(ret == 0, "redeemUnderlying error");
            WETHGateway.depositETH{value: amount}(msg.sender);
        } else {
            address asset = ICErc20(CToken).underlying();
            ICErc20(CToken).redeemUnderlying(amount);
            POOL.deposit(asset, amount, msg.sender);
        }
    }

    function _safeTransferETH(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success, "ETH_TRANSFER_FAILED");
    }

    /**
     * @dev transfer ERC20 from the utility contract, for ERC20 recovery in case of stuck tokens due
     * direct transfers to the contract address.
     * @param token token to transfer
     * @param to recipient of the transfer
     * @param amount amount to send
     */
    function emergencyTokenTransfer(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).transfer(to, amount);
    }

    /**
     * @dev transfer native Ether from the utility contract, for native Ether recovery in case of stuck Ether
     * due selfdestructs or transfer ether to pre-computated contract address before deployment.
     * @param to recipient of the transfer
     * @param amount amount to send
     */
    function emergencyEtherTransfer(address to, uint256 amount) external onlyOwner {
        _safeTransferETH(to, amount);
    }

    receive() external payable {}

    /**
     * @dev Revert fallback calls
     */
    fallback() external payable {
        revert("Fallback not allowed");
    }
}
