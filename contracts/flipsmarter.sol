// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

struct ProjectInfo {
	uint64 bornTime;
	uint64 deadline;
	uint96 minDonationAmount;

	uint96  maxRaisedAmount;
	address receiver;

	uint96  minRaisedAmount;
	address coinType;

	bytes  description;
}

// @dev FlipSmarter is for fund-raising, it is an enhance evm version of flipstarter.cash
contract FlipSmarter {
	// @dev The creater of fund-raising project (also the fund receiver) must deposit some pledge during 
	// creation, which will be returned when the project finishes. This pledge ensures on-chain resources
	// are not abused.
	uint public pledge;

	// @dev The one who can change pledge's value
	address public pledgeSetter;

	// @dev The address which will replace pledgeSetter
	address public newPledgeSetter;

	// @dev A project is identified by its name whose lenght is no larger than 32. With its name, you can
	// query its detailed information. Two projects with the same name cannot be active at the same time.
	mapping(bytes32 => ProjectInfo) private projNameToInfo;

	// @dev A list of currently active projects
	bytes32[] private projectNameList;

	// @dev Maps a project's name to its index (where to find its name in projectNameList) and the
	// amount donated to it so far.
	mapping(bytes32 => uint) private projNameToIdxAmt;

	// @dev This map's key is project name and its value is a list of donators 
	mapping(bytes32 => address[]) private projDonatorList;

	// @dev Given a project's name and a donator's address, query the donator's index (where to find it
	// in the projDonatorList) and her donated amount to this project.
	mapping(bytes32 => mapping(address => uint)) private projDonatorToIdxAmt;

	// @dev The address of precompile smart contract for SEP101
	address constant SEP101Contract = address(bytes20(uint160(0x2712)));

	// @dev The address of precompile smart contract for SEP206
	address constant SEP206Contract = address(bytes20(uint160(0x2711)));

	// @dev The upper bound of how long a project can keep active
	uint constant MaxTimeSpan = 60 * 24 * 3600; // 60 days

	// @dev The upper bound of how many donators a project can has
	uint constant MaxDonatorCount = 500;

	// @dev The upper bound of a project's description length
	uint constant MaxDescriptionLength = 512;

	// @dev The upper bound of a donator's message length
	uint constant MaxMessageLength = 128;

	// @dev If the list of donators has less member of this count, it can be cleared when finishing
	// a project.
	uint constant DonatorLastClearCount = 60;

	// =================================================================

	// @dev Emitted when a new project is create
	event Create(bytes32 indexed projectName);

	// @dev Emitted when a new project is finished
	event Finish(bytes32 indexed projectName);

	// @dev Emitted when someone donates to a project
	event Donate(bytes32 indexed projectName, address indexed donator, uint amount, bytes message);

	// @dev Emitted when someone undonates from a project
	event Undonate(bytes32 indexed projectName, address indexed donator, uint amount);

	// =================================================================

	// @dev Given a project's deadline and the amount donated to it, returns whether it's finalized
	// If now is after the deadline, then it's finalized.
	// If now is still before the deadline but the donated coins are more than maxRaisedAmount, then
	// it's also finalized.
	// If a project is finalized, you cannot donate to it anymore.
	// If a project is finalized and succeeds, you cannot undonate from it anymore.
	// After a project is finalized, anyone can clear the donators' records, and if it fails, return the
	// donated coins as well. The project owner cannot finish a project before all the donators' records
	// are cleared.
	function isFinalized(ProjectInfo memory info, uint donatedAmount) private view returns (bool) {
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

	function saveProjectInfo(bytes32 projectName, ProjectInfo memory info) private {
		projNameToInfo[projectName] = info;
	}

	function loadProjectInfo(bytes32 projectName, ProjectInfo memory info) private view {
		info = projNameToInfo[projectName];
		require(info.bornTime != 0, "project-not-found");
	}

	function deleteProjectInfo(bytes32 projectName) private {
		delete projNameToInfo[projectName];
	}

	// =================================================================
	function setProjectIndexAndAmount(bytes32 projectName, uint index, uint amount) private {
		projNameToIdxAmt[projectName] = (index<<96) | amount;
	}

	function getProjectIndex(bytes32 projectName) private view returns (uint) {
		uint word = projNameToIdxAmt[projectName];
		return uint(uint64(word>>96));
	}

	function getProjectAmount(bytes32 projectName) private view returns (uint) {
		uint word = projNameToIdxAmt[projectName];
		return uint(uint96(word));
	}

	// @dev Remove a project's name from projectNameList and projNameToIdxAmt, keeping the indexes
	// contained in projNameToIdxAmt valid.
	function removeProjectIndexAndAmount(bytes32 projectName) private {
		uint index = getProjectIndex(projectName);
		delete projNameToIdxAmt[projectName];
		uint last = projectNameList.length-1;
		if(index != last) { // move the project at last to index
			bytes32 lastName = projectNameList[last];
			projectNameList[index] = lastName;
			uint amount = getProjectAmount(lastName);
			setProjectIndexAndAmount(lastName, index, amount);
		}
		projectNameList.pop();
	}

	// =================================================================
	function setDonatorIndexAndAmount(bytes32 projectName, address donator, uint index, uint amount) private {
		projDonatorToIdxAmt[projectName][donator] = (index<<96) | amount;
	}

	function getDonatorIndex(bytes32 projectName, address donator) private view returns (uint) {
		uint word = projDonatorToIdxAmt[projectName][donator];
		return uint(uint64(word>>96));
	}

	function getDonatorAmount(bytes32 projectName, address donator) public view returns (uint) {
		uint word = projDonatorToIdxAmt[projectName][donator];
		return uint(uint96(word));
	}
	
	// @dev Remove a donator's address from projDonatorList[projectName] and projDonatorToIdxAmt[projectName],
	// keeping the indexes contained in projDonatorToIdxAmt[projectName] valid.
	function removeDonatorIndexAndAmount(bytes32 projectName, address donator) private returns (uint) {
		uint index = getDonatorIndex(projectName, donator);
		delete projDonatorToIdxAmt[projectName][donator];
		address[] storage donatorList = projDonatorList[projectName];
		uint last = donatorList.length-1;
		uint amount = getDonatorAmount(projectName, donator);
		if(index != last) {
			address lastDonator = donatorList[last];
			donatorList[index] = lastDonator;
			setDonatorIndexAndAmount(projectName, donator, index, amount);
		}
		donatorList.pop();
		return amount;
	}

	// =================================================================

	// @dev When the donators' records are all erased for a project, use this function to erase all the records
	// of the project itself from this smart contract. After this erasion, the project's name can be reused for
	// some other project.
	function removeProject(bytes32 projectName) private {
		address[] storage donatorList = projDonatorList[projectName];
		require(donatorList.length == 0, "donators-records-not-cleared");
		deleteProjectInfo(projectName);
		removeProjectIndexAndAmount(projectName);
	}

	// @dev Remove at most `count` donators addresses from projDonatorList[projectName] and
	// projDonatorToIdxAmt[projectName]. At the same time, return the donated coins to the donators,
	// if this project fails.
	// Requirements:
	// - This project must have been finalized
	function clearDonators(bytes32 projectName, uint count) external {
		ProjectInfo memory info;
		loadProjectInfo(projectName, info);
		uint donatedAmount = getProjectAmount(projectName);
		require(isFinalized(info, donatedAmount), "not-finalized");
		bool returnCoins = donatedAmount < info.minRaisedAmount;
		address[] storage donatorList = projDonatorList[projectName];
		_clearDonators(projectName, count, donatorList, returnCoins, info.coinType);
	}

	// @dev Remove at most `count` donators addresses from donatorList and projDonatorToIdxAmt[projectName],
	// At the same time, return the donated SEP20 coins of `coinType` to the donators if returnCoins==true.
	function _clearDonators(bytes32 projectName, uint count, address[] storage donatorList,
							bool returnCoins, address coinType) private {
		if(count > donatorList.length) {
			count = donatorList.length;
		}
		for((uint i, uint j) = (0, donatorList.length-1); i<count; (i, j)=(i+1, j-1)) {
			address donator = donatorList[j];
			donatorList.pop();
			uint amount = getDonatorAmount(projectName, donator);
			delete projDonatorToIdxAmt[projectName][donator];
			if(returnCoins) {
				safeTransfer(coinType, donator, amount);
			}
		}
	}

	// @dev Create a new fund-raising project by depositing `pledge` BCH in this contract. 
	// @param deadline No more donations are accepted after deadline. After deadline, the project is finalized.
	//  It cannot be later than `MaxTimeSpan` seconds later.
	// @param minDonationAmount The minimum amount of one single donation.
	// @param minRaisedAmount The minimum raised amount, if the raised fund is less than this value, then 
	//  this project fails.
	// @param maxRaisedAmount The maximum raised amount, if the raised fund is more than this value, then 
	//  this project is finalized immediately, even before the deadline.
	// @param coinType Which kind of SEP20 token this project raises. Set it to 0x2711 for BCH.
	// @param projectName The project's name, which can uniquely identify one project. Its length must be 
	//  no longer than 32.
	// @param description Which describes this project. Its length must be longer than `MaxDescriptionLength`.
	// Requirements:
	// - This project's total donators (determinded by minDonationAmount) cannot be more than `MaxDonatorCount`
	function create(uint64 deadline, uint96 minDonationAmount, uint96 maxRaisedAmount, uint96 minRaisedAmount,
		address coinType, bytes32 projectName, bytes calldata description) external payable {
		require(block.timestamp + MaxTimeSpan > deadline, "deadline-must-be-in-60-days");
		require(uint(minDonationAmount)*MaxDonatorCount > uint(maxRaisedAmount), "too-many-donators");
		require(msg.value == pledge, "incorrect-pledge");
		require(description.length <= MaxDescriptionLength, "description-too-long");
		ProjectInfo memory info;
		info.bornTime = uint64(block.timestamp);
		info.deadline = deadline;
		info.minDonationAmount = minDonationAmount;
		info.maxRaisedAmount = maxRaisedAmount;
		info.receiver = msg.sender;
		info.minRaisedAmount = minRaisedAmount;
		info.coinType = coinType;
		info.description = description;
		saveProjectInfo(projectName, info);
		setProjectIndexAndAmount(projectName, projectNameList.length, 0);
		projectNameList.push(projectName);
		emit Create(projectName);
	}

	// @dev Finish a project by returning the pledge BCH back to its owner and removing its records.
	//  If it succeeds, send the raised coins to its owner as well.
	// Requirements:
	// - The donators' records must be no more than `DonatorLastClearCount`
	function finish(bytes32 projectName) external {
		ProjectInfo memory info;
		loadProjectInfo(projectName, info);
		uint donatedAmount = getProjectAmount(projectName);
		require(isFinalized(info, donatedAmount), "not-finalized");
		address[] storage donatorList = projDonatorList[projectName];
		bool succeed = donatedAmount >= info.minRaisedAmount;
		if(donatorList.length <= DonatorLastClearCount) {
			_clearDonators(projectName, donatorList.length, donatorList, !succeed, info.coinType);
		} else {
			require(false, "too-many-remained-donator-records");
		}
		if(succeed) {
			safeTransfer(info.coinType, info.receiver, donatedAmount);
		}
		removeProject(projectName);
		safeTransfer(SEP206Contract, info.receiver, pledge);
		emit Finish(projectName);
	}

	// @dev Donate `amount` coins to a project named `projectName`, and leave a `message` to its owner.
	// Requirements:
	// - This project has not been finalized.
	// - This donator has not donated to this project before, or has undonated her donation.
	function donate(bytes32 projectName, uint96 amount, bytes calldata message) external payable {
		require(message.length <= MaxMessageLength, "message-too-long");
		ProjectInfo memory info;
		loadProjectInfo(projectName, info);
		uint donatedAmount = getProjectAmount(projectName);
		require(!isFinalized(info, donatedAmount), "already-finalized");
		uint oldAmount = getDonatorAmount(projectName, msg.sender);
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
		address[] storage donatorList = projDonatorList[projectName];
		setDonatorIndexAndAmount(projectName, msg.sender, donatorList.length, realAmount);
		donatorList.push(msg.sender);
		emit Donate(projectName, msg.sender, realAmount, message);
	}

	// @dev Undo your donation to a project.
	// Requirements:
	// - If the project succeeds and is finalized, you cannot undonate.
	function undonate(bytes32 projectName) external {
		ProjectInfo memory info;
		loadProjectInfo(projectName, info);
		uint donatedAmount = getProjectAmount(projectName);
		if(isFinalized(info, donatedAmount)) {
			require(donatedAmount < info.minRaisedAmount, "cannot-undonate-after-success");
		}
		uint amount = removeDonatorIndexAndAmount(projectName, msg.sender);
		safeTransfer(info.coinType, msg.sender, amount);
		emit Undonate(projectName, msg.sender, amount);
	}

	// =================================================================

	function setPledge(uint value) external {
		require(msg.sender == pledgeSetter, "not-pledge-setter");
		pledge = value;
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

	// @dev Query a project's detail and the amount donated to it so far.
	function getProjectInfoAndDonatedAmount(bytes32 projectName) external view returns (
						ProjectInfo memory info, uint amount) {
		loadProjectInfo(projectName, info);
		amount = getProjectAmount(projectName);
	}

	// @dev Returns projectNameList's content between `start` and `end` as `names`, and its length as count.
	function getProjectNames(uint start, uint end) external view returns (uint count, bytes32[] memory names) {
		count = projectNameList.length;
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
			names[i-start] = projectNameList[i];
		}
	}

	// @dev Returns projDonatorList[projectName]'s content between `start` and `end` as `donators`, and
	// its length as count. For each donator in `donators`, her donated amount is recorded in `amounts`,
	// at the same index as in `donators`.
	function getDonations(bytes32 projectName, uint start, uint end) external view returns (
			uint count, address[] memory donators, uint[] memory amounts) {
		address[] storage donatorList = projDonatorList[projectName];
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
			amounts[j] = getDonatorAmount(projectName, donator);
		}
	}
}
