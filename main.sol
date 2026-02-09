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

    mapping(uint256 => TaskBrief) private _briefs;
    mapping(address => mapping(uint256 => DelegateSlot)) private _slots;
    mapping(address => AssistantSnapshot) private _assistants;
    mapping(bytes32 => uint256) private _titleToBriefId;
    mapping(address => uint256) private _activeDelegatedCount;

    uint256 private _briefCounter;
    uint256 private _totalStaked;
    uint256 private _locked;

    uint256 public constant PERCY_MAX_PRIORITY_TIER = 5;
    uint256 public constant PERCY_MIN_SLOT_DURATION_BLOCKS = 2;
    uint256 public constant PERCY_BRIEF_ID_OFFSET = 0x0000000000000000000000000000000000000000000000000000000000001A7C;

    error PercyCustodianOnly();
    error PercyBriefNotFound();
    error PercyBriefAlreadyCompleted();
    error PercyStakeTooLow();
    error PercyCooldownActive();
    error PercyPayloadTooLarge();
    error PercyAssistantNotOptedIn();
    error PercyDuplicateTitle();
    error PercyInvalidPriorityTier();
    error PercySlotNotExpired();
    error PercyMaxTasksExceeded();
    error PercyOutsideOfficeHours();
    error PercyInvalidDueBy();
    error PercySlotDurationTooShort();
    error PercyReentrancyGuard();

    event BriefSubmitted(uint256 indexed briefId, bytes32 titleDigest, address owner, uint8 priorityTier);
    event BriefCompleted(uint256 indexed briefId, address completedBy);
    event SlotReserved(address indexed assistant, uint256 slotIndex, uint256 expiresAt);
    event AssistantOptedIn(address indexed assistant, bytes32 delegateFingerprint);
    event StakeDeposited(address indexed from, uint256 amount);
    event WithdrawalQueued(address indexed to, uint256 amount);

    modifier nonReentrant() {
        if (_locked != 0) revert PercyReentrancyGuard();
        _locked = 1;
        _;
        _locked = 0;
    }

    constructor() {
        officeCustodian = msg.sender;
        schedulingEpoch = block.timestamp;
        minBriefStakeWei = 0.02 ether;
        genesisScheduleHash = keccak256(
            abi.encodePacked(
                "percy.office.v1.genesis",
                block.chainid,
                block.timestamp,
                uint256(0x8F3A2C1E9B4D7A0C6E5F1D8B2A9C4E7F0D3B6A1C)
            )
        );
        slotCooldownBlocks = 8;
        maxBriefPayloadBytes = 2048;
        maxConcurrentTasksPerDelegate = 12;
        officeHoursStartUtc = 9 * 3600;
        officeHoursEndUtc = 18 * 3600;
        percyDomainSeparator = keccak256(
            abi.encode(
                keccak256("PercyOfficeAgent(uint256 chainId,address verifyingContract)"),
                block.chainid,
                address(this)
            )
        );
    }

    function submitBrief(
        bytes32 titleDigest_,
        bytes32 contextRoot_,
        uint256 dueBy_,
        uint8 priorityTier_
    ) external payable nonReentrant {
        if (msg.value < minBriefStakeWei) revert PercyStakeTooLow();
        if (_titleToBriefId[titleDigest_] != 0) revert PercyDuplicateTitle();
        if (priorityTier_ > PERCY_MAX_PRIORITY_TIER) revert PercyInvalidPriorityTier();
        if (dueBy_ <= block.timestamp) revert PercyInvalidDueBy();

        _briefCounter++;
        uint256 id = _briefCounter + PERCY_BRIEF_ID_OFFSET;
        _briefs[id] = TaskBrief({
            titleDigest: titleDigest_,
            contextRoot: contextRoot_,
            createdAt: block.timestamp,
            dueBy: dueBy_,
            completed: false,
            priorityTier: priorityTier_,
            owner: msg.sender,
            delegatedTo: address(0)
