// SPDX-License-Identifier: AGPL-3.0-only

pragma solidity 0.8.10;

import {ICollectModule} from '../../../interfaces/ICollectModule.sol';
import {Errors} from '../../../libraries/Errors.sol';
import {FeeModuleBase} from '../FeeModuleBase.sol';
import {ModuleBase} from '../ModuleBase.sol';
import {FollowValidationModuleBase} from '../FollowValidationModuleBase.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import '@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol';
import '@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol';

/**
 * @notice A struct containing the necessary data to execute collect actions on a publication.
 *
 * @param amount The collecting cost associated with this publication.
 * @param recipient The recipient address associated with this publication.
 * @param currency The currency associated with this publication.
 * @param referralFee The referral fee associated with this publication.
 */
struct ProfilePublicationData {
    uint256 amount;
    address recipient;
    address currency;
    uint16 referralFee;
    uint256 raffleAmount;
    uint256 rafflePercent;
    uint256 raffleFrequency;
    address[] collectors;
}

struct RequestData {
    uint256 profileId;
    uint256 pubId;
}

/**
 * @title RaffleCollectModule
 * @author Lens Protocol
 *
 * @notice This is a simple Lens CollectModule implementation, inheriting from the ICollectModule interface and
 * the FeeCollectModuleBase abstract contract.
 *
 * This module works by allowing unlimited collects for a publication at a given price.
 */
