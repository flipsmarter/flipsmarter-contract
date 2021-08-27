// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

struct CampaignInfo {
	uint64 bornTime;
	uint64 deadline;
	uint96 minDonationAmount;
	uint32 pledgeU32;

	uint96  maxRaisedAmount;
	address receiver;

	uint96  minRaisedAmount;
	address coinType;

	bytes  description;
}

// @dev FlipSmarter is for fund-raising, it is an enhance evm version of flipstarter.cash
contract FlipSmarter {
	// @dev The creater of fund-raising campaign (also the fund receiver) must deposit some pledge at 
	// creation, which will be returned when the campaign finishes. This pledge ensures on-chain resources
	// are not abused.
	uint32 public pledgeU32;

	// @dev The one who can change pledge's value
	address public pledgeSetter;

	// @dev The address which will replace pledgeSetter
	address public newPledgeSetter;

	// @dev A campaign is identified by its name whose length is no larger than 32. With its name, you can
	// query its detailed information. Two campaigns with the same name cannot be active at the same time.
	mapping(bytes32 => CampaignInfo) private campNameToInfo;

	// @dev A list of currently active campaigns
	bytes32[] private campaignNameList;

	// @dev Maps a campaign's name to its index (where to find its name in campaignNameList) and the
	// amount donated to it so far.
	mapping(bytes32 => uint) private campNameToIdxAmt;

	// @dev This map's key is campaign name and its value is a list of donators 
	mapping(bytes32 => address[]) private campDonatorList;

	// @dev Given a campaign's name and a donator's address, query the donator's index (where to find it
	// in the campDonatorList) and her donation amount to this campaign.
	mapping(bytes32 => mapping(address => uint)) private campDonatorToIdxAmt;

	// @dev The address of precompile smart contract for SEP101
	address constant SEP101Contract = address(bytes20(uint160(0x2712)));

	// @dev The address of precompile smart contract for SEP206
	address constant SEP206Contract = address(bytes20(uint160(0x2711)));

	// @dev The upper bound of how long a campaign can keep active
	uint constant MaxTimeSpan = 60 * 24 * 3600; // 60 days

	// @dev The upper bound of how many donators a campaign can has
	uint constant MaxDonatorCount = 500;

	// @dev The upper bound of a campaign's description length
	uint constant MaxDescriptionLength = 512;

	// @dev The upper bound of a donator's message length
	uint constant MaxMessageLength = 256;

	// @dev If the list of donators has less member than this count, it can be cleared when finishing
	// a campaign.
	uint constant DonatorLastClearCount = 60;

	// @dev The real pledge amount is calculated by pledgeU32*PledgeUnit
	uint constant PledgeUnit = 10**12;

	// =================================================================

	// @dev Emitted when a new campaign is started
	event Start(bytes32 indexed campaignName);

	// @dev Emitted when a new campaign is finished
	event Finish(bytes32 indexed campaignName);

	// @dev Emitted when someone donates to a campaign
	event Donate(bytes32 indexed campaignName, address indexed donator, uint amount, bytes message);

	// @dev Emitted when someone undonates from a campaign
	event Undonate(bytes32 indexed campaignName, address indexed donator, uint amount);

	// =================================================================

	// @dev Given a campaign's deadline and the donated amount, returns whether it's finalized
	// If now is after the deadline, then it's finalized.
	// If now is still before the deadline but the donated amount is more than maxRaisedAmount, then
	// it's also finalized.
	// If a campaign is finalized, you cannot donate to it anymore.
	// If a campaign is finalized and succeeds, you cannot undonate from it anymore.
	// After a campaign is finalized, anyone can clear the donators' records, and if it fails, the donated
	// coins is returned as the records are cleared. The campaign owner cannot finish a campaign before all
	// the donators' records are cleared.
	function isFinalized(CampaignInfo memory info, uint donatedAmount) private view returns (bool) {
		return (block.timestamp > info.deadline || donatedAmount > info.maxRaisedAmount);
	}

	// =================================================================

	function safeTransfer(address coinType, address receiver, uint value) private {
		if(coinType == SEP206Contract) {
			receiver.call{value: value, gas: 9000}("");
		} else {
			IERC20(coinType).transfer(receiver, value);
		}
	}

	function saveCampaignInfo(bytes32 campaignName, CampaignInfo memory info) private {
		campNameToInfo[campaignName] = info;
	}

	function loadCampaignInfo(bytes32 campaignName) private view returns (CampaignInfo memory info) {
		info = campNameToInfo[campaignName];
		require(info.bornTime != 0, "campaign-not-found");
	}

	function deleteCampaignInfo(bytes32 campaignName) private {
		delete campNameToInfo[campaignName];
	}

	// =================================================================
	function setCampaignIndexAndAmount(bytes32 campaignName, uint index, uint amount) private {
		campNameToIdxAmt[campaignName] = (index<<96) | amount;
	}

	function getCampaignIndex(bytes32 campaignName) private view returns (uint) {
		uint word = campNameToIdxAmt[campaignName];
		return word>>96;
	}

	function getCampaignAmount(bytes32 campaignName) private view returns (uint) {
		uint word = campNameToIdxAmt[campaignName];
		return uint(uint96(word));
	}

	// @dev Remove a campaign's name from campaignNameList and campNameToIdxAmt, keeping the indexes
	// contained in campNameToIdxAmt valid.
	function removeCampaignIndexAndAmount(bytes32 campaignName) private {
		uint index = getCampaignIndex(campaignName);
		delete campNameToIdxAmt[campaignName];
		uint last = campaignNameList.length-1;
		if(index != last) { // move the campaign at last to index
			bytes32 lastName = campaignNameList[last];
			campaignNameList[index] = lastName;
			uint amount = getCampaignAmount(lastName);
			setCampaignIndexAndAmount(lastName, index, amount);
		}
		campaignNameList.pop();
	}

	// =================================================================
	function setDonatorIndexAndAmount(bytes32 campaignName, address donator, uint index, uint amount) private {
		campDonatorToIdxAmt[campaignName][donator] = (index<<96) | amount;
	}

	function getDonatorIndexAndAmount(bytes32 campaignName, address donator) private view returns (uint, uint) {
		uint word = campDonatorToIdxAmt[campaignName][donator];
		return (word>>96, uint(uint96(word)));
	}

	function getDonatorIndex(bytes32 campaignName, address donator) private view returns (uint) {
		uint word = campDonatorToIdxAmt[campaignName][donator];
		return word>>96;
	}

	function getDonatorAmount(bytes32 campaignName, address donator) public view returns (uint) {
		uint word = campDonatorToIdxAmt[campaignName][donator];
		return uint(uint96(word));
	}
	
	// @dev Remove a donator's address from campDonatorList[campaignName] and campDonatorToIdxAmt[campaignName],
	// keeping the indexes contained in campDonatorToIdxAmt[campaignName] valid.
	function removeDonatorIndexAndAmount(bytes32 campaignName, address donator) private returns (uint) {
		(uint index, uint removedAmt) = getDonatorIndexAndAmount(campaignName, donator);
		delete campDonatorToIdxAmt[campaignName][donator];
		address[] storage donatorList = campDonatorList[campaignName];
		uint last = donatorList.length-1;
		if(index != last) {
			address lastDonator = donatorList[last];
			donatorList[index] = lastDonator;
			uint amt = getDonatorAmount(campaignName, lastDonator);
			setDonatorIndexAndAmount(campaignName, lastDonator, index, amt);
		}
		donatorList.pop();
		return removedAmt;
	}

	// =================================================================

	// @dev When the donators' records are all erased for a campaign, use this function to erase all the records
	// of the campaign itself from this smart contract. After this erasion, `campaignName` can be reused for
	// some other campaign.
	function removeCampaign(bytes32 campaignName) private {
		address[] storage donatorList = campDonatorList[campaignName];
		require(donatorList.length == 0, "donators-records-not-cleared");
		deleteCampaignInfo(campaignName);
		removeCampaignIndexAndAmount(campaignName);
	}

	// @dev Remove at most `count` donators' addresses from campDonatorList[campaignName] and
	// campDonatorToIdxAmt[campaignName]. At the same time, return the donated coins to the donators,
	// if this campaign fails.
	// Requirements:
	// - This campaign must have been finalized
	function clearDonators(bytes32 campaignName, uint count) external {
		CampaignInfo memory info = loadCampaignInfo(campaignName);
		uint donatedAmount = getCampaignAmount(campaignName);
		require(isFinalized(info, donatedAmount), "not-finalized");
		bool returnCoins = donatedAmount < info.minRaisedAmount;
		address[] storage donatorList = campDonatorList[campaignName];
		_clearDonators(campaignName, count, donatorList, returnCoins, info.coinType);
	}

	// @dev Remove at most `count` donators addresses from donatorList and campDonatorToIdxAmt[campaignName],
	// At the same time, return the donated SEP20 coins of `coinType` back to the donators if returnCoins==true.
	function _clearDonators(bytes32 campaignName, uint count, address[] storage donatorList,
							bool returnCoins, address coinType) private {
		if(count > donatorList.length) {
			count = donatorList.length;
		}
		for((uint i, uint j) = (0, donatorList.length-1); i<count; (i, j)=(i+1, j-1)) {
			address donator = donatorList[j];
			donatorList.pop();
			uint amount = getDonatorAmount(campaignName, donator);
			delete campDonatorToIdxAmt[campaignName][donator];
			if(returnCoins) {
				safeTransfer(coinType, donator, amount);
			}
		}
	}

	// @dev Start a new fund-raising campaign by depositing `pledgeU32*PledgeUnit` BCH in this contract. 
	// @param deadline No more donations are accepted after deadline. After deadline, the campaign is finalized.
	//  It cannot be after `MaxTimeSpan` seconds later.
	// @param minDonationAmount The minimum amount of one single donation.
	// @param minRaisedAmount The minimum raised amount, if the raised fund is less than this value, then 
	//  this campaign fails and the fund must be returned to the donators.
	// @param maxRaisedAmount The maximum raised amount, if the raised fund is more than this value, then 
	//  this campaign is finalized immediately, even before the deadline.
	// @param coinType Which kind of SEP20 token this campaign raises. Set it to 0x2711 when raising BCH.
	// @param campaignName The campaign's name, which can uniquely identify one campaign. Its length must be 
	//  no longer than 32.
	// @param description The detailed introduction of this campaign. Its length must be longer than 
	//   `MaxDescriptionLength`.
	// Requirements:
	// - Currently there are no other active campaign been named as `campaignName`
	// - This campaign's total donators (determinded by minDonationAmount) cannot be more than `MaxDonatorCount`
	// - `maxRaisedAmount` must no less than `minRaisedAmount`
	function start(uint64 deadline, uint96 minDonationAmount, uint96 maxRaisedAmount, uint96 minRaisedAmount,
			address coinType, bytes32 campaignName, bytes calldata description) external payable {
		require(block.timestamp + MaxTimeSpan > deadline, "deadline-must-be-in-60-days");
		require(uint(minDonationAmount)*MaxDonatorCount > uint(maxRaisedAmount), "too-many-donators");
		uint pledge = pledgeU32 * PledgeUnit;
		require(msg.value == pledge, "incorrect-pledge");
		require(description.length <= MaxDescriptionLength, "description-too-long");
		require(maxRaisedAmount >= minRaisedAmount, "incorrect-amount");
		CampaignInfo memory info = campNameToInfo[campaignName];
		require(info.bornTime == 0, "campaign-name-conflicts");
		info.pledgeU32 = pledgeU32;
		info.bornTime = uint64(block.timestamp);
		info.deadline = deadline;
		info.minDonationAmount = minDonationAmount;
		info.maxRaisedAmount = maxRaisedAmount;
		info.receiver = msg.sender;
		info.minRaisedAmount = minRaisedAmount;
		info.coinType = coinType;
		info.description = description;
		saveCampaignInfo(campaignName, info);
		setCampaignIndexAndAmount(campaignName, campaignNameList.length, 0);
		campaignNameList.push(campaignName);
		emit Start(campaignName);
	}

	// @dev Finish a campaign by returning the pledge BCH back to its owner and removing its records.
	//  If it succeeds, send the raised coins to its owner as well. The donator list's length must be zero
	//  or smaller than DonatorLastClearCount, such that it can be cleared in this function call.
	// Requirements:
	// - The donators' records must be no more than `DonatorLastClearCount`
	// - This campaign is finalized, or the creater wants to finish it because of no donator at all (zero donation value)
	function finish(bytes32 campaignName) external {
		CampaignInfo memory info = loadCampaignInfo(campaignName);
		uint donatedAmount = getCampaignAmount(campaignName);
		if(donatedAmount == 0) {
			if(block.timestamp < info.deadline) {
				require(msg.sender == info.receiver, "not-creater");
			}
		} else {
			require(isFinalized(info, donatedAmount), "not-finalized");
			bool succeed = donatedAmount >= info.minRaisedAmount;
			address[] storage donatorList = campDonatorList[campaignName];
			if(donatorList.length > DonatorLastClearCount) {
				require(false, "too-many-remained-donator-records");
			} else if(donatorList.length != 0) {
				_clearDonators(campaignName, donatorList.length, donatorList, !succeed, info.coinType);
			}
			if(succeed) {
				safeTransfer(info.coinType, info.receiver, donatedAmount);
			}
		}
		removeCampaign(campaignName);
		safeTransfer(SEP206Contract, info.receiver, info.pledgeU32*PledgeUnit);
		emit Finish(campaignName);
	}

	// @dev Donate `amount` coins to a campaign named `campaignName`, and leave a `message` to its owner.
	// Requirements:
	// - This campaign has not been finalized.
	// - This donator has not donated to this campaign before, or has undonated her donation already.
	function donate(bytes32 campaignName, uint96 amount, bytes calldata message) external payable {
		require(message.length <= MaxMessageLength, "message-too-long");
		CampaignInfo memory info = loadCampaignInfo(campaignName);
		uint donatedAmount = getCampaignAmount(campaignName);
		require(!isFinalized(info, donatedAmount), "already-finalized");
		uint oldAmount = getDonatorAmount(campaignName, msg.sender);
		require(oldAmount == 0, "already-donated");
		uint realAmount = uint(amount);
		if(info.coinType == SEP206Contract) {
			require(msg.value == uint(amount), "value-mismatch");
		} else {
			require(msg.value == 0, "dont-send-bch");
			uint oldBalance = IERC20(info.coinType).balanceOf(address(this));
			IERC20(info.coinType).transferFrom(msg.sender, address(this), uint(amount));
			uint newBalance = IERC20(info.coinType).balanceOf(address(this));
			realAmount = newBalance - oldBalance;
		}
		address[] storage donatorList = campDonatorList[campaignName];
		setDonatorIndexAndAmount(campaignName, msg.sender, donatorList.length, realAmount);
		donatorList.push(msg.sender);
		emit Donate(campaignName, msg.sender, realAmount, message);
	}

	// @dev Revoke your donation to a campaign and get back your money.
	// Requirements:
	// - If the campaign is finalized as a successful one, you cannot undonate.
	function undonate(bytes32 campaignName) external {
		CampaignInfo memory info = loadCampaignInfo(campaignName);
		uint donatedAmount = getCampaignAmount(campaignName);
		if(isFinalized(info, donatedAmount)) {
			require(donatedAmount < info.minRaisedAmount, "cannot-undonate-after-success");
		}
		uint amount = removeDonatorIndexAndAmount(campaignName, msg.sender);
		safeTransfer(info.coinType, msg.sender, amount);
		emit Undonate(campaignName, msg.sender, amount);
	}

	// =================================================================

	function setPledge(uint32 value) external {
		require(msg.sender == pledgeSetter, "not-pledge-setter");
		pledgeU32 = value;
	}

	function changePledgeSetter(address newSetter) external {
		require(msg.sender == pledgeSetter, "not-pledge-setter");
		newPledgeSetter = newSetter;
	}

	function switchPledgeSetter() external {
		require(msg.sender == newPledgeSetter, "not-new-pledge-setter");
		pledgeSetter = newPledgeSetter;
	}
	
	//==========================================================

	// @dev Query a campaign's detail and the amount donated to it so far.
	function getCampaignInfoAndDonatedAmount(bytes32 campaignName) external view returns (
						CampaignInfo memory info, uint amount) {
		info = loadCampaignInfo(campaignName);
		amount = getCampaignAmount(campaignName);
	}

	// @dev Returns campaignNameList's content between `start` and `end` as `names`, and its length as count.
	function getCampaignNames(uint start, uint end) external view returns (uint count, bytes32[] memory names) {
		count = campaignNameList.length;
		if(end > count) {
			end = count;
		}
		if(end <= start) {
			names = new bytes32[](0);
			return (count, names);
		}
		uint size = end - start;
		names = new bytes32[](size);
		for(uint i=start; i<end; i++) {
			names[i-start] = campaignNameList[i];
		}
	}

	// @dev Returns campDonatorList[campaignName]'s content between `start` and `end` as `donators`, and
	// its length as count. For each donator in `donators`, her donated amount is recorded in `amounts`,
	// at the same index as in `donators`.
	function getDonations(bytes32 campaignName, uint start, uint end) external view returns (
					uint count, address[] memory donators, uint[] memory amounts) {
		address[] storage donatorList = campDonatorList[campaignName];
		count = donatorList.length;
		if(end > count) {
			end = count;
		}
		if(end <= start) {
			donators = new address[](0);
			amounts = new uint[](0);
			return (count, donators, amounts);
		}
		uint size = end - start;
		donators = new address[](size);
		amounts = new uint[](size);
		for(uint i=start; i<end; i++) {
			uint j = i-start;
			address donator = donatorList[i];
			donators[j] = donator;
			amounts[j] = getDonatorAmount(campaignName, donator);
		}
	}
}
