// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title HookMiner
/// @notice Mines CREATE2 salts to find hook addresses with the correct permission flags.
library HookMiner {
    /// @notice The canonical CREATE2 deployer (deployed on most EVM chains).
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice Mask for the 14 least significant bits (hook permission flags).
    uint160 constant FLAG_MASK = 0x3FFF;

    /// @notice Find a salt that produces a CREATE2 address with the desired flags.
    /// @param deployer The CREATE2 deployer address
    /// @param flags The desired permission flags (only the low 14 bits matter)
    /// @param creationCode The contract creation code including constructor args
    /// @param maxIterations Maximum number of salts to try
    /// @return salt The salt that produces a matching address
    /// @return hookAddress The resulting hook address
    function find(address deployer, uint160 flags, bytes memory creationCode, uint256 maxIterations)
        internal
        pure
        returns (bytes32 salt, address hookAddress)
    {
        bytes32 initCodeHash = keccak256(creationCode);
        uint160 requiredFlags = flags & FLAG_MASK;

        for (uint256 i = 0; i < maxIterations; i++) {
            salt = bytes32(i);
            hookAddress = computeAddress(deployer, salt, initCodeHash);

            if (uint160(hookAddress) & FLAG_MASK == requiredFlags) {
                return (salt, hookAddress);
            }
        }

        revert("HookMiner: could not find salt");
    }

    /// @notice Compute the CREATE2 address for a given deployer, salt, and initCodeHash.
    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash)
        internal
        pure
        returns (address)
    {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
