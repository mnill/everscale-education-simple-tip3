pragma ton-solidity >= 0.53.0;
pragma AbiHeader expire;
pragma AbiHeader pubkey;

import "./TokenWallet.sol";


interface ITokenRootContract {
  function deployEmptyWallet(
    uint256 _wallet_public_key,
    uint128 _deploy_evers
  ) external responsible returns(address);

  function mint(
    address to,
    uint128 tokens
  ) external;

  function deployWalletWithBalance(
    uint256 _wallet_public_key,
    uint128 _deploy_evers,
    uint128 _tokens
  ) external returns ( address );
}

library TokenRootContractErrors {
  uint8 constant error_tvm_pubkey_not_set = 100;
  uint8 constant error_message_sender_is_not_my_owner = 101;
  uint8 constant error_deploy_ever_to_small = 102;
  uint8 constant error_insufficient_evers_on_contract_balance = 103;
  uint8 constant error_deploy_wallet_pubkey_not_set = 104;
}

contract TokenRootContract is ITokenRootContract {
  uint128 public start_gas_balance;
  uint128 public total_supply;

  // The code of the wallet contract is needed to deploy the wallet contract.
  // In the tvm the code is also stored in the TvmCell and it can be sent via messages.
  TvmCell static wallet_code;

  constructor() public {
    require(tvm.pubkey() != 0, TokenRootContractErrors.error_tvm_pubkey_not_set);
    tvm.accept();

    start_gas_balance = address(this).balance;
  }

  modifier onlyOwner() {
    require(tvm.pubkey() != 0 && tvm.pubkey() == msg.pubkey(), TokenRootContractErrors.error_message_sender_is_not_my_owner);
    _;
  }


  function deployWallet(
    uint256 _wallet_public_key,
    uint128 _deploy_evers
  ) private returns (address) {

    // stateInit - the message deploying the contract where we establish the code the contract and its static variables.
    // Essentially the hash(stateInit) is the contract address.
    // The contract address depends on the code and the intial variables.
    // So we can determine the contract address just by knowing its code
    // and initial variables (not those that are sent in the constructor).

    //Pay attention on what the wallet address depend on.
    //He is depend on root_address(this), wallet code and the owner's public key.

    TvmCell stateInit = tvm.buildStateInit({
        //We specify the contract interface so Solidity correctly packs varInit into TvmCell (BoC, see the previous chapter).
        contr: TokenWalletContract,
        varInit: {
            //значения static переменных
            root_address: address(this)
        },
        // pubkey - this will return the tvm.pubkey().
        // Essentially this is just another static variable that is introduced separately.
        pubkey: _wallet_public_key,
        code: wallet_code
    });

    // Here we create one message that will deploy the contract
    // (if the contract is already deployed , nothing will happen)
    // also this message will call that the constructor
    // () without arguments .
    address wallet = new TokenWalletContract{
        stateInit: stateInit,
        value: _deploy_evers, // the amount of native coins we are sending with the message
        wid: address(this).wid,
        flag: 0 // this flag denotes that we are paying for the creation of the message from the value we are sending with the contract.
    }();

    return wallet;
  }

  function deployEmptyWallet(
    uint256 _wallet_public_key,
    uint128 _deploy_evers
  ) override external responsible returns (address) {
    // With the help of this function, any other contract can deploy a wallet.

    require(_wallet_public_key != 0, TokenRootContractErrors.error_deploy_wallet_pubkey_not_set);
    require(_deploy_evers >= 0.05 ton, TokenRootContractErrors.error_deploy_ever_to_small);


    // This function reserves money on the contract account equal to the balance
    // of the contract at the moment when the transaction is started. In order not to allow the message
    // to spend money from the contract balance.
    // This is a complex moment and we will look at the details in the Additional Materials section
    // in "Carefully working with value"
    tvm.rawReserve(0, 4);

    address deployed_contract = deployWallet(_wallet_public_key, _deploy_evers);


    // Our function is labelled responsible, this means that it is possible to be called
    // with a smart contract and it will create a message with a callback.
    // The compiler will simply add a field to the function arguments
    // answerID, which shows the ID of the function that will be called
    // by sending a message back to the msg.sender address

    // Why do we use 128 here and not 64 - because from this transaction
    // we have two external calls, one is to deploy the wallet contract,
    // and the second is the answer: responsible.
    // You can find more details about this in the "Carefully working with value" section.

    return { value: 0, bounce: false, flag: 128 } deployed_contract;
  }

  // minting tokens
  function mint(
    address _to,
    uint128 _tokens
  ) override external onlyOwner {

    // This method is called by an external message,
    // here we have put some fool-proof protection in place.
    // This way we will pay for the fulfillment of the transaction from the contract account,
    // then we check that there are more EVERs on the contract account
    // then there were when it was deployed. This prevents a situation in which
    // there are no funds on the contract account and it gets deleted from the network
    // or frozen because it conannot pay for its storage.

    require(address(this).balance > start_gas_balance, TokenRootContractErrors.error_insufficient_evers_on_contract_balance);
    require(_tokens > 0);

    // We agree to pay for the transaction from the contract account.
    tvm.accept();

    // We send a message with a call of the accept function to the contract at the indicated address.
    // To the message a sum of 0.01 EVER from the account address will be attached
    // (this will be done automatically, unless otherwise indicated)
    ITokenWalletContract(_to).accept(_tokens);

    total_supply += _tokens;
  }

  function deployWalletWithBalance(
    uint256 _wallet_public_key,
    uint128 _deploy_evers,
    uint128 _tokens
  ) override external onlyOwner returns ( address ) {

    require(_wallet_public_key != 0, TokenRootContractErrors.error_deploy_wallet_pubkey_not_set);
    require(_deploy_evers >= 0.1 ton, TokenRootContractErrors.error_deploy_ever_to_small);

    // Similar fool-proof mechanism to the one above,
    // but here we also add _deploy_evers
    require(address(this).balance > start_gas_balance + _deploy_evers, TokenRootContractErrors.error_insufficient_evers_on_contract_balance);

    require(_tokens > 0);

    tvm.accept();

    // we deploy the wallet
    address deployed_contract = deployWallet(_wallet_public_key, _deploy_evers);


    // we send tokens to the wallet in the following message.
    ITokenWalletContract(deployed_contract).accept(_tokens);

    total_supply += _tokens;

    return deployed_contract;
  }

  onBounce(TvmSlice slice) external {
    tvm.accept();

    // This is a utility function for handling errors. You probably noticed that in
    // the mint function we did not check if the contract was deployed at the destination
    // address. By default, when calling another contract, the message
    // will have a flag bounce value of: true. If when the message is being processed by the contract
    // an exception occurs at the destination address or the contract
    // does not exist, then automatically (if there is't enough money
    // attached to the message) a return message is sent with a call to
    // the onBounce function and with arguments.
    // Here there is a stupid limitation requiring that arguments fit
    // into 224 bits (WTF) but hopefully this is changed.


    // We use this function to show you how to handle a situation
    // when tokens are minted to a non-existing address and to subtract from the total_supply
    // as the tokens were not printed.

    // This function cannot just be called, the message must have a special bounced: true flag,
    // which cannot be added manually when sending. There is no need to do additional checks that we actually sent
    // the message. So bad actor can not subtract from the total supply by sending unexpected bounced message.

    uint32 functionId = slice.decode(uint32);
    if (functionId == tvm.functionId(ITokenWalletContract.accept)) {
        uint128 latest_bounced_tokens = slice.decode(uint128);
        total_supply -= latest_bounced_tokens;
    }
  }
}

