// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title  Vendored Pons launch venue interfaces (factory + locker)
/// @notice PROVENANCE: transcribed from the verified `PonsLaunchFactory` at
///         `0xA5aAb3F0c6EeadF30Ef1D3Eb997108E976351feB` and the verified
///         `PonsLaunchLocker` at `0x736D76699C26D0d966744cAe304C000d471f7F35`
///         on Robinhood Chain 4663 (compiler `v0.8.30+commit.73712a01`),
///         fetched from `robinhoodchain.blockscout.com`. Every selector, struct
///         field order and field width below is byte-identical to that source.
///
///         TWO CONTRACTS, ONE VENUE, and the split is the whole reason this
///         adapter looks different from the Sushi one. The FACTORY mints and
///         pools; the LOCKER permanently holds the LP NFT and owns the fee
///         policy. `launchToken` names a `feeWallet` that does DOUBLE DUTY —
///         it is both the dev buy's recipient and the initial fee redirect —
///         and only the locker can separate the two afterwards. See
///         `PonsLaunchAdapter.launch`.
///
///         WHICH VERSION. There are two Pons factories on 4663. The v1 at
///         `0x0c37a24F5D23A486FA692d1500881d698B1F77a4` carries the IDENTICAL
///         `launchEnabled` gate under the same owner, so it offers no path v2
///         does not; this file is written against the v2/active deployment.
///
///         REDUCED SURFACE — vendored is only what `PonsLaunchAdapter` calls
///         plus what the deploy ceremony asserts identity with, following the
///         `ISushiLaunchpad` / `IMorpho` precedent. Deliberately NOT vendored:
///           - every `onlyOwner` setter (`setLaunchFee`, `setLaunchEnabled`,
///             `setWhitelistedLauncher`, `addLaunchConfig`, `addDexConfig`,
///             `setDexStatus`, `updateLaunchConfig`, and the locker's
///             `setFeeCollector` / `setProtocolFeeRecipient` /
///             `setProtocolFeeShare`) — venue governance, not ours. Their
///             effects are read live through the views below.
///           - `predictTokenAddress`, `lockPosition`, `onERC721Received`, the
///             `deployerTokens` / `feeRecipientTokens` enumerations, and every
///             event.
///           - `graduationStatus` IS vendored but never called on-chain; see
///             `PonsLaunchAdapter.phase` for why graduation is not a phase.
///
///         PRAGMA: upstream compiles under `v0.8.30`; this file declares
///         `0.8.28` to match the repo. Behaviour-preserving — an `interface`
///         emits no bytecode, and ABI encoding of these signatures is identical
///         across both compiler versions (no user-defined value types, no
///         transient storage, no custom-error layout changes between them).
///
///         VENUE FACTS the adapter depends on, each verified live on 4663 at
///         block ~51.14M and each the reason a member below is here:
///           - `launchEnabled() == false` and `launchToken` opens with
///             `if (!launchEnabled && !whitelistedLaunchers[msg.sender]) revert
///             NotWhitelisted();`. The venue is CLOSED. This adapter is inert
///             until Pons flips the flag or whitelists the adapter address —
///             which is per-address, and is the reason the adapter must be a
///             singleton rather than a per-launch clone.
///           - `launchFee() == 5e14` wei of NATIVE, taken from `msg.value` and
///             forwarded to `locker.protocolFeeRecipient()`. Repriceable by the
///             owner, hence the live read in `nativeFeeSource()`.
///           - `initialBuyAmount = msg.value - launchFee`, so the dev buy is
///             ALSO funded in native — unlike Sushi, where only the fee was.
///           - The whole `supply` goes into a one-sided V3 position that is
///             transferred to the LOCKER and locked. The creator receives ZERO
///             tokens, so the dev buy IS the fund's reserve — hence the
///             adapter's insistence on a nonzero `quoteIn`.
///           - `launchConfigCount() == 1`, `dexConfigCount() == 1`. Config 0 is
///             `{pairToken: WETH, graduationThreshold: 4.2e18, initialTick:
///             -204200, supply: 1e27, maxWalletBps: 500, maxTxBps: 550,
///             restrictionBlocks: 2, reservedFee: 0, enabled: true,
///             routerRequiresDeadline: false}`; dex 0 is `uniswap v3` at pool
///             fee 10000 / tick spacing 200, enabled.
///           - `locker.protocolFeeShare() == 30` (percent), snapshotted per
///             token at lock time — so the fee RECIPIENT receives the gross
///             `collect` minus 30%, and `collectFees` must report the
///             recipient's own deltas rather than the locker's return tuple.
///           - THE INITIAL BUY CARRIES NO SLIPPAGE FLOOR. The factory passes
///             `amountOutMinimum: 0` to the router. Nothing at the venue
///             enforces `minTokensOut`, so the adapter's own post-launch
///             balance check is the ONLY thing that does — the opposite of
///             Sushi, where `InsufficientInitialBuyOutput` was the primary
///             guard and the adapter's check was belt-and-braces.
///           - The launch token's `maxWalletBps` / `maxTxBps` restrictions do
///             NOT apply to the atomic launch buy: the factory opens a
///             one-call `_initialBuyRecipient` exemption around it. The reserve
///             is therefore not capped at 5% of supply.
///           - Reverts the adapter relies on rather than duplicating:
///             `NotWhitelisted` (the gate), `LaunchFeeNotPaid`
///             (`msg.value < launchFee`), `InvalidLaunchConfigId` /
///             `LaunchConfigDisabled` / `InvalidDexId` / `DexDisabled`,
///             `PoolAlreadyExists` and `TokenDeploymentFailed` (the CREATE2
///             collision the adapter's salt namespacing exists to avoid),
///             `NoFeesToCollect` (locker, nothing accrued), `TokenNotFound`
///             (locker and `graduationStatus`, on an unissued token).
///           - `getLaunchedToken` DOES NOT REVERT on an unissued token: it
///             returns a zero-filled struct with `exists == false`. That is the
///             opposite of Sushi's `launchInfo`, and it is why `phase` keys off
///             `exists` rather than off the call succeeding.
///           - Both contracts are `ReentrancyGuard`ed on every state-changing
///             entry point, and `locker.factory()` / `factory.locker()` point
///             at each other.
interface IPonsLaunchFactory {
    /// @notice Social handles carried into the token's own metadata. FIVE
    ///         members, in this order — the arity is load-bearing because it is
    ///         part of `launchToken`'s selector and part of the CREATE2 init
    ///         code hash.
    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    /// @notice Metadata and — in `feeWallet` — the venue's only routing knob.
    /// @dev `feeWallet` DOES DOUBLE DUTY inside `launchToken`, and untangling
    ///      that is the adapter's central problem:
    ///        - `initialBuyRecipient = feeWallet == address(0) ? msg.sender
    ///          : feeWallet` — it is where the dev buy lands;
    ///        - `if (feeWallet != address(0)) locker.setFeeRedirect(token,
    ///          feeWallet)` — it is also where LP fees are pointed.
    ///      The template needs those to be two DIFFERENT addresses (reserve to
    ///      the strategy, fees to the vault), which is why `launch` names the
    ///      strategy here and re-points the locker in the same transaction.
    struct TokenParams {
        string name;
        string symbol;
        string logo;
        string description;
        Socials socials;
        address feeWallet;
    }