contract RaffleCollectModule is
    ICollectModule,
    FeeModuleBase,
    FollowValidationModuleBase,
    VRFConsumerBaseV2
{
    using SafeERC20 for IERC20;

    VRFCoordinatorV2Interface public vrfCoordinator;
    uint64 public vrfSubscriptionId;

    mapping(uint256 => RequestData) internal requests;
    mapping(uint256 => mapping(uint256 => ProfilePublicationData))
        internal _dataByPublicationByProfile;

    bytes32 private vrfKeyHash;
    uint32 private constant callbackGasLimit = 100000;
    uint16 private constant requestConfirmations = 3;

    constructor(
        address hub,
        address moduleGlobals,
        address coordinator,
        bytes32 keyHash,
        uint64 subscriptionId
    ) FeeModuleBase(moduleGlobals) ModuleBase(hub) VRFConsumerBaseV2(coordinator) {
        vrfCoordinator = VRFCoordinatorV2Interface(coordinator);
        vrfKeyHash = keyHash;
        vrfSubscriptionId = subscriptionId;
    }

    /**
     * @notice This collect module levies a fee on collects and supports referrals. Thus, we need to decode data.
     *
     * @param profileId The token ID of the profile of the publisher, passed by the hub.
     * @param pubId The publication ID of the newly created publication, passed by the hub.
     * @param data The arbitrary data parameter, decoded into:
     *      uint256 amount: The currency total amount to levy.
     *      address currency: The currency address, must be internally whitelisted.
     *      address recipient: The custom recipient address to direct earnings to.
     *      uint16 referralFee: The referral fee to set.
     *
     * @return An abi encoded bytes parameter, which is the same as the passed data parameter.
     */
    function initializePublicationCollectModule(
        uint256 profileId,
        uint256 pubId,
        bytes calldata data
    ) external override onlyHub returns (bytes memory) {
        (
            uint256 amount,
            uint256 rafflePercent,
            uint256 raffleFrequency,
            address currency,
            address recipient,
            uint16 referralFee
        ) = abi.decode(data, (uint256, uint256, uint256, address, address, uint16));
        if (
            !_currencyWhitelisted(currency) ||
            recipient == address(0) ||
            referralFee > BPS_MAX ||
            amount == 0
        ) revert Errors.InitParamsInvalid();

        _dataByPublicationByProfile[profileId][pubId].referralFee = referralFee;
        _dataByPublicationByProfile[profileId][pubId].recipient = recipient;
        _dataByPublicationByProfile[profileId][pubId].currency = currency;
        _dataByPublicationByProfile[profileId][pubId].amount = amount;
        _dataByPublicationByProfile[profileId][pubId].rafflePercent = rafflePercent;
        _dataByPublicationByProfile[profileId][pubId].raffleFrequency = raffleFrequency;

        return data;
    }

    /**
     * @dev Processes a collect by:
     *  1. Ensuring the collector is a follower
     *  2. Charging a fee
     */
    function processCollect(
        uint256 referrerProfileId,
        address collector,
        uint256 profileId,
        uint256 pubId,
        bytes calldata data
    ) external virtual override onlyHub {
        _checkFollowValidity(profileId, collector);

        uint256 amount = _dataByPublicationByProfile[profileId][pubId].amount;
        address currency = _dataByPublicationByProfile[profileId][pubId].currency;
        _validateDataIsExpected(data, currency, amount);

        (address treasury, uint16 treasuryFee) = _treasuryData();
        uint256 treasuryAmount = (amount * treasuryFee) / BPS_MAX;
        uint256 raffleAmount = (amount *
            _dataByPublicationByProfile[profileId][pubId].rafflePercent) / BPS_MAX;
        uint256 adjustedAmount = amount - treasuryAmount - raffleAmount;

        if (treasuryAmount > 0)
            IERC20(currency).safeTransferFrom(collector, treasury, treasuryAmount);

        if (raffleAmount > 0) {
            IERC20(currency).safeTransferFrom(collector, address(this), raffleAmount);
            _dataByPublicationByProfile[profileId][pubId].raffleAmount =
                _dataByPublicationByProfile[profileId][pubId].raffleAmount +
                raffleAmount;
        }

        _processCollectWithReferral(
            referrerProfileId,
            collector,
            profileId,
            pubId,
            adjustedAmount,
            data
        );

        _dataByPublicationByProfile[profileId][pubId].collectors.push(collector);
        if (
            _dataByPublicationByProfile[profileId][pubId].collectors.length %
                _dataByPublicationByProfile[profileId][pubId].raffleFrequency ==
            0
        ) {
            uint256 requestId = vrfCoordinator.requestRandomWords(
                vrfKeyHash,
                vrfSubscriptionId,
                requestConfirmations,
                callbackGasLimit,
                1
            );
            requests[requestId].profileId = profileId;
            requests[requestId].pubId = pubId;
        }
    }

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        RequestData memory request = requests[requestId];
        uint256 collectorIndex = (randomWords[0] %
            _dataByPublicationByProfile[request.profileId][request.pubId].collectors.length);
        IERC20(_dataByPublicationByProfile[request.profileId][request.pubId].currency).safeTransfer(
                _dataByPublicationByProfile[request.profileId][request.pubId].collectors[
                    collectorIndex
                ],
                _dataByPublicationByProfile[request.profileId][request.pubId].raffleAmount
            );
        _dataByPublicationByProfile[request.profileId][request.pubId].raffleAmount = 0;
    }

    /**
     * @notice Returns the publication data for a given publication, or an empty struct if that publication was not
     * initialized with this module.
     *
     * @param profileId The token ID of the profile mapped to the publication to query.
     * @param pubId The publication ID of the publication to query.
     *
     * @return The ProfilePublicationData struct mapped to that publication.
     */
    function getPublicationData(uint256 profileId, uint256 pubId)
        external
        view
        returns (ProfilePublicationData memory)
    {
        return _dataByPublicationByProfile[profileId][pubId];
    }

    function _processCollectWithReferral(
        uint256 referrerProfileId,
        address collector,
        uint256 profileId,
        uint256 pubId,
        uint256 adjustedAmount,
        bytes calldata data
    ) internal {
        address currency = _dataByPublicationByProfile[profileId][pubId].currency;
        uint256 referralFee = _dataByPublicationByProfile[profileId][pubId].referralFee;

        if (referralFee != 0) {
            // The reason we levy the referral fee on the adjusted amount is so that referral fees
            // don't bypass the treasury fee, in essence referrals pay their fair share to the treasury.
            uint256 referralAmount = (adjustedAmount * referralFee) / BPS_MAX;
            adjustedAmount = adjustedAmount - referralAmount;

            address referralRecipient = IERC721(HUB).ownerOf(referrerProfileId);

            IERC20(currency).safeTransferFrom(collector, referralRecipient, referralAmount);
        }

        address recipient = _dataByPublicationByProfile[profileId][pubId].recipient;

        IERC20(currency).safeTransferFrom(collector, recipient, adjustedAmount);
    }
}
