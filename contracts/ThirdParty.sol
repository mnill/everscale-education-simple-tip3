pragma ton-solidity >= 0.53.0;
pragma AbiHeader expire;
pragma AbiHeader pubkey;

import "./TokenRoot.sol";

contract ThirdPartyContract  {

  address public lastDeployedWallet;

  constructor() public {
    require(tvm.pubkey() != 0, 2);
    tvm.accept();
  }

  modifier onlyOwner() {
    require(tvm.pubkey() == msg.pubkey(), 3);
    _;
  }

  function deployWallet(
    address _root_contract,
    uint256 _wallet_public_key,
    uint128 _send_evers,
    uint128 _deploy_evers
  ) external onlyOwner {
    // This entire Third party contract was done to show you how to call the responsible function.
    // Everything is simple here, we just call the function and transfer callback - this is the ID function to call
    tvm.accept();
    ITokenRootContract(_root_contract).deployEmptyWallet{
        value: _send_evers,
        callback: onGetDeployed
    }(_wallet_public_key, _deploy_evers);
  }

  function onGetDeployed(
    address _address
  ) public {
    // The callback we call Root in answer to deployEmptyWallet.
    // There is no built-in check to make sure this function
    // is truly being called in answer to your call.

    // So you have to check is you really made this call.
    // For example, by store the address of root that you are interacting with
    // and checking that the response is something like require(msg.sender == root_address)

    // Fun fact, when we get an answer here, that does not mean
    // that the wallet is deployed. This means that the Root
    // contract created an outgoing deploy message.
    // We can receive this message before the wallet is deployed
    // (the message is en route).
    // In principle, the LT (see additional information) guarantees us,
    // that if we want to call a wallet method from here,
    // our message will not arrive earlier than the wallet is deployed.
    lastDeployedWallet = _address;
  }
}