    /// @notice One pairing/economics preset. Owner-managed, so `quoteSupported`
    ///         reads the live set rather than keeping an allowlist here.
    /// @dev `pairToken` is the asset a launch is paired against — the
    ///      `ILaunchAdapter` "quote". `routerRequiresDeadline` selects which of
    ///      two `exactInputSingle` shapes the factory calls for the dev buy.
    struct LaunchConfig {
        address pairToken;
        uint256 graduationThreshold;
        int24 initialTick;
        uint256 supply;
        uint16 maxWalletBps;
        uint16 maxTxBps;
        uint32 restrictionBlocks;
        uint24 reservedFee;
        bool enabled;
        bool routerRequiresDeadline;
    }

    /// @notice One V3 deployment the venue can pool into.
    struct DexConfig {
        string name;
        address factory;
        address positionManager;
        address swapRouter;
        uint24 poolFee;
        int24 tickSpacing;
        bool enabled;
    }

    /// @notice Per-launch venue record. FULLY STATIC — thirteen in-place words,
    ///         which is what lets `phase` read it by length-checked raw
    ///         staticcall. `exists` is word 11; `deployer` is word 1.
    /// @dev `deployer` is `msg.sender` of `launchToken` — this adapter, for
    ///      every launch it issued — and it is the authority the locker checks
    ///      in `setFeeRedirect` and `collectFees`.
    struct LaunchedToken {
        address token;
        address deployer;
        address pairedToken;
        address positionManager;
        uint256 positionId;
        uint256 dexId;
        uint256 launchConfigId;
        uint256 restrictionsEndBlock;
        uint256 supply;
        bool isToken0;
        uint24 poolFee;
        bool exists;
        uint256 initialBuyAmount;
    }

