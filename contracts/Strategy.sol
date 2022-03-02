// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;
import "@openzeppelin/contracts/math/Math.sol";
import "../interfaces/Stakewise.sol";

// These are the core Yearn libraries
import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

interface IUniV3 {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params)
        external
        payable
        returns (uint256 amountOut);

    struct ExactOutputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
    }

    function exactOutput(ExactOutputParams calldata params)
        external
        payable
        returns (uint256 amountIn);

    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        payable
        returns (uint256 amountIn);

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }
}

interface IERC20Extended {
    function decimals() external view returns (uint8);

    function name() external view returns (string memory);

    function symbol() external view returns (string memory);
}

interface IWETH is IERC20 {
    function deposit() external payable;

    function decimals() external view returns (uint256);

    function withdraw(uint256) external;
}

// Import interfaces for many popular DeFi projects, or add your own!
//import "../interfaces/<protocol>/<Interface>.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    address public constant sETH2 =
        address(0xFe2e637202056d30016725477c5da089Ab0A043A); // want -- 3
    address public constant rETH2 =
        address(0x20BC832ca081b91433ff6c17f85701B6e92486c5);
    address public constant weth =
        address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address public constant uniswapv3 =
        address(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    address public constant StakewisePool =
        address(0xC874b064f465bdD6411D45734b56fac750Cda29A);
    uint24 public uniStableFee;
    uint24 public uniStableFeeAlternate;
    uint256 public maxDepositWithoutQueue;
    bool public swapTosETH2;

    constructor(address _vault) public BaseStrategy(_vault) {
        IERC20(weth).approve(uniswapv3, 0);
        IERC20(weth).approve(uniswapv3, type(uint256).max);
        IERC20(sETH2).approve(uniswapv3, 0);
        IERC20(sETH2).approve(uniswapv3, type(uint256).max);
        IERC20(rETH2).approve(uniswapv3, 0);
        IERC20(rETH2).approve(uniswapv3, type(uint256).max);

        uniStableFee = 3000;
        uniStableFeeAlternate = 500;
        maxDepositWithoutQueue = 32 ether; // stakewise has a maxDeposit limit , if the deposited amount is bigger than this it will go on queue
        swapTosETH2 = true; // default to swap weth to seth2 rather than mint
        // You can set these parameters on deployment to whatever you want
        // maxReportDelay = 6300;
        // profitFactor = 100;
        // debtThreshold = 0;
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************
    function setUnistableFee(uint24 _uniStableFee) external onlyAuthorized {
        uniStableFee = _uniStableFee;
    }

    function setUnistableFeeAlternate(uint24 _uniStableFeeAlternate)
        external
        onlyAuthorized
    {
        uniStableFeeAlternate = _uniStableFeeAlternate;
    }

    function setMaxDepositWithoutQueue(uint256 _ethers)
        external
        onlyAuthorized
    {
        maxDepositWithoutQueue = _ethers * 1e18;
    }

    function setSwapTosETH2(bool _changeSwap) external onlyAuthorized {
        swapTosETH2 = _changeSwap;
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfSETH2() public view returns (uint256) {
        //
        return IERC20(sETH2).balanceOf(address(this));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        // we treat as seth2 and eth are equivalent
        // most of the time when we adjustPosition with swapping weth to seth2 we will generate a small amount of profit rather than mint 1:1
        // unfortunately we do not have a chance to burn the reward so we have to sell it which we will have small amount of loss
        return balanceOfSETH2().add(balanceOfWant());
    }

    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return "StrategyStakewiseETH";
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        if (_debtOutstanding > 0) {
            uint256 _amountFreed = 0;
            (_amountFreed, _loss) = liquidatePosition(_debtOutstanding);
            _debtPayment = Math.min(_amountFreed, _debtOutstanding);
        }
        uint256 _wantBefore = want.balanceOf(address(this)); // 0
        _swapRewardsToWant();
        uint256 _wantAfter = want.balanceOf(address(this)); // 100
        _profit = _wantAfter.sub(_wantBefore);
        //net off profit and loss
        if (_profit >= _loss) {
            _profit = _profit - _loss; // when we withdraw we might have lose so make sure everything is clean
            _loss = 0;
        } else {
            _profit = 0;
            _loss = _loss - _profit;
        }

        // TODO: Do stuff here to free up any returns back into `want`
        // NOTE: Return `_profit` which is value generated by all positions, priced in `want`
        // NOTE: Should try to free up at least `_debtOutstanding` of underlying position
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _wantBalance = balanceOfWant(); // weth
        if (_wantBalance > 0) {
            if (swapTosETH2) {
                IUniV3(uniswapv3).exactInput(
                    IUniV3.ExactInputParams(
                        abi.encodePacked(
                            address(weth),
                            uint24(uniStableFee),
                            address(sETH2)
                        ),
                        address(this),
                        block.timestamp,
                        _wantBalance,
                        0
                    )
                );
            } else {
                if (_wantBalance <= maxDepositWithoutQueue) {
                    // make sure that we are respecting the deposit limit
                    IWETH(weth).withdraw(_wantBalance);
                    uint256 ethBalance = address(this).balance;
                    IStakewise(StakewisePool).stake{value: ethBalance}();
                }
            }
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        // TODO: Do stuff here to free up to `_amountNeeded` from all positions back into `want`
        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`

        uint256 wantBalance = balanceOfWant();
        if (wantBalance > _amountNeeded) {
            // if there is enough free want, let's use it
            return (_amountNeeded, 0);
        }

        // we need to free funds
        uint256 amountRequired = _amountNeeded.sub(wantBalance);
        _withdrawSome(amountRequired);
        uint256 freeAssets = balanceOfWant();
        if (_amountNeeded > freeAssets) {
            _liquidatedAmount = freeAssets;
            _loss = _amountNeeded.sub(_liquidatedAmount);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function _withdrawSome(uint256 _amount) internal {
        uint256 debt = vault.strategies(address(this)).totalDebt;
        _amount = (_amount.mul(balanceOfSETH2()).mul(1e18)).div(debt);
        _amount = Math.min(_amount, balanceOfSETH2());
        if (_amount > 0) {
            IUniV3(uniswapv3).exactInput(
                IUniV3.ExactInputParams(
                    abi.encodePacked(
                        address(sETH2),
                        uint24(uniStableFee),
                        address(weth)
                    ),
                    address(this),
                    block.timestamp,
                    _amount,
                    0
                )
            );
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        // TODO: Liquidate all positions and return the amount freed.
        require(emergencyExit);
        _withdrawSome(balanceOfSETH2());
        return want.balanceOf(address(this));
    }

    function _swapRewardsToWant() internal {
        uint256 _rethbalance = IERC20(rETH2).balanceOf(address(this));
        if (_rethbalance > 0) {
            IUniV3(uniswapv3).exactInput(
                IUniV3.ExactInputParams(
                    abi.encodePacked(
                        address(rETH2),
                        uint24(uniStableFeeAlternate),
                        address(sETH2),
                        uint24(uniStableFee),
                        address(weth)
                    ),
                    address(this),
                    block.timestamp,
                    _rethbalance,
                    0
                )
            );
        }
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary

    function prepareMigration(address _newStrategy) internal override {
        uint256 sethbalance = balanceOfSETH2();
        uint256 rethbalance = IERC20(rETH2).balanceOf(address(this));
        IERC20(sETH2).safeTransfer(_newStrategy, sethbalance);
        IERC20(rETH2).safeTransfer(_newStrategy, rethbalance);
    }

    // Override this to add all tokens/tokenized positions this contract manages
    // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
    // NOTE: Do *not* include `want`, already included in `sweep` below
    //
    // Example:
    //
    //    function protectedTokens() internal override view returns (address[] memory) {
    //      address[] memory protected = new address[](3);
    //      protected[0] = tokenA;
    //      protected[1] = tokenB;
    //      protected[2] = tokenC;
    //      return protected;
    //    }
    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {
        address[] memory protected = new address[](2);
        protected[0] = rETH2;
        protected[1] = sETH2;
        return protected;
    }

    /**
     * @notice
     *  Provide an accurate conversion from `_amtInWei` (denominated in wei)
     *  to `want` (using the native decimal characteristics of `want`).
     * @dev
     *  Care must be taken when working with decimals to assure that the conversion
     *  is compatible. As an example:
     *
     *      given 1e17 wei (0.1 ETH) as input, and want is USDC (6 decimals),
     *      with USDC/ETH = 1800, this should give back 1800000000 (180 USDC)
     *
     * @param _amtInWei The amount (in wei/1e-18 ETH) to convert to `want`
     * @return The amount in `want` of `_amtInEth` converted to `want`
     **/
    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        // TODO create an accurate price oracle
        return _amtInWei;
    }

    receive() external payable {}
}
