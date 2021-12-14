pragma ton-solidity >= 0.51.0;
pragma AbiHeader expire;
pragma AbiHeader pubkey;

import "./TokenRoot.sol";

contract TokenWalletDeployerContract  {

    uint128 public bounced;
    address public lastDeployedWallet;

    constructor() public {
        require(tvm.pubkey() != 0, 2);
        tvm.accept();
    }

    modifier onlyOwner() {
        require(tvm.pubkey() == msg.pubkey(), 3);
        _;
    }

    function onGetDeployed(
        address _address
    ) public {
        lastDeployedWallet = _address;
    }

    function deployWallet(
        address _root_contract,
        uint256 _wallet_public_key,
        uint128 _send_evers,
        uint128 _deploy_evers
    ) external onlyOwner  {
        tvm.accept();
        ITokenRootContract(_root_contract).deployEmptyWallet{value:_send_evers, callback: onGetDeployed}(_wallet_public_key, _deploy_evers, address(0));
    }

    onBounce(TvmSlice slice) external {
        bounced++;
    }
}

