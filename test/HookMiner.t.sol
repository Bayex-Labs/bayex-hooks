// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BayexHook} from "../src/BayexHook.sol";
import {HookMiner} from "../script/HookMiner.sol";

contract HookMinerTest is Test {
    function test_minesCorrectFlags() public pure {
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        address deployer = HookMiner.CREATE2_DEPLOYER;
        address poolManager = address(0x1234);
        address owner = address(0xBEEF);

        bytes memory creationCode =
            abi.encodePacked(type(BayexHook).creationCode, abi.encode(IPoolManager(poolManager), owner));

        (bytes32 salt, address hookAddress) = HookMiner.find(deployer, flags, creationCode, 10_000_000);

        // Verify the mined address has correct flags
        uint160 addressFlags = uint160(hookAddress) & HookMiner.FLAG_MASK;
        uint160 requiredFlags = flags & HookMiner.FLAG_MASK;
        assertEq(addressFlags, requiredFlags, "Mined address flags should match required flags");

        // Verify salt is not zero (would be very lucky)
        assertTrue(salt != bytes32(0) || hookAddress != address(0), "Should find a valid salt");
    }
}
