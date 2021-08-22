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

contract FlipSmarter {
	uint public pledge; //TODO: some function to change it

	mapping(bytes32 => ProjectInfo) private projNameToInfo;

	bytes32[] private projectNameList;
	mapping(bytes32 => uint) private projNameToIdxAmt;

	mapping(bytes32 => address[]) private projDonatorList;
	mapping(bytes32 => mapping(address => uint)) private projDonatorToIdxAmt;

	// @dev The address of precompile smart contract for SEP101
	address constant SEP101Contract = address(bytes20(uint160(0x2712)));

	// @dev The address of precompile smart contract for SEP206
	address constant SEP206Contract = address(bytes20(uint160(0x2711)));

	uint constant MaxTimeSpan = 60 * 24 * 3600; // 60 days
	uint constant MaxDonatorCount = 500;
	uint constant MaxDescriptionLength = 512;
	uint constant MaxMessageLength = 128;
	uint constant DonatorLastClearCount = 60;
	uint constant MaxReturnedSliceSize = 300;

	function safeTransfer(address receiver, uint value) private {
		receiver.call{value: value, gas: 9000}("");
	}

	function saveProjectInfo(bytes32 projectName, ProjectInfo memory info) private {
		projNameToInfo[projectName] = info;
	}

	function loadProjectInfo(bytes32 projectName, ProjectInfo memory info) private view {
		info = projNameToInfo[projectName];
		require(info.bornTime != 0, "project-not-found");
	}

	function getProjectInfoAsBytes(bytes32 projectName) private returns (bytes memory) {//TODO
		return abi.encode(projNameToInfo[projectName]);
	}

	function deleteProjectInfo(bytes32 projectName) private {
		delete projNameToInfo[projectName];
	}

	// =================================================================
	function setProjectIndexAndAmount(bytes32 projectName, uint index, uint amount) private {
		projNameToIdxAmt[projectName] = (index<<96) | amount;
	}

	function getProjectIndexAndAmount(bytes32 projectName) private view returns (uint index, uint amount) {
		uint word = projNameToIdxAmt[projectName];
		return (uint(uint64(word>>96)), uint(uint96(word)));
	}

	function getProjectIndex(bytes32 projectName) private view returns (uint) {
		uint word = projNameToIdxAmt[projectName];
		return uint(uint64(word>>96));
	}

	function getProjectAmount(bytes32 projectName) private view returns (uint) {
		uint word = projNameToIdxAmt[projectName];
		return uint(uint96(word));
	}

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

	function getDonatorIndexAndAmount(bytes32 projectName, address donator) private view returns (uint index, uint amount) {
		uint word = projDonatorToIdxAmt[projectName][donator];
		return (uint(uint64(word>>96)), uint(uint96(word)));
	}

	function getDonatorIndex(bytes32 projectName, address donator) private view returns (uint) {
		uint word = projDonatorToIdxAmt[projectName][donator];
		return uint(uint64(word>>96));
	}

	function getDonatorAmount(bytes32 projectName, address donator) public view returns (uint) {
		uint word = projDonatorToIdxAmt[projectName][donator];
		return uint(uint96(word));
	}
	
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
	function removeProject(bytes32 projectName) private {
		address[] storage donatorList = projDonatorList[projectName];
		require(donatorList.length == 0, "donators-records-not-cleared");
		delete projDonatorList[projectName];
		deleteProjectInfo(projectName);
		removeProjectIndexAndAmount(projectName);
	}

	function clearDonators(bytes32 projectName, uint count) external {
		ProjectInfo memory info;
		loadProjectInfo(projectName, info);
		uint donatedAmount = getProjectAmount(projectName);
		require(isFinalized(info, donatedAmount), "not-finalized");
		bool returnCoins = donatedAmount < info.minRaisedAmount;
		address[] storage donatorList = projDonatorList[projectName];
		_clearDonators(projectName, count, donatorList, returnCoins, info.coinType);
	}

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
				IERC20(coinType).transfer(donator, amount);
			}
		}
	}

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
	}

	function isFinalized(ProjectInfo memory info, uint donatedAmount) private view returns (bool) {
		return (block.timestamp > info.deadline || donatedAmount > info.maxRaisedAmount);
	}

	function finish(bytes32 projectName) external {
		ProjectInfo memory info;
		loadProjectInfo(projectName, info);
		uint donatedAmount = getProjectAmount(projectName);
		require(isFinalized(info, donatedAmount), "not-finalized");
		address[] storage donatorList = projDonatorList[projectName];
		bool succeed = donatedAmount >= info.minRaisedAmount;
		if(donatorList.length <= DonatorLastClearCount) {
			_clearDonators(projectName, donatorList.length, donatorList, !succeed, info.coinType);
		}
		if(succeed) {
			IERC20(info.coinType).transfer(info.receiver, donatedAmount);
		}
		removeProject(projectName);
		IERC20(SEP206Contract).transfer(info.receiver, pledge);
	}

	function donate(bytes32 projectName, uint96 amount, bytes calldata message) external payable {
		require(message.length <= MaxMessageLength, "message-too-long");
		ProjectInfo memory info;
		loadProjectInfo(projectName, info);
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
	}

	function undonate(bytes32 projectName) external {
		ProjectInfo memory info;
		loadProjectInfo(projectName, info);
		uint donatedAmount = getProjectAmount(projectName);
		require(!isFinalized(info, donatedAmount), "already-finalized");
		uint amount = removeDonatorIndexAndAmount(projectName, msg.sender);
		IERC20(info.coinType).transfer(msg.sender, amount);
	}

	//==========================================================
	function getProjectInfo(bytes32 projectName) external view returns (ProjectInfo memory info, uint amount) {
		loadProjectInfo(projectName, info);
		amount = getProjectAmount(projectName);
	}

	function getProjectNames(uint start, uint end) external view returns (bytes32[] memory names, uint count) {
		count = projectNameList.length;
		if(end > count) {
			end = count;
		}
		if(end <= start) {
			names = new bytes32[](0);
			return (names, count);
		}
		uint size = end - start;
		require(size < MaxReturnedSliceSize, "size-too-large");
		names = new bytes32[](size);
		for(uint i=start; i<end; i++) {
			names[i-start] = projectNameList[i];
		}
	}

	function getDonations(bytes32 projectName, uint start, uint end) external view returns (
			address[] memory donators, uint[] memory amounts, uint count) {
		address[] storage donatorList = projDonatorList[projectName];
		count = donatorList.length;
		if(end > count) {
			end = count;
		}
		if(end <= start) {
			donators = new address[](0);
			amounts = new uint[](0);
			return (donators, amounts, count);
		}
		uint size = end - start;
		require(size < MaxReturnedSliceSize, "size-too-large");
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

