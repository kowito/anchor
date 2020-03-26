pragma solidity ^0.5.16;

import "./CErc20.sol";
import "./CToken.sol";
import "./PriceOracle.sol";
import "./Comptroller.sol";
import "./SafeMath.sol";

interface V1PriceOracleInterface {
    function assetPrices(address asset) external view returns (uint);
}

contract PriceOracleProxy is PriceOracle {
    using SafeMath for uint256;

    /**
     * @notice The v1 price oracle, which will continue to serve prices for v1 assets
     */
    V1PriceOracleInterface public v1PriceOracle;

    /**
     * @notice The comptroller which is used to white-list assets the proxy will price
     * @dev Assets which are not white-listed will not be priced, to defend against abuse
     */
    Comptroller public comptroller;

    /**
     * @notice address of the cEther contract, which has a constant price
     */
    address public cEthAddress;

    /**
     * @notice address of the cUSDC contract, which we hand pick a key for
     */
    address public cUsdcAddress;

    /**
     * @notice address of the cSAI contract, which we peg to the DAI price
     */
    address public cSaiAddress;

    /**
     * @notice address of the cDAI contract, which we hand pick a key for
     */
    address public cDaiAddress;

    /**
     * @notice address of the cUsdt contract, which we hand pick a key for
     */
    address public cUsdtAddress;

    /**
     * @notice the key in the v1 Price Oracle that will contain the USDC/ETH price
     */
    address constant usdcOracleKey = address(1);

    /**
     * @notice the key in the v1 Price Oracle that will contain the DAI/ETH price
     */
    address constant daiOracleKey = address(2);

    /**
     * @notice the key in the v1 Price Oracle that will contain the USD/ETH price
     */
    address public makerUsdOracleKey;

    /**
     * @param comptroller_ The address of the comptroller, which will be consulted for market listing status
     * @param v1PriceOracle_ The address of the v1 price oracle, which will continue to operate and hold prices for collateral assets
     * @param cEthAddress_ The address of cETH, which will return a constant 1e18, since all prices relative to ether
     * @param cUsdcAddress_ The address of cUSDC, which will be read from a special oracle key
     * @param cSaiAddress_ The address of cSAI, which will be read from a special oracle key
     * @param cDaiAddress_ The address of cDAI, which will be pegged to the SAI price
     */
    constructor(address comptroller_,
                address v1PriceOracle_,
                address cEthAddress_,
                address cUsdcAddress_,
                address cSaiAddress_,
                address cDaiAddress_,
                address cUsdtAddress_) public {
        comptroller = Comptroller(comptroller_);
        v1PriceOracle = V1PriceOracleInterface(v1PriceOracle_);

        cEthAddress = cEthAddress_;
        cUsdcAddress = cUsdcAddress_;
        cSaiAddress = cSaiAddress_;
        cDaiAddress = cDaiAddress_;
        cUsdtAddress = cUsdtAddress_;

        if (cSaiAddress_ != address(0)) {
            makerUsdOracleKey = CErc20(cSaiAddress_).underlying();
        }
    }

    /**
     * @notice Get the underlying price of a listed cToken asset
     * @param cToken The cToken to get the underlying price of
     * @return The underlying asset price mantissa (scaled by 1e18).
     *  Zero means the price is unavailable.
     */
    function getUnderlyingPrice(CToken cToken) public view returns (uint) {
        address cTokenAddress = address(cToken);
        (bool isListed, ) = comptroller.markets(cTokenAddress);

        if (!isListed) {
            // not white-listed, worthless
            return 0;
        }

        if (cTokenAddress == cEthAddress) {
            // ether always worth 1
            return 1e18;
        }

        if (cTokenAddress == cUsdcAddress || cTokenAddress == cUsdtAddress) {
            // we assume USDC/USD and USDT/USD = 1
            //  use the maker usd price (for a token w/ 6 decimals)
            return v1PriceOracle.assetPrices(makerUsdOracleKey).mul(1e12); // 1e(18 - 6)
        }

        if (cTokenAddress == cSaiAddress || cTokenAddress == cDaiAddress) {
            // and let DAI/ETH float based on the DAI/USDC ratio
            // check and bound the DAI/USDC posted price ratio
            //  and use that to scale the maker price (for a token w/ 18 decimals)]
            uint makerUsdPrice = v1PriceOracle.assetPrices(makerUsdOracleKey);
            uint postedUsdcPrice = v1PriceOracle.assetPrices(usdcOracleKey);
            uint postedScaledDaiPrice = v1PriceOracle.assetPrices(daiOracleKey).mul(1e12);
            uint daiUsdcRatio = postedScaledDaiPrice.mul(1e18).div(postedUsdcPrice);

            if (daiUsdcRatio < 0.95e18) {
                return makerUsdPrice.mul(0.95e18).div(1e18);
            }

            if (daiUsdcRatio > 1.05e18) {
                return makerUsdPrice.mul(1.05e18).div(1e18);
            }

            return makerUsdPrice.mul(daiUsdcRatio).div(1e18);
        }

        // otherwise just read from v1 oracle
        address underlying = CErc20(cTokenAddress).underlying();
        return v1PriceOracle.assetPrices(underlying);
    }
}
