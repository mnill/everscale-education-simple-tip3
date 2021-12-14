pragma ton-solidity >= 0.51.0;
pragma AbiHeader expire;
pragma AbiHeader pubkey;


interface ITokenWalletContract {
    function getBalance() external view responsible returns (uint128);
    function accept(uint128 tokens) external;
}

library TokenWalletContractErrors {
    uint8 constant error_tvm_pubkey_not_set = 100;
    uint8 constant error_message_sender_is_not_my_owner = 104;
}

contract TokenWalletContract is ITokenWalletContract {

    address static root_address;
    TvmCell static wallet_code;
    uint128 public balance;

    constructor() public {
        require(tvm.pubkey() != 0, TokenWalletContractErrors.error_tvm_pubkey_not_set);
        tvm.accept();
    }

    modifier onlyRoot() {
        require(root_address == msg.sender, TokenWalletContractErrors.error_message_sender_is_not_my_owner);
        _;
    }

    function getBalance() override external view responsible returns (uint128) {
        return { value: 0, bounce: false, flag: 64 } balance;
    }

    function accept(uint128 tokens) override external onlyRoot {
        //accept minted tokens from root contract
        tvm.accept();
        balance += tokens;
    }
}

