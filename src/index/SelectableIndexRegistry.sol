// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IIndexPriceSource, IMemeBasketIndex} from "./IIndexPriceSource.sol";
import {IMemeDaqLaunchpad} from "../interfaces/IMemeDaqLaunchpad.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {DidxBasketRegistry} from "./DidxBasketRegistry.sol";

interface ISelectableBasketIndex is IMemeBasketIndex {
    struct Component { address token; IIndexPriceSource source; uint16 weightBps; uint256 basePriceE18; }
    function getConstituents() external view returns (Component[] memory);
    function revision() external view returns (uint256);
}

/// @notice Owner-approved four-member benchmarks. A registered composition and baseline are sealed forever.
///         Disabling stops new launches, but does not change an existing token's benchmark.
///         Price sources must be reviewed before approval; this registry does not audit their implementations.
contract SelectableIndexRegistry {
    address public immutable launchpad;
    mapping(address => bytes32) public compositionHash;
    mapping(address => bool) public indexEnabled;
    address[] private _indexes;

    error NotLaunchpad();
    error BadIndex();
    error IndexNotEnabled(address oracle);
    error IndexCompositionChanged(address oracle);
    event IndexRegistered(address indexed oracle, bytes32 compositionHash);
    event IndexEnabled(address indexed oracle, bool enabled);

    constructor() { launchpad = msg.sender; }

    /// @dev Stateless validation kept outside the launchpad to stay within EIP-170's runtime limit.
    function validateQuote(address currency, IMemeDaqLaunchpad.QuoteConfig calldata cfg, address defaultBasket, DidxBasketRegistry registry) external view {
        bool basketHub = currency == defaultBasket || (address(registry) != address(0) && registry.isBasket(currency));
        if (currency == address(0)) {
            if (!cfg.isHub || !cfg.enabled || cfg.source != IMemeDaqLaunchpad.PriceSource.CHAINLINK || cfg.decimals != 18) revert IMemeDaqLaunchpad.BadConfig();
        } else if ((cfg.isHub && !basketHub) || cfg.decimals != IERC20Metadata(currency).decimals()) revert IMemeDaqLaunchpad.BadConfig();
        if (cfg.decimals > 18 || cfg.maxWeightBps > 10000) revert IMemeDaqLaunchpad.BadConfig();
        if (cfg.enabled) {
            if (cfg.maxWeightBps == 0 || cfg.source == IMemeDaqLaunchpad.PriceSource.NONE) revert IMemeDaqLaunchpad.BadConfig();
            if (cfg.source != IMemeDaqLaunchpad.PriceSource.USD_PEG && cfg.maxAge == 0) revert IMemeDaqLaunchpad.BadConfig();
            if (cfg.source == IMemeDaqLaunchpad.PriceSource.CHAINLINK && cfg.feed == address(0)) revert IMemeDaqLaunchpad.BadConfig();
        }
    }

    modifier onlyLaunchpad() {
        if (msg.sender != launchpad) revert NotLaunchpad();
        _;
    }

    function registerIndex(address oracle) external onlyLaunchpad {
        if (oracle.code.length == 0 || compositionHash[oracle] != bytes32(0)) revert BadIndex();
        ISelectableBasketIndex candidate = ISelectableBasketIndex(oracle);
        ISelectableBasketIndex.Component[] memory members = candidate.getConstituents();
        uint256 revision = candidate.revision();
        if (members.length != 4 || revision == 0) revert BadIndex();
        for (uint256 i; i < 4; ++i) {
            ISelectableBasketIndex.Component memory c = members[i];
            if (c.token.code.length == 0 || address(c.source).code.length == 0 || c.weightBps != 2500
                || c.basePriceE18 == 0 || c.source.baseToken() != c.token) revert BadIndex();
            for (uint256 j; j < i; ++j) if (c.token == members[j].token) revert BadIndex();
        }
        (uint256 points, uint256 time) = candidate.latestIndex();
        if (points == 0 || time == 0 || time > block.timestamp) revert BadIndex();
        bytes32 fingerprint = keccak256(abi.encode(members, revision));
        compositionHash[oracle] = fingerprint;
        indexEnabled[oracle] = true;
        _indexes.push(oracle);
        emit IndexRegistered(oracle, fingerprint);
        emit IndexEnabled(oracle, true);
    }

    function setIndexEnabled(address oracle, bool enabled) external onlyLaunchpad {
        if (compositionHash[oracle] == bytes32(0)) revert BadIndex();
        if (enabled) verify(oracle, false);
        indexEnabled[oracle] = enabled;
        emit IndexEnabled(oracle, enabled);
    }

    function getIndexes() external view returns (address[] memory oracles, bool[] memory enabled) {
        oracles = _indexes;
        enabled = new bool[](oracles.length);
        for (uint256 i; i < oracles.length; ++i) enabled[i] = indexEnabled[oracles[i]];
    }

    function verify(address oracle, bool requireEnabled) public view {
        bytes32 expected = compositionHash[oracle];
        if (expected == bytes32(0) || (requireEnabled && !indexEnabled[oracle])) revert IndexNotEnabled(oracle);
        ISelectableBasketIndex candidate = ISelectableBasketIndex(oracle);
        if (keccak256(abi.encode(candidate.getConstituents(), candidate.revision())) != expected) {
            revert IndexCompositionChanged(oracle);
        }
    }
}
