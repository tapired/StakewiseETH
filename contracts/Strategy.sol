// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;
import "@openzeppelin/contracts/math/Math.sol";
import "../interfaces/Stakewise.sol";

// These are the core Yearn libraries
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

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
    uint64 public uniStableFee;
    uint64 public uniStableFeeAlternate;
    uint64 public slippageProtectionOut; // = 50; //out of 10000. 50 = 0.5%
    uint256 public maxDepositWithoutQueue;
    uint256 public maxSingleTrade;
    uint256 public constant DENOMINATOR = 10_000;
    bool public swapTosETH2;

    constructor(address _vault) public BaseStrategy(_vault) {
        IERC20(weth).approve(uniswapv3, type(uint256).max);
        IERC20(sETH2).approve(uniswapv3, type(uint256).max);
        IERC20(rETH2).approve(uniswapv3, type(uint256).max);

        uniStableFee = 3000;
        uniStableFeeAlternate = 500;
        maxDepositWithoutQueue = 32 ether; // stakewise has a maxDeposit limit , if the deposited amount is bigger than this it will go on queue
        maxSingleTrade = 1_000 * 1e18;
        slippageProtectionOut = 50;
        swapTosETH2 = true; // default to swap weth to seth2 rather than mint
    }

    function setUnistableFee(uint24 _uniStableFee) external onlyAuthorized {
        uniStableFee = _uniStableFee;
    }

    function setUnistableFeeAlternate(uint24 _uniStableFeeAlternate)
        external
        onlyAuthorized
    {
        uniStableFeeAlternate = _uniStableFeeAlternate;
    }

    function setMaxDepositWithoutQueue(uint256 _wei) external onlyAuthorized {
        maxDepositWithoutQueue = _wei;
    }

    function setMaxSingleTrade(uint256 _maxSingleTrade)
        external
        onlyAuthorized
    {
        maxSingleTrade = _maxSingleTrade;
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
        return balanceOfSETH2().add(balanceOfWant());
    }

    function name() external view override returns (string memory) {
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
        uint256 debt = vault.strategies(address(this)).totalDebt;

        if (debt > estimatedTotalAssets()) {
            _loss = debt.sub(estimatedTotalAssets());
        }

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
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _wantBalance = balanceOfWant(); // weth
        if (_wantBalance > 0) {
            if (swapTosETH2) {
                _wantBalance = Math.min(_wantBalance, maxSingleTrade);
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
        _amount = _amount.mul(balanceOfSETH2()).div(debt);
        _amount = Math.min(_amount, balanceOfSETH2());
        /* uint256 slippageAllowance = _amount.mul(DENOMINATOR.sub(slippageProtectionOut)).div(DENOMINATOR); */
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

    function prepareMigration(address _newStrategy) internal override {
        uint256 sethbalance = balanceOfSETH2();
        uint256 rethbalance = IERC20(rETH2).balanceOf(address(this));
        IERC20(sETH2).safeTransfer(_newStrategy, sethbalance);
        IERC20(rETH2).safeTransfer(_newStrategy, rethbalance);
    }

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

    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        return _amtInWei;
    }

    receive() external payable {}
}
