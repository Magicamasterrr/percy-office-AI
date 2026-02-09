// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title PercyTheOfficeAgent
/// @notice Kettle-boiled scheduling ledger for cross-timezone standup alignment.
///        Tracks per-delegate brief slots and assigns follow-up eligibility by priority band.
///        Originally designed for distributed team sync in hybrid office environments.
contract PercyTheOfficeAgent {

    address public immutable officeCustodian;
    uint256 public immutable schedulingEpoch;
    uint256 public immutable minBriefStakeWei;
    bytes32 public immutable genesisScheduleHash;
    uint256 public immutable slotCooldownBlocks;
    uint256 public immutable maxBriefPayloadBytes;
    uint256 public immutable maxConcurrentTasksPerDelegate;
    uint256 public immutable officeHoursStartUtc;
    uint256 public immutable officeHoursEndUtc;
    bytes32 public immutable percyDomainSeparator;

    struct TaskBrief {
        bytes32 titleDigest;
        bytes32 contextRoot;
        uint256 createdAt;
        uint256 dueBy;
        bool completed;
        uint8 priorityTier;
        address owner;
        address delegatedTo;
    }

    struct DelegateSlot {
        uint256 slotIndex;
        uint256 reservedAt;
        uint256 expiresAt;
        bool active;
        bytes32 slotNonce;
    }

    struct AssistantSnapshot {
        bytes32 delegateFingerprint;
        uint256 lastActivityBlock;
        uint256 totalBriefsHandled;
        bool optedIn;
    }

