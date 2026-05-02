// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
 * InfinityBurn (INFB) - Production-ready Lite
 * - ERC20 compatible
 * - Fees: burn + reserve + dev + liquidity
 * - Auto Liquidity (swap & liquify)
 * - Launch control + limits
 */

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

interface IRouter {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn, uint amountOutMin, address[] calldata path,
        address to, uint deadline
    ) external;
    function addLiquidityETH(
        address token, uint amountTokenDesired, uint amountTokenMin, uint amountETHMin,
        address to, uint deadline
    ) external payable returns (uint, uint, uint);
}

interface IFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

contract InfinityBurn is IERC20 {

    string public name = "InfinityBurn";
    string public symbol = "INFB";
    uint8 public decimals = 18;

    uint256 private _totalSupply = 1_000_000_000 * 1e18;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    address public owner;
    address public reserveWallet;
    address public devWallet;

    // Fees (%)
    uint256 public burnFee = 1;
    uint256 public reserveFee = 1;
    uint256 public devFee = 1;
    uint256 public liquidityFee = 2;

    mapping(address => bool) public isExcludedFromFee;

    // Limits
    uint256 public maxTxAmount;
    uint256 public maxWallet;

    // Router
    IRouter public router;
    address public pair;

    bool public tradingEnabled = false;
    bool private inSwap;
    uint256 public swapThreshold = _totalSupply / 10000; // 0.01%

    address public DEAD = 0x000000000000000000000000000000000000dEaD;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier lockSwap {
        inSwap = true;
        _;
        inSwap = false;
    }

    constructor(address _router, address _reserve, address _dev) {
        owner = msg.sender;
        reserveWallet = _reserve;
        devWallet = _dev;

        router = IRouter(_router);
        pair = IFactory(router.factory()).createPair(address(this), router.WETH());

        _balances[msg.sender] = _totalSupply;

        maxTxAmount = _totalSupply / 100; // 1%
        maxWallet = _totalSupply / 50;    // 2%

        isExcludedFromFee[msg.sender] = true;
        isExcludedFromFee[_reserve] = true;
        isExcludedFromFee[_dev] = true;
    }

    receive() external payable {}

    // ERC20
    function totalSupply() public view override returns (uint256) { return _totalSupply; }
    function balanceOf(address account) public view override returns (uint256) { return _balances[account]; }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        return true;
    }

    function allowance(address a, address b) public view override returns (uint256) {
        return _allowances[a][b];
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _allowances[sender][msg.sender] -= amount;
        _transfer(sender, recipient, amount);
        return true;
    }

    // Launch
    function enableTrading() external onlyOwner {
        tradingEnabled = true;
    }

    // Core Transfer
    function _transfer(address from, address to, uint256 amount) internal {
        require(_balances[from] >= amount, "Balance low");

        if (!isExcludedFromFee[from] && !isExcludedFromFee[to]) {
            require(tradingEnabled, "Trading off");
            require(amount <= maxTxAmount, "Max TX");
            require(_balances[to] + amount <= maxWallet, "Max wallet");
        }

        // Swap & Liquify
        uint256 contractToken = _balances[address(this)];
        if (contractToken >= swapThreshold && !inSwap && from != pair) {
            swapAndLiquify(contractToken);
        }

        uint256 feeAmount = 0;

        if (!isExcludedFromFee[from] && !isExcludedFromFee[to]) {
            uint256 burn = (amount * burnFee) / 100;
            uint256 reserve = (amount * reserveFee) / 100;
            uint256 dev = (amount * devFee) / 100;
            uint256 liq = (amount * liquidityFee) / 100;

            feeAmount = burn + reserve + dev + liq;

            _balances[DEAD] += burn;
            _totalSupply -= burn;

            _balances[reserveWallet] += reserve;
            _balances[devWallet] += dev;
            _balances[address(this)] += liq;
        }

        uint256 sendAmount = amount - feeAmount;

        _balances[from] -= amount;
        _balances[to] += sendAmount;
    }

    // Auto Liquidity
    function swapAndLiquify(uint256 tokens) private lockSwap {
        uint256 half = tokens / 2;
        uint256 otherHalf = tokens - half;

        uint256 initialBalance = address(this).balance;

        _approve(address(this), address(router), half);

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();

        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            half, 0, path, address(this), block.timestamp
        );

        uint256 newBalance = address(this).balance - initialBalance;

        _approve(address(this), address(router), otherHalf);

        router.addLiquidityETH{value: newBalance}(
            address(this),
            otherHalf,
            0,
            0,
            owner,
            block.timestamp
        );
    }

    function _approve(address owner_, address spender, uint256 amount) internal {
        _allowances[owner_][spender] = amount;
    }
}
