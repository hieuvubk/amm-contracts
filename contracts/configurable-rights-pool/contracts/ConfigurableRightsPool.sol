// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.6.12;

// Needed to handle structures externally
pragma experimental ABIEncoderV2;

// Imports
import "@openzeppelin/contracts/utils/Address.sol";
import "./IBFactory.sol";
import "./PCToken.sol";
import "./utils/BalancerReentrancyGuard.sol";
import "./utils/BalancerOwnable.sol";
import "./IFCXAccessControl.sol";

// Interfaces

// Libraries
import {RightsManager} from "../libraries/RightsManager.sol";
import "../libraries/SmartPoolManager.sol";
import "../libraries/SafeApprove.sol";

// Contracts

/**
 * @author Balancer Labs
 * @title Smart Pool with customizable features
 * @notice PCToken is the "Balancer Smart Pool" token (transferred upon finalization)
 * @dev Rights are defined as follows (index values into the array)
 *      0: canPauseSwapping - can setPublicSwap back to false after turning it on
 *                            by default, it is off on initialization and can only be turned on
 *      1: canChangeSwapFee - can setSwapFee after initialization (by default, it is fixed at create time)
 *      2: canChangeWeights - can bind new token weights (allowed by default in base pool)
 *      3: canAddRemoveTokens - can bind/unbind tokens (allowed by default in base pool)
 *      4: canWhitelistLPs - can restrict LPs to a whitelist
 *      5: canChangeCap - can change the BSP cap (max # of pool tokens)
 *
 * Note that functions called on bPool and bFactory may look like internal calls,
 *   but since they are contracts accessed through an interface, they are really external.
 * To make this explicit, we could write "IBPool(address(bPool)).function()" everywhere,
 *   instead of "bPool.function()".
 */
