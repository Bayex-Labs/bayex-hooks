// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BayexHook} from "../src/BayexHook.sol";
import {HookMiner} from "./HookMiner.sol";

/// @title DeployBayexHook
/// @notice Deployment script for BayexHook.
///
/// Usage:
///   1. Set environment variables:
///        POOL_MANAGER  — address of the deployed Uniswap v4 PoolManager
///        HOOK_OWNER    — address that will own the hook (configurePool, setTrustedRouter)
///        PRIVATE_KEY   — deployer private key (for broadcast)
///
///   2. Run:
///        forge script script/DeployBayexHook.s.sol:DeployBayexHook \
///          --rpc-url $RPC_URL --broadcast --verify
///
///   The script will:
///     a. Compute the required hook permission flags
///     b. Mine a CREATE2 salt that produces an address with those flags
///     c. Deploy BayexHook via the canonical CREATE2 deployer
///     d. Log the deployed address and next steps
contract DeployBayexHook is Script {
    /// @notice The canonical CREATE2 deployer available on most EVM chains.
    /// See https://github.com/Arachnid/deterministic-deployment-proxy
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        // ── Read environment ────────────────────────────────────────
        address poolManagerAddr = vm.envAddress("POOL_MANAGER");
        address hookOwner = vm.envAddress("HOOK_OWNER");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // ── Compute required flags ──────────────────────────────────
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        // ── Build creation code ─────────────────────────────────────
        bytes memory creationCode = abi.encodePacked(
            type(BayexHook).creationCode, abi.encode(IPoolManager(poolManagerAddr), hookOwner)
        );

        // ── Mine a CREATE2 salt ─────────────────────────────────────
        console.log("Mining CREATE2 salt for hook flags:", uint256(flags));
        console.log("This may take a moment...");

        (bytes32 salt, address expectedAddress) = HookMiner.find(CREATE2_DEPLOYER, flags, creationCode, 10_000_000);

        console.log("Found salt:", uint256(salt));
        console.log("Expected hook address:", expectedAddress);

        // ── Deploy via canonical CREATE2 deployer ───────────────────
        // The deployer expects: salt (32 bytes) ++ creationCode
        bytes memory payload = abi.encodePacked(salt, creationCode);

        vm.startBroadcast(deployerPrivateKey);

        (bool success, bytes memory result) = CREATE2_DEPLOYER.call(payload);
        require(success, "CREATE2 deployment failed");

        vm.stopBroadcast();

        // The CREATE2 deployer returns the deployed address
        address deployedAddress = address(uint160(bytes20(result)));

        // Fallback: compute address if return data is empty (some deployer variants)
        if (deployedAddress == address(0)) {
            deployedAddress = expectedAddress;
        }

        // Verify the address has code
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(deployedAddress)
        }

        // If the deployer didn't return the address, use the expected one
        if (codeSize == 0) {
            codeSize = expectedAddress.code.length;
            deployedAddress = expectedAddress;
        }

        require(codeSize > 0, "No code at expected address");

        console.log("---");
        console.log("BayexHook deployed at:", deployedAddress);
        console.log("Owner:", hookOwner);
        console.log("PoolManager:", poolManagerAddr);
        console.log("---");
        console.log("Next steps:");
        console.log("  1. Call hook.setTrustedRouter(routerAddress, true) from the owner");
        console.log("  2. Call hook.configurePool(poolKey, baseFee, k, windowSize, decayRate) from the owner");
        console.log("  3. Initialize the pool via PoolManager with the hook address");
    }
}
