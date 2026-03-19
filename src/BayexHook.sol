// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @title BayexHook
/// @notice A Uniswap v4 hook that captures arbitrage surplus and redistributes it to LPs
/// in prediction market conditional token pools via directional flow imbalance fees.
///
/// Core mechanism:
///   fee = baseFee + k * (netDirectionalFlow / totalFlow)^2
///
/// - beforeSwap: reads flow imbalance, computes dynamic fee, returns lpFeeOverride
/// - afterSwap: updates directional flow tracking with time decay
contract BayexHook is IHooks {
    using PoolIdLibrary for PoolKey;

    // ─── Errors ──────────────────────────────────────────────────────────
    error OnlyPoolManager();
    error PoolNotInitialized();
    error InvalidParameters();

    // ─── Events ──────────────────────────────────────────────────────────
    event PoolConfigured(PoolId indexed poolId, uint24 baseFee, uint256 k, uint256 windowSize, uint256 decayRate);
    event DynamicFeeApplied(PoolId indexed poolId, uint24 fee, uint256 imbalanceRatio);

    // ─── Structs ─────────────────────────────────────────────────────────

    struct PoolConfig {
        uint24 baseFee;      // Minimum fee in hundredths of bip (e.g., 3000 = 0.30%)
        uint256 k;           // Aggressiveness scalar (fixed-point 1e18 = 1.0)
        uint256 windowSize;  // Sliding window in seconds
        uint256 decayRate;   // Decay rate per second (fixed-point 1e18 = 1.0)
    }

    struct FlowState {
        int256 netFlow;         // Net directional flow (positive = zeroForOne dominant)
        uint256 totalFlow;      // Absolute total flow volume
        uint256 lastUpdateTime; // Timestamp of last update
    }

    // ─── Constants ───────────────────────────────────────────────────────
    uint256 internal constant WAD = 1e18;
    uint24 internal constant MAX_FEE = 1_000_000; // 100% in hundredths of bip

    // ─── Immutables ──────────────────────────────────────────────────────
    IPoolManager public immutable poolManager;

    // ─── Storage ─────────────────────────────────────────────────────────
    mapping(PoolId => PoolConfig) public poolConfigs;
    mapping(PoolId => FlowState) public flowStates;

    // ─── Modifiers ───────────────────────────────────────────────────────
    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────
    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    // ─── Hook Permission Flags ───────────────────────────────────────────

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─── Configuration ───────────────────────────────────────────────────

    /// @notice Configure the hook parameters for a pool. Called by pool deployer before initialization.
    /// @param key The pool key
    /// @param baseFee Minimum fee in hundredths of bip
    /// @param k Aggressiveness of surplus capture (1e18 = 1.0)
    /// @param windowSize Time window for flow tracking in seconds
    /// @param decayRate How quickly imbalance decays (1e18 per second = instant decay)
    function configurePool(
        PoolKey calldata key,
        uint24 baseFee,
        uint256 k,
        uint256 windowSize,
        uint256 decayRate
    ) external {
        if (baseFee > MAX_FEE) revert InvalidParameters();
        if (windowSize == 0) revert InvalidParameters();

        PoolId poolId = key.toId();
        poolConfigs[poolId] = PoolConfig({
            baseFee: baseFee,
            k: k,
            windowSize: windowSize,
            decayRate: decayRate
        });

        emit PoolConfigured(poolId, baseFee, k, windowSize, decayRate);
    }

    // ─── Hook Entry Points ───────────────────────────────────────────────

    function beforeInitialize(address, PoolKey calldata, uint160) external virtual returns (bytes4) {
        revert("not implemented");
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        virtual
        onlyPoolManager
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        // Initialize flow state
        flowStates[poolId] = FlowState({netFlow: 0, totalFlow: 0, lastUpdateTime: block.timestamp});
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert("not implemented");
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external virtual returns (bytes4, BalanceDelta) {
        revert("not implemented");
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external virtual returns (bytes4) {
        revert("not implemented");
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external virtual returns (bytes4, BalanceDelta) {
        revert("not implemented");
    }

    /// @notice Computes dynamic fee based on directional flow imbalance.
    /// fee = baseFee + k * (|netFlow| / totalFlow)^2
    /// Returns the fee as lpFeeOverride with OVERRIDE_FEE_FLAG set.
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        virtual
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        PoolConfig storage config = poolConfigs[poolId];
        FlowState storage state = flowStates[poolId];

        uint24 fee = config.baseFee;

        if (state.totalFlow > 0) {
            // Apply time decay to flow state before reading
            uint256 elapsed = block.timestamp - state.lastUpdateTime;
            (int256 decayedNet, uint256 decayedTotal) = _applyDecay(
                state.netFlow, state.totalFlow, elapsed, config.decayRate, config.windowSize
            );

            if (decayedTotal > 0) {
                // imbalanceRatio = |netFlow| / totalFlow (scaled by WAD)
                uint256 absNet = decayedNet >= 0 ? uint256(decayedNet) : uint256(-decayedNet);
                uint256 imbalanceRatio = (absNet * WAD) / decayedTotal;

                // surcharge = k * imbalanceRatio^2 / WAD
                // Result is in hundredths of bip (same units as baseFee)
                uint256 surcharge = (config.k * imbalanceRatio * imbalanceRatio) / (WAD * WAD);

                uint256 totalFee = uint256(config.baseFee) + surcharge;
                fee = totalFee > MAX_FEE ? MAX_FEE : uint24(totalFee);

                emit DynamicFeeApplied(poolId, fee, imbalanceRatio);
            }
        }

        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            fee | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    /// @notice Updates directional flow tracking after each swap.
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external virtual onlyPoolManager returns (bytes4, int128) {
        PoolId poolId = key.toId();
        PoolConfig storage config = poolConfigs[poolId];
        FlowState storage state = flowStates[poolId];

        // Apply decay first
        uint256 elapsed = block.timestamp - state.lastUpdateTime;
        (int256 decayedNet, uint256 decayedTotal) =
            _applyDecay(state.netFlow, state.totalFlow, elapsed, config.decayRate, config.windowSize);

        // Compute the absolute swap amount for flow tracking
        // amountSpecified: negative = exactInput, positive = exactOutput
        int256 swapAmount = params.amountSpecified;
        uint256 absAmount = swapAmount >= 0 ? uint256(swapAmount) : uint256(-swapAmount);

        // Update flow: zeroForOne swaps add positive flow, oneForZero add negative
        if (params.zeroForOne) {
            decayedNet += int256(absAmount);
        } else {
            decayedNet -= int256(absAmount);
        }
        decayedTotal += absAmount;

        state.netFlow = decayedNet;
        state.totalFlow = decayedTotal;
        state.lastUpdateTime = block.timestamp;

        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert("not implemented");
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert("not implemented");
    }

    // ─── Internal Helpers ────────────────────────────────────────────────

    /// @notice Applies exponential-like decay to flow state based on elapsed time.
    /// Uses linear decay approximation: factor = max(0, 1 - decayRate * elapsed / windowSize)
    function _applyDecay(
        int256 netFlow,
        uint256 totalFlow,
        uint256 elapsed,
        uint256 decayRate,
        uint256 windowSize
    ) internal pure returns (int256 decayedNet, uint256 decayedTotal) {
        if (elapsed == 0) {
            return (netFlow, totalFlow);
        }

        // decay = decayRate * elapsed / windowSize (capped at WAD = full decay)
        uint256 decayAmount = (decayRate * elapsed) / windowSize;

        if (decayAmount >= WAD) {
            // Full decay — reset flow state
            return (0, 0);
        }

        // factor = WAD - decayAmount
        uint256 factor = WAD - decayAmount;
        decayedNet = (netFlow * int256(factor)) / int256(WAD);
        decayedTotal = (totalFlow * factor) / WAD;
    }

    // ─── View Helpers ────────────────────────────────────────────────────

    /// @notice Returns the current imbalance ratio for a pool (scaled by WAD).
    function getImbalanceRatio(PoolKey calldata key) external view returns (uint256) {
        PoolId poolId = key.toId();
        PoolConfig storage config = poolConfigs[poolId];
        FlowState storage state = flowStates[poolId];

        if (state.totalFlow == 0) return 0;

        uint256 elapsed = block.timestamp - state.lastUpdateTime;
        (int256 decayedNet, uint256 decayedTotal) =
            _applyDecay(state.netFlow, state.totalFlow, elapsed, config.decayRate, config.windowSize);

        if (decayedTotal == 0) return 0;

        uint256 absNet = decayedNet >= 0 ? uint256(decayedNet) : uint256(-decayedNet);
        return (absNet * WAD) / decayedTotal;
    }

    /// @notice Returns the current dynamic fee for a pool (in hundredths of bip).
    function getCurrentFee(PoolKey calldata key) external view returns (uint24) {
        PoolId poolId = key.toId();
        PoolConfig storage config = poolConfigs[poolId];
        FlowState storage state = flowStates[poolId];

        if (state.totalFlow == 0) return config.baseFee;

        uint256 elapsed = block.timestamp - state.lastUpdateTime;
        (int256 decayedNet, uint256 decayedTotal) =
            _applyDecay(state.netFlow, state.totalFlow, elapsed, config.decayRate, config.windowSize);

        if (decayedTotal == 0) return config.baseFee;

        uint256 absNet = decayedNet >= 0 ? uint256(decayedNet) : uint256(-decayedNet);
        uint256 imbalanceRatio = (absNet * WAD) / decayedTotal;
        uint256 surcharge = (config.k * imbalanceRatio * imbalanceRatio) / (WAD * WAD);
        uint256 totalFee = uint256(config.baseFee) + surcharge;

        return totalFee > MAX_FEE ? MAX_FEE : uint24(totalFee);
    }
}
