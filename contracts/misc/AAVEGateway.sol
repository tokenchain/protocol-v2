// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {Ownable} from "./Ownable.sol";
import {IERC20} from "./IERC20.sol";
import {IMarginPool} from "./IMarginPool.sol";
import {ILendingPool} from "./ILendingPool.sol";
import {AAVEDataTypes} from "./AAVEDataTypes.sol";
import {SafeERC20} from "./SafeERC20.sol";

contract AAVEGateway is Ownable {
    using SafeERC20 for IERC20;
    IMarginPool internal immutable POOL;
    ILendingPool internal AAVEPool;

    constructor(address _pool, address _AAVEPoolAddress) public {
        POOL = IMarginPool(_pool);
        AAVEPool = ILendingPool(_AAVEPoolAddress);
    }

    function approveAllAsset() public {
        address[] memory reserveList = POOL.getReservesList();
        for (uint256 i = 0; i < reserveList.length; i++) {
            IERC20(reserveList[i]).approve(address(AAVEPool), uint256(-1));
            IERC20(reserveList[i]).approve(address(POOL), uint256(-1));
        }
    }

    function approveAsset(address asset) public {
        IERC20(asset).approve(address(AAVEPool), uint256(-1));
        IERC20(asset).approve(address(POOL), uint256(-1));
    }

    /**
     * @dev Get MarginPool address used by WETHGateway
     */
    function getMarginPoolAddress() external view returns (address) {
        return address(POOL);
    }


    function depositAToken(address asset, uint256 amount) external {
        AAVEDataTypes.ReserveData memory reserve = AAVEPool.getReserveData(asset);
        IERC20(reserve.aTokenAddress).safeTransferFrom(msg.sender, address(this), amount);
        AAVEPool.withdraw(asset, amount, address(this));
        POOL.deposit(asset, amount, msg.sender);
    }
    
    function getUserAccountData(address user) external view returns(uint256 totalCollateralETH, uint256 totalDebtETH, uint256 ltv){
        (totalCollateralETH, totalDebtETH, , , ltv, ) = AAVEPool.getUserAccountData(user);
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
