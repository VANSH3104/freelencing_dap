// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Freelancing is Ownable, ReentrancyGuard {
    using Counters for Counters.Counter;
    
    enum JobStatus { Open, Assigned, Completed, Disputed, Cancelled }

    struct Application {
        address freelancer;
        string resume;
        uint256 bidAmount;
        uint256 timestamp;
    }

    struct Job {
        uint256 jobId;
        address client;
        string jobTitle;
        string description;
        uint256 price;
        JobStatus status;
        address freelancer;
        uint256 createdAt;
        uint256 completedAt;
        bool fundsReleased;
    }

    struct UserProfile {
        bool isClient;
        bool isFreelancer;
        string resume;
        uint256 rating;
        uint256 completedJobs;
        uint256 createdAt;
    }

    // Mappings
    mapping(uint256 => Job) public jobs;
    mapping(address => UserProfile) public users;
    mapping(uint256 => Application[]) public jobApplications;
    mapping(uint256 => mapping(address => bool)) public hasApplied;
    mapping(address => uint256[]) public clientJobs;
    mapping(address => uint256[]) public freelancerJobs;
    mapping(uint256 => uint256) public escrowedFunds;

    // Counters
    Counters.Counter private _jobCounter;
    Counters.Counter private _userCounter;

    // Constants
    uint256 public constant PLATFORM_FEE_PERCENT = 2;
    address public immutable platformWallet;

    // Events
    event UserRegistered(address indexed user, bool isClient, bool isFreelancer);
    event JobCreated(uint256 indexed jobId, address indexed client, string jobTitle, uint256 price);
    event JobAssigned(uint256 indexed jobId, address indexed freelancer, uint256 bidAmount);
    event JobCompleted(uint256 indexed jobId);
    event PaymentReleased(uint256 indexed jobId, address indexed freelancer, uint256 amount);
    event FreelancerApplied(uint256 indexed jobId, address indexed freelancer, string resume, uint256 bidAmount);
    event JobCancelled(uint256 indexed jobId, address indexed client);
    event JobUpdated(uint256 indexed jobId, address indexed client, string newTitle, string newDescription);
    event DisputeRaised(uint256 indexed jobId, address indexed raisedBy);
    event RatingGiven(uint256 indexed jobId, address indexed from, address indexed to, uint256 rating);

    constructor(address _platformWallet) Ownable(msg.sender) {
        platformWallet = _platformWallet;
    }

    // Combined registration function
    function registerUser(bool _isClient, bool _isFreelancer, string calldata _resume) external {
        require(!users[msg.sender].isClient && !users[msg.sender].isFreelancer, "Already registered");
        require(_isClient || _isFreelancer, "Must be client or freelancer");
        
        users[msg.sender] = UserProfile({
            isClient: _isClient,
            isFreelancer: _isFreelancer,
            resume: _isFreelancer ? _resume : "",
            rating: 0,
            completedJobs: 0,
            createdAt: block.timestamp
        });
        
        _userCounter.increment();
        emit UserRegistered(msg.sender, _isClient, _isFreelancer);
    }

    // Create a new job with escrow
    function createJob(string calldata _title, string calldata _description, uint256 _price) external payable {
        require(users[msg.sender].isClient, "Only clients can post jobs");
        require(_price > 0, "Price must be positive");
        require(bytes(_title).length > 0, "Title cannot be empty");
        require(bytes(_description).length > 0, "Description cannot be empty");

        _jobCounter.increment();
        uint256 jobId = _jobCounter.current();
        
        jobs[jobId] = Job({
            jobId: jobId,
            client: msg.sender,
            jobTitle: _title,
            description: _description,
            price: _price,
            status: JobStatus.Open,
            freelancer: address(0),
            createdAt: block.timestamp,
            completedAt: 0,
            fundsReleased: false
        });

        escrowedFunds[jobId] = msg.value;
        clientJobs[msg.sender].push(jobId);
        
        emit JobCreated(jobId, msg.sender, _title, _price);
    }

    // Apply for a job with optional bid amount
    function applyForJob(uint256 _jobId, string calldata _resume, uint256 _bidAmount) external {
        require(jobs[_jobId].jobId == _jobId, "Invalid job ID");
        require(users[msg.sender].isFreelancer, "Only freelancers can apply");
        require(jobs[_jobId].status == JobStatus.Open, "Job not open");
        require(!hasApplied[_jobId][msg.sender], "Already applied");
        require(_bidAmount <= jobs[_jobId].price, "Bid cannot exceed job price");

        jobApplications[_jobId].push(Application({
            freelancer: msg.sender,
            resume: _resume,
            bidAmount: _bidAmount,
            timestamp: block.timestamp
        }));

        hasApplied[_jobId][msg.sender] = true;
        
        emit FreelancerApplied(_jobId, msg.sender, _resume, _bidAmount);
    }

    // Assign job to freelancer with optional bid acceptance
    function assignJob(uint256 _jobId, address _freelancer, uint256 _applicationIndex) external {
        require(jobs[_jobId].jobId == _jobId, "Invalid job ID");
        require(jobs[_jobId].client == msg.sender, "Only job owner can assign");
        require(jobs[_jobId].status == JobStatus.Open, "Job not open");
        require(users[_freelancer].isFreelancer, "Invalid freelancer");
        require(_applicationIndex < jobApplications[_jobId].length, "Invalid application index");
        require(jobApplications[_jobId][_applicationIndex].freelancer == _freelancer, "Freelancer mismatch");

        jobs[_jobId].freelancer = _freelancer;
        jobs[_jobId].status = JobStatus.Assigned;
        
        // If bid is lower than original price, adjust the price
        uint256 bidAmount = jobApplications[_jobId][_applicationIndex].bidAmount;
        if (bidAmount > 0 && bidAmount < jobs[_jobId].price) {
            jobs[_jobId].price = bidAmount;
        }
        
        freelancerJobs[_freelancer].push(_jobId);
        
        emit JobAssigned(_jobId, _freelancer, bidAmount);
    }

    // Mark job as completed (can be called by both parties)
    function completeJob(uint256 _jobId) external {
        require(jobs[_jobId].jobId == _jobId, "Invalid job ID");
        require(
            jobs[_jobId].freelancer == msg.sender || jobs[_jobId].client == msg.sender,
            "Only freelancer or client can complete"
        );
        require(jobs[_jobId].status == JobStatus.Assigned, "Job not assigned");

        jobs[_jobId].status = JobStatus.Completed;
        jobs[_jobId].completedAt = block.timestamp;
        users[jobs[_jobId].freelancer].completedJobs++;
        
        emit JobCompleted(_jobId);
    }

    // Release payment to freelancer (with platform fee)
    function releasePayment(uint256 _jobId) external nonReentrant {
        require(jobs[_jobId].jobId == _jobId, "Invalid job ID");
        require(jobs[_jobId].client == msg.sender, "Only client can release");
        require(jobs[_jobId].status == JobStatus.Completed, "Job not completed");
        require(!jobs[_jobId].fundsReleased, "Payment already released");
        require(escrowedFunds[_jobId] >= jobs[_jobId].price, "Insufficient escrowed funds");

        uint256 amount = jobs[_jobId].price;
        address freelancer = jobs[_jobId].freelancer;
        
        // Calculate platform fee
        uint256 platformFee = (amount * PLATFORM_FEE_PERCENT) / 100;
        uint256 freelancerAmount = amount - platformFee;

        // Update state before transfer
        jobs[_jobId].fundsReleased = true;
        escrowedFunds[_jobId] -= amount;

        // Transfer funds
        (bool success1, ) = payable(freelancer).call{value: freelancerAmount}("");
        (bool success2, ) = payable(platformWallet).call{value: platformFee}("");
        require(success1 && success2, "Transfer failed");

        emit PaymentReleased(_jobId, freelancer, freelancerAmount);
    }

    // Cancel job and refund client
    function cancelJob(uint256 _jobId) external nonReentrant {
        require(jobs[_jobId].jobId == _jobId, "Invalid job ID");
        require(jobs[_jobId].client == msg.sender, "Only client can cancel");
        require(jobs[_jobId].status == JobStatus.Open, "Job not cancellable");
        require(escrowedFunds[_jobId] > 0, "No funds to refund");

        uint256 amount = escrowedFunds[_jobId];
        escrowedFunds[_jobId] = 0;
        jobs[_jobId].status = JobStatus.Cancelled;

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Refund failed");
        
        emit JobCancelled(_jobId, msg.sender);
    }

    // Raise a dispute
    function raiseDispute(uint256 _jobId) external {
        require(jobs[_jobId].jobId == _jobId, "Invalid job ID");
        require(
            jobs[_jobId].freelancer == msg.sender || jobs[_jobId].client == msg.sender,
            "Only freelancer or client can dispute"
        );
        require(
            jobs[_jobId].status == JobStatus.Assigned || jobs[_jobId].status == JobStatus.Completed,
            "Invalid job status for dispute"
        );

        jobs[_jobId].status = JobStatus.Disputed;
        
        emit DisputeRaised(_jobId, msg.sender);
    }

    // Give rating (1-5)
    function giveRating(uint256 _jobId, uint256 _rating) external {
        require(jobs[_jobId].jobId == _jobId, "Invalid job ID");
        require(jobs[_jobId].status == JobStatus.Completed, "Job not completed");
        require(_rating >= 1 && _rating <= 5, "Rating must be 1-5");
        
        if (msg.sender == jobs[_jobId].client) {
            // Client rating freelancer
            address freelancer = jobs[_jobId].freelancer;
            users[freelancer].rating = (users[freelancer].rating * users[freelancer].completedJobs + _rating) / 
                                      (users[freelancer].completedJobs + 1);
            emit RatingGiven(_jobId, msg.sender, freelancer, _rating);
        } else if (msg.sender == jobs[_jobId].freelancer) {
            // Freelancer rating client
            address client = jobs[_jobId].client;
            users[client].rating = (users[client].rating * users[client].completedJobs + _rating) / 
                                 (users[client].completedJobs + 1);
            emit RatingGiven(_jobId, msg.sender, client, _rating);
        } else {
            revert("Not authorized");
        }
    }

    // Edit job details
    function editJob(uint256 _jobId, string calldata _newTitle, string calldata _newDescription) external {
        require(jobs[_jobId].jobId == _jobId, "Invalid job ID");
        require(jobs[_jobId].client == msg.sender, "Only job owner can edit");
        require(jobs[_jobId].status == JobStatus.Open, "Can only edit open jobs");
        require(bytes(_newTitle).length > 0, "Title cannot be empty");
        require(bytes(_newDescription).length > 0, "Description cannot be empty");

        jobs[_jobId].jobTitle = _newTitle;
        jobs[_jobId].description = _newDescription;

        emit JobUpdated(_jobId, msg.sender, _newTitle, _newDescription);
    }

    // View functions for frontend
    function getJobApplications(uint256 _jobId) external view returns (Application[] memory) {
        require(jobs[_jobId].jobId == _jobId, "Invalid job ID");
        return jobApplications[_jobId];
    }

    function getClientJobs(address _client) external view returns (uint256[] memory) {
        return clientJobs[_client];
    }

    function getFreelancerJobs(address _freelancer) external view returns (uint256[] memory) {
        return freelancerJobs[_freelancer];
    }

    function getJobDetails(uint256 _jobId) external view returns (Job memory) {
        require(jobs[_jobId].jobId == _jobId, "Invalid job ID");
        return jobs[_jobId];
    }

    function getUserProfile(address _user) external view returns (UserProfile memory) {
        return users[_user];
    }

    function getTotalJobs() external view returns (uint256) {
        return _jobCounter.current();
    }

    function getTotalUsers() external view returns (uint256) {
        return _userCounter.current();
    }

    function getEscrowedAmount(uint256 _jobId) external view returns (uint256) {
        return escrowedFunds[_jobId];
    }
}