// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {IvoryToken} from "./IvoryToken.sol";
import {IvoryMarket} from "./IvoryMarket.sol";

/// @notice Holds the token creation code, so the factory stays under the EVM code size limit.
contract IvoryTokenDeployer {
    bool public constant isIvoryTokenDeployer = true;

    function deploy(string calldata name, string calldata symbol, string calldata uri, address quote, address lockVault, address factory) external returns (IvoryToken) {
        return new IvoryToken(name, symbol, uri, quote, lockVault, factory);
    }
}

/// @notice Holds the market creation code, for the same reason.
contract IvoryMarketDeployer {
    bool public constant isIvoryMarketDeployer = true;

    function deploy(IvoryMarket.Init calldata init) external returns (IvoryMarket) {
        return new IvoryMarket(init);
    }
}
