// SPDX-License-Identifier: AGPL-3.0-only

pragma solidity 0.8.10;

import {ICollectModule} from '../../../interfaces/ICollectModule.sol';
import {Errors} from '../../../libraries/Errors.sol';
import {IOffsetHelper} from '../../../toucan/interfaces/IOffsetHelper.sol';
import {FeeModuleBase} from '../FeeModuleBase.sol';
import {ModuleBase} from '../ModuleBase.sol';
import {FollowValidationModuleBase} from '../FollowValidationModuleBase.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';

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
    uint256 offsetPercent;
    address recipient;
    address currency;
    address poolToken;
    uint16 referralFee;
}

/**
 * @title CarbonOffsetCollectModule
 * @author Lens Protocol
 *
 * @notice This is a simple Lens CollectModule implementation, inheriting from the ICollectModule interface and
 * the FeeCollectModuleBase abstract contract.
 *
 * This module works by allowing unlimited collects for a publication at a given price.
 */
contract CarbonOffsetCollectModule is ICollectModule, FeeModuleBase, FollowValidationModuleBase {
    using SafeERC20 for IERC20;

    IOffsetHelper public offsetHelper;
    mapping(uint256 => mapping(uint256 => ProfilePublicationData))
        internal _dataByPublicationByProfile;

    constructor(
        address hub,
        address moduleGlobals,
        address _offsetHelper
    ) FeeModuleBase(moduleGlobals) ModuleBase(hub) {
        if (_offsetHelper == address(0)) revert Errors.InitParamsInvalid();

        offsetHelper = IOffsetHelper(_offsetHelper);
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
            uint256 offsetPercent,
            address currency,
            address poolToken,
            address recipient,
            uint16 referralFee
        ) = abi.decode(data, (uint256, uint256, address, address, address, uint16));
        if (
            !_currencyWhitelisted(currency) ||
            (!offsetHelper.isSwapable(currency) && !offsetHelper.isRedeemable(currency)) ||
            (!offsetHelper.isRedeemable(poolToken)) ||
            recipient == address(0) ||
            referralFee > BPS_MAX ||
            amount == 0
        ) revert Errors.InitParamsInvalid();

        _dataByPublicationByProfile[profileId][pubId].referralFee = referralFee;
        _dataByPublicationByProfile[profileId][pubId].recipient = recipient;
        _dataByPublicationByProfile[profileId][pubId].currency = currency;
        _dataByPublicationByProfile[profileId][pubId].poolToken = poolToken;
        _dataByPublicationByProfile[profileId][pubId].amount = amount;
        _dataByPublicationByProfile[profileId][pubId].offsetPercent = offsetPercent;

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
        uint256 offsetAmount = (amount *
            _dataByPublicationByProfile[profileId][pubId].offsetPercent) / BPS_MAX;
        uint256 adjustedAmount = amount - treasuryAmount - offsetAmount;

        if (treasuryAmount > 0)
            IERC20(currency).safeTransferFrom(collector, treasury, treasuryAmount);

        if (offsetAmount > 0) {
            IERC20(currency).safeTransferFrom(collector, address(this), offsetAmount);
            IERC20(currency).approve(address(offsetHelper), offsetAmount);

            if (offsetHelper.isSwapable(currency)) {
                offsetHelper.autoOffset(
                    currency,
                    _dataByPublicationByProfile[profileId][pubId].poolToken,
                    offsetAmount
                );
            } else {
                offsetHelper.autoOffsetUsingPoolToken(currency, offsetAmount);
            }
        }

        _processCollectWithReferral(
            referrerProfileId,
            collector,
            profileId,
            pubId,
            adjustedAmount,
            data
        );
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

        if (referrerProfileId == profileId && referralFee != 0) {
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
