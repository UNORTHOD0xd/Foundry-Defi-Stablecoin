// SPDX-License-Identifier: MIT

//////////////////////////////////////////////////////////////////////////////
//                         ORACLE LIBRARY NOTES                             //
//////////////////////////////////////////////////////////////////////////////
//
//
// WHY CHAINLINK?
// - DECENTRALIZED: Multiple independent nodes report prices
// - MANIPULATION RESISTANT: Aggregates data from many sources
// - RELIABLE: Battle-tested, secures billions in DeFi TVL
// - Alternative: Centralized oracles (single point of failure = bad!)
//
// CHAINLINK PRICE FEED RETURN VALUES:
// - roundId: Unique identifier for this price update round
// - answer: The actual price (e.g., ETH/USD = 350000000000 = $3500.00)
// - startedAt: Timestamp when this round started
// - updatedAt: Timestamp when the price was last updated (CRITICAL!)
// - answeredInRound: The round in which the answer was computed
//
// WHY STALENESS CHECKS MATTER:
// - If Chainlink stops updating (network issues, node failures), old prices persist
// - Old prices can be EXPLOITED:
//   Example: ETH was $3500 yesterday, crashed to $2000 today
//   If we use stale $3500 price, users can mint more DSC than they should!
// - TIMEOUT = 3 hours: If price is older than 3 hours, reject it
// - This makes the protocol "fail closed" - safer to halt than use bad data
//
// COMMON ORACLE ATTACK VECTORS:
// - FLASH LOAN MANIPULATION: Attackers use flash loans to move DEX prices
//   Chainlink is resistant because it uses off-chain data sources
// - STALE PRICE EXPLOITATION: Using old prices to profit (we prevent this!)
// - ORACLE FAILURE: If all nodes go down, protocol should halt (we do this!)
//
// USING THIS LIBRARY:
// - Declared as: using OracleLib for AggregatorV3Interface;
// - Called as: priceFeed.staleCheckLatestRoundData();
// - This syntax is possible because of "library ... for Type" pattern
//
//////////////////////////////////////////////////////////////////////////////

pragma solidity ^0.8.18;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleLib
 * @author unorthod0xd
 * @notice This library is used to check the Chainlink Oracle for stale price data.
 * If the data is stale, the function will revert and render the DSCEngine unusable - this is by design.
 * We want the protocol to freeze if prices become unreliable, rather than operate with bad data.
 */
library OracleLib {
    error OracleLib__StalePrice();

    // 3 hours = 10800 seconds
    // Why 3 hours? Chainlink ETH/USD updates every ~1 hour on mainnet
    // 3 hours gives buffer for network congestion while catching real outages
    uint256 private constant TIMEOUT = 3 hours;

    /**
     * @notice Fetches the latest price data from a Chainlink price feed with staleness validation
     * @param priceFeed The Chainlink AggregatorV3Interface price feed to query
     * @return roundId The round ID of this price update
     * @return answer The price (with 8 decimals for USD pairs)
     * @return startedAt When this round started
     * @return updatedAt When the price was last updated (used for staleness check)
     * @return answeredInRound The round in which the answer was computed
     * @dev Reverts with OracleLib__StalePrice if data is older than TIMEOUT
     * @dev This is a "wrapper" function - it calls the original and adds validation
     */
    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();

        // Calculate how long ago the price was updated
        uint256 secondsSince = block.timestamp - updatedAt;

        // If price is too old, revert - don't allow operations with stale data
        if (secondsSince > TIMEOUT) revert OracleLib__StalePrice();

        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
