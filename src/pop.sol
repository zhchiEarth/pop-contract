// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

/*
    In the first version, we will first implement a proving market that supports
circom circuits with PLONK protocol. The client submits a download URL
of a circom program, the vk and the Input Data to the circuit. Also the
client needs to specify a deadline of the task and a string to specify the ZKP
protocol (in this version, only "PLONK" is acceptable). In this version, we will
not integrate the credit part.
*/
contract PoP is OwnableUpgradeable, AccessControlUpgradeable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct Task {
        string url;         // the download URL of a circom program
        string vk;           
        string protocol;    // which protocol the task uses
        address client;     // user who create the task
        address miner;      // The server that receives this task, defalut null
        uint256 price;      // reward for this task
        uint256 deadline;   // the timestamp of the end of the task
        TaskStatus status;  // the status of the task
        bytes data;         // input data
        bytes proof;        // proof result data, default null
    }

    // save user data
    struct UserInfo {
        uint256 amount; // How many tokens the user has provided.
        uint256 freeze; // Amount of token lock.
    }

    mapping(string => address) public protocols;                // supported protocols, protocol -> token
    mapping(uint256 => Task) public tasks;                      // task map, id -> task
    mapping(address => mapping(address => UserInfo)) public userInfo;  // user's info, user -> token -> info
    mapping(uint256 => bool) public claimed;                           // whether a task has been reward
    mapping(address => uint256) public minAsks;                        // the lowest price when a user create a task
    mapping(string => mapping(address => uint256)) public minAdd;      // the minimum amount when user staking token, protocol -> token -> amount
    uint256 public counter;                                     // task counter, unique in the whole set

    bytes32 constant HASH_EMPTY_STRING = keccak256(abi.encode(""));

    enum TaskStatus{ SUBMITTED, ASSIGNED, VERIFIED_SUCCESS, VERIFIED_FAILED }

    event NewTask(uint256 indexed id, bytes data);
    event UpdateTaskStatus(uint256 indexed id, TaskStatus status);

    /**
     * @dev Initialize pool contract function.
     */
    function initialize() public initializer {
        __Ownable_init();
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function setAsk(address _token, uint256 _ask) external onlyOwner {
        minAsks[_token] = _ask;
    }

    function setMinAdd(string memory _proto, address _token, uint256 _min) external onlyOwner {
        require(_token != address(0), "invalid token address");
        require(protocols[_proto] != address(0), "unknown protocol");

        minAdd[_proto][_token] = _min;
    }

    function addProtocol(string memory _proto, address _token) external onlyOwner() {
        require(_token != address(0), "invalid token address");
        protocols[_proto] = _token;
    }

    function removeProtocol(string memory _proto) external onlyOwner() {
        protocols[_proto] = address(0);
    }

    /*
        send a transaction that specifies a URL to the circom circuit, the input data and vk of the circuit, 
        the deadline of the task (End timestamp), the ZKP algorithm to use (string), and include in the transaction the amount of ZK0 
        token willing to pay. The contract assigns a unique ID to the task and stores the vk and Input Data
    */
    function submitTask(bytes memory data) external returns (uint256) {        
       (uint256 _price, uint256 _deadline, string memory _url, string memory _vk, string memory _proto, bytes memory _input) = abi.decode(
           data, 
           (uint256, uint256, string, string, string, bytes)
       );

       address _token = protocols[_proto];

       require(_deadline > block.timestamp, "invalid deadline");
       require(_price >= minAsks[_token], "invalid price");
       require(protocols[_proto] != address(0), "unknown protocol");
       require(keccak256(abi.encode(_url)) != HASH_EMPTY_STRING, "invalid url");
       require(keccak256(abi.encode(_vk)) != HASH_EMPTY_STRING, "invalid vk");
       require(keccak256(abi.encode(_input)) != HASH_EMPTY_STRING, "invalid input data");

       IERC20(_token).safeTransferFrom(msg.sender, address(this), _price);

       UserInfo storage _info = userInfo[msg.sender][_token];
       _info.freeze = _info.freeze.add(_price);

       Task memory _task = Task({
           data: _input, 
           proof: "", 
           url: _url, 
           vk: _vk, 
           protocol: _proto, 
           client: msg.sender, 
           miner: address(0), 
           price: _price, 
           deadline: _deadline, 
           status: TaskStatus.SUBMITTED
        });

       uint256 _id = counter;
       tasks[_id] = _task;
       counter++;

       emit NewTask(_id, data);
       return _id;
    }

    /*
        If the task is finished, return the proof generated by the prover.
    */
    function GetProof(uint256 _id) external returns (bytes memory) {
        require(_id < counter, "invalid id");

        _checkTask(_id);
        return tasks[_id].proof;
    }

    function _checkTask(uint256 _id) internal {
        Task storage _task = tasks[_id];

        // check task timeout
        if (_task.status == TaskStatus.ASSIGNED && _task.deadline < block.timestamp) {
            address _token = protocols[_task.protocol];
            uint256 _amount = _task.price.div(2);

            UserInfo storage _miner = userInfo[_task.miner][_token];
            UserInfo storage _client = userInfo[_task.client][_token];

            _miner.freeze = _miner.freeze.sub(_amount);

            _client.amount = _client.amount.add(_amount);
            _client.amount = _client.amount.add(_task.price);
            _client.freeze = _client.freeze.sub(_task.price);

            _task.status = TaskStatus.VERIFIED_FAILED;
            emit UpdateTaskStatus(_id, TaskStatus.VERIFIED_FAILED);
        }
    }

    /*
        If the client is the owner of the task with id,
        the task is already taken by some miner but is expired, transfer 0.5x
        the price of the task as the compensation to the client from the miner’s
        staking
    */
    function ClaimCompensation(uint256 _id) external {
        require(_id < counter, "invalid id");

        _checkTask(_id);

        Task storage _task = tasks[_id];
        require(msg.sender == _task.client, "without permission");

        address _token = protocols[_task.protocol];

        if (_task.status == TaskStatus.VERIFIED_FAILED && !claimed[_id]) { 
            IERC20 _erc = IERC20(_token);
            uint256 _amount = _task.price.div(2);
            UserInfo storage _client = userInfo[msg.sender][_token];

            _amount = _task.price.add(_amount);
            require(_client.amount >= _amount, "insufficient amount");
            _client.amount = _client.amount.sub(_amount);

            _erc.safeTransfer(msg.sender, _amount);
            claimed[_id] = true;
        }
    }

    /*
        return the detailed information about the task with id.
    */
    function GetTask(uint256 _id) external returns (bytes memory) {
        require(_id < counter, "invalid id");

        _checkTask(_id);

        Task memory _task = tasks[_id];
        return abi.encode(
            _task.price, _task.deadline, _task.url, _task.vk, 
            _task.protocol, _task.client, _task.miner, _task.status,
            _task.data
        );
    }

    /*
        stake ZK0 tokens into the smart contract.
    */
    function Stake(string memory _proto, uint256 _amount) external {
        address _token = protocols[_proto];

        require(_token != address(0), "unknown protocol");
        require(_amount >= minAdd[_proto][_token], "stack amount too low");

        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        UserInfo storage _info = userInfo[msg.sender][_token];
        _info.amount = _info.amount.add(_amount);
    }

    function Unstake(string memory _proto, uint256 _amount) external {
        address _token = protocols[_proto];
        require(_token != address(0), "unknown protocol");

        UserInfo storage _info = userInfo[msg.sender][_token];
        require(_info.amount >= _amount, "invalid withdraw amount");

        IERC20 _erc = IERC20(_token);
        _erc.safeTransfer(msg.sender, _amount);
       
        _info.amount = _info.amount.sub(_amount);
    }
    
    /*
        If the task is available and the miner’s staking is more
        than 0.5x the price of the task, assign the task with id to the miner.
    */
    function TakeTask(uint256 _id) external {
        require(_id < counter, "invalid id");

        _checkTask(_id);

        Task storage _task = tasks[_id];
        require(_task.status == TaskStatus.SUBMITTED, "task has been accepted");

        address _token = protocols[_task.protocol];
        UserInfo storage _info = userInfo[msg.sender][_token];
        uint256 _limit = _task.price.div(2);

        if (_info.amount >= _limit) {
            _info.amount = _info.amount.sub(_limit);
            _info.freeze = _info.freeze.add(_limit);
            
            _task.miner = msg.sender;
            _task.status = TaskStatus.ASSIGNED;
        }
    }

    /*
        Verify the sender is the miner who took the task before and the task is not finished or expired. 
        Verify the PLONK proof using vk and Input Data. The PLONK verification contract can be found
        on Github. If the proof is verified, transfer the price of task paid by the
        client to the miner. Mark the task as finished and record the proof on
        chain
    */
    function VerifyProof(uint256 _id, bytes memory _proof) external returns (bool) {
        require(_id < counter, "invalid id");
        
        _checkTask(_id);

        Task storage _task = tasks[_id];
        require(msg.sender == _task.miner, "not miner");
        require(_task.status == TaskStatus.ASSIGNED, "task not being processe");

        // todo
        bool _result = true;
        address _token = protocols[_task.protocol];
        uint256 _limit = _task.price.div(2);

        UserInfo storage _miner = userInfo[msg.sender][_token];
        UserInfo storage _client = userInfo[_task.client][_token];

        // verify success
        if (_result) {
            _miner.amount = _miner.amount.add(_task.price);
            _miner.amount = _miner.amount.add(_limit);
            _miner.freeze = _miner.freeze.sub(_limit);

            _client.freeze = _client.freeze.sub(_task.price);

            _task.proof = _proof;
            _task.status = TaskStatus.VERIFIED_SUCCESS;
            return true;
        }

        // verify failed  
        _miner.freeze = _miner.freeze.sub(_limit);

        _client.amount = _client.amount.add(_limit);
        _client.amount = _client.amount.add(_task.price);
        _client.freeze = _client.freeze.sub(_task.price);

        _task.status = TaskStatus.VERIFIED_FAILED;
        return false;
    }
}
