// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal mock for HyperCore account margin summary precompile (0x...080F).
///         Always returns a successful abi-encoded AccountMarginSummary
///         (int64 accountValue, uint64 marginUsed, uint64 ntlPos, int64 rawUsd).
contract MockAccountMarginSummaryPrecompile {
    int64 public accountValue;
    uint64 public marginUsed;
    uint64 public ntlPos;
    int64 public rawUsd;

    function setSummary(int64 accountValue_, uint64 marginUsed_, uint64 ntlPos_, int64 rawUsd_) external {
        accountValue = accountValue_;
        marginUsed = marginUsed_;
        ntlPos = ntlPos_;
        rawUsd = rawUsd_;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(accountValue, marginUsed, ntlPos, rawUsd);
    }
}
