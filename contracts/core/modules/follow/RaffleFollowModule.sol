// SPDX-License-Identifier: AGPL-3.0-only

pragma solidity 0.8.10;

import {IFollowModule} from '../../../interfaces/IFollowModule.sol';
import {ILensHub} from '../../../interfaces/ILensHub.sol';
import {Errors} from '../../../libraries/Errors.sol';
import {FeeModuleBase} from '../FeeModuleBase.sol';
import {ModuleBase} from '../ModuleBase.sol';
import {FollowValidatorFollowModuleBase} from './FollowValidatorFollowModuleBase.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import '@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol';
import '@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol';

/**
 * @notice A struct containing the necessary data to execute follow actions on a given profile.
 *
 * @param currency The currency associated with this profile.
 * @param amount The following cost associated with this profile.
 * @param recipient The recipient address associated with this profile.
 */
struct ProfileData {
    address currency;
    uint256 amount;
    uint256 raffleAmount;
    uint256 rafflePercent;
    uint256 raffleFrequency;
    address recipient;
    address[] followers;
}

/**
 * @title RaffleFollowModule
 * @author Lens Protocol
 *
 * @notice This is a simple Lens FollowModule implementation, inheriting from the IFollowModule interface, but with additional
 * variables that can be controlled by governance, such as the governance & treasury addresses as well as the treasury fee.
 */
contract RaffleFollowModule is
    IFollowModule,
    FeeModuleBase,
    FollowValidatorFollowModuleBase,
    VRFConsumerBaseV2
{
    using SafeERC20 for IERC20;

    VRFCoordinatorV2Interface public vrfCoordinator;
    uint64 public vrfSubscriptionId;

    mapping(uint256 => uint256) internal requestIdToProfile;
    mapping(uint256 => ProfileData) internal _dataByProfile;

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
            uint256 rafflePercent,
            uint256 raffleFrequency,
            address currency,
            address recipient
        ) = abi.decode(data, (uint256, uint256, uint256, address, address));
        if (!_currencyWhitelisted(currency) || recipient == address(0) || amount == 0)
            revert Errors.InitParamsInvalid();

        _dataByProfile[profileId].amount = amount;
        _dataByProfile[profileId].rafflePercent = rafflePercent;
        _dataByProfile[profileId].raffleFrequency = raffleFrequency;
        _dataByProfile[profileId].currency = currency;
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
        address currency = _dataByProfile[profileId].currency;
        _validateDataIsExpected(data, currency, amount);

        (address treasury, uint16 treasuryFee) = _treasuryData();
        address recipient = _dataByProfile[profileId].recipient;
        uint256 treasuryAmount = (amount * treasuryFee) / BPS_MAX;
        uint256 raffleAmount = (amount * _dataByProfile[profileId].rafflePercent) / BPS_MAX;
        uint256 adjustedAmount = amount - treasuryAmount - raffleAmount;

        IERC20(currency).safeTransferFrom(follower, recipient, adjustedAmount);
        if (treasuryAmount > 0)
            IERC20(currency).safeTransferFrom(follower, treasury, treasuryAmount);
        if (raffleAmount > 0) {
            IERC20(currency).safeTransferFrom(follower, address(this), raffleAmount);
            _dataByProfile[profileId].raffleAmount =
                _dataByProfile[profileId].raffleAmount +
                raffleAmount;
        }

        _dataByProfile[profileId].followers.push(follower);
        if (
            _dataByProfile[profileId].followers.length %
                _dataByProfile[profileId].raffleFrequency ==
            0
        ) {
            uint256 requestId = vrfCoordinator.requestRandomWords(
                vrfKeyHash,
                vrfSubscriptionId,
                requestConfirmations,
                callbackGasLimit,
                1
            );
            requestIdToProfile[requestId] = profileId;
        }
    }

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        uint256 profileId = requestIdToProfile[requestId];
        uint256 followerIndex = (randomWords[0] % _dataByProfile[profileId].followers.length);
        IERC20(_dataByProfile[profileId].currency).safeTransfer(
            _dataByProfile[profileId].followers[followerIndex],
            _dataByProfile[profileId].raffleAmount
        );
        _dataByProfile[profileId].raffleAmount = 0;
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
