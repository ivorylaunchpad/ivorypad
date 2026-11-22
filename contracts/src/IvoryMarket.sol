// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IvoryToken} from "./IvoryToken.sol";

interface IWrappedNative { function deposit() external payable; }
interface IDexPair { function mint(address to) external returns (uint256 liquidity); function getReserves() external view returns (uint112, uint112, uint32); function token0() external view returns (address); }

/// @notice The launch market of a token: a virtual-reserve constant product pool holding the full supply.
/// It has no liquidity removal, no owner and no upgrade path. When the real quote it holds reaches the
/// coin's graduation target, the curve closes and the market moves its liquidity to the coin's WhiteSwap
/// pair at the same price: 2% of the real quote goes to the treasury, the rest and the matching tokens seed
/// the pair, the LP tokens are burned (locked forever) and the unused tokens are burned. From then on the
/// token itself charges the 0.3% protocol fee and the coin's tax on every pair trade.
/// It also exposes the Uniswap V2 pair views and events (token0, token1, factory, getReserves,
/// Swap, Sync) so DEX indexers can list it. The reserves it reports are the ones that set the
/// price, so they include the virtual opening quote reserve.
contract IvoryMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint256 private constant BPS = 10000;
    /// @notice Fixed 0.3% of every trade for the treasury, on top of the coin's own tax.
    uint256 public constant PROTOCOL_FEE_BPS = 30;
    /// @notice One-time share of the real quote raised that goes to the treasury at graduation.
    uint256 public constant GRADUATION_FEE_BPS = 200;

    struct Init {
        IvoryToken token;
        address quote;
        uint256 startQuote;
        uint256 graduationRaise;
        address creator;
        address recipient;
        address treasury;
        uint16 buyTax;
        uint16 sellTax;
        uint16 creatorBps;
        uint16 holderBps;
        uint16 buybackBps;
        address factory;
        /// @dev The quote as indexers and the DEX see it: WWBT for a native WBT market.
        address pairQuote;
        /// @dev The coin's WhiteSwap pair, created empty at launch.
        address dexPair;
    }

    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    /// @notice Gas the graduating trade must still have before it tries the migration (a few times what the real
    /// WhiteSwap migration uses). Without it, eth_estimateGas settles on a limit where the try below runs out of
    /// gas and the trade succeeds without migrating, so every wallet-estimated graduating trade would skip it.
    uint256 public constant MIGRATION_GAS = 800_000;
    IvoryToken public immutable token;
    address public immutable quote;
    address public immutable creator;
    address public immutable recipient;
    address public immutable treasury;
    uint256 public immutable startQuote;
    uint16 public immutable creatorBps;
    uint16 public immutable holderBps;
    uint16 public immutable buybackBps;
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    address public immutable pairQuote;
    address public immutable dexPair;

    uint16 public buyTax;
    uint16 public sellTax;
    /// @notice Real quote (above the virtual opening reserve) the pool must hold to graduate. Zero: never graduates.
    uint256 public immutable graduationRaise;
    /// @notice Set once, by the trade that takes the pool past graduationRaise. The curve stops trading then.
    bool public graduated;
    /// @notice Set once the liquidity is in the WhiteSwap pair. Normally in the same transaction as graduation;
    /// if that step fails, anyone can finish it with migrate().
    bool public migrated;
    uint64 public graduatedAt;
    uint256 public reserveToken;
    uint256 public reserveQuote;
    uint256 public platformOwed;
    uint256 public creatorOwed;
    uint256 public holderPending;
    uint256 public buybackPending;

    event Trade(address indexed trader, bool indexed isBuy, uint256 quoteAmount, uint256 tokenAmount, uint256 tax, uint256 reserveToken, uint256 reserveQuote);
    event Buyback(uint256 quoteAmount, uint256 tokensBurned);
    event Graduated(uint256 reserveToken, uint256 reserveQuote, uint256 marketCap);
    event Migrated(address indexed pair, uint256 quoteToPair, uint256 tokensToPair, uint256 tokensBurned, uint256 graduationFee, uint256 liquidity);
    event Swap(address indexed sender, uint256 amount0In, uint256 amount1In, uint256 amount0Out, uint256 amount1Out, address indexed to);
    event Sync(uint112 reserve0, uint112 reserve1);

    constructor(Init memory p) {
        token = p.token;
        quote = p.quote;
        startQuote = p.startQuote;
        graduationRaise = p.graduationRaise;
        creator = p.creator;
        recipient = p.recipient;
        treasury = p.treasury;
        buyTax = p.buyTax;
        sellTax = p.sellTax;
        creatorBps = p.creatorBps;
        holderBps = p.holderBps;
        buybackBps = p.buybackBps;
        reserveToken = p.token.SUPPLY();
        reserveQuote = p.startQuote;
        factory = p.factory;
        pairQuote = p.pairQuote;
        dexPair = p.dexPair;
        bool tokenFirst = address(p.token) < p.pairQuote;
        token0 = tokenFirst ? address(p.token) : p.pairQuote;
        token1 = tokenFirst ? p.pairQuote : address(p.token);
    }

    /// @notice Uniswap V2 style reserves, in token0/token1 order, capped to uint112. The timestamp is
    /// the current block, which saves a storage write on every trade.
    function getReserves() public view returns (uint112 reserve0, uint112 reserve1, uint32 timestamp) {
        if (migrated) return IDexPair(dexPair).getReserves();
        (uint112 t, uint112 q) = (_u112(reserveToken), _u112(reserveQuote));
        (reserve0, reserve1) = token0 == address(token) ? (t, q) : (q, t);
        timestamp = uint32(block.timestamp);
    }

    /// @notice The fee returned is the protocol fee plus the coin's tax.
    function quoteBuy(uint256 quoteIn) public view returns (uint256 tokensOut, uint256 fee) {
        fee = quoteIn * (PROTOCOL_FEE_BPS + buyTax) / BPS;
        uint256 net = quoteIn - fee;
        tokensOut = reserveToken * net / (reserveQuote + net);
    }

    /// @notice The fee returned is the protocol fee plus the coin's tax.
    function quoteSell(uint256 tokensIn) public view returns (uint256 quoteOut, uint256 fee) {
        uint256 gross = reserveQuote * tokensIn / (reserveToken + tokensIn);
        fee = gross * (PROTOCOL_FEE_BPS + sellTax) / BPS;
        quoteOut = gross - fee;
    }

    /// @notice Quote per whole token, scaled by 1e18.
    function price() public view returns (uint256) {
        if (!migrated) return reserveQuote * 1e18 / reserveToken;
        (uint112 r0, uint112 r1, ) = IDexPair(dexPair).getReserves();
        (uint256 t, uint256 q) = IDexPair(dexPair).token0() == address(token) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        return t == 0 ? 0 : q * 1e18 / t;
    }

    function marketCap() external view returns (uint256) { return price() * token.totalSupply() / 1e18; }

    function buy(uint256 quoteIn, uint256 minTokens, uint256 deadline, address to) external payable nonReentrant returns (uint256 tokensOut) {
        require(!graduated, "graduated: trade on WhiteSwap");
        require(block.timestamp <= deadline, "deadline");
        require(quoteIn > 0 && to != address(0), "input");
        _pull(quoteIn);
        uint256 fee;
        (tokensOut, fee) = quoteBuy(quoteIn);
        require(tokensOut > 0 && tokensOut >= minTokens, "slippage");
        reserveQuote += quoteIn - fee;
        reserveToken -= tokensOut;
        IERC20(address(token)).safeTransfer(to, tokensOut);
        _route(quoteIn, fee);
        emit Trade(to, true, quoteIn, tokensOut, fee, reserveToken, reserveQuote);
        _swapEvent(msg.sender, to, 0, quoteIn, tokensOut, 0);
        _checkGraduation();
    }

    function sell(uint256 tokensIn, uint256 minQuote, uint256 deadline, address to) external nonReentrant returns (uint256 quoteOut) {
        require(!graduated, "graduated: trade on WhiteSwap");
        require(block.timestamp <= deadline, "deadline");
        require(tokensIn > 0 && to != address(0), "input");
        uint256 fee;
        (quoteOut, fee) = quoteSell(tokensIn);
        require(quoteOut > 0 && quoteOut >= minQuote, "slippage");
        uint256 before = token.balanceOf(address(this));
        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), tokensIn);
        require(token.balanceOf(address(this)) - before == tokensIn, "token delta");
        reserveToken += tokensIn;
        reserveQuote -= quoteOut + fee;
        _route(quoteOut + fee, fee);
        _pay(to, quoteOut);
        emit Trade(msg.sender, false, quoteOut, tokensIn, fee, reserveToken, reserveQuote);
        _swapEvent(msg.sender, to, tokensIn, 0, 0, quoteOut);
    }

    /// @notice Nobody owns a market: no owner, no admin, no upgrade, and the taxes set at launch are fixed forever.
    /// Exposed as owner() = address(0) so explorers and token scanners show ownership as renounced.
    function owner() external pure returns (address) { return address(0); }

    /// @notice Anyone can run it: buys with the buyback budget, burns, and pays holders.
    function harvest() external nonReentrant {
        require(!graduated, "graduated");
        _flushHolders();
        _buyback();
        _checkGraduation();
    }

    function _buyback() private {
        uint256 amount = buybackPending;
        if (amount == 0) return;
        uint256 tokensOut = reserveToken * amount / (reserveQuote + amount);
        if (tokensOut == 0) return;
        buybackPending = 0;
        reserveQuote += amount;
        reserveToken -= tokensOut;
        token.burn(tokensOut);
        emit Buyback(amount, tokensOut);
        _swapEvent(address(this), DEAD, 0, amount, tokensOut, 0);
    }

    /// @notice Finishes a graduation whose migration did not complete in the graduating trade. Anyone can call it.
    function migrate() external nonReentrant {
        require(graduated && !migrated, "not pending");
        _migrate();
    }

    /// @dev Lets the graduating trade attempt the migration without reverting the trade if it fails.
    function migrateFromSelf() external {
        require(msg.sender == address(this) && graduated && !migrated, "self only");
        _migrate();
    }

    /// @notice After graduation the token sells DEX fees here for an ERC-20 quote (a V2 pair cannot pay a
    /// token of its own pair); this forwards them to the token.
    function forwardQuote(uint256 amount) external {
        require(msg.sender == address(token) && quote != address(0), "token only");
        IERC20(quote).safeTransfer(address(token), amount);
    }

    function claimCreator() external nonReentrant returns (uint256 amount) {
        amount = creatorOwed;
        require(amount > 0, "nothing owed");
        creatorOwed = 0;
        _pay(recipient, amount);
    }

    function claimPlatform() external nonReentrant returns (uint256 amount) {
        amount = platformOwed;
        require(amount > 0, "nothing owed");
        platformOwed = 0;
        _pay(treasury, amount);
    }

    /// @param tradeSize Quote value of the trade before fees.
    function _route(uint256 tradeSize, uint256 fee) private {
        if (fee == 0) return;
        uint256 platform = tradeSize * PROTOCOL_FEE_BPS / BPS;
        if (platform > fee) platform = fee;
        uint256 rest = fee - platform;
        uint256 toCreator = rest * creatorBps / BPS;
        uint256 toHolders = rest * holderBps / BPS;
        platformOwed += platform;
        creatorOwed += toCreator;
        holderPending += toHolders;
        buybackPending += rest - toCreator - toHolders;
        _flushHolders();
    }

    function _flushHolders() private {
        uint256 amount = holderPending;
        if (amount == 0 || token.dividendSupply() == 0) return;
        holderPending = 0;
        if (quote == address(0)) {
            token.distributeReward{value: amount}(amount);
        } else {
            IERC20(quote).forceApprove(address(token), amount);
            token.distributeReward(amount);
        }
    }

    /// @notice Share of the graduation target raised so far, scaled by 1e18 (1e18 = graduated).
    function graduationProgress() external view returns (uint256) {
        if (graduated) return 1e18;
        if (graduationRaise == 0 || reserveQuote <= startQuote) return 0;
        uint256 p = (reserveQuote - startQuote) * 1e18 / graduationRaise;
        return p > 1e18 ? 1e18 : p;
    }

    function _checkGraduation() private {
        if (graduated || graduationRaise == 0 || reserveQuote < startQuote + graduationRaise) return;
        graduated = true;
        graduatedAt = uint64(block.timestamp);
        emit Graduated(reserveToken, reserveQuote, reserveQuote * token.totalSupply() / reserveToken);
        require(gasleft() >= MIGRATION_GAS, "gas: graduation needs more");
        try this.migrateFromSelf{gas: gasleft() - 30_000}() {} catch {}
    }

    function _migrate() private {
        migrated = true;
        _buyback();
        _flushHolders();
        uint256 real = reserveQuote - startQuote;
        // Holder rewards that could not be paid (no holders) go into the pool rather than staying stuck.
        real += holderPending;
        holderPending = 0;
        uint256 fee = real * GRADUATION_FEE_BPS / BPS;
        platformOwed += fee;
        uint256 quoteToPair = real - fee;
        // Same price as the curve: tokens = quote / (reserveQuote / reserveToken).
        uint256 tokensToPair = quoteToPair * reserveToken / reserveQuote;
        uint256 toBurn = reserveToken - tokensToPair;
        reserveToken = 0;
        reserveQuote = 0;
        token.graduate();
        IERC20(address(token)).safeTransfer(dexPair, tokensToPair);
        if (quote == address(0)) {
            IWrappedNative(pairQuote).deposit{value: quoteToPair}();
            IERC20(pairQuote).safeTransfer(dexPair, quoteToPair);
        } else {
            IERC20(quote).safeTransfer(dexPair, quoteToPair);
        }
        uint256 liquidity = IDexPair(dexPair).mint(DEAD);
        if (toBurn > 0) token.burn(toBurn);
        emit Migrated(dexPair, quoteToPair, tokensToPair, toBurn, fee, liquidity);
    }

    /// @dev Sync then Swap, in the order a Uniswap V2 pair emits them.
    function _swapEvent(address sender, address to, uint256 tokenIn, uint256 quoteIn, uint256 tokenOut, uint256 quoteOut) private {
        (uint112 r0, uint112 r1, ) = getReserves();
        emit Sync(r0, r1);
        if (token0 == address(token)) emit Swap(sender, tokenIn, quoteIn, tokenOut, quoteOut, to);
        else emit Swap(sender, quoteIn, tokenIn, quoteOut, tokenOut, to);
    }

    function _u112(uint256 x) private pure returns (uint112) { return x > type(uint112).max ? type(uint112).max : uint112(x); }

    function _pull(uint256 amount) private {
        if (quote == address(0)) {
            require(msg.value == amount, "value");
        } else {
            require(msg.value == 0, "value");
            uint256 before = IERC20(quote).balanceOf(address(this));
            IERC20(quote).safeTransferFrom(msg.sender, address(this), amount);
            require(IERC20(quote).balanceOf(address(this)) - before == amount, "quote delta");
        }
    }

    function _pay(address to, uint256 amount) private {
        if (amount == 0) return;
        if (quote == address(0)) {
            (bool ok, ) = to.call{value: amount}("");
            require(ok, "payout");
        } else {
            IERC20(quote).safeTransfer(to, amount);
        }
    }
}