    /// @notice Deploy, pool, lock, record and (with any `msg.value` above the
    ///         launch fee) buy — all in this one transaction, which is why the
    ///         adapter reports `Live` immediately and makes `finalize` a no-op.
    /// @dev GATED: reverts `NotWhitelisted` unless `launchEnabled` or the
    ///      caller is a whitelisted launcher. `salt` seeds the CREATE2 that
    ///      mints the token; the init code hash covers the metadata, the
    ///      config/dex parameters and the DEPLOYER — so a shared adapter
    ///      launching identical metadata twice under one salt would collide.
    function launchToken(TokenParams calldata params, uint256 launchConfigId, uint256 dexId, bytes32 salt)
        external
        payable
        returns (address token);

    /// @notice Per-launch record. DOES NOT REVERT for an unissued token — it
    ///         returns a zero struct whose `exists` is false.
    function getLaunchedToken(address token) external view returns (LaunchedToken memory);

    /// @notice Paired-token principal still in the locked position, against the
    ///         config's threshold.
    /// @dev REVERTS `TokenNotFound` on an unissued token, and reads a pool's
    ///      `slot0` plus the position manager. Vendored for completeness and
    ///      for off-chain readers; `PonsLaunchAdapter` never calls it — see the
    ///      note on `phase` for why graduation is not a lifecycle phase here.
    function graduationStatus(address token)
        external
        view
        returns (uint256 pairedPrincipal, uint256 threshold, bool graduated);

    /// @notice One launch configuration. REVERTS `InvalidLaunchConfigId` when
    ///         `id >= launchConfigCount()`.
    function getLaunchConfig(uint256 id) external view returns (LaunchConfig memory);

    /// @notice One V3 deployment configuration. REVERTS `InvalidDexId` when
    ///         `id >= dexConfigCount()`.
    function getDexConfig(uint256 id) external view returns (DexConfig memory);

    /// @notice How many launch configurations exist. Owner-growable, which is
    ///         why `quoteSupported` iterates it live and bounds the scan.
    function launchConfigCount() external view returns (uint256);

    /// @notice How many V3 deployments exist.
    function dexConfigCount() external view returns (uint256);

    /// @notice Native launch fee, in wei. Repriceable by the venue owner.
    function launchFee() external view returns (uint256);

    /// @notice Whether launches are open to non-whitelisted callers. FALSE on
    ///         4663 today — the live blocker this adapter is written against.
    function launchEnabled() external view returns (bool);

    /// @notice Per-address launch permission while the public gate is closed.
    ///         Per-ADDRESS, which is why the adapter is a singleton.
    function whitelistedLaunchers(address launcher) external view returns (bool);

    /// @notice The locker this factory locks positions into and redirects fees
    ///         through. Read in the adapter's constructor so the pair cannot be
    ///         mis-wired, and round-tripped by the deploy ceremony.
    function locker() external view returns (address);
}

/// @notice The permanent LP-position custodian and the venue's fee policy.
interface IPonsLaunchLocker {
    /// @notice Re-point one launch's creator fee share.
    /// @dev AUTHORISED FOR `launched.deployer` OR the factory. The adapter is
    ///      the deployer of every launch it issues, so it may call this — which
    ///      is exactly what makes the reserve/fee split expressible in one
    ///      transaction, and exactly the residual power `PonsLaunchAdapter`'s
    ///      header addresses.
    function setFeeRedirect(address token, address newFeeWallet) external;

    /// @notice Collect the position's V3 fees and split them between
    ///         `protocolFeeRecipient` and the token's fee recipient.
    /// @dev NOT permissionless at the venue: the caller must be the locker
    ///      owner, the launch's `deployer`, the current recipient, or an
    ///      allowlisted `feeCollectors` entry. The adapter IS the deployer, so
    ///      driving this THROUGH the adapter is permissionless on our side.
    ///
    ///      REVERTS `NoFeesToCollect()` when the position yields nothing, and
    ///      `TokenNotFound()` for an unissued or unlocked token — both of which
    ///      the adapter tolerates rather than propagating.
    ///
    ///      RETURNS THE GROSS, not the recipient's share: the protocol keeps
    ///      `tokenProtocolFeeShares[token]` percent (30 today) before the
    ///      recipient is paid. `collectFees` therefore measures balances.
    function collectFees(address token) external returns (uint256 amount0, uint256 amount1);

    /// @notice Current fee destination for one launch; `address(0)` means the
    ///         locker falls back to `launched.deployer`.
    function feeRedirects(address token) external view returns (address);

    /// @notice The factory this locker is permanently bound to.
    function factory() external view returns (address);

    /// @notice Percent of collected fees the protocol keeps on FUTURE locks.
    function protocolFeeShare() external view returns (uint256);

    /// @notice Where the factory forwards the native launch fee.
    function protocolFeeRecipient() external view returns (address);
}

/// @notice Minimal wrapped-native surface. Named `IWrappedNative` rather than
///         `IWETH` so a file may import this vendor set alongside the Sushi one
///         without a symbol clash.
interface IWrappedNative {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
