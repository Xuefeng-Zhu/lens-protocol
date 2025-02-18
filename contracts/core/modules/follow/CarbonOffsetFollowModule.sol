// SPDX-License-Identifier: AGPL-3.0-only

pragma solidity 0.8.10;

import {IFollowModule} from '../../../interfaces/IFollowModule.sol';
import {ILensHub} from '../../../interfaces/ILensHub.sol';
import {IOffsetHelper} from '../../../toucan/interfaces/IOffsetHelper.sol';
import {Errors} from '../../../libraries/Errors.sol';
import {FeeModuleBase} from '../FeeModuleBase.sol';
import {ModuleBase} from '../ModuleBase.sol';
import {FollowValidatorFollowModuleBase} from './FollowValidatorFollowModuleBase.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';

/**
 * @notice A struct containing the necessary data to execute follow actions on a given profile.
 *
 * @param currency The currency associated with this profile.
 * @param amount The following cost associated with this profile.
 * @param recipient The recipient address associated with this profile.
 */
struct ProfileData {
    address currency;
    address poolToken;
    uint256 amount;
    uint256 offsetPercent;
    address recipient;
}

/**
 * @title CarbonOffsetFollowModule
 * @author Lens Protocol
 *
 * @notice This is a simple Lens FollowModule implementation, inheriting from the IFollowModule interface, but with additional
 * variables that can be controlled by governance, such as the governance & treasury addresses as well as the treasury fee.
 */
contract CarbonOffsetFollowModule is IFollowModule, FeeModuleBase, FollowValidatorFollowModuleBase {
    using SafeERC20 for IERC20;

    IOffsetHelper public offsetHelper;
    mapping(uint256 => ProfileData) internal _dataByProfile;

    constructor(
        address hub,
        address moduleGlobals,
        address _offsetHelper
    ) FeeModuleBase(moduleGlobals) ModuleBase(hub) {
        if (_offsetHelper == address(0)) revert Errors.InitParamsInvalid();

        offsetHelper = IOffsetHelper(_offsetHelper);
    }

    /**
     * @notice This follow module levies a fee on follows.
     *
     * @param data The arbitrary data parameter, decoded into:
     *      address currency: The currency address, must be internally whitelisted.
     *      uint256 amount: The currency total amount to levy.
     *      address recipient: The custom recipient address to direct earnings to.
     *
     * @return An abi encoded bytes parameter, which is the same as the passed data parameter.
     */
    function initializeFollowModule(uint256 profileId, bytes calldata data)
        external
        override
        onlyHub
        returns (bytes memory)
    {
        (
            uint256 amount,
            uint256 offsetPercent,
            address currency,
            address poolToken,
            address recipient
        ) = abi.decode(data, (uint256, uint256, address, address, address));
        if (
            !_currencyWhitelisted(currency) ||
            (!offsetHelper.isSwapable(currency) && !offsetHelper.isRedeemable(currency)) ||
            (!offsetHelper.isRedeemable(poolToken)) ||
            recipient == address(0) ||
            amount == 0
        ) revert Errors.InitParamsInvalid();

        _dataByProfile[profileId].amount = amount;
        _dataByProfile[profileId].offsetPercent = offsetPercent;
        _dataByProfile[profileId].currency = currency;
        _dataByProfile[profileId].poolToken = poolToken;
        _dataByProfile[profileId].recipient = recipient;
        return data;
    }

    /**
     * @dev Processes a follow by:
     *  1. Charging a fee
     */
    function processFollow(
        address follower,
        uint256 profileId,
        bytes calldata data
    ) external override onlyHub {
        uint256 amount = _dataByProfile[profileId].amount;
        uint256 offsetPercent = _dataByProfile[profileId].offsetPercent;
        address currency = _dataByProfile[profileId].currency;
        address poolToken = _dataByProfile[profileId].poolToken;
        _validateDataIsExpected(data, currency, amount);

        (address treasury, uint16 treasuryFee) = _treasuryData();
        address recipient = _dataByProfile[profileId].recipient;
        uint256 treasuryAmount = (amount * treasuryFee) / BPS_MAX;
        uint256 offsetAmount = (amount * offsetPercent) / BPS_MAX;
        uint256 adjustedAmount = amount - treasuryAmount - offsetAmount;

        IERC20(currency).safeTransferFrom(follower, recipient, adjustedAmount);
        if (offsetAmount > 0) {
            IERC20(currency).safeTransferFrom(follower, address(this), offsetAmount);
            IERC20(currency).approve(address(offsetHelper), offsetAmount);

            if (offsetHelper.isSwapable(currency)) {
                offsetHelper.autoOffset(currency, poolToken, offsetAmount);
            } else {
                offsetHelper.autoOffsetUsingPoolToken(currency, offsetAmount);
            }
        }
        if (treasuryAmount > 0)
            IERC20(currency).safeTransferFrom(follower, treasury, treasuryAmount);
    }

    /**
     * @dev We don't need to execute any additional logic on transfers in this follow module.
     */
    function followModuleTransferHook(
        uint256 profileId,
        address from,
        address to,
        uint256 followNFTTokenId
    ) external override {}

    /**
     * @notice Returns the profile data for a given profile, or an empty struct if that profile was not initialized
     * with this module.
     *
     * @param profileId The token ID of the profile to query.
     *
     * @return The ProfileData struct mapped to that profile.
     */
    function getProfileData(uint256 profileId) external view returns (ProfileData memory) {
        return _dataByProfile[profileId];
    }
}
