// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.6.12;

interface ICErc20 {
    function underlying() external view returns (address);
    function redeem(uint redeemTokens) external returns (uint);
    function redeemUnderlying(uint redeemAmount) external returns (uint);
    function transferFrom(address src, address dst, uint256 amount) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
    function balanceOfUnderlying(address owner) external returns (uint);
}