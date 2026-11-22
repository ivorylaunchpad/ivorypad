// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev What the token reads from its market.
interface IIvoryMarketView {
    function buyTax() external view returns (uint16);
    function sellTax() external view returns (uint16);
    function creatorBps() external view returns (uint16);
    function holderBps() external view returns (uint16);
    function treasury() external view returns (address);
    function recipient() external view returns (address);
    function forwardQuote(uint256 amount) external;
}

/// @dev The WhiteSwap (Uniswap V2 style) router calls the token makes after graduation.
interface IDexRouter {
    function swapExactTokensForNativeSupportingFeeOnTransferTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external;
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external;
}

/// @notice Fixed-supply launch token. Holders earn the quote asset by balance and can burn.
/// Before graduation every trade happens in the coin's own market, which charges the fees, and the
/// token has no transfer tax. Once the market graduates and moves its liquidity to the coin's WhiteSwap
/// pair, buys and sells against that pair pay the same fees here: the fixed 0.3% protocol fee plus the
/// coin's own tax (read live from its market, so it can only go down). Fee tokens are sold for the quote
/// asset in small batches during later sells and paid out to the treasury, the creator and holders; the
/// buyback share is burned on the spot. Wallet to wallet transfers are never taxed.
contract IvoryToken is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint256 public constant SUPPLY = 1e27;
    uint256 private constant MAG = 2 ** 128;
    uint256 private constant BPS = 10000;
    uint256 public constant PROTOCOL_FEE_BPS = 30;
    /// @notice Fee tokens are sold once this many have piled up, and at most SWAP_MAX at a time.
    uint256 public constant SWAP_MIN = SUPPLY / 20000; // 0.005% of supply
    uint256 public constant SWAP_MAX = SUPPLY / 2000;  // 0.05% of supply
    address private constant DEAD = address(0xdead);

    address public immutable factory;
    /// @dev address(0) means rewards are paid in native WBT.
    address public immutable quote;
    string public uri;
    address public market;
    address public exemptWallet;
    /// @notice The coin's WhiteSwap pair. Nothing can be sent to it before graduation.
    address public pair;
    address public router;
    /// @notice The quote as the DEX sees it (WWBT for a native WBT coin).
    address public pairQuote;
    bool public graduated;
    uint256 public antiSnipeUntil;
    uint256 public dividendSupply;
    uint256 public magnifiedRewardPerShare;
    mapping(address => int256) private correction;
    mapping(address => uint256) public withdrawnRewards;
    mapping(address => bool) public excluded;

    /// @notice Fee tokens waiting to be sold, by destination.
    uint256 public feeTokensProtocol;
    uint256 public feeTokensCreator;
    uint256 public feeTokensHolders;
    /// @notice Quote owed from sold fee tokens, claimable by anyone to the treasury or the creator's recipient.
    uint256 public protocolOwed;
    uint256 public creatorOwed;
    bool private swapping;

    event RewardsDistributed(uint256 amount);
    event RewardClaimed(address indexed holder, uint256 amount);
    event Graduated(address pair);
    event DexFee(address indexed trader, bool isBuy, uint256 tokens, uint256 burned);
    event FeesSold(uint256 tokens, uint256 quoteOut);
    event FeesClaimed(address indexed to, uint256 amount, bool protocol);

    constructor(string memory name_, string memory symbol_, string memory uri_, address quote_, address lockVault, address factory_) ERC20(name_, symbol_) {
        factory = factory_;
        quote = quote_;
        uri = uri_;
        excluded[factory_] = true;
        excluded[address(0)] = true;
        excluded[DEAD] = true;
        excluded[lockVault] = true;
        excluded[address(this)] = true;
        _mint(factory_, SUPPLY);
    }

    receive() external payable {}

    /// @notice Nobody owns the token: fixed supply minted once at launch, no mint, no admin, no upgrade. Exposed as
    /// owner() = address(0) so explorers and token scanners show ownership as renounced.
    function owner() external pure returns (address) { return address(0); }

    function configure(address market_, address exempt, uint256 antiSnipeSeconds, address pair_, address router_, address pairQuote_) external {
        require(msg.sender == factory && market == address(0) && market_ != address(0) && pair_ != address(0), "configure");
        market = market_;
        exemptWallet = exempt;
        pair = pair_;
        router = router_;
        pairQuote = pairQuote_;
        excluded[market_] = true;
        excluded[pair_] = true;
        if (antiSnipeSeconds > 0) antiSnipeUntil = block.timestamp + antiSnipeSeconds;
    }

    /// @notice Called by the market right before it seeds the pair.
    function graduate() external {
        require(msg.sender == market && !graduated, "graduate");
        graduated = true;
        emit Graduated(pair);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (block.timestamp < antiSnipeUntil && to != market && to != address(0) && to != DEAD && to != exemptWallet && to != pair) {
            require(balanceOf(to) + value <= SUPPLY / 100, "anti-snipe: 1% wallet limit");
        }
        bool dexLeg = pair != address(0) && (from == pair || to == pair);
        if (dexLeg && !graduated) revert("pair opens at graduation");
        if (dexLeg && !swapping && value > 0 && from != address(this) && to != address(this) && from != market && to != market) {
            bool isSell = to == pair;
            if (isSell) _sellFees();
            IIvoryMarketView m = IIvoryMarketView(market);
            uint256 tax = isSell ? m.sellTax() : m.buyTax();
            uint256 fee = value * (PROTOCOL_FEE_BPS + tax) / BPS;
            if (fee > 0) {
                uint256 protocolPart = value * PROTOCOL_FEE_BPS / BPS;
                uint256 rest = fee - protocolPart;
                uint256 toCreator = rest * m.creatorBps() / BPS;
                uint256 toHolders = rest * m.holderBps() / BPS;
                uint256 toBurn = rest - toCreator - toHolders;
                feeTokensProtocol += protocolPart;
                feeTokensCreator += toCreator;
                feeTokensHolders += toHolders;
                _move(from, address(this), fee - toBurn);
                if (toBurn > 0) _move(from, address(0), toBurn);
                emit DexFee(isSell ? from : to, !isSell, fee, toBurn);
                value -= fee;
            }
        }
        _move(from, to, value);
    }

    /// @dev Balance move with holder-reward bookkeeping.
    function _move(address from, address to, uint256 value) private {
        uint256 m = magnifiedRewardPerShare;
        if (!excluded[from]) { correction[from] += int256(m * value); dividendSupply -= value; }
        if (!excluded[to]) { correction[to] -= int256(m * value); dividendSupply += value; }
        super._update(from, to, value);
    }

    /// @dev Sells a batch of fee tokens through the pair. Runs only inside a seller's transfer, never
    /// inside the pair's own swap, and a failure never blocks the trade that triggered it.
    function _sellFees() private {
        uint256 total = feeTokensProtocol + feeTokensCreator + feeTokensHolders;
        if (total < SWAP_MIN || router == address(0)) return;
        uint256 amount = total > SWAP_MAX ? SWAP_MAX : total;
        uint256 p = feeTokensProtocol * amount / total;
        uint256 c = feeTokensCreator * amount / total;
        uint256 h = amount - p - c;
        swapping = true;
        _approve(address(this), router, amount);
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = pairQuote;
        uint256 got;
        bool ok;
        if (quote == address(0)) {
            uint256 before = address(this).balance;
            try IDexRouter(router).swapExactTokensForNativeSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp) { ok = true; got = address(this).balance - before; } catch {}
        } else {
            // A V2 pair cannot pay out to one of its own tokens, so the quote lands at the market and is forwarded here.
            uint256 before = IERC20(quote).balanceOf(market);
            try IDexRouter(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, market, block.timestamp) {
                got = IERC20(quote).balanceOf(market) - before;
                if (got > 0) IIvoryMarketView(market).forwardQuote(got);
                ok = true;
            } catch {}
        }
        _approve(address(this), router, 0);
        swapping = false;
        if (!ok) return;
        feeTokensProtocol -= p;
        feeTokensCreator -= c;
        feeTokensHolders -= h;
        if (got == 0) return;
        uint256 toProtocol = got * p / amount;
        uint256 toCreator = got * c / amount;
        uint256 toHolders = got - toProtocol - toCreator;
        creatorOwed += toCreator;
        if (dividendSupply > 0 && toHolders > 0) {
            magnifiedRewardPerShare += toHolders * MAG / dividendSupply;
            emit RewardsDistributed(toHolders);
        } else {
            toProtocol += toHolders;
        }
        protocolOwed += toProtocol;
        emit FeesSold(amount, got);
    }

    /// @notice Anyone can push the protocol's share of DEX fees to the treasury.
    function claimProtocol() external nonReentrant returns (uint256 amount) {
        amount = protocolOwed;
        require(amount > 0, "nothing owed");
        protocolOwed = 0;
        address to = IIvoryMarketView(market).treasury();
        _pay(to, amount);
        emit FeesClaimed(to, amount, true);
    }

    /// @notice Anyone can push the creator's share of DEX fees to the creator's recipient. It moves only
    /// fees already sold for quote, so it never touches the pool, the price or the supply.
    function claimCreator() external nonReentrant returns (uint256 amount) {
        amount = creatorOwed;
        require(amount > 0, "nothing owed");
        creatorOwed = 0;
        address to = IIvoryMarketView(market).recipient();
        _pay(to, amount);
        emit FeesClaimed(to, amount, false);
    }

    function burn(uint256 amount) external { _burn(msg.sender, amount); }

    /// @notice Called by the market only when dividendSupply is nonzero.
    function distributeReward(uint256 amount) external payable nonReentrant {
        require(msg.sender == market && dividendSupply > 0 && amount > 0, "distribution");
        if (quote == address(0)) {
            require(msg.value == amount, "value");
        } else {
            require(msg.value == 0, "value");
            IERC20(quote).safeTransferFrom(msg.sender, address(this), amount);
        }
        magnifiedRewardPerShare += amount * MAG / dividendSupply;
        emit RewardsDistributed(amount);
    }

    function cumulativeRewardOf(address holder) public view returns (uint256) {
        int256 value = correction[holder] + int256(magnifiedRewardPerShare * (excluded[holder] ? 0 : balanceOf(holder)));
        return value > 0 ? uint256(value) / MAG : 0;
    }

    function withdrawableRewardOf(address holder) public view returns (uint256) {
        uint256 total = cumulativeRewardOf(holder);
        uint256 done = withdrawnRewards[holder];
        return total > done ? total - done : 0;
    }

    function claimRewards() external nonReentrant returns (uint256 value) {
        value = withdrawableRewardOf(msg.sender);
        require(value > 0, "no rewards");
        withdrawnRewards[msg.sender] += value;
        _pay(msg.sender, value);
        emit RewardClaimed(msg.sender, value);
    }

    function _pay(address to, uint256 amount) private {
        if (quote == address(0)) {
            (bool ok, ) = to.call{value: amount}("");
            require(ok, "payout");
        } else {
            IERC20(quote).safeTransfer(to, amount);
        }
    }
}
