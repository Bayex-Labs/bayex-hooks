// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Ownable2Step, Ownable} from "v4-core/lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "v4-core/lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/// @title BayexHook
/// @notice A Uniswap v4 hook for prediction market pools (USDC / conditional token)
/// that captures arbitrage surplus via directional flow imbalance fees and collects
/// fees primarily in USDC based on per-LP fee denomination preferences.
///
/// Core fee mechanism:
///   fee = baseFee + k * (netDirectionalFlow / totalFlow)^2
///
/// Fee collection:
///   - LP fees are NOT distributed via the pool's built-in mechanism (lpFeeOverride = 0)
///   - Hook takes fees from both swap sides using delta returns
///   - The USDC/token split is determined by aggregate LP preferences
///   - Each LP configures their preferred fee denomination (default 100% USDC)
///
/// @dev Known limitation: Fee distribution is proportional to ALL tracked LP liquidity,
/// not just in-range liquidity. Out-of-range positions earn fees they wouldn't earn in
/// the standard v4 fee mechanism. For prediction markets with narrow bounded price
/// ranges, this is mitigated by using wide tick ranges. A production upgrade would
/// replicate Uniswap's tick-based feeGrowthInside accounting for precise in-range
/// distribution.
contract BayexHook is IHooks, Ownable2Step, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using BalanceDeltaLibrary for BalanceDelta;

    // ─── Errors ──────────────────────────────────────────────────────────
    error OnlyPoolManager();
    error PoolNotInitialized();
    error InvalidParameters();
    error InvalidHookData();
    error InvalidFeeSplit();
    error NoPosition();
    error InsufficientLiquidity();
    error UntrustedRouter();
    error TransferFailed();

    // ─── Events ──────────────────────────────────────────────────────────
    event PoolConfigured(PoolId indexed poolId, uint24 baseFee, uint256 k, uint256 windowSize, uint256 decayRate);
    event DynamicFeeApplied(PoolId indexed poolId, uint24 fee, uint256 imbalanceRatio);
    event LPPositionUpdated(
        PoolId indexed poolId, address indexed lp, int24 tickLower, int24 tickUpper, uint128 liquidity
    );
    event FeeSplitConfigured(PoolId indexed poolId, address indexed lp, uint256 feeSplitUSDC);
    event FeesClaimed(address indexed lp, uint256 usdcAmount, uint256 tokenAmount);
    event FeesCollected(PoolId indexed poolId, uint256 usdcFee, uint256 tokenFee);
    event TrustedRouterSet(address indexed router, bool trusted);

    // ─── Structs ─────────────────────────────────────────────────────────

    struct PoolConfig {
        uint24 baseFee; // Minimum fee in hundredths of bip (e.g., 3000 = 0.30%)
        uint256 k; // Aggressiveness scalar (fixed-point 1e18 = 1.0)
        uint256 windowSize; // Sliding window in seconds
        uint256 decayRate; // Decay rate per second (fixed-point 1e18 = 1.0)
    }

    struct FlowState {
        int256 netFlow; // Net directional flow (positive = zeroForOne dominant)
        uint256 totalFlow; // Absolute total flow volume
        uint256 lastUpdateTime; // Timestamp of last update
    }

    struct LPPosition {
        uint128 liquidity;
        uint256 feeSplitUSDC; // WAD = 100% USDC, 0 = 100% token
        uint256 accruedFeesUSDC; // Snapshotted unclaimed USDC fees
        uint256 accruedFeesToken; // Snapshotted unclaimed token fees
        uint256 feePerLiqUSDCCheckpoint; // feePerLiquidityUSDC at last snapshot
        uint256 feePerLiqTokenCheckpoint; // feePerLiquidityToken at last snapshot
    }

    struct FeeState {
        uint256 feePerLiquidityUSDC; // Accumulated USDC fees per unit of USDC-weighted liquidity
        uint256 feePerLiquidityToken; // Accumulated token fees per unit of token-weighted liquidity
        uint256 totalLiquidity; // Total tracked LP liquidity
        uint256 totalUSDCWeight; // sum(LP_liquidity * LP_feeSplitUSDC / WAD)
        uint256 totalTokenWeight; // sum(LP_liquidity * (WAD - LP_feeSplitUSDC) / WAD)
    }

    // ─── Constants ───────────────────────────────────────────────────────
    uint256 internal constant WAD = 1e18;
    uint24 internal constant MAX_FEE = 1_000_000; // 100% in hundredths of bip

    // Transient storage slots for passing data between beforeSwap and afterSwap.
    // Slots 1-4 are safe from collision: transient storage is per-contract and per-tx,
    // and only this contract writes to its own transient slots within a single swap.

    // ─── Immutables ──────────────────────────────────────────────────────
    IPoolManager public immutable poolManager;

    // ─── Storage ─────────────────────────────────────────────────────────
    mapping(PoolId => PoolConfig) public poolConfigs;
    mapping(PoolId => FlowState) public flowStates;
    mapping(PoolId => FeeState) public feeStates;
    mapping(bytes32 => LPPosition) public lpPositions;
    mapping(address => bool) public trustedRouters;

    // ─── Modifiers ───────────────────────────────────────────────────────
    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────
    constructor(IPoolManager _poolManager, address _owner) Ownable(_owner) {
        poolManager = _poolManager;
    }

    // ─── Hook Permission Flags ───────────────────────────────────────────

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─── Admin Functions ─────────────────────────────────────────────────

    /// @notice Configure the hook parameters for a pool. Owner only.
    function configurePool(PoolKey calldata key, uint24 baseFee, uint256 k, uint256 windowSize, uint256 decayRate)
        external
        onlyOwner
    {
        if (baseFee > MAX_FEE) revert InvalidParameters();
        if (windowSize == 0) revert InvalidParameters();

        PoolId poolId = key.toId();
        poolConfigs[poolId] = PoolConfig({baseFee: baseFee, k: k, windowSize: windowSize, decayRate: decayRate});

        emit PoolConfigured(poolId, baseFee, k, windowSize, decayRate);
    }

    /// @notice Set whether a router contract is trusted for LP operations.
    /// @dev Trusted routers are responsible for encoding the correct `msg.sender`
    /// as the LP address in hookData. Only liquidity operations from trusted
    /// routers are accepted, preventing LP address spoofing.
    function setTrustedRouter(address router, bool trusted) external onlyOwner {
        trustedRouters[router] = trusted;
        emit TrustedRouterSet(router, trusted);
    }

    // ─── LP Fee Split Configuration ──────────────────────────────────────

    /// @notice LP configures their preferred USDC fee split for a position.
    /// @param key The pool key
    /// @param tickLower Lower tick of the position
    /// @param tickUpper Upper tick of the position
    /// @param salt Position salt
    /// @param newSplitUSDC New USDC split (WAD = 100% USDC, 0 = 100% token)
    function configureFeeSplit(PoolKey calldata key, int24 tickLower, int24 tickUpper, bytes32 salt, uint256 newSplitUSDC)
        external
    {
        if (newSplitUSDC > WAD) revert InvalidFeeSplit();

        PoolId poolId = key.toId();
        bytes32 posKey = _positionKey(poolId, msg.sender, tickLower, tickUpper, salt);
        LPPosition storage pos = lpPositions[posKey];

        if (pos.liquidity == 0) revert NoPosition();

        FeeState storage fState = feeStates[poolId];

        // Snapshot current fees at old split before changing
        _snapshotFees(pos, fState);

        // Remove old weights
        uint256 oldUSDCWeight = (uint256(pos.liquidity) * pos.feeSplitUSDC) / WAD;
        uint256 oldTokenWeight = (uint256(pos.liquidity) * (WAD - pos.feeSplitUSDC)) / WAD;
        fState.totalUSDCWeight -= oldUSDCWeight;
        fState.totalTokenWeight -= oldTokenWeight;

        // Update split
        pos.feeSplitUSDC = newSplitUSDC;

        // Add new weights
        uint256 newUSDCWeight = (uint256(pos.liquidity) * newSplitUSDC) / WAD;
        uint256 newTokenWeight = (uint256(pos.liquidity) * (WAD - newSplitUSDC)) / WAD;
        fState.totalUSDCWeight += newUSDCWeight;
        fState.totalTokenWeight += newTokenWeight;

        emit FeeSplitConfigured(poolId, msg.sender, newSplitUSDC);
    }

    // ─── Fee Claims ──────────────────────────────────────────────────────

    /// @notice LP claims their accrued fees for a position.
    function claimFees(PoolKey calldata key, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        nonReentrant
    {
        PoolId poolId = key.toId();
        bytes32 posKey = _positionKey(poolId, msg.sender, tickLower, tickUpper, salt);
        LPPosition storage pos = lpPositions[posKey];

        if (pos.liquidity == 0 && pos.accruedFeesUSDC == 0 && pos.accruedFeesToken == 0) {
            revert NoPosition();
        }

        FeeState storage fState = feeStates[poolId];

        // Snapshot to capture any pending fees
        _snapshotFees(pos, fState);

        uint256 usdcAmount = pos.accruedFeesUSDC;
        uint256 tokenAmount = pos.accruedFeesToken;

        pos.accruedFeesUSDC = 0;
        pos.accruedFeesToken = 0;

        // Transfer USDC (currency0) and token (currency1) to LP
        if (usdcAmount > 0) {
            _safeTransfer(Currency.unwrap(key.currency0), msg.sender, usdcAmount);
        }
        if (tokenAmount > 0) {
            _safeTransfer(Currency.unwrap(key.currency1), msg.sender, tokenAmount);
        }

        emit FeesClaimed(msg.sender, usdcAmount, tokenAmount);
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
        flowStates[poolId] = FlowState({netFlow: 0, totalFlow: 0, lastUpdateTime: block.timestamp});
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external virtual onlyPoolManager returns (bytes4) {
        if (!trustedRouters[sender]) revert UntrustedRouter();
        if (hookData.length < 32) revert InvalidHookData();
        if (params.liquidityDelta <= 0) revert InvalidParameters();
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata hookData
    ) external virtual onlyPoolManager returns (bytes4, BalanceDelta) {
        _processAddLiquidity(key, params, hookData);
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata hookData
    ) external virtual onlyPoolManager returns (bytes4) {
        if (!trustedRouters[sender]) revert UntrustedRouter();
        if (hookData.length < 32) revert InvalidHookData();
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata hookData
    ) external virtual onlyPoolManager returns (bytes4, BalanceDelta) {
        _processRemoveLiquidity(key, params, hookData);
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @notice Computes dynamic fee and takes fee from the specified (input) side.
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        virtual
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        FeeState storage fState = feeStates[poolId];
        uint24 feePercent = _computeFee(poolConfigs[poolId], flowStates[poolId], params);

        // If no LPs tracked, fall back to standard lpFeeOverride
        if (fState.totalLiquidity == 0) {
            return (
                IHooks.beforeSwap.selector,
                toBeforeSwapDelta(int128(0), int128(0)),
                feePercent | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
        }

        uint256 aggregateUSDCSplit = (fState.totalUSDCWeight * WAD) / fState.totalLiquidity;
        uint256 specifiedFee = _computeSpecifiedFee(params, feePercent, aggregateUSDCSplit);

        // Only take if there is weight to distribute to; otherwise fees would be stuck
        if (specifiedFee > 0) {
            bool specifiedIsUSDC = (params.amountSpecified < 0) == params.zeroForOne;
            bool hasWeight = specifiedIsUSDC ? fState.totalUSDCWeight > 0 : fState.totalTokenWeight > 0;
            if (!hasWeight) {
                specifiedFee = 0;
            } else {
                poolManager.take(specifiedIsUSDC ? key.currency0 : key.currency1, address(this), specifiedFee);
            }
        }

        // Store data in transient storage for afterSwap
        assembly {
            tstore(1, feePercent)
            tstore(2, aggregateUSDCSplit)
            tstore(3, specifiedFee)
        }
        {
            bool specifiedIsUSDC = (params.amountSpecified < 0) == params.zeroForOne;
            assembly {
                tstore(4, specifiedIsUSDC)
            }
        }

        return (
            IHooks.beforeSwap.selector,
            toBeforeSwapDelta(int128(uint128(specifiedFee)), int128(0)),
            LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    /// @notice Takes fee from the unspecified (output) side and updates fee accumulators.
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external virtual onlyPoolManager returns (bytes4, int128) {
        PoolId poolId = key.toId();
        _updateFlowState(poolConfigs[poolId], flowStates[poolId], params);

        FeeState storage fState = feeStates[poolId];
        if (fState.totalLiquidity == 0) {
            return (IHooks.afterSwap.selector, int128(0));
        }

        uint256 unspecifiedFee = _collectUnspecifiedFee(key, delta, fState);
        return (IHooks.afterSwap.selector, unspecifiedFee.toInt128());
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

    /// @notice Safely transfers ERC20 tokens, reverting on failure.
    function _safeTransfer(address token, address to, uint256 amount) internal {
        bool success = IERC20Minimal(token).transfer(to, amount);
        if (!success) revert TransferFailed();
    }

    /// @notice Collects fee from the unspecified side and updates accumulators.
    function _collectUnspecifiedFee(PoolKey calldata key, BalanceDelta delta, FeeState storage fState)
        internal
        returns (uint256 unspecifiedFee)
    {
        // Read transient storage from beforeSwap
        uint256 feePercent;
        uint256 aggregateUSDCSplit;
        uint256 specifiedFee;
        uint256 specifiedIsUSDCRaw;
        assembly {
            feePercent := tload(1)
            aggregateUSDCSplit := tload(2)
            specifiedFee := tload(3)
            specifiedIsUSDCRaw := tload(4)
        }
        bool specifiedIsUSDC = specifiedIsUSDCRaw != 0;

        // Get the unspecified-side amount from delta
        int128 unspecifiedAmount = specifiedIsUSDC ? delta.amount1() : delta.amount0();
        uint256 absUnspecified =
            unspecifiedAmount < 0 ? uint256(uint128(-unspecifiedAmount)) : uint256(uint128(unspecifiedAmount));

        // Compute unspecified-side fee
        uint256 unspecifiedFeeRatio = specifiedIsUSDC ? (WAD - aggregateUSDCSplit) : aggregateUSDCSplit;
        unspecifiedFee = (absUnspecified * feePercent * unspecifiedFeeRatio) / (uint256(MAX_FEE) * WAD);

        // Only take if there is weight to distribute to; otherwise fees would be stuck
        if (unspecifiedFee > 0) {
            bool unspecifiedIsUSDC = !specifiedIsUSDC;
            bool hasWeight = unspecifiedIsUSDC ? fState.totalUSDCWeight > 0 : fState.totalTokenWeight > 0;
            if (!hasWeight) {
                unspecifiedFee = 0;
            } else {
                Currency unspecifiedCurrency = specifiedIsUSDC ? key.currency1 : key.currency0;
                poolManager.take(unspecifiedCurrency, address(this), unspecifiedFee);
            }
        }

        // Determine which fees are USDC vs token and update accumulators
        uint256 usdcFee = specifiedIsUSDC ? specifiedFee : unspecifiedFee;
        uint256 tokenFee = specifiedIsUSDC ? unspecifiedFee : specifiedFee;

        if (usdcFee > 0 && fState.totalUSDCWeight > 0) {
            fState.feePerLiquidityUSDC += (usdcFee * WAD) / fState.totalUSDCWeight;
        }
        if (tokenFee > 0 && fState.totalTokenWeight > 0) {
            fState.feePerLiquidityToken += (tokenFee * WAD) / fState.totalTokenWeight;
        }

        emit FeesCollected(key.toId(), usdcFee, tokenFee);
    }

    function _processRemoveLiquidity(
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal {
        address lpAddress = abi.decode(hookData, (address));
        PoolId poolId = key.toId();
        bytes32 posKey = _positionKey(poolId, lpAddress, params.tickLower, params.tickUpper, params.salt);
        LPPosition storage pos = lpPositions[posKey];
        FeeState storage fState = feeStates[poolId];

        if (pos.liquidity == 0) revert NoPosition();

        _snapshotFees(pos, fState);

        uint128 liquidityRemoved = uint128(uint256(-params.liquidityDelta));
        if (liquidityRemoved > pos.liquidity) revert InsufficientLiquidity();

        fState.totalLiquidity -= uint256(liquidityRemoved);
        fState.totalUSDCWeight -= (uint256(liquidityRemoved) * pos.feeSplitUSDC) / WAD;
        fState.totalTokenWeight -= (uint256(liquidityRemoved) * (WAD - pos.feeSplitUSDC)) / WAD;

        pos.liquidity -= liquidityRemoved;

        emit LPPositionUpdated(poolId, lpAddress, params.tickLower, params.tickUpper, pos.liquidity);
    }

    function _processAddLiquidity(
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal {
        address lpAddress = abi.decode(hookData, (address));
        PoolId poolId = key.toId();
        bytes32 posKey = _positionKey(poolId, lpAddress, params.tickLower, params.tickUpper, params.salt);
        LPPosition storage pos = lpPositions[posKey];
        FeeState storage fState = feeStates[poolId];

        if (pos.liquidity > 0) {
            _snapshotFees(pos, fState);
        } else {
            pos.feeSplitUSDC = WAD;
            pos.feePerLiqUSDCCheckpoint = fState.feePerLiquidityUSDC;
            pos.feePerLiqTokenCheckpoint = fState.feePerLiquidityToken;
        }

        uint128 liquidityDelta = uint128(uint256(params.liquidityDelta));
        pos.liquidity += liquidityDelta;

        fState.totalLiquidity += uint256(liquidityDelta);
        fState.totalUSDCWeight += (uint256(liquidityDelta) * pos.feeSplitUSDC) / WAD;
        fState.totalTokenWeight += (uint256(liquidityDelta) * (WAD - pos.feeSplitUSDC)) / WAD;

        emit LPPositionUpdated(poolId, lpAddress, params.tickLower, params.tickUpper, pos.liquidity);
    }

    /// @notice Computes the fee amount to take from the specified side of the swap.
    function _computeSpecifiedFee(IPoolManager.SwapParams calldata params, uint24 feePercent, uint256 aggregateUSDCSplit)
        internal
        pure
        returns (uint256)
    {
        bool specifiedIsUSDC = (params.amountSpecified < 0) == params.zeroForOne;
        uint256 absAmount =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 specifiedFeeRatio = specifiedIsUSDC ? aggregateUSDCSplit : (WAD - aggregateUSDCSplit);
        return (absAmount * uint256(feePercent) * specifiedFeeRatio) / (uint256(MAX_FEE) * WAD);
    }

    /// @notice Computes the dynamic fee based on projected flow imbalance.
    function _computeFee(PoolConfig storage config, FlowState storage state, IPoolManager.SwapParams calldata params)
        internal
        view
        returns (uint24)
    {
        uint24 baseFee = config.baseFee;
        uint256 k = config.k;

        (int256 decayedNet, uint256 decayedTotal) = _applyDecay(
            state.netFlow, state.totalFlow, block.timestamp - state.lastUpdateTime, config.decayRate, config.windowSize
        );

        uint256 absAmount =
            params.amountSpecified >= 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified);

        int256 projectedNet = params.zeroForOne ? decayedNet + int256(absAmount) : decayedNet - int256(absAmount);
        uint256 projectedTotal = decayedTotal + absAmount;

        if (projectedTotal == 0) return baseFee;

        uint256 absNet = projectedNet >= 0 ? uint256(projectedNet) : uint256(-projectedNet);
        uint256 imbalanceRatio = (absNet * WAD) / projectedTotal;
        uint256 totalFee = uint256(baseFee) + (k * imbalanceRatio * imbalanceRatio) / (WAD * WAD);
        return totalFee > MAX_FEE ? MAX_FEE : uint24(totalFee);
    }

    /// @notice Updates flow state after a swap.
    function _updateFlowState(PoolConfig storage config, FlowState storage state, IPoolManager.SwapParams calldata params)
        internal
    {
        uint256 elapsed = block.timestamp - state.lastUpdateTime;
        (int256 decayedNet, uint256 decayedTotal) =
            _applyDecay(state.netFlow, state.totalFlow, elapsed, config.decayRate, config.windowSize);

        int256 swapAmount = params.amountSpecified;
        uint256 absAmount = swapAmount >= 0 ? uint256(swapAmount) : uint256(-swapAmount);

        if (params.zeroForOne) {
            decayedNet += int256(absAmount);
        } else {
            decayedNet -= int256(absAmount);
        }
        decayedTotal += absAmount;

        state.netFlow = decayedNet;
        state.totalFlow = decayedTotal;
        state.lastUpdateTime = block.timestamp;
    }

    /// @notice Applies exponential-like decay to flow state based on elapsed time.
    function _applyDecay(int256 netFlow, uint256 totalFlow, uint256 elapsed, uint256 decayRate, uint256 windowSize)
        internal
        pure
        returns (int256 decayedNet, uint256 decayedTotal)
    {
        if (elapsed == 0) {
            return (netFlow, totalFlow);
        }

        uint256 decayAmount = (decayRate * elapsed) / windowSize;

        if (decayAmount >= WAD) {
            return (0, 0);
        }

        uint256 factor = WAD - decayAmount;
        decayedNet = (netFlow * int256(factor)) / int256(WAD);
        decayedTotal = (totalFlow * factor) / WAD;
    }

    /// @notice Snapshots pending fees into LP's accrued balances.
    function _snapshotFees(LPPosition storage pos, FeeState storage fState) internal {
        if (pos.liquidity == 0) return;

        // Pending USDC fees: LP earns proportional to their USDC weight
        uint256 usdcDelta = fState.feePerLiquidityUSDC - pos.feePerLiqUSDCCheckpoint;
        if (usdcDelta > 0) {
            pos.accruedFeesUSDC += (uint256(pos.liquidity) * pos.feeSplitUSDC * usdcDelta) / (WAD * WAD);
        }

        // Pending token fees: LP earns proportional to their token weight
        uint256 tokenDelta = fState.feePerLiquidityToken - pos.feePerLiqTokenCheckpoint;
        if (tokenDelta > 0) {
            pos.accruedFeesToken += (uint256(pos.liquidity) * (WAD - pos.feeSplitUSDC) * tokenDelta) / (WAD * WAD);
        }

        // Update checkpoints
        pos.feePerLiqUSDCCheckpoint = fState.feePerLiquidityUSDC;
        pos.feePerLiqTokenCheckpoint = fState.feePerLiquidityToken;
    }

    /// @notice Computes the unique key for an LP position.
    function _positionKey(PoolId poolId, address lp, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(PoolId.unwrap(poolId), lp, tickLower, tickUpper, salt));
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

    /// @notice Returns pending (unclaimed) fees for an LP position.
    function getPendingFees(PoolKey calldata key, address lp, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        view
        returns (uint256 pendingUSDC, uint256 pendingToken)
    {
        PoolId poolId = key.toId();
        bytes32 posKey = _positionKey(poolId, lp, tickLower, tickUpper, salt);
        LPPosition storage pos = lpPositions[posKey];
        FeeState storage fState = feeStates[poolId];

        pendingUSDC = pos.accruedFeesUSDC;
        pendingToken = pos.accruedFeesToken;

        if (pos.liquidity > 0) {
            uint256 usdcDelta = fState.feePerLiquidityUSDC - pos.feePerLiqUSDCCheckpoint;
            if (usdcDelta > 0) {
                pendingUSDC += (uint256(pos.liquidity) * pos.feeSplitUSDC * usdcDelta) / (WAD * WAD);
            }
            uint256 tokenDelta = fState.feePerLiquidityToken - pos.feePerLiqTokenCheckpoint;
            if (tokenDelta > 0) {
                pendingToken += (uint256(pos.liquidity) * (WAD - pos.feeSplitUSDC) * tokenDelta) / (WAD * WAD);
            }
        }
    }

    /// @notice Returns the aggregate USDC fee split for a pool (WAD-scaled).
    function getAggregateUSDCSplit(PoolKey calldata key) external view returns (uint256) {
        PoolId poolId = key.toId();
        FeeState storage fState = feeStates[poolId];
        if (fState.totalLiquidity == 0) return WAD;
        return (fState.totalUSDCWeight * WAD) / fState.totalLiquidity;
    }
}
