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
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
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

    // LP addresses
    address constant LP1 = address(0xA001);
    address constant LP2 = address(0xA002);

    // Owner of the hook
    address constant OWNER = address(0xBEEF);

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddress = address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags));

        deployCodeTo(
            "BayexHook.sol:BayexHook", abi.encode(address(manager), OWNER), hookAddress
        );
        hook = BayexHook(hookAddress);

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: int24(60),
            hooks: IHooks(hookAddress)
        });
        poolId = poolKey.toId();

        // Owner configures pool and trusts the routers
        vm.startPrank(OWNER);
        hook.configurePool(poolKey, BASE_FEE, K, WINDOW_SIZE, DECAY_RATE);
        hook.setTrustedRouter(address(modifyLiquidityRouter), true);
        vm.stopPrank();

        // Initialize pool
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // Add liquidity with LP1 encoded in hookData
        bytes memory hookData = abi.encode(LP1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 10e18, salt: 0}),
            hookData
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

    function test_ownerIsSet() public view {
        assertEq(hook.owner(), OWNER);
    }

    function test_flowStateInitialized() public view {
        (int256 netFlow, uint256 totalFlow, uint256 lastUpdateTime) = hook.flowStates(poolId);
        assertEq(netFlow, 0);
        assertEq(totalFlow, 0);
        assertGt(lastUpdateTime, 0);
    }

    function test_lpPositionTracked() public view {
        bytes32 posKey = _positionKey(LP1, -120, 120, bytes32(0));
        (uint128 liquidity, uint256 feeSplitUSDC,,,,) = hook.lpPositions(posKey);
        assertEq(liquidity, 10e18);
        assertEq(feeSplitUSDC, 1e18); // 100% USDC default
    }

    function test_feeStateInitialized() public view {
        (,, uint256 totalLiquidity, uint256 totalUSDCWeight, uint256 totalTokenWeight) = hook.feeStates(poolId);
        assertEq(totalLiquidity, 10e18);
        assertEq(totalUSDCWeight, 10e18); // 100% USDC weight (default split)
        assertEq(totalTokenWeight, 0);
    }

    function test_aggregateUSDCSplitDefault() public view {
        uint256 split = hook.getAggregateUSDCSplit(poolKey);
        assertEq(split, 1e18); // 100% USDC
    }

    // ─── Access Control Tests ────────────────────────────────────────────

    function test_onlyOwnerCanConfigurePool() public {
        vm.prank(address(0xdead));
        vm.expectRevert();
        hook.configurePool(poolKey, BASE_FEE, K, WINDOW_SIZE, DECAY_RATE);
    }

    function test_onlyOwnerCanSetTrustedRouter() public {
        vm.prank(address(0xdead));
        vm.expectRevert();
        hook.setTrustedRouter(address(0x1234), true);
    }

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

    // ─── Trusted Router Tests ────────────────────────────────────────────

    function test_revertAddLiquidityFromUntrustedRouter() public {
        // modifyLiquidityNoChecks is NOT trusted
        vm.expectRevert();
        modifyLiquidityNoChecks.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0}),
            abi.encode(LP2)
        );
    }

    function test_trustedRouterCanAddLiquidity() public {
        // modifyLiquidityRouter IS trusted (set in setUp)
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 1e18,
                salt: bytes32(uint256(1))
            }),
            abi.encode(LP2)
        );

        bytes32 posKey = _positionKey(LP2, -120, 120, bytes32(uint256(1)));
        (uint128 liquidity,,,,,) = hook.lpPositions(posKey);
        assertEq(liquidity, 1e18);
    }

    function test_revertAddLiquidityWithoutHookData() public {
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0}),
            ZERO_BYTES
        );
    }

    // ─── Swap Fee Collection Tests ───────────────────────────────────────

    function test_swapCollectsFeesInUSDC() public {
        uint256 hookBalance0Before = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(hook));
        uint256 hookBalance1Before = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(hook));

        // Swap: USDC -> token (zeroForOne, exactInput)
        swap(poolKey, true, -1e15, abi.encode(LP1));

        uint256 hookBalance0After = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(hook));
        uint256 hookBalance1After = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(hook));

        assertGt(hookBalance0After, hookBalance0Before, "hook should collect USDC fees");
        // With 100% USDC split, no token fees should be collected
        assertEq(hookBalance1After, hookBalance1Before, "hook should not collect token fees with 100% USDC split");
    }

    function test_swapCollectsFeesBothSidesWithMixedSplit() public {
        vm.prank(LP1);
        hook.configureFeeSplit(poolKey, -120, 120, bytes32(0), 0.5e18);

        uint256 hookBalance0Before = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(hook));
        uint256 hookBalance1Before = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(hook));

        swap(poolKey, true, -1e15, abi.encode(LP1));

        uint256 hookBalance0After = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(hook));
        uint256 hookBalance1After = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(hook));

        assertGt(hookBalance0After, hookBalance0Before, "hook should collect USDC fees");
        assertGt(hookBalance1After, hookBalance1Before, "hook should collect token fees");
    }

    // ─── Fee Claiming Tests ─────────────────────────────────────────────

    function test_claimFeesAfterSwap() public {
        swap(poolKey, true, -1e15, abi.encode(LP1));
        swap(poolKey, false, -1e15, abi.encode(LP1));

        (uint256 pendingUSDC, uint256 pendingToken) = hook.getPendingFees(poolKey, LP1, -120, 120, bytes32(0));
        assertGt(pendingUSDC, 0, "should have pending USDC fees");
        assertEq(pendingToken, 0, "should have no pending token fees with 100% split");

        uint256 lp1Balance0Before = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(LP1);
        vm.prank(LP1);
        hook.claimFees(poolKey, -120, 120, bytes32(0));
        uint256 lp1Balance0After = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(LP1);

        assertGt(lp1Balance0After, lp1Balance0Before, "LP should receive USDC fees");

        (pendingUSDC, pendingToken) = hook.getPendingFees(poolKey, LP1, -120, 120, bytes32(0));
        assertEq(pendingUSDC, 0, "pending USDC should be 0 after claim");
        assertEq(pendingToken, 0, "pending token should be 0 after claim");
    }

    // ─── Fee Split Configuration Tests ──────────────────────────────────

    function test_configureFeeSplit() public {
        vm.prank(LP1);
        hook.configureFeeSplit(poolKey, -120, 120, bytes32(0), 0.5e18);

        bytes32 posKey = _positionKey(LP1, -120, 120, bytes32(0));
        (, uint256 feeSplitUSDC,,,,) = hook.lpPositions(posKey);
        assertEq(feeSplitUSDC, 0.5e18);

        (,, uint256 totalLiquidity, uint256 totalUSDCWeight, uint256 totalTokenWeight) = hook.feeStates(poolId);
        assertEq(totalLiquidity, 10e18);
        assertEq(totalUSDCWeight, 5e18);
        assertEq(totalTokenWeight, 5e18);
    }

    function test_configureFeeSplitSnapshotsFees() public {
        swap(poolKey, true, -1e15, abi.encode(LP1));

        (uint256 pendingBefore,) = hook.getPendingFees(poolKey, LP1, -120, 120, bytes32(0));
        assertGt(pendingBefore, 0, "should have fees before split change");

        vm.prank(LP1);
        hook.configureFeeSplit(poolKey, -120, 120, bytes32(0), 0.5e18);

        (uint256 pendingAfter,) = hook.getPendingFees(poolKey, LP1, -120, 120, bytes32(0));
        assertEq(pendingAfter, pendingBefore, "snapshotted fees should be preserved");
    }

    function test_revertConfigureFeeSplitNoPosition() public {
        vm.prank(address(0xdead));
        vm.expectRevert(BayexHook.NoPosition.selector);
        hook.configureFeeSplit(poolKey, -120, 120, bytes32(0), 0.5e18);
    }

    function test_revertConfigureFeeSplitTooHigh() public {
        vm.prank(LP1);
        vm.expectRevert(BayexHook.InvalidFeeSplit.selector);
        hook.configureFeeSplit(poolKey, -120, 120, bytes32(0), 1e18 + 1);
    }

    // ─── Multiple LPs Tests ─────────────────────────────────────────────

    function test_multipleLPsWithDifferentSplits() public {
        // Add LP2
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 10e18,
                salt: bytes32(uint256(1))
            }),
            abi.encode(LP2)
        );

        // LP2 changes to 0% USDC (100% token)
        vm.prank(LP2);
        hook.configureFeeSplit(poolKey, -120, 120, bytes32(uint256(1)), 0);

        uint256 split = hook.getAggregateUSDCSplit(poolKey);
        assertEq(split, 0.5e18, "aggregate should be 50% USDC");

        swap(poolKey, true, -1e15, abi.encode(LP1));

        (uint256 lp1USDC, uint256 lp1Token) = hook.getPendingFees(poolKey, LP1, -120, 120, bytes32(0));
        (uint256 lp2USDC, uint256 lp2Token) = hook.getPendingFees(poolKey, LP2, -120, 120, bytes32(uint256(1)));

        assertGt(lp1USDC, 0, "LP1 should have USDC fees");
        assertEq(lp1Token, 0, "LP1 should have no token fees (100% USDC split)");
        assertEq(lp2USDC, 0, "LP2 should have no USDC fees (0% USDC split)");
        assertGt(lp2Token, 0, "LP2 should have token fees");
    }

    // ─── Remove Liquidity Tests ─────────────────────────────────────────

    function test_removeLiquidityPreservesAccruedFees() public {
        swap(poolKey, true, -1e15, abi.encode(LP1));

        (uint256 pendingBefore,) = hook.getPendingFees(poolKey, LP1, -120, 120, bytes32(0));
        assertGt(pendingBefore, 0);

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: -5e18, salt: 0}),
            abi.encode(LP1)
        );

        (uint256 pendingAfter,) = hook.getPendingFees(poolKey, LP1, -120, 120, bytes32(0));
        assertEq(pendingAfter, pendingBefore, "accrued fees should be preserved after remove");

        vm.prank(LP1);
        hook.claimFees(poolKey, -120, 120, bytes32(0));

        uint256 lp1Balance = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(LP1);
        assertGt(lp1Balance, 0, "LP should receive fees after partial remove");
    }

    // ─── Zero-Weight Edge Case Tests ────────────────────────────────────

    function test_zeroTokenWeightSkipsTake() public {
        // Default: 100% USDC split, so totalTokenWeight = 0
        // Swap should NOT take token fees (they'd be stuck)
        (,,,, uint256 totalTokenWeight) = hook.feeStates(poolId);
        assertEq(totalTokenWeight, 0);

        uint256 hookBalance1Before = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(hook));
        swap(poolKey, true, -1e15, abi.encode(LP1));
        uint256 hookBalance1After = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(hook));

        assertEq(hookBalance1After, hookBalance1Before, "no token fees taken when tokenWeight is 0");
    }

    // ─── Flow Imbalance & Decay Tests ───────────────────────────────────

    function test_firstSwapPaysProjectedFee() public {
        uint24 feeBefore = hook.getCurrentFee(poolKey);
        assertEq(feeBefore, BASE_FEE);

        swap(poolKey, true, -1e15, abi.encode(LP1));

        (int256 netFlow, uint256 totalFlow,) = hook.flowStates(poolId);
        assertGt(netFlow, 0);
        assertGt(totalFlow, 0);

        // forge-lint: disable-next-line(unsafe-typecast)
        uint24 feeAfter = hook.getCurrentFee(poolKey);
        assertEq(feeAfter, BASE_FEE + uint24(K));
    }

    function test_feeEscalatesWithOneSidedFlow() public {
        uint24 fee0 = hook.getCurrentFee(poolKey);
        assertEq(fee0, BASE_FEE);

        swap(poolKey, true, -1e15, abi.encode(LP1));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint24 fee1 = hook.getCurrentFee(poolKey);
        assertEq(fee1, BASE_FEE + uint24(K));

        swap(poolKey, true, -1e15, abi.encode(LP1));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint24 fee2 = hook.getCurrentFee(poolKey);
        assertEq(fee2, BASE_FEE + uint24(K));

        assertGt(fee2, BASE_FEE);
    }

    function test_balancedFlowKeepsFeeAtBase() public {
        swap(poolKey, true, -1e15, abi.encode(LP1));
        swap(poolKey, false, -1e15, abi.encode(LP1));

        uint24 fee = hook.getCurrentFee(poolKey);
        assertLe(fee, BASE_FEE + 100);
    }

    function test_feeDecaysOverTime() public {
        swap(poolKey, true, -1e15, abi.encode(LP1));

        // forge-lint: disable-next-line(unsafe-typecast)
        uint24 feeBeforeDecay = hook.getCurrentFee(poolKey);
        assertEq(feeBeforeDecay, BASE_FEE + uint24(K));

        vm.warp(block.timestamp + WINDOW_SIZE / 2);
        uint24 feeAfterHalfDecay = hook.getCurrentFee(poolKey);
        assertGe(feeAfterHalfDecay, BASE_FEE);

        vm.warp(block.timestamp + WINDOW_SIZE);
        uint24 feeAfterFullDecay = hook.getCurrentFee(poolKey);
        assertEq(feeAfterFullDecay, BASE_FEE);
    }

    function test_fullDecayResetsToBaseFee() public {
        swap(poolKey, true, -1e15, abi.encode(LP1));
        swap(poolKey, true, -1e15, abi.encode(LP1));

        vm.warp(block.timestamp + WINDOW_SIZE + 1);

        uint24 fee = hook.getCurrentFee(poolKey);
        assertEq(fee, BASE_FEE);
    }

    function test_imbalanceRatioAfterOneSidedFlow() public {
        swap(poolKey, true, -1e15, abi.encode(LP1));
        uint256 ratio = hook.getImbalanceRatio(poolKey);
        assertEq(ratio, 1e18);
    }

    function test_imbalanceRatioAfterBalancedFlow() public {
        swap(poolKey, true, -1e15, abi.encode(LP1));
        swap(poolKey, false, -1e15, abi.encode(LP1));
        uint256 ratio = hook.getImbalanceRatio(poolKey);
        assertLt(ratio, 0.1e18);
    }

    // ─── Configuration Validation Tests ──────────────────────────────────

    function test_revertOnInvalidBaseFee() public {
        vm.prank(OWNER);
        vm.expectRevert(BayexHook.InvalidParameters.selector);
        hook.configurePool(poolKey, uint24(1_000_001), K, WINDOW_SIZE, DECAY_RATE);
    }

    function test_revertOnZeroWindow() public {
        vm.prank(OWNER);
        vm.expectRevert(BayexHook.InvalidParameters.selector);
        hook.configurePool(poolKey, BASE_FEE, K, 0, DECAY_RATE);
    }

    function test_feeCappedAtMax() public {
        vm.prank(OWNER);
        hook.configurePool(poolKey, BASE_FEE, 2_000_000, WINDOW_SIZE, DECAY_RATE);
        swap(poolKey, true, -1e15, abi.encode(LP1));
        uint24 fee = hook.getCurrentFee(poolKey);
        assertEq(fee, 1_000_000);
    }

    // ─── Arbitrage Scenario Test ─────────────────────────────────────────

    function test_arbitrageScenario() public {
        uint24 fee0 = hook.getCurrentFee(poolKey);
        assertEq(fee0, BASE_FEE, "pre-trade fee should be baseFee");

        swap(poolKey, true, -1e15, abi.encode(LP1));
        uint24 fee1 = hook.getCurrentFee(poolKey);

        swap(poolKey, true, -1e15, abi.encode(LP1));
        uint24 fee2 = hook.getCurrentFee(poolKey);

        swap(poolKey, true, -1e15, abi.encode(LP1));
        uint24 fee3 = hook.getCurrentFee(poolKey);

        assertGt(fee1, BASE_FEE, "fee should rise after first arb");
        assertGt(fee2, BASE_FEE, "fee should stay elevated");
        assertEq(fee2, fee1, "one-sided flow keeps imbalance at 1.0");
        assertEq(fee3, fee2, "sustained one-sided flow maintains fee");

        vm.warp(block.timestamp + WINDOW_SIZE + 1);
        uint24 feeAfterWave = hook.getCurrentFee(poolKey);
        assertEq(feeAfterWave, BASE_FEE, "fee resets after decay window");
    }

    // ─── Fee Split Change with Subsequent Fees Test ─────────────────────

    function test_feeSplitChangeAffectsSubsequentFees() public {
        swap(poolKey, true, -1e15, abi.encode(LP1));
        (uint256 usdcBefore,) = hook.getPendingFees(poolKey, LP1, -120, 120, bytes32(0));

        vm.prank(LP1);
        hook.configureFeeSplit(poolKey, -120, 120, bytes32(0), 0.5e18);

        swap(poolKey, true, -1e15, abi.encode(LP1));

        (uint256 usdcAfter, uint256 tokenAfter) = hook.getPendingFees(poolKey, LP1, -120, 120, bytes32(0));

        assertGt(usdcAfter, usdcBefore, "USDC fees should increase");
        assertGt(tokenAfter, 0, "should have token fees after 50/50 split");
    }

    // ─── Ownership Transfer Test ─────────────────────────────────────────

    function test_ownershipTransfer() public {
        address newOwner = address(0xCAFE);

        vm.prank(OWNER);
        hook.transferOwnership(newOwner);

        // Pending owner should be set
        assertEq(hook.pendingOwner(), newOwner);
        // Old owner is still owner until accepted
        assertEq(hook.owner(), OWNER);

        // New owner accepts
        vm.prank(newOwner);
        hook.acceptOwnership();
        assertEq(hook.owner(), newOwner);

        // New owner can configure
        vm.prank(newOwner);
        hook.configurePool(poolKey, 5000, K, WINDOW_SIZE, DECAY_RATE);
        (uint24 baseFee,,,) = hook.poolConfigs(poolId);
        assertEq(baseFee, 5000);
    }

    // ─── Helper ──────────────────────────────────────────────────────────

    function _positionKey(address lp, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(PoolId.unwrap(poolId), lp, tickLower, tickUpper, salt));
    }
}