contract ConfigurableRightsPool is PCToken, BalancerOwnable, BalancerReentrancyGuard {
    using BalancerSafeMath for uint256;
    using SafeApprove for IERC20;

    // Type declarations

    struct PoolParams {
        // Balancer Pool Token (representing shares of the pool)
        string poolTokenSymbol;
        string poolTokenName;
        // Tokens inside the Pool
        address[] constituentTokens;
        uint256[] tokenBalances;
        uint256[] tokenWeights;
        uint256 swapFee;
        uint256 protocolFee;
    }

    // State variables

    IBFactory public bFactory;
    IBPool public bPool;

    // Struct holding the rights configuration
    RightsManager.Rights public rights;

    // Hold the parameters used in updateWeightsGradually
    SmartPoolManager.GradualUpdateParams public gradualUpdate;

    // This is for adding a new (currently unbound) token to the pool
    // It's a two-step process: commitAddToken(), then applyAddToken()
    SmartPoolManager.NewTokenParams public newToken;

    // Fee is initialized on creation, and can be changed if permission is set
    // Only needed for temporary storage between construction and createPool
    // Thereafter, the swap fee should always be read from the underlying pool
    uint256 private _initialSwapFee;

    uint256 private _initialProtocolFee;

    address private _initialAccessAddress;

    // Store the list of tokens in the pool, and balances
    // NOTE that the token list is *only* used to store the pool tokens between
    //   construction and createPool - thereafter, use the underlying BPool's list
    //   (avoids synchronization issues)
    address[] private _initialTokens;
    uint256[] private _initialBalances;

    // Enforce a minimum time between the start and end blocks
    uint256 public minimumWeightChangeBlockPeriod;
    // Enforce a mandatory wait time between updates
    // This is also the wait time between committing and applying a new token
    uint256 public addTokenTimeLockInBlocks;

    // Whitelist of LPs (if configured)
    mapping(address => bool) private _liquidityProviderWhitelist;

    // Cap on the pool size (i.e., # of tokens minted when joining)
    // Limits the risk of experimental pools; failsafe/backup for fixed-size pools
    uint256 public bspCap;

    // Event declarations

    // Anonymous logger event - can only be filtered by contract address

    event LogCall(bytes4 indexed sig, address indexed caller, bytes data) anonymous;

    event LogJoin(address indexed caller, address indexed tokenIn, uint256 tokenAmountIn);

    event LogExit(address indexed caller, address indexed tokenOut, uint256 tokenAmountOut);

    event CapChanged(address indexed caller, uint256 oldCap, uint256 newCap);

    event NewTokenCommitted(address indexed token, address indexed pool, address indexed caller);

    // Modifiers

    modifier onlyWhitelist() {
        require(
            IFCXAccessControl(_initialAccessAddress).whitelisted(tx.origin),
            "FCXAccessControl: sender is not in whitelist"
        );
        _;
    }

    modifier logs() {
        emit LogCall(msg.sig, msg.sender, msg.data);
        _;
    }

    // Mark functions that require delegation to the underlying Pool
    modifier needsBPool() {
        require(address(bPool) != address(0), "ERR_NOT_CREATED");
        _;
    }

    modifier lockUnderlyingPool() {
        // Turn off swapping on the underlying pool during joins
        // Otherwise tokens with callbacks would enable attacks involving simultaneous swaps and joins
        bool origSwapState = bPool.isPublicSwap();
        bPool.setPublicSwap(false);
        _;
        bPool.setPublicSwap(origSwapState);
    }

    // Default values for these variables (used only in updateWeightsGradually), set in the constructor
    // Pools without permission to update weights cannot use them anyway, and should call
    //   the default createPool() function.
    // To override these defaults, pass them into the overloaded createPool()
    // Period is in blocks; 500 blocks ~ 2 hours; 90,000 blocks ~ 2 weeks
    uint256 public constant DEFAULT_MIN_WEIGHT_CHANGE_BLOCK_PERIOD = 90000;
    uint256 public constant DEFAULT_ADD_TOKEN_TIME_LOCK_IN_BLOCKS = 500;
    bytes32 private constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // Function declarations

    /**
     * @notice Construct a new Configurable Rights Pool (wrapper around BPool)
     * @dev _initialTokens and _swapFee are only used for temporary storage between construction
     *      and create pool, and should not be used thereafter! _initialTokens is destroyed in
     *      createPool to prevent this, and _swapFee is kept in sync (defensively), but
     *      should never be used except in this constructor and createPool()
     * @param factoryAddress - the BPoolFactory used to create the underlying pool
     * @param poolParams - struct containing pool parameters
     * @param rightsStruct - Set of permissions we are assigning to this smart pool
     */
    constructor(
        address factoryAddress,
        address logic,
        PoolParams memory poolParams,
        RightsManager.Rights memory rightsStruct
    ) public PCToken(poolParams.poolTokenSymbol, poolParams.poolTokenName) {
        // We don't have a pool yet; check now or it will fail later (in order of likelihood to fail)
        // (and be unrecoverable if they don't have permission set to change it)
        // Most likely to fail, so check first
        require(poolParams.swapFee >= BalancerConstants.MIN_FEE, "ERR_INVALID_SWAP_FEE");
        require(poolParams.swapFee <= BalancerConstants.MAX_FEE, "ERR_INVALID_SWAP_FEE");

        require(poolParams.protocolFee <= BalancerConstants.MAX_FEE, "ERR_INVALID_PROTOCOL_FEE");
        // Arrays must be parallel
        require(poolParams.tokenBalances.length == poolParams.constituentTokens.length, "ERR_START_BALANCES_MISMATCH");
        require(poolParams.tokenWeights.length == poolParams.constituentTokens.length, "ERR_START_WEIGHTS_MISMATCH");
        // Cannot have too many or too few - technically redundant, since BPool.bind() would fail later
        // But if we don't check now, we could have a useless contract with no way to create a pool

        require(poolParams.constituentTokens.length >= BalancerConstants.MIN_ASSET_LIMIT, "ERR_TOO_FEW_TOKENS");
        require(poolParams.constituentTokens.length <= BalancerConstants.MAX_ASSET_LIMIT, "ERR_TOO_MANY_TOKENS");
        // There are further possible checks (e.g., if they use the same token twice), but
        // we can let bind() catch things like that (i.e., not things that might reasonably work)

        SmartPoolManager.verifyTokenCompliance(poolParams.constituentTokens);

        bFactory = IBFactory(factoryAddress);
        rights = rightsStruct;
        _initialTokens = poolParams.constituentTokens;
        _initialBalances = poolParams.tokenBalances;
        _initialSwapFee = poolParams.swapFee;
        _initialProtocolFee = poolParams.protocolFee;
        _initialAccessAddress = bFactory.getAccessControlAddress();

        // These default block time parameters can be overridden in createPool
        minimumWeightChangeBlockPeriod = DEFAULT_MIN_WEIGHT_CHANGE_BLOCK_PERIOD;
        addTokenTimeLockInBlocks = DEFAULT_ADD_TOKEN_TIME_LOCK_IN_BLOCKS;

        gradualUpdate.startWeights = poolParams.tokenWeights;
        // Initializing (unnecessarily) for documentation - 0 means no gradual weight change has been initiated
        gradualUpdate.startBlock = 0;
        // By default, there is no cap (unlimited pool token minting)
        bspCap = BalancerConstants.MAX_UINT;

        // extension
        assert(_IMPLEMENTATION_SLOT == bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1));
        _setImplementation(logic);
    }

    /**
     * @dev Stores a new address in the EIP1967 implementation slot.
     */
    function _setImplementation(address newImplementation) private {
        require(Address.isContract(newImplementation), "UpgradeableProxy: new implementation is not a contract");

        bytes32 slot = _IMPLEMENTATION_SLOT;

        // solhint-disable-next-line no-inline-assembly
        assembly {
            sstore(slot, newImplementation)
        }
    }

    /**
     * @dev Returns the current implementation address.
     */
    function _implementation() internal view returns (address impl) {
        bytes32 slot = _IMPLEMENTATION_SLOT;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            impl := sload(slot)
        }
    }

    /**
     * @dev Delegates the current call to `implementation`.
     *
     * This function does not return to its internall call site, it will return directly to the external caller.
     */
    function _delegate(address implementation) internal {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // Copy msg.data. We take full control of memory in this inline assembly
            // block because it will not return to Solidity code. We overwrite the
            // Solidity scratch pad at memory position 0.
            calldatacopy(0, 0, calldatasize())

            // Call the implementation.
            // out and outsize are 0 because we don't know the size yet.
            let result := delegatecall(gas(), implementation, 0, calldatasize(), 0, 0)

            // Copy the returned data.
            returndatacopy(0, 0, returndatasize())

            switch result
            // delegatecall returns 0 on error.
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }

    /**
     * @dev Fallback function that delegates calls to the address returned by `_implementation()`. Will run if no other
     * function in the contract matches the call data.
     */
    fallback() external {
        _delegate(_implementation());
    }

    /**
     * @notice Set the cap (max # of pool tokens)
     * @dev _bspCap defaults in the constructor to unlimited
     *      Can set to 0 (or anywhere below the current supply), to halt new investment
     *      Prevent setting it before creating a pool, since createPool sets to intialSupply
     *      (it does this to avoid an unlimited cap window between construction and createPool)
     *      Therefore setting it before then has no effect, so should not be allowed
     * @param newCap - new value of the cap
     */
    function setCap(uint256 newCap) external logs lock needsBPool onlyOwner {
        require(rights.canChangeCap, "ERR_CANNOT_CHANGE_CAP");

        emit CapChanged(msg.sender, bspCap, newCap);

        bspCap = newCap;
    }

    /**
     * @notice Create a new Smart Pool - and set the block period time parameters
     * @dev Initialize the swap fee to the value provided in the CRP constructor
     *      Can be changed if the canChangeSwapFee permission is enabled
     *      Time parameters will be fixed at these values
     *
     *      If this contract doesn't have canChangeWeights permission - or you want to use the default
     *      values, the block time arguments are not needed, and you can just call the single-argument
     *      createPool()
     * @param initialSupply - Starting token balance
     * @param minimumWeightChangeBlockPeriodParam - Enforce a minimum time between the start and end blocks
     * @param addTokenTimeLockInBlocksParam - Enforce a mandatory wait time between updates
     *                                   This is also the wait time between committing and applying a new token
     */
    function createPool(
        uint256 initialSupply,
        uint256 minimumWeightChangeBlockPeriodParam,
        uint256 addTokenTimeLockInBlocksParam
    ) external virtual onlyOwner logs lock {
        require(
            minimumWeightChangeBlockPeriodParam >= addTokenTimeLockInBlocksParam,
            "ERR_INCONSISTENT_TOKEN_TIME_LOCK"
        );

        minimumWeightChangeBlockPeriod = minimumWeightChangeBlockPeriodParam;
        addTokenTimeLockInBlocks = addTokenTimeLockInBlocksParam;

        createPoolInternal(initialSupply);
    }

    /**
     * @notice Create a new Smart Pool
     * @dev Delegates to internal function
     * @param initialSupply starting token balance
     */
    function createPool(uint256 initialSupply) external virtual onlyOwner logs lock {
        createPoolInternal(initialSupply);
    }

    /**
     * @notice Update the weight of an existing token
     * @dev Notice Balance is not an input (like with rebind on BPool) since we will require prices not to change
     *      This is achieved by forcing balances to change proportionally to weights, so that prices don't change
     *      If prices could be changed, this would allow the controller to drain the pool by arbing price changes
     * @param token - token to be reweighted
     * @param newWeight - new weight of the token
     */
    function updateWeight(address token, uint256 newWeight) external virtual logs lock onlyOwner needsBPool {
        require(rights.canChangeWeights, "ERR_NOT_CONFIGURABLE_WEIGHTS");

        // We don't want people to set weights manually if there's a block-based update in progress
        require(gradualUpdate.startBlock == 0, "ERR_NO_UPDATE_DURING_GRADUAL");

        // Delegate to library to save space
        SmartPoolManager.updateWeight(IConfigurableRightsPool(address(this)), bPool, token, newWeight);
    }

    /**
     * @notice Update weights in a predetermined way, between startBlock and endBlock,
     *         through external calls to pokeWeights
     * @dev Must call pokeWeights at least once past the end for it to do the final update
     *      and enable calling this again.
     *      It is possible to call updateWeightsGradually during an update in some use cases
     *      For instance, setting newWeights to currentWeights to stop the update where it is
     * @param newWeights - final weights we want to get to. Note that the ORDER (and number) of
     *                     tokens can change if you have added or removed tokens from the pool
     *                     It ensures the counts are correct, but can't help you with the order!
     *                     You can get the underlying BPool (it's public), and call
     *                     getCurrentTokens() to see the current ordering, if you're not sure
     * @param startBlock - when weights should start to change
     * @param endBlock - when weights will be at their final values
     */
    function updateWeightsGradually(
        uint256[] calldata newWeights,
        uint256 startBlock,
        uint256 endBlock
    ) external virtual logs lock onlyOwner needsBPool {
        require(rights.canChangeWeights, "ERR_NOT_CONFIGURABLE_WEIGHTS");
        // Don't start this when we're in the middle of adding a new token
        require(!newToken.isCommitted, "ERR_PENDING_TOKEN_ADD");

        // Library computes the startBlock, computes startWeights as the current
        // denormalized weights of the core pool tokens.
        SmartPoolManager.updateWeightsGradually(
            bPool,
            gradualUpdate,
            newWeights,
            startBlock,
            endBlock,
            minimumWeightChangeBlockPeriod
        );
    }

    /**
     * @notice External function called to make the contract update weights according to plan
     * @dev Still works if we poke after the end of the period; also works if the weights don't change
     *      Resets if we are poking beyond the end, so that we can do it again
     */
    function pokeWeights() external virtual logs lock needsBPool {
        require(rights.canChangeWeights, "ERR_NOT_CONFIGURABLE_WEIGHTS");

        // Delegate to library to save space
        SmartPoolManager.pokeWeights(bPool, gradualUpdate);
    }

    /**
     * @notice Schedule (commit) a token to be added; must call applyAddToken after a fixed
     *         number of blocks to actually add the token
     *
     * @dev The purpose of this two-stage commit is to give warning of a potentially dangerous
     *      operation. A malicious pool operator could add a large amount of a low-value token,
     *      then drain the pool through price manipulation. Of course, there are many
     *      legitimate purposes, such as adding additional collateral tokens.
     *
     * @param token - the token to be added
     * @param balance - how much to be added
     * @param denormalizedWeight - the desired token weight
     */
    function commitAddToken(
        address token,
        uint256 balance,
        uint256 denormalizedWeight
    ) external virtual logs lock onlyOwner needsBPool {
        require(rights.canAddRemoveTokens, "ERR_CANNOT_ADD_REMOVE_TOKENS");

        // Can't do this while a progressive update is happening
        require(gradualUpdate.startBlock == 0, "ERR_NO_UPDATE_DURING_GRADUAL");

        SmartPoolManager.verifyTokenCompliance(token);

        emit NewTokenCommitted(token, address(this), msg.sender);

        // Delegate to library to save space
        SmartPoolManager.commitAddToken(bPool, token, balance, denormalizedWeight, newToken);
    }

    /**
     * @notice Add the token previously committed (in commitAddToken) to the pool
     */
    function applyAddToken() external virtual logs lock onlyOwner needsBPool {
        require(rights.canAddRemoveTokens, "ERR_CANNOT_ADD_REMOVE_TOKENS");

        // Delegate to library to save space
        SmartPoolManager.applyAddToken(
            IConfigurableRightsPool(address(this)),
            bPool,
            addTokenTimeLockInBlocks,
            newToken
        );
    }

    /**
     * @notice Remove a token from the pool
     * @dev bPool is a contract interface; function calls on it are external
     * @param token - token to remove
     */
    function removeToken(address token) external logs lock onlyOwner needsBPool {
        // It's possible to have remove rights without having add rights
        require(rights.canAddRemoveTokens, "ERR_CANNOT_ADD_REMOVE_TOKENS");
        // After createPool, token list is maintained in the underlying BPool
        require(!newToken.isCommitted, "ERR_REMOVE_WITH_ADD_PENDING");
        // Prevent removing during an update (or token lists can get out of sync)
        require(gradualUpdate.startBlock == 0, "ERR_NO_UPDATE_DURING_GRADUAL");

        // Delegate to library to save space
        SmartPoolManager.removeToken(IConfigurableRightsPool(address(this)), bPool, token);
    }

    /**
     * @notice Join a pool
     * @dev Emits a LogJoin event (for each token)
     *      bPool is a contract interface; function calls on it are external
     * @param poolAmountOut - number of pool tokens to receive
     * @param maxAmountsIn - Max amount of asset tokens to spend
     */
    function joinPool(uint256 poolAmountOut, uint256[] calldata maxAmountsIn)
        external
        onlyWhitelist
        logs
        lock
        needsBPool
        lockUnderlyingPool
    {
        require(!rights.canWhitelistLPs || _liquidityProviderWhitelist[msg.sender] || _liquidityProviderWhitelist[tx.origin], "ERR_NOT_ON_WHITELIST");

        // Delegate to library to save space

        // Library computes actualAmountsIn, and does many validations
        // Cannot call the push/pull/min from an external library for
        // any of these pool functions. Since msg.sender can be anybody,
        // they must be internal
        uint256[] memory actualAmountsIn = SmartPoolManager.joinPool(
            IConfigurableRightsPool(address(this)),
            bPool,
            poolAmountOut,
            maxAmountsIn
        );

        // After createPool, token list is maintained in the underlying BPool
        address[] memory poolTokens = bPool.getCurrentTokens();

        for (uint256 i = 0; i < poolTokens.length; i++) {
            address t = poolTokens[i];
            uint256 tokenAmountIn = actualAmountsIn[i];

            emit LogJoin(msg.sender, t, tokenAmountIn);

            _pullUnderlying(t, msg.sender, tokenAmountIn);
        }

        _mintPoolShare(poolAmountOut);
        _pushPoolShare(msg.sender, poolAmountOut);
    }

    /**
     * @notice Exit a pool - redeem pool tokens for underlying assets
     * @dev Emits a LogExit event for each token
     *      bPool is a contract interface; function calls on it are external
     * @param poolAmountIn - amount of pool tokens to redeem
     * @param minAmountsOut - minimum amount of asset tokens to receive
     */
    function exitPool(uint256 poolAmountIn, uint256[] calldata minAmountsOut)
        external
        onlyWhitelist
        logs
        lock
        needsBPool
        lockUnderlyingPool
    {
        // Delegate to library to save space

        // Library computes actualAmountsOut, and does many validations
        // Also computes the exitFee and pAiAfterExitFee
        (uint256 exitFee, uint256 pAiAfterExitFee, uint256[] memory actualAmountsOut) = SmartPoolManager.exitPool(
            IConfigurableRightsPool(address(this)),
            bPool,
            poolAmountIn,
            minAmountsOut
        );

        _pullPoolShare(msg.sender, poolAmountIn);
        _pushPoolShare(address(bFactory), exitFee);
        _burnPoolShare(pAiAfterExitFee);

        // After createPool, token list is maintained in the underlying BPool
        address[] memory poolTokens = bPool.getCurrentTokens();

        for (uint256 i = 0; i < poolTokens.length; i++) {
            address t = poolTokens[i];
            uint256 tokenAmountOut = actualAmountsOut[i];

            emit LogExit(msg.sender, t, tokenAmountOut);

            _pushUnderlying(t, msg.sender, tokenAmountOut);
        }
    }

    /**
     * @notice Join by swapping a fixed amount of an external token in (must be present in the pool)
     *         System calculates the pool token amount
     * @dev emits a LogJoin event
     * @param tokenIn - which token we're transferring in
     * @param tokenAmountIn - amount of deposit
     * @param minPoolAmountOut - minimum of pool tokens to receive
     * @return poolAmountOut - amount of pool tokens minted and transferred
     */
    function joinswapExternAmountIn(
        address tokenIn,
        uint256 tokenAmountIn,
        uint256 minPoolAmountOut
    ) external onlyWhitelist logs lock needsBPool returns (uint256 poolAmountOut) {
        require(!rights.canWhitelistLPs || _liquidityProviderWhitelist[msg.sender] || _liquidityProviderWhitelist[tx.origin], "ERR_NOT_ON_WHITELIST");

        // Delegate to library to save space
        poolAmountOut = SmartPoolManager.joinswapExternAmountIn(
            IConfigurableRightsPool(address(this)),
            bPool,
            tokenIn,
            tokenAmountIn,
            minPoolAmountOut
        );

        emit LogJoin(msg.sender, tokenIn, tokenAmountIn);

        _mintPoolShare(poolAmountOut);
        _pushPoolShare(msg.sender, poolAmountOut);
        _pullUnderlying(tokenIn, msg.sender, tokenAmountIn);

        return poolAmountOut;
    }

    /**
     * @notice Join by swapping an external token in (must be present in the pool)
     *         To receive an exact amount of pool tokens out. System calculates the deposit amount
     * @dev emits a LogJoin event
     * @param tokenIn - which token we're transferring in (system calculates amount required)
     * @param poolAmountOut - amount of pool tokens to be received
     * @param maxAmountIn - Maximum asset tokens that can be pulled to pay for the pool tokens
     * @return tokenAmountIn - amount of asset tokens transferred in to purchase the pool tokens
     */
    function joinswapPoolAmountOut(
        address tokenIn,
        uint256 poolAmountOut,
        uint256 maxAmountIn
    ) external onlyWhitelist logs lock needsBPool returns (uint256 tokenAmountIn) {
        require(!rights.canWhitelistLPs || _liquidityProviderWhitelist[msg.sender] || _liquidityProviderWhitelist[tx.origin], "ERR_NOT_ON_WHITELIST");

        // Delegate to library to save space
        tokenAmountIn = SmartPoolManager.joinswapPoolAmountOut(
            IConfigurableRightsPool(address(this)),
            bPool,
            tokenIn,
            poolAmountOut,
            maxAmountIn
        );

        emit LogJoin(msg.sender, tokenIn, tokenAmountIn);

        _mintPoolShare(poolAmountOut);
        _pushPoolShare(msg.sender, poolAmountOut);
        _pullUnderlying(tokenIn, msg.sender, tokenAmountIn);

        return tokenAmountIn;
    }

    /**
     * @notice Exit a pool - redeem a specific number of pool tokens for an underlying asset
     *         Asset must be present in the pool, and will incur an EXIT_FEE (if set to non-zero)
     * @dev Emits a LogExit event for the token
     * @param tokenOut - which token the caller wants to receive
     * @param poolAmountIn - amount of pool tokens to redeem
     * @param minAmountOut - minimum asset tokens to receive
     * @return tokenAmountOut - amount of asset tokens returned
     */
    function exitswapPoolAmountIn(
        address tokenOut,
        uint256 poolAmountIn,
        uint256 minAmountOut
    ) external onlyWhitelist logs lock needsBPool returns (uint256 tokenAmountOut) {
        // Delegate to library to save space

        // Calculates final amountOut, and the fee and final amount in
        (uint256 exitFee, uint256 amountOut) = SmartPoolManager.exitswapPoolAmountIn(
            IConfigurableRightsPool(address(this)),
            bPool,
            tokenOut,
            poolAmountIn,
            minAmountOut
        );

        tokenAmountOut = amountOut;
        uint256 pAiAfterExitFee = BalancerSafeMath.bsub(poolAmountIn, exitFee);

        emit LogExit(msg.sender, tokenOut, tokenAmountOut);

        _pullPoolShare(msg.sender, poolAmountIn);
        _burnPoolShare(pAiAfterExitFee);
        _pushPoolShare(address(bFactory), exitFee);
        _pushUnderlying(tokenOut, msg.sender, tokenAmountOut);

        return tokenAmountOut;
    }

    /**
     * @notice Exit a pool - redeem pool tokens for a specific amount of underlying assets
     *         Asset must be present in the pool
     * @dev Emits a LogExit event for the token
     * @param tokenOut - which token the caller wants to receive
     * @param tokenAmountOut - amount of underlying asset tokens to receive
     * @param maxPoolAmountIn - maximum pool tokens to be redeemed
     * @return poolAmountIn - amount of pool tokens redeemed
     */
    function exitswapExternAmountOut(
        address tokenOut,
        uint256 tokenAmountOut,
        uint256 maxPoolAmountIn
    ) external onlyWhitelist logs lock needsBPool returns (uint256 poolAmountIn) {
        // Delegate to library to save space

        // Calculates final amounts in, accounting for the exit fee
        (uint256 exitFee, uint256 amountIn) = SmartPoolManager.exitswapExternAmountOut(
            IConfigurableRightsPool(address(this)),
            bPool,
            tokenOut,
            tokenAmountOut,
            maxPoolAmountIn
        );

        poolAmountIn = amountIn;
        uint256 pAiAfterExitFee = BalancerSafeMath.bsub(poolAmountIn, exitFee);

        emit LogExit(msg.sender, tokenOut, tokenAmountOut);

        _pullPoolShare(msg.sender, poolAmountIn);
        _burnPoolShare(pAiAfterExitFee);
        _pushPoolShare(address(bFactory), exitFee);
        _pushUnderlying(tokenOut, msg.sender, tokenAmountOut);

        return poolAmountIn;
    }

    /**
     * @notice Getter for specific permissions
     * @dev value of the enum is just the 0-based index in the enumeration
     *      For instance canPauseSwapping is 0; canChangeWeights is 2
     * @return token boolean true if we have the given permission
     */
    function hasPermission(RightsManager.Permissions permission) external view virtual returns (bool) {
        return RightsManager.hasPermission(rights, permission);
    }

    /**
     * @notice Getter for the RightsManager contract
     * @dev Convenience function to get the address of the RightsManager library (so clients can check version)
     * @return address of the RightsManager library
     */
    function getRightsManagerVersion() external pure returns (address) {
        return address(RightsManager);
    }

    /**
     * @notice Getter for the BalancerSafeMath contract
     * @dev Convenience function to get the address of the BalancerSafeMath library (so clients can check version)
     * @return address of the BalancerSafeMath library
     */
    function getBalancerSafeMathVersion() external pure returns (address) {
        return address(BalancerSafeMath);
    }

    /**
     * @notice Getter for the SmartPoolManager contract
     * @dev Convenience function to get the address of the SmartPoolManager library (so clients can check version)
     * @return address of the SmartPoolManager library
     */
    function getSmartPoolManagerVersion() external pure returns (address) {
        return address(SmartPoolManager);
    }

    // Public functions

    // "Public" versions that can safely be called from SmartPoolManager
    // Allows only the contract itself to call them (not the controller or any external account)

    function mintPoolShareFromLib(uint256 amount) public {
        require(msg.sender == address(this), "ERR_NOT_CONTROLLER");

        _mint(amount);
    }

    function pushPoolShareFromLib(address to, uint256 amount) public {
        require(msg.sender == address(this), "ERR_NOT_CONTROLLER");

        _push(to, amount);
    }

    function pullPoolShareFromLib(address from, uint256 amount) public {
        require(msg.sender == address(this), "ERR_NOT_CONTROLLER");

        _pull(from, amount);
    }

    function burnPoolShareFromLib(uint256 amount) public {
        require(msg.sender == address(this), "ERR_NOT_CONTROLLER");

        _burn(amount);
    }

    // Internal functions

    // Lint wants the function to have a leading underscore too
    /* solhint-disable private-vars-leading-underscore */

    /**
     * @notice Create a new Smart Pool
     * @dev Initialize the swap fee to the value provided in the CRP constructor
     *      Can be changed if the canChangeSwapFee permission is enabled
     * @param initialSupply starting token balance
     */
    function createPoolInternal(uint256 initialSupply) internal {
        require(address(bPool) == address(0), "ERR_IS_CREATED");
        require(initialSupply >= BalancerConstants.MIN_POOL_SUPPLY, "ERR_INIT_SUPPLY_MIN");
        require(initialSupply <= BalancerConstants.MAX_POOL_SUPPLY, "ERR_INIT_SUPPLY_MAX");

        // If the controller can change the cap, initialize it to the initial supply
        // Defensive programming, so that there is no gap between creating the pool
        // (initialized to unlimited in the constructor), and setting the cap,
        // which they will presumably do if they have this right.
        if (rights.canChangeCap) {
            bspCap = initialSupply;
        }

        // There is technically reentrancy here, since we're making external calls and
        // then transferring tokens. However, the external calls are all to the underlying BPool

        // To the extent possible, modify state variables before calling functions
        _mintPoolShare(initialSupply);
        _pushPoolShare(msg.sender, initialSupply);

        // Deploy new BPool (bFactory and bPool are interfaces; all calls are external)
        bPool = bFactory.newBPool();

        // EXIT_FEE must always be zero, or ConfigurableRightsPool._pushUnderlying will fail
        require(bPool.EXIT_FEE() == 0, "ERR_NONZERO_EXIT_FEE");
        require(BalancerConstants.EXIT_FEE == 0, "ERR_NONZERO_EXIT_FEE");

        for (uint256 i = 0; i < _initialTokens.length; i++) {
            address t = _initialTokens[i];
            uint256 bal = _initialBalances[i];
            uint256 denorm = gradualUpdate.startWeights[i];

            bool returnValue = IERC20(t).transferFrom(msg.sender, address(this), bal);
            require(returnValue, "ERR_ERC20_FALSE");

            returnValue = IERC20(t).safeApprove(address(bPool), BalancerConstants.MAX_UINT);
            require(returnValue, "ERR_ERC20_FALSE");

            bPool.bind(t, bal, denorm);
        }

        while (_initialTokens.length > 0) {
            // Modifying state variable after external calls here,
            // but not essential, so not dangerous
            _initialTokens.pop();
        }

        // Set fee to the initial value set in the constructor
        // Hereafter, read the swapFee from the underlying pool, not the local state variable
        bPool.setSwapFee(_initialSwapFee);
        bPool.setPublicSwap(true);
        bPool.setProtocolFee(_initialProtocolFee);
        bPool.setAccessControlAddress(_initialAccessAddress);

        // "destroy" the temporary swap fee (like _initialTokens above) in case a subclass tries to use it
        _initialSwapFee = 0;
        _initialProtocolFee = 0;
    }

    /* solhint-enable private-vars-leading-underscore */

    // Rebind BPool and pull tokens from address
    // bPool is a contract interface; function calls on it are external
    function _pullUnderlying(
        address erc20,
        address from,
        uint256 amount
    ) internal needsBPool {
        // Gets current Balance of token i, Bi, and weight of token i, Wi, from BPool.
        uint256 tokenBalance = bPool.getBalance(erc20);
        uint256 tokenWeight = bPool.getDenormalizedWeight(erc20);

        bool xfer = IERC20(erc20).transferFrom(from, address(this), amount);
        require(xfer, "ERR_ERC20_FALSE");
        bPool.rebind(erc20, BalancerSafeMath.badd(tokenBalance, amount), tokenWeight);
    }

    // Rebind BPool and push tokens to address
    // bPool is a contract interface; function calls on it are external
    function _pushUnderlying(
        address erc20,
        address to,
        uint256 amount
    ) internal needsBPool {
        // Gets current Balance of token i, Bi, and weight of token i, Wi, from BPool.
        uint256 tokenBalance = bPool.getBalance(erc20);
        uint256 tokenWeight = bPool.getDenormalizedWeight(erc20);
        bPool.rebind(erc20, BalancerSafeMath.bsub(tokenBalance, amount), tokenWeight);

        bool xfer = IERC20(erc20).transfer(to, amount);
        require(xfer, "ERR_ERC20_FALSE");
    }

    // Wrappers around corresponding core functions

    //
    function _mint(uint256 amount) internal override {
        super._mint(amount);
        require(varTotalSupply <= bspCap, "ERR_CAP_LIMIT_REACHED");
    }

    function _mintPoolShare(uint256 amount) internal {
        _mint(amount);
    }

    function _pushPoolShare(address to, uint256 amount) internal {
        _push(to, amount);
    }

    function _pullPoolShare(address from, uint256 amount) internal {
        _pull(from, amount);
    }

    function _burnPoolShare(uint256 amount) internal {
        _burn(amount);
    }
}
