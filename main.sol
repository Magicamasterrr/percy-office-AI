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
        });
        _titleToBriefId[titleDigest_] = id;
        _totalStaked += msg.value;

        emit BriefSubmitted(id, titleDigest_, msg.sender, priorityTier_);
    }

    function completeBrief(uint256 briefId_) external {
        TaskBrief storage b = _briefs[briefId_];
        if (b.owner == address(0)) revert PercyBriefNotFound();
        if (b.completed) revert PercyBriefAlreadyCompleted();
        if (b.owner != msg.sender && b.delegatedTo != msg.sender) revert PercyCustodianOnly();

        b.completed = true;
        if (b.delegatedTo != address(0)) {
            _activeDelegatedCount[b.delegatedTo]--;
        }
        if (_assistants[msg.sender].delegateFingerprint != bytes32(0)) {
            _assistants[msg.sender].totalBriefsHandled++;
            _assistants[msg.sender].lastActivityBlock = block.number;
        }
        emit BriefCompleted(briefId_, msg.sender);
    }

    function delegateBrief(uint256 briefId_, address to_) external {
        TaskBrief storage b = _briefs[briefId_];
        if (b.owner == address(0)) revert PercyBriefNotFound();
        if (b.completed) revert PercyBriefAlreadyCompleted();
        if (b.owner != msg.sender) revert PercyCustodianOnly();
        if (!_assistants[to_].optedIn) revert PercyAssistantNotOptedIn();
        if (_activeDelegatedCount[to_] >= maxConcurrentTasksPerDelegate) revert PercyMaxTasksExceeded();

        if (b.delegatedTo != address(0)) {
            _activeDelegatedCount[b.delegatedTo]--;
        }
        b.delegatedTo = to_;
        _activeDelegatedCount[to_]++;
    }

    function optInAssistant(bytes32 delegateFingerprint_) external {
        _assistants[msg.sender] = AssistantSnapshot({
            delegateFingerprint: delegateFingerprint_,
            lastActivityBlock: block.number,
            totalBriefsHandled: _assistants[msg.sender].totalBriefsHandled,
            optedIn: true
        });
        emit AssistantOptedIn(msg.sender, delegateFingerprint_);
    }

    function reserveSlot(uint256 slotIndex_, uint256 durationBlocks_) external {
        if (!_assistants[msg.sender].optedIn) revert PercyAssistantNotOptedIn();
        DelegateSlot storage s = _slots[msg.sender][slotIndex_];
        if (s.active && s.expiresAt > block.number) revert PercySlotNotExpired();
        if (durationBlocks_ < PERCY_MIN_SLOT_DURATION_BLOCKS) revert PercySlotDurationTooShort();

        uint256 expiresAt = block.number + durationBlocks_;
        s.slotIndex = slotIndex_;
        s.reservedAt = block.number;
        s.expiresAt = expiresAt;
        s.active = true;
        s.slotNonce = keccak256(abi.encodePacked(msg.sender, slotIndex_, block.timestamp, block.prevrandao));

        emit SlotReserved(msg.sender, slotIndex_, expiresAt);
    }

    function getBrief(uint256 briefId_) external view returns (
        bytes32 titleDigest,
        bytes32 contextRoot,
        uint256 createdAt,
        uint256 dueBy,
        bool completed,
        uint8 priorityTier,
        address owner,
        address delegatedTo
    ) {
        TaskBrief storage b = _briefs[briefId_];
        return (
            b.titleDigest,
            b.contextRoot,
            b.createdAt,
            b.dueBy,
            b.completed,
            b.priorityTier,
            b.owner,
            b.delegatedTo
        );
    }

    function getAssistantSnapshot(address assistant_) external view returns (
        bytes32 delegateFingerprint,
        uint256 lastActivityBlock,
        uint256 totalBriefsHandled,
