// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {Address, Turnstile, Ownable} from "./deps.sol";
import {Cantofornia} from "./minter.sol";

contract Splitter is Ownable {
    /** Pool params **/

    // the timestamp when the contract was instantiated (used for unlock calculations)
    uint256 public startTime;
    // the timestamp when funds were last unlocked (used for unlock calculations)
    uint256 public lastUnlockTime;
    // cliff duration (in seconds)
    uint256 public unlockCliff;
    // how frequently the unlockedFunds will be updated (in seconds)
    uint256 public unlockPeriod;
    // the percentage of locked funds that will be transferred to the unlocked pool
    uint8 public unlockPercent;
    // the percentage of funds that is allocated for the team
    uint8 public teamSplit;
    // the address the team will use to withdraw funds
    address public teamAddress;
    // the amount of canto that is claimable by the team
    uint256 public teamFunds = 0;
    // the amount of canto that is not yet claimable
    uint256 public lockedFunds = 0; 
    // the total amount of canto that has been unlocked
    // note: withdrawing funds does not subtract from unlocked funds (up only)
    uint256 public unlockedFunds = 0; 


    /** Accounting variables **/

    // the number of unique addresses that are members
    uint16 public memberCount = 0;
    // the sum of each address' power
    uint256 public totalPower = 0;
    // a map of wagon NFT IDs to whether or not they have been registered (true if registered)
    mapping(uint256 => bool) private registeredWagons;
    // a map of addresses to the amount of funds they have withdrawn
    // this is used to calculate available balance
    mapping(address => uint256) private withdrawnFunds;
    // addr -> pool share (poolShare = power[addr] / totalPower) mapping
    mapping(address => uint16) private power;


    /** CSR variables **/

    // the ID of the wagon contract's CSR NFT 
    uint256 public wagonCsrId;
    // the ID of this contract's CSR NFT
    uint256 public splitterCsrId;
    // the CSR turnstile contract
    Turnstile private turnstile = Turnstile(0x8279528D7E3E5988B24d5ae23D7b80bC86BBA1Cf); // a testnet turnstile
    // Turnstile private turnstile = Turnstile(0xEcf044C5B4b867CFda001101c617eCd347095B44);
    // the address of the wagon minter contract
    address wagonAddress;

    
    /** Events **/

    event ReceivedFunds(uint256 amount, address from);
    event WagonRegistered(uint256 wagonId, address owner, bool isInitial);
    event CsrRewardsClaimed(uint256 csrId, uint256 rewards, address claimedBy);
    event BalanceWithdrawn(uint256 amount, address sender);
    event FundsUnlocked(uint256 amount, address sender);

    constructor(uint256 _unlockCliff, uint256 _unlockPeriod, uint8 _unlockPercent, uint8 _teamSplit, address _teamAddress) {
        // Initialize pool parameters
        startTime = block.timestamp;
        lastUnlockTime = 0;
        unlockCliff = _unlockCliff;
        unlockPeriod = _unlockPeriod;
        unlockPercent = _unlockPercent; // must be between 1 and 99
        teamSplit = _teamSplit; // must be between 1 and 99
        teamAddress = _teamAddress;

        // Initialize CSR variables
        splitterCsrId = turnstile.register(address(this));
    }

    modifier onlyVictors(uint256 wagonTokenId) {
        require(Cantofornia(wagonAddress).ownsWagon(msg.sender, wagonTokenId), "Unauthorized sender. msg.sender is not the owner of the wagon");
        require(Cantofornia(wagonAddress).wagonState(wagonTokenId) == Cantofornia.WagonState.Successful, "Unauthorized token ID. Wagon must be in the successful state.");
        _;
    }

    modifier onlyMembers() {
        // TODO: think about > vs !=
        require(power[msg.sender] > uint16(0), "msg.sender must be a member of this contract");
        _;
    }

    modifier onlyTeam() {
        require(msg.sender == teamAddress, "msg.sender must be the team address specified in instantiation");
        _;
    }

    fallback() external payable {
        addToLockedPool(msg.value);
        emit ReceivedFunds(msg.value, msg.sender);
    }

    receive() external payable {
        addToLockedPool(msg.value);
        emit ReceivedFunds(msg.value, msg.sender);
    }

    function deposit() external payable {
        addToLockedPool(msg.value);
        emit ReceivedFunds(msg.value, msg.sender);
    }

    // Requires owner to create wagon and CSR NFTs
    // Owner must call setSplitterInfo from the wagon contract
    function setWagonCsrId(uint256 csrId) external {
        require(owner() == tx.origin, "Unauthorized. msg.sender must be the wagon contract");
        wagonCsrId = csrId;
        wagonAddress = msg.sender;
    }

    function registerWagon(uint256 wagonTokenId) external onlyVictors(wagonTokenId) {
        require(registeredWagons[wagonTokenId] == false, "Wagon already registered");
        bool isInitial = false;
        if (power[msg.sender] == uint16(0)) {
            // Initialize member
            power[msg.sender] = uint16(1);
            memberCount++;
            isInitial = true;
        }
        registeredWagons[wagonTokenId] = true;
        totalPower++;

        emit WagonRegistered(wagonTokenId, msg.sender, isInitial);
    }

    function claimFromCSR(uint256 csrId, uint256 amount) external onlyMembers returns (uint256) {
        require(csrId == wagonCsrId || csrId == splitterCsrId, "Invalid CSR NFT id");
        uint256 prevBalance = lockedFunds;
        uint256 amountWithdrawn = turnstile.withdraw(csrId, payable(this), amount);
        if (lockedFunds != prevBalance + amountWithdrawn) {
            revert("Could not claim from CSR. Invalid update to lockedFunds");
        }
        
        emit CsrRewardsClaimed(csrId, amountWithdrawn, msg.sender);
        return amountWithdrawn;
    }

    function withdrawBalance(uint256 amount, bool all) external onlyMembers returns (uint256) {
        uint256 availableFunds = getBalanceOfSender();
        uint256 toWithdraw = all ? availableFunds : amount;
        if (toWithdraw > availableFunds) {
            revert("Invalid withdraw amount. Insufficient funds");
        }
        withdrawnFunds[msg.sender] += toWithdraw;
        // Send funds last to ensure no re-entrancy
        Address.sendValue(payable(msg.sender), toWithdraw);
        emit BalanceWithdrawn(toWithdraw, msg.sender);
        return toWithdraw;
    }

    function withdrawTeamBalance(uint256 amount, bool all) external onlyTeam returns (uint256) {
        uint256 toWithdraw = all ? teamFunds : amount;
        if (toWithdraw > teamFunds) {
            revert("Invalid withdraw amount. Insufficient funds");
        }
        teamFunds -= toWithdraw;
        Address.sendValue(payable(teamAddress), toWithdraw);
        emit BalanceWithdrawn(toWithdraw, msg.sender);
        return toWithdraw;
    }

    function addToLockedPool(uint256 amount) internal {
        if (amount > 0) {
            // allocate teamSplit% of fees to the team
            uint256 teamAmount = (amount * teamSplit) / 100;
            teamFunds += teamAmount;
            lockedFunds += amount - teamAmount;
        }
    }

    function unlockFunds() external onlyMembers returns (uint256) {
        require(block.timestamp >= startTime + unlockCliff, "Vesting has not reached cliff. Try again later");
        // TODO: remove if you can't get this to fail in tests
        require(lastUnlockTime <= 0, "Something broke bad..."); 
        require(block.timestamp >= lastUnlockTime + unlockPeriod, "Funds still vesting. Try again later");
        uint256 unlockAmount = (lockedFunds * unlockPercent) / 100;
        lockedFunds -= unlockAmount;
        unlockedFunds += unlockAmount;
        emit FundsUnlocked(unlockAmount, msg.sender);
        return unlockAmount;
    }

    /* QUERY METHODS */
    function getBalanceOfSender() internal view onlyMembers returns (uint256) {
        uint256 maxAvailable = (unlockedFunds * power[msg.sender]) / totalPower;
        uint256 amountWithdrawn = withdrawnFunds[msg.sender];
        return maxAvailable - amountWithdrawn;
    }
    
}
