// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { LiquidityAmounts } from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";

/// @title RewardTokensManager
/// @notice Creates a Uniswap v4 pool for FNBT/PNPT and mints concentrated liquidity positions
contract RewardTokensManager is Ownable {
    using PoolIdLibrary for PoolKey; // For converting PoolKey to PoolId
    using StateLibrary for IPoolManager; // For reading pool state

    //  Pool configuration constants
    /// @notice 0.3% swap fee tier (3000 fee units)
    uint24 public constant FEE_TIER = 3000;

    /// @notice Tick spacing that pairs with the 0.3% fee tier
    int24 public constant TICK_SPACING = 60;

    /// @notice No hooks attached to this pool
    address public constant HOOKS = address(0);

    // The derivation of the target tick from the 1 FNBT = 10 PNPT
    // 1 FNBT = R0.10, 1 PNPT = R0.01  ->  1 FNBT = 10 PNPT
    // In Uniswap v4: price = token1 / token0 = 1.0001^tick
    // log_{1.0001}(10) = ln(10) / ln(1.0001) = 2.302585 / 0.000099995 = 23027
    int24 private constant TARGET_TICK_MAGNITUDE = 23027;

    // Immutable states
    IPoolManager public immutable poolManager;

    /// @notice Uniswap v4 PositionManager stored as address so no interface import is needed
    address public immutable positionManager;

    address public immutable pnpToken;
    address public immutable fnbToken;

    /// @notice The two pool tokens in address-sorted order
    Currency public immutable currency0;
    Currency public immutable currency1;

    // Mutable states
    /// @notice Tracks which poolIds have been created by this contract
    mapping(bytes32 => bool) public createdPools;

    /// Stored pool id set by createPool, zero until the pool is created
    bytes32 private _poolId;

    // Events
    /// @notice Emitted when the Uniswap v4 pool is created and initialised
    event PoolCreated(
        bytes32 indexed poolId,
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        uint160 sqrtPriceX96
    );

    /// @notice Emitted when a concentrated liquidity position is minted
    event LiquidityMinted(
        bytes32 indexed poolId,
        uint256 positionId,
        address indexed owner,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    );

    // Errors

    /// @notice Reverts when the supplied tick range does not contain the assignment target tick
    error TickRangeDoesNotCoverAssignmentPrice();

    // Constructor
    /// @param _poolManager     Uniswap v4 PoolManager address
    /// @param _positionManager Uniswap v4 PositionManager address
    /// @param _pnpToken        PNPToken (PNPT) contract address
    /// @param _fnbToken        FNBToken (FNBT) contract address
    constructor(
        address _poolManager,
        address _positionManager,
        address _pnpToken,
        address _fnbToken
    ) Ownable(msg.sender) {
        poolManager = IPoolManager(_poolManager);
        positionManager = _positionManager; // Stored as address to avoid importing PositionManager interface
        pnpToken = _pnpToken;
        fnbToken = _fnbToken;

        // Uniswap v4 requires currency0 < currency1 (by address) in the PoolKey
        if (_pnpToken < _fnbToken) {
            // currency0 = PNPT, currency1 = FNBT
            currency0 = Currency.wrap(_pnpToken);
            currency1 = Currency.wrap(_fnbToken);
        } else {
            // currency0 = FNBT, currency1 = PNPT
            currency0 = Currency.wrap(_fnbToken);
            currency1 = Currency.wrap(_pnpToken);
        }
    }

    // View helpers
    /// @notice Returns the assignment target tick derived from 1 FNBT = 10 PNPT
    /// price = currency1 / currency0 = 1.0001^tick
    /// If currency0 = FNBT: price = PNPT/FNBT = 10  -> tick  =  23027
    /// If currency0 = PNPT: price = FNBT/PNPT = 0.1 -> tick  = -23027
    function getTargetTick() public view returns (int24) {
        // The target tick is positive if currency0 is the more expensive token (FNBT),
        // The target tick is negative if currency0 is the cheaper token (PNPT)
        if (Currency.unwrap(currency0) == fnbToken) {
            return TARGET_TICK_MAGNITUDE;
        } else {
            return -TARGET_TICK_MAGNITUDE;
        }
    }

    /// @notice Returns the PoolId created by this contract (zero until createPool is called)
    function getPoolId() public view returns (bytes32) {
        return _poolId;
    }

    /// @notice Returns the two pool currencies in their sorted order
    function getCanonicalCurrencies() public view returns (address, address) {
        return (Currency.unwrap(currency0), Currency.unwrap(currency1));
    }

    // Internal helpers

    /// @notice Builds the PoolKey used throughout this contract
    function _buildPoolKey() internal view returns (PoolKey memory) {
        return
            // PoolKey fields: currency0, currency1, fee, tickSpacing, hooks
            PoolKey({
                currency0: currency0,
                currency1: currency1,
                fee: FEE_TIER,
                tickSpacing: TICK_SPACING,
                hooks: IHooks(HOOKS)
            });
    }

    // Part 2: Pool creation

    /// @notice Creates and initialises the FNBT/PNPT Uniswap v4 pool
    ///         Uses fee tier 0.3% (3000), tick spacing 60, and no hooks,
    ///         onlyOwner prevents arbitrary callers from initialising the pool
    ///         at an unintended price before the contract owner can act
    /// @param sqrtPriceX96 Starting pool price in Q64.96 sqrt format
    /// @return poolId The PoolId of the created pool as a bytes32
    function createPool(uint160 sqrtPriceX96) external onlyOwner returns (bytes32 poolId) {
        PoolKey memory key = _buildPoolKey(); // Build the PoolKey for the FNBT/PNPT pool

        // Initialise the pool via the singleton PoolManager
        poolManager.initialize(key, sqrtPriceX96);

        poolId = PoolId.unwrap(key.toId()); // Convert PoolKey to PoolId for indexing
        _poolId = poolId;
        createdPools[poolId] = true;

        // Emit the pool creation event with all relevant parameters for off-chain indexing
        emit PoolCreated(
            poolId,
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            FEE_TIER,
            TICK_SPACING,
            HOOKS,
            sqrtPriceX96
        );
    }

    // Part 3: Mint liquidity

    /// @notice Mints a concentrated liquidity position in the FNBT/PNPT pool
    ///         The caller must approve this contract on both tokens before calling.
    ///         Any token dust left after minting is returned to the caller.
    /// @param tickLower      Lower tick of the position (must be TICK_SPACING-aligned)
    /// @param tickUpper      Upper tick of the position (must be TICK_SPACING-aligned)
    /// @param amount0Desired Maximum amount of currency0 the caller is willing to deposit
    /// @param amount1Desired Maximum amount of currency1 the caller is willing to deposit
    /// @return positionId   ERC-721 token id of the minted position (from PositionManager)
    /// @return poolId       PoolId of the pool the position was minted into
    function mintLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) external returns (uint256 positionId, bytes32 poolId) {
        // 1) Validate user inputs and tick constraints
        require(amount0Desired > 0 || amount1Desired > 0, "RewardTokensManager: zero amounts");
        require(tickLower < tickUpper, "RewardTokensManager: invalid tick range");
        require(tickLower % TICK_SPACING == 0, "RewardTokensManager: tickLower not aligned");
        require(tickUpper % TICK_SPACING == 0, "RewardTokensManager: tickUpper not aligned");

        // 2) Ensure the chosen range includes the assignment target tick
        // The target tick encodes 1 FNBT = 10 PNPT (log_{1.0001}(10) = 23027)
        int24 targetTick = getTargetTick();
        if (tickLower >= targetTick || tickUpper <= targetTick) {
            revert TickRangeDoesNotCoverAssignmentPrice();
        }

        // 3) Resolve and verify the liquidity pool
        PoolKey memory key = _buildPoolKey(); // Build the PoolKey for the FNBT/PNPT pool
        poolId = PoolId.unwrap(key.toId()); // Convert PoolKey to PoolId for indexing
        require(createdPools[poolId], "RewardTokensManager: pool not created");

        // 4) Compute liquidity from desired token amounts at the current pool price
        // sqrtPriceX96 is read from PoolManager slot0 for the live price
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(key.toId());
        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceAX96,
            sqrtPriceBX96,
            amount0Desired,
            amount1Desired
        );
        require(liquidity > 0, "RewardTokensManager: zero liquidity");

        // 5) Pull desired token amounts from owner into this manager
        // The caller must have approved this contract on both tokens first
        if (amount0Desired > 0) {
            IERC20(Currency.unwrap(currency0)).transferFrom(msg.sender, address(this), amount0Desired);
        }
        if (amount1Desired > 0) {
            IERC20(Currency.unwrap(currency1)).transferFrom(msg.sender, address(this), amount1Desired);
        }

        // 6) Approve Permit2 so PositionManager can settle pool deltas
        // PositionManager exposes its Permit2 address as a public immutable
        (bool ok, bytes memory ret) = positionManager.call(abi.encodeWithSignature("permit2()"));
        require(ok, "RewardTokensManager: permit2 call failed");
        address permit2Addr = abi.decode(ret, (address)); // Read the Permit2 address from PositionManager
        // Approve max uint256 to avoid re-approvals for future mints
        IERC20(Currency.unwrap(currency0)).approve(permit2Addr, type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(permit2Addr, type(uint256).max);

        // 7) Prepare PositionManager mint actions and execute modifyLiquidities
        // nextTokenId() before the mint equals the id that will be assigned to the new position
        (ok, ret) = positionManager.call(abi.encodeWithSignature("nextTokenId()"));
        require(ok, "RewardTokensManager: nextTokenId call failed");
        positionId = abi.decode(ret, (uint256)); // Read the next token id from PositionManager to know the id of the position we are minting

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        // MINT_POSITION params: PoolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, recipient, hookData
        params[0] = abi.encode(
            key,
            tickLower,
            tickUpper,
            uint256(liquidity),
            uint128(amount0Desired),
            uint128(amount1Desired),
            msg.sender, // NFT recipient — the caller owns the minted position
            bytes("")
        );
        // SETTLE_PAIR params: the two currencies whose deltas must be settled after minting
        params[1] = abi.encode(currency0, currency1);

        // Call modifyLiquidities on PositionManager with the encoded actions and params, and a deadline in the near future
        (ok, ) = positionManager.call(
            abi.encodeWithSignature(
                "modifyLiquidities(bytes,uint256)",
                abi.encode(actions, params),
                block.timestamp + 60
            )
        );
        require(ok, "RewardTokensManager: modifyLiquidities failed");

        // 8) Verify mint succeeded
        // PositionManager must have assigned exactly one new token
        (ok, ret) = positionManager.call(abi.encodeWithSignature("nextTokenId()"));
        require(ok && abi.decode(ret, (uint256)) == positionId + 1, "RewardTokensManager: mint failed");

        // 9) Return any unspent token dust to the caller and emit the assignment event
        uint256 balance0 = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 balance1 = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        // Return any unspent tokens to the caller
        if (balance0 > 0) IERC20(Currency.unwrap(currency0)).transfer(msg.sender, balance0);
        if (balance1 > 0) IERC20(Currency.unwrap(currency1)).transfer(msg.sender, balance1);

        // Emit the LiquidityMinted event with all relevant parameters for off-chain indexing
        emit LiquidityMinted(poolId, positionId, msg.sender, tickLower, tickUpper, liquidity);
    }
}
