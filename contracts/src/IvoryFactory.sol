// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IvoryToken} from "./IvoryToken.sol";
import {IvoryMarket} from "./IvoryMarket.sol";
import {IvoryTokenDeployer, IvoryMarketDeployer} from "./IvoryDeployers.sol";

interface IDexFactory { function createPair(address tokenA, address tokenB) external returns (address pair); }

/// @notice Creates a token and its market atomically. The owner can pause new launches and
/// manage quote assets, and cannot touch any live market. It also exposes the Uniswap V2 factory
/// views and PairCreated event, so DEX indexers find every market.
contract IvoryFactory is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint256 public constant MAX_FIRST_BUY = 5e25; // 5% of supply
    uint256 public constant ANTI_SNIPE_SECONDS = 60;
    uint256 public constant MAX_LAUNCH_FEE = 1 ether;

    struct Params {
        string name;
        string symbol;
        string uri;
        address quote;
        address recipient;
        uint16 buyTax;
        uint16 sellTax;
        uint16 creatorBps;
        uint16 holderBps;
        uint16 buybackBps;
        bool antiSnipe;
        uint256 firstBuy;
        uint256 minFirstBuyTokens;
        uint256 deadline;
    }
    struct Launch {
        address token;
        address market;
        address creator;
        address quote;
        uint64 createdAt;
    }

    address public treasury;
    address public immutable lockVault;
    IvoryTokenDeployer public immutable tokenDeployer;
    IvoryMarketDeployer public immutable marketDeployer;
    /// @notice Wrapped WBT (WWBT): what indexers see as the pair asset of a native WBT market.
    address public immutable wrappedNative;
    /// @notice WhiteSwap factory and router: every coin gets an empty pair at launch and moves there at graduation.
    address public immutable dexFactory;
    address public immutable dexRouter;
    bool public paused;
    /// @notice False: only the owner and the wallets on the launcher list can launch coins (invite-only). True: anyone.
    bool public openLaunch;
    /// @notice Wallets allowed to launch while launching is invite-only.
    mapping(address => bool) public launcher;
    /// @notice Paid to the treasury in native WBT on every launch, whatever the pair is.
    uint256 public launchFee;
    /// @notice Opening virtual quote reserve per quote asset. Zero means disabled; address(0) is native WBT.
    mapping(address => uint256) public startQuote;
    /// @notice Real quote a pool must raise to graduate, per quote asset. Zero means coins on it never graduate.
    mapping(address => uint256) public graduationRaise;
    Launch[] public launches;
    mapping(address => uint256) private indexPlusOne;
    mapping(address => mapping(address => address)) public getPair;

    event LaunchCreated(uint256 indexed id, address indexed token, address indexed market, address creator, address quote, string name, string symbol, string uri);
    event QuoteSet(address indexed quote, uint256 startQuote, uint256 graduationRaise);
    event PausedSet(bool paused);
    event OpenLaunchSet(bool open);
    event LauncherSet(address indexed wallet, bool allowed);
    event TreasurySet(address treasury);
    event LaunchFeeSet(uint256 launchFee);
    event PairCreated(address indexed token0, address indexed token1, address pair, uint256 allPairsLength);

    constructor(address owner_, address treasury_, address lockVault_, IvoryTokenDeployer tokenDeployer_, IvoryMarketDeployer marketDeployer_, uint256 nativeStart, uint256 nativeGraduation, uint256 launchFee_, address wrappedNative_, address dexFactory_, address dexRouter_) Ownable(owner_) {
        require(treasury_ != address(0) && lockVault_ != address(0) && wrappedNative_ != address(0) && dexFactory_ != address(0) && dexRouter_ != address(0) && nativeStart > 0 && launchFee_ <= MAX_LAUNCH_FEE, "config");
        wrappedNative = wrappedNative_;
        dexFactory = dexFactory_;
        dexRouter = dexRouter_;
        launchFee = launchFee_;
        treasury = treasury_;
        lockVault = lockVault_;
        tokenDeployer = tokenDeployer_;
        marketDeployer = marketDeployer_;
        startQuote[address(0)] = nativeStart;
        graduationRaise[address(0)] = nativeGraduation;
        emit QuoteSet(address(0), nativeStart, nativeGraduation);
    }

    /// @notice Settings apply to coins launched afterwards; live coins keep the values they launched with.
    function setQuote(address quote, uint256 start, uint256 graduation) external onlyOwner {
        startQuote[quote] = start;
        graduationRaise[quote] = graduation;
        emit QuoteSet(quote, start, graduation);
    }
    function setPaused(bool value) external onlyOwner { paused = value; emit PausedSet(value); }
    /// @notice Opens launching to everyone (true) or keeps it to the owner and the launcher list (false).
    function setOpenLaunch(bool value) external onlyOwner { openLaunch = value; emit OpenLaunchSet(value); }
    function setLaunchers(address[] calldata wallets, bool allowed) external onlyOwner {
        for (uint256 i = 0; i < wallets.length; i++) { launcher[wallets[i]] = allowed; emit LauncherSet(wallets[i], allowed); }
    }
    function canLaunch(address wallet) public view returns (bool) { return openLaunch || wallet == owner() || launcher[wallet]; }
    function setTreasury(address value) external onlyOwner { require(value != address(0), "treasury"); treasury = value; emit TreasurySet(value); }
    function setLaunchFee(uint256 value) external onlyOwner { require(value <= MAX_LAUNCH_FEE, "fee cap"); launchFee = value; emit LaunchFeeSet(value); }
    function launchCount() external view returns (uint256) { return launches.length; }
    function allPairsLength() external view returns (uint256) { return launches.length; }
    function allPairs(uint256 i) external view returns (address) { return launches[i].market; }
    function isLaunchToken(address token) external view returns (bool) { return indexPlusOne[token] != 0; }

    function launchOf(address token) external view returns (Launch memory) {
        uint256 i = indexPlusOne[token];
        require(i != 0, "unknown token");
        return launches[i - 1];
    }

    function createLaunch(Params calldata p) external payable nonReentrant returns (address token, address market) {
        require(!paused, "paused");
        require(canLaunch(msg.sender), "launch: invite only");
        require(block.timestamp <= p.deadline, "deadline");
        _validate(p);
        uint256 fee = launchFee;
        require(msg.value == fee + (p.quote == address(0) ? p.firstBuy : 0), "value");
        if (fee > 0) {
            (bool ok, ) = treasury.call{value: fee}("");
            require(ok, "fee");
        }
        (token, market) = _deploy(p);
        launches.push(Launch(token, market, msg.sender, p.quote, uint64(block.timestamp)));
        indexPlusOne[token] = launches.length;
        emit LaunchCreated(launches.length - 1, token, market, msg.sender, p.quote, p.name, p.symbol, p.uri);
        address pairQuote = _pairQuote(p.quote);
        getPair[token][pairQuote] = market;
        getPair[pairQuote][token] = market;
        (address t0, address t1) = token < pairQuote ? (token, pairQuote) : (pairQuote, token);
        emit PairCreated(t0, t1, market, launches.length);
        if (p.firstBuy > 0) _firstBuy(p, IvoryMarket(payable(market)));
    }

    function _validate(Params calldata p) private view {
        uint256 nameLength = bytes(p.name).length;
        uint256 symbolLength = bytes(p.symbol).length;
        require(nameLength >= 1 && nameLength <= 32 && symbolLength >= 1 && symbolLength <= 12 && bytes(p.uri).length <= 512, "metadata");
        require(startQuote[p.quote] > 0, "quote disabled");
        require(p.buyTax <= 1000 && p.sellTax <= 1000, "tax range");
        require(uint256(p.creatorBps) + p.holderBps + p.buybackBps == 10000, "split");
    }

    function _deploy(Params calldata p) private returns (address token, address market) {
        address recipient = p.recipient == address(0) ? msg.sender : p.recipient;
        IvoryToken created = tokenDeployer.deploy(p.name, p.symbol, p.uri, p.quote, lockVault, address(this));
        // A brand-new token has no pair yet, so this cannot be front-run. Transfers to it stay blocked until graduation.
        address dexPair = IDexFactory(dexFactory).createPair(address(created), _pairQuote(p.quote));
        IvoryMarket createdMarket = marketDeployer.deploy(IvoryMarket.Init({
            token: created, quote: p.quote, startQuote: startQuote[p.quote], graduationRaise: graduationRaise[p.quote], creator: msg.sender, recipient: recipient,
            treasury: treasury, buyTax: p.buyTax, sellTax: p.sellTax,
            creatorBps: p.creatorBps, holderBps: p.holderBps, buybackBps: p.buybackBps,
            factory: address(this), pairQuote: _pairQuote(p.quote), dexPair: dexPair
        }));
        token = address(created);
        market = address(createdMarket);
        created.configure(market, msg.sender, p.antiSnipe ? ANTI_SNIPE_SECONDS : 0, dexPair, dexRouter, _pairQuote(p.quote));
        IERC20(token).safeTransfer(market, created.SUPPLY());
    }

    function _pairQuote(address quote) private view returns (address) { return quote == address(0) ? wrappedNative : quote; }

    function _firstBuy(Params calldata p, IvoryMarket market) private {
        uint256 tokens;
        if (p.quote == address(0)) {
            tokens = market.buy{value: p.firstBuy}(p.firstBuy, p.minFirstBuyTokens, p.deadline, msg.sender);
        } else {
            IERC20(p.quote).safeTransferFrom(msg.sender, address(this), p.firstBuy);
            IERC20(p.quote).forceApprove(address(market), p.firstBuy);
            tokens = market.buy(p.firstBuy, p.minFirstBuyTokens, p.deadline, msg.sender);
        }
        require(tokens <= MAX_FIRST_BUY, "first buy above 5%");
    }
}
