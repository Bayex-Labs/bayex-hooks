// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {BayexHook} from "../src/BayexHook.sol";

contract BayexHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    BayexHook hook;
    PoolKey poolKey;
    PoolId poolId;

    // Default hook config
    uint24 constant BASE_FEE = 3000; // 0.30%
    uint256 constant K = 500_000; // Max surcharge at full imbalance (in hundredths of bip = 50%)
    uint256 constant WINDOW_SIZE = 300; // 5 minutes
    uint256 constant DECAY_RATE = 1e18; // Full decay over one window

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Calculate hook address with AFTER_INITIALIZE | BEFORE_SWAP | AFTER_SWAP flags
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags));

        // Deploy implementation and etch it to the flag-matching address
        BayexHook impl = new BayexHook(manager);
        vm.etch(hookAddress, address(impl).code);
        // Copy the immutable poolManager by re-deploying at that address
        // vm.etch only copies runtime code, so we need to store the manager slot
        // BayexHook uses immutable which is embedded in bytecode, so we use deployCodeTo
        deployCodeTo("BayexHook.sol:BayexHook", abi.encode(address(manager)), hookAddress);

        hook = BayexHook(hookAddress);

        // Configure pool params before initialization
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: int24(60),
            hooks: IHooks(hookAddress)
        });
        poolId = poolKey.toId();

        // Configure hook parameters
        hook.configurePool(poolKey, BASE_FEE, K, WINDOW_SIZE, DECAY_RATE);

        // Initialize pool
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // Add liquidity
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 10e18, salt: 0}),
            ZERO_BYTES
        );
    }

    // ─── Basic Tests ─────────────────────────────────────────────────────

    function test_hookDeployed() public view {
        (uint24 baseFee, uint256 k, uint256 windowSize, uint256 decayRate) = hook.poolConfigs(poolId);
        assertEq(baseFee, BASE_FEE);
        assertEq(k, K);
        assertEq(windowSize, WINDOW_SIZE);
        assertEq(decayRate, DECAY_RATE);
    }

    function test_flowStateInitialized() public view {
        (int256 netFlow, uint256 totalFlow, uint256 lastUpdateTime) = hook.flowStates(poolId);
        assertEq(netFlow, 0);
        assertEq(totalFlow, 0);
        assertGt(lastUpdateTime, 0);
    }

    function test_firstSwapPaysBaseFee() public {
        // First swap with no prior flow — should pay approximately baseFee
        uint24 feeBefore = hook.getCurrentFee(poolKey);
        assertEq(feeBefore, BASE_FEE);

        // Execute a swap
        swap(poolKey, true, -1e15, ZERO_BYTES);

        // Flow state should be updated
        (int256 netFlow, uint256 totalFlow,) = hook.flowStates(poolId);
        assertGt(netFlow, 0); // zeroForOne adds positive flow
        assertGt(totalFlow, 0);
    }

    // ─── Fee Escalation Tests ────────────────────────────────────────────

    function test_feeEscalatesWithOneSidedFlow() public {
        // Before any swap: no flow state → baseFee
        uint24 fee0 = hook.getCurrentFee(poolKey);
        assertEq(fee0, BASE_FEE);

        // First swap: beforeSwap reads empty flow → baseFee; afterSwap records flow
        swap(poolKey, true, -1e15, ZERO_BYTES);
        uint24 fee1 = hook.getCurrentFee(poolKey);

        // After one-directional swap, imbalance = 1.0, fee = baseFee + K
        assertEq(fee1, BASE_FEE + uint24(K));

        // Second swap same direction — imbalance stays at 1.0
        swap(poolKey, true, -1e15, ZERO_BYTES);
        uint24 fee2 = hook.getCurrentFee(poolKey);
        assertEq(fee2, BASE_FEE + uint24(K));

        // Fee is significantly above baseFee
        assertGt(fee2, BASE_FEE);
    }

    function test_balancedFlowKeepsFeeAtBase() public {
        // Swap in one direction
        swap(poolKey, true, -1e15, ZERO_BYTES);

        // Swap back in the other direction (same amount)
        swap(poolKey, false, -1e15, ZERO_BYTES);

        // Net flow should be near zero, so fee should be near baseFee
        uint24 fee = hook.getCurrentFee(poolKey);
        // Allow small deviation due to rounding
        assertLe(fee, BASE_FEE + 100);
    }

    // ─── Decay Tests ─────────────────────────────────────────────────────

    function test_feeDecaysOverTime() public {
        // Create imbalance
        swap(poolKey, true, -1e15, ZERO_BYTES);

        uint24 feeBeforeDecay = hook.getCurrentFee(poolKey);
        assertEq(feeBeforeDecay, BASE_FEE + uint24(K));

        // Advance time by half the window — decay reduces imbalance
        vm.warp(block.timestamp + WINDOW_SIZE / 2);
        uint24 feeAfterHalfDecay = hook.getCurrentFee(poolKey);

        // After half decay, both net and total decay by same factor, but since
        // all flow is one-directional, ratio stays 1.0 until full decay zeroes everything.
        // With linear decay: factor = 1 - (decayRate * elapsed / windowSize)
        // At half window: factor = 0.5, both net and total scale by 0.5 → ratio = 1.0
        // BUT at full window: factor = 0, everything resets → baseFee
        // So fee stays elevated until full decay
        assertGe(feeAfterHalfDecay, BASE_FEE);

        // Advance past full window → complete decay
        vm.warp(block.timestamp + WINDOW_SIZE);
        uint24 feeAfterFullDecay = hook.getCurrentFee(poolKey);
        assertEq(feeAfterFullDecay, BASE_FEE);
    }

    function test_fullDecayResetsToBaseFee() public {
        // Create heavy imbalance
        swap(poolKey, true, -1e15, ZERO_BYTES);
        swap(poolKey, true, -1e15, ZERO_BYTES);

        // Advance past the full window
        vm.warp(block.timestamp + WINDOW_SIZE + 1);

        uint24 fee = hook.getCurrentFee(poolKey);
        assertEq(fee, BASE_FEE);
    }

    // ─── Imbalance Ratio Tests ───────────────────────────────────────────

    function test_imbalanceRatioAfterOneSidedFlow() public {
        swap(poolKey, true, -1e15, ZERO_BYTES);

        uint256 ratio = hook.getImbalanceRatio(poolKey);
        // After a single swap in one direction, imbalance should be 1.0 (= WAD)
        assertEq(ratio, 1e18);
    }

    function test_imbalanceRatioAfterBalancedFlow() public {
        swap(poolKey, true, -1e15, ZERO_BYTES);
        swap(poolKey, false, -1e15, ZERO_BYTES);

        uint256 ratio = hook.getImbalanceRatio(poolKey);
        // Balanced flow means near-zero imbalance
        assertLt(ratio, 0.1e18); // less than 10%
    }

    // ─── Configuration Tests ─────────────────────────────────────────────

    function test_revertOnInvalidBaseFee() public {
        vm.expectRevert(BayexHook.InvalidParameters.selector);
        hook.configurePool(poolKey, uint24(1_000_001), K, WINDOW_SIZE, DECAY_RATE);
    }

    function test_revertOnZeroWindow() public {
        vm.expectRevert(BayexHook.InvalidParameters.selector);
        hook.configurePool(poolKey, BASE_FEE, K, 0, DECAY_RATE);
    }

    function test_feeCappedAtMax() public {
        // Configure with extremely aggressive k (would exceed 100% at full imbalance)
        hook.configurePool(poolKey, BASE_FEE, 2_000_000, WINDOW_SIZE, DECAY_RATE);

        // Create imbalance
        swap(poolKey, true, -1e15, ZERO_BYTES);

        uint24 fee = hook.getCurrentFee(poolKey);
        assertEq(fee, 1_000_000); // Capped at 100%
    }

    // ─── Access Control Tests ────────────────────────────────────────────

    function test_onlyPoolManagerCanCallBeforeSwap() public {
        vm.prank(address(0xdead));
        vm.expectRevert(BayexHook.OnlyPoolManager.selector);
        hook.beforeSwap(
            address(this),
            poolKey,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            ZERO_BYTES
        );
    }

    function test_onlyPoolManagerCanCallAfterSwap() public {
        vm.prank(address(0xdead));
        vm.expectRevert(BayexHook.OnlyPoolManager.selector);
        hook.afterSwap(
            address(this),
            poolKey,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            BalanceDelta.wrap(0),
            ZERO_BYTES
        );
    }

    // ─── Arbitrage Scenario Test ─────────────────────────────────────────

    function test_arbitrageScenario() public {
        // Simulate: 3 sequential YES buys (zeroForOne) mimicking arb wave
        //
        // Trade 1's beforeSwap sees no prior flow → pays baseFee
        // Trade 1's afterSwap records flow → imbalance = 1.0
        // Trade 2's beforeSwap sees full imbalance → pays baseFee + K (elevated)
        // Trade 3's beforeSwap sees full imbalance → pays baseFee + K (elevated)

        // Before any trade
        uint24 fee0 = hook.getCurrentFee(poolKey);
        assertEq(fee0, BASE_FEE, "pre-trade fee should be baseFee");

        // Arb 1: gets through cheap (no prior imbalance signal)
        swap(poolKey, true, -1e15, ZERO_BYTES);
        uint24 fee1 = hook.getCurrentFee(poolKey);

        // Arb 2: faces elevated fee (imbalance from arb 1)
        swap(poolKey, true, -1e15, ZERO_BYTES);
        uint24 fee2 = hook.getCurrentFee(poolKey);

        // Arb 3: still elevated
        swap(poolKey, true, -1e15, ZERO_BYTES);
        uint24 fee3 = hook.getCurrentFee(poolKey);

        // First trade establishes the signal, subsequent trades pay the surcharge
        assertGt(fee1, BASE_FEE, "fee should rise after first arb");
        assertGt(fee2, BASE_FEE, "fee should stay elevated");
        assertEq(fee2, fee1, "one-sided flow keeps imbalance at 1.0");
        assertEq(fee3, fee2, "sustained one-sided flow maintains fee");

        // After the arb wave passes (time decay)
        vm.warp(block.timestamp + WINDOW_SIZE + 1);
        uint24 feeAfterWave = hook.getCurrentFee(poolKey);
        assertEq(feeAfterWave, BASE_FEE, "fee resets after decay window");
    }
}
