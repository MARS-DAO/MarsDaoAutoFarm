// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./lib/IERC20.sol";
import "./lib/IMarsAutoFarm.sol";
import "./lib/SafeERC20.sol";
//import "./lib/console.sol";

pragma experimental ABIEncoderV2;

contract MarsAutoFarmGovernance{
    using SafeERC20 for IERC20;

    struct Proposal {
        address proposer;
        uint256 proposerLockupAmount;
        uint256 deadline;
        uint256 readyToExecutionTime;
        uint256 cancellationTime;
        uint256 YES;
        uint256 NO;
        bool executed;
        Func callfunction;
        uint256[] pools;
        string signature;
        bytes calldatas;
    }

    struct BUSYINFO{
        bool busy;
        uint256 voting_id;
    }

    enum ProposalState{
        Unknown,
        Failed,
        Cancelled,
        Active,
        Succeeded,
        ExecutionWaiting,
        Executed
    }

    enum Func {
        setBurnRate,
        setbuyBackRate,
        setSwapSlippageBP,
        inCaseTokensGetStuck,
        pause,
        unpause,
        setRouter0,
        setRouter1,
        setRouter2,
        setGov
    }

    string[10] public signatures=[
        "setBurnRate(uint256)",
        "setbuyBackRate(uint256)",
        "setSwapSlippageBP(uint256)",
        "inCaseTokensGetStuck(address,uint256,address)",
        "pause()",
        "unpause()",
        "setRouter0(address[][])",
        "setRouter1(address[][])",
        "setRouter2(address[][])",
        "setGov(address)"
    ];

    IMarsAutoFarm immutable public marsAutoFarm;
    IERC20 immutable public marsToken;
    IERC20 immutable public governanceToken;

    uint256 constant public PROPOSAL_CREATION_FEE= 100*1e18;//mars
    uint256 constant public LOCKUP_FOR_PROPOSAL = 1000*1e18;//GMARSDAO
    uint256 constant public LOCKUP_FOR_SPECIAL_PROPOSAL = 100000*1e18;//GMARSDAO
    uint256 constant public MIN_LOCKUP_FOR_VOTING = 100*1e18;
    uint256 constant public MAX_LOCKUP_FOR_VOTING = 30000*1e18;

    uint256 constant public QUORUM_VOTES =100_000*1e18;
    uint256 constant public EXECUTION_WAITING_PERIOD = 5 days;
    uint256 constant public EXECUTION_LOCK_PERIOD = 4 days;
    uint256 constant public VOTING_PERIOD = 3 days;
    address public constant burnAddress =
        0x000000000000000000000000000000000000dEaD;

    Proposal[] public proposals;
    mapping(uint256 => mapping(address => uint256)) public userLockupAmount;
    mapping(Func=>mapping(uint256=>BUSYINFO)) public functionStatus;
    
    event ProposalCreated(uint256 proposalId);
    event VoteCast(uint256 proposalId, address voter,uint256 votes,bool support);
    event ProposalExecuted(uint256 proposalId);
    
    modifier exists(uint256 _proposalId) {
        require(state(_proposalId)!=ProposalState.Unknown,"proposal not exist");
        _;
    }


    constructor(address _marsAutoFarm,address _marsTokenAddress,address _governanceTokenAddress) public{
        marsAutoFarm=IMarsAutoFarm(_marsAutoFarm);
        marsToken=IERC20(_marsTokenAddress);
        governanceToken=IERC20(_governanceTokenAddress);
    }

    function propose(uint256[] memory pools,Func callfunction,bytes memory calldatas) external returns (uint256){
        
        uint256 valueThatNeedChacked=0;
        if(callfunction<Func.inCaseTokensGetStuck){
            valueThatNeedChacked=abi.decode(calldatas,(uint256));
            if(callfunction==Func.setSwapSlippageBP){
                require(valueThatNeedChacked<1000,"slippage should be between 0-1000");
            }else if(callfunction==Func.setbuyBackRate){
                require(valueThatNeedChacked <= 7000, "buyBackRate too high");
                require(valueThatNeedChacked >= 3000, "buyBackRate too low"); 
            }else {
                require(valueThatNeedChacked <= 4500, "burnRate too high");
                require(valueThatNeedChacked >= 1000, "burnRate too low");
            }
        }
        
        uint256 poolsLenth=marsAutoFarm.poolLength();
        uint256 proposalId=proposals.length;
         
        for(uint256 i=0;i<pools.length;i++){
            require(pools[i]<poolsLenth,string(abi.encodePacked("pool ", uint2str(pools[i])," is not exist")));
            BUSYINFO storage func_status = functionStatus[callfunction][pools[i]];
            require(func_status.busy==false || state(func_status.voting_id) < ProposalState.Active, 
            string(abi.encodePacked("proposal ",uint2str(func_status.voting_id)," for changes in pool ",uint2str(pools[i])," already exists.")));
            func_status.busy=true;func_status.voting_id=proposalId;
        }

        marsToken.safeTransferFrom(
            address(msg.sender),
            burnAddress,
            PROPOSAL_CREATION_FEE
        );
        uint256 proposerLockupAmount= callfunction<Func.pause ? LOCKUP_FOR_PROPOSAL:LOCKUP_FOR_SPECIAL_PROPOSAL;
        governanceToken.safeTransferFrom(
            address(msg.sender),
            address(this),
            proposerLockupAmount
        );

        proposals.push(Proposal({
            proposer : msg.sender,
            proposerLockupAmount:proposerLockupAmount,
            deadline : block.timestamp+VOTING_PERIOD,
            readyToExecutionTime : block.timestamp+EXECUTION_LOCK_PERIOD,
            cancellationTime : block.timestamp+EXECUTION_WAITING_PERIOD,
            YES : 0,
            NO : 0,
            executed : false,
            callfunction : callfunction,
            pools : pools,
            signature:signatures[uint256(callfunction)],
            calldatas : calldatas
        }));

        emit ProposalCreated(
            proposalId
        );

        return proposalId;
    }

    function verifyCallResult(
        bool success,
        bytes memory returndata,
        string memory errorMessage
    ) internal pure returns (bytes memory) {
        if (success) {
            return returndata;
        } else {
            // Look for revert reason and bubble it up if present
            if (returndata.length > 0) {
                // The easiest way to bubble the revert reason is using memory via assembly

                // solhint-disable-next-line no-inline-assembly
                assembly {
                    let returndata_size := mload(returndata)
                    revert(add(32, returndata), returndata_size)
                }
            } else {
                revert(errorMessage);
            }
        }
    }


    function execute(uint256 proposalId) external{

        require(state(proposalId) == ProposalState.ExecutionWaiting, "execution not available");
        Proposal storage proposal = proposals[proposalId];
        proposal.executed=true;
        Func exec_function=proposal.callfunction;

        bytes memory calldatas=abi.encodePacked(bytes4(keccak256(bytes(signatures[uint256(proposal.callfunction)]))), proposal.calldatas);

        for(uint256 i=0;i<proposal.pools.length;i++){
            address target=marsAutoFarm.poolInfo(proposal.pools[i]).strat;
            functionStatus[exec_function][proposal.pools[i]].busy=false;
            (bool success, bytes memory returndata) = target.call(calldatas);
            verifyCallResult(success, returndata, string(abi.encodePacked("execution error for ",uint2str(proposal.pools[i])," pool")));
        }

        emit ProposalExecuted(proposalId);
    }


    function castVote(uint256 proposalId,uint256 votes,bool support) external exists(proposalId){
        require(state(proposalId) == ProposalState.Active, "voting is closed");
        Proposal storage proposal = proposals[proposalId];
        require(userLockupAmount[proposalId][msg.sender] == 0, "already voted");
        require(votes>=MIN_LOCKUP_FOR_VOTING, "votes is too little");
        require(votes<=MAX_LOCKUP_FOR_VOTING, "votes is too much");
        governanceToken.safeTransferFrom(
            address(msg.sender),
            address(this),
            votes
        );

        userLockupAmount[proposalId][msg.sender] = votes;

        if(support){
            proposal.YES+=votes;
        }else{
            proposal.NO+=votes;
        }

        emit VoteCast(proposalId, msg.sender,votes,support);
    }

    function getBackProposalStake(uint256 proposalId) external exists(proposalId){
        ProposalState currentState = state(proposalId);
        require(currentState < ProposalState.Active || currentState ==  ProposalState.Executed, "voting is not closed yet");
        Proposal storage proposal = proposals[proposalId];
        require(proposal.proposer==msg.sender,"caller not proposer");
        uint256 proposerLockupAmount=proposal.proposerLockupAmount;
        proposal.proposerLockupAmount=0;
        governanceToken.safeTransfer(
            proposal.proposer,
            proposerLockupAmount
        );
    }

    function getBackVotingStake(uint256 proposalId) external exists(proposalId){
        require(state(proposalId) != ProposalState.Active, "voting is not closed yet");
        uint256 stakeAmount=userLockupAmount[proposalId][msg.sender];
        require(stakeAmount > 0, "your stake is 0");
        userLockupAmount[proposalId][msg.sender]=0;
        governanceToken.safeTransfer(
            address(msg.sender),
            stakeAmount
        );
    }

    function proposalsCount() public view returns (uint256) {
        return proposals.length;
    }

    function getActions(uint256 proposalId) public view exists(proposalId) returns (Func,uint256[] memory,string memory,bytes memory) {
        Proposal storage p = proposals[proposalId];
        return (p.callfunction,p.pools,p.signature,p.calldatas);
    }
    
    function state(uint256 proposalId) public view returns (ProposalState) {
        
        if(proposalId<proposals.length){
            Proposal storage proposal = proposals[proposalId];
            
            if (proposal.deadline > block.timestamp) {
                return ProposalState.Active;
            }
            
            if((proposal.YES+proposal.NO)>=QUORUM_VOTES && proposal.YES>proposal.NO){

                if (proposal.executed) {
                    return ProposalState.Executed;
                }

                if(proposal.readyToExecutionTime>block.timestamp){
                    return ProposalState.Succeeded;
                }

                if (proposal.cancellationTime > block.timestamp) {
                    return ProposalState.ExecutionWaiting;
                }

                return ProposalState.Cancelled;
            }
            
            return ProposalState.Failed;
        }
        
        return ProposalState.Unknown;
    }

    function uint2str(uint256 _i)
        internal
        pure
        returns (string memory _uintAsString)
    {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len - 1;
        while (_i != 0) {
            bstr[k--] = bytes1(uint8(48 + (_i % 10)));
            _i /= 10;
        }
        return string(bstr);
    }

}