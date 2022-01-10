pragma ton-solidity >= 0.53.0;
pragma AbiHeader expire;
pragma AbiHeader pubkey;


interface ITokenWalletContract {
  function getBalance() external view responsible returns (uint128);
  function accept(uint128 _tokens) external;
  function transferToRecipient(uint256 _recipient_public_key, uint128 _tokens, uint128 _deploy_evers, uint128 _transfer_evers) external;
  function internalTransfer(uint128 _tokens, uint256 _sender_public_key, address _send_gas_to) external;
}

library TokenWalletContractErrors {
  uint8 constant error_tvm_pubkey_not_set = 100;
  uint8 constant error_message_sender_is_not_my_owner = 101;
  uint8 constant error_message_transfer_not_enough_balance = 102;
  uint8 constant error_message_transfer_wrong_recipient = 103;
  uint8 constant error_message_transfer_low_message_value = 104;
  uint8 constant error_message_internal_transfer_bad_sender = 105;
  uint8 constant error_message_transfer_balance_too_low = 106;
}

contract TokenWalletContract is ITokenWalletContract {

  address static root_address;
  TvmCell static wallet_code;
  uint128 public balance;

  constructor() public {
    //Проверяем что паб кей установлен
    require(tvm.pubkey() != 0, TokenWalletContractErrors.error_tvm_pubkey_not_set);
    tvm.accept();
  }

  modifier onlyRoot() {
    require(root_address == msg.sender, TokenWalletContractErrors.error_message_sender_is_not_my_owner);
    _;
  }

  modifier onlyOwner() {
    require(tvm.pubkey() == msg.pubkey(), TokenWalletContractErrors.error_message_sender_is_not_my_owner);
    _;
  }

  function accept(uint128 _tokens) override external onlyRoot {
    //Просто принимаем любое количество токенов которые нам захотел перевести Root контракт
    tvm.accept();
    balance += _tokens;
  }

  function getBalance() override external view responsible returns (uint128) {
    // Любой контракт может узнать баланс нашего кошелька
    return { value: 0, bounce: false, flag: 64 } balance;
  }

  function transferToRecipient(
    uint256 _recipient_public_key,
    uint128 _tokens,
    uint128 _deploy_evers,
    uint128 _transfer_evers
  ) override external onlyOwner {
    // Этим методом мы можем перевести токены на любой другой аналогичный кошелек напрямую.
    // При этом мы можем указать, что мы хотим сначало задеплоить этот кошелек.

    require(_tokens > 0);
    require(_tokens <= balance, TokenWalletContractErrors.error_message_transfer_not_enough_balance);
    require(_recipient_public_key != 0, TokenWalletContractErrors.error_message_transfer_wrong_recipient);
    // Cебе нельзя отправить :-)
    require(_recipient_public_key != tvm.pubkey());

    require(address(this).balance > _deploy_evers + _transfer_evers, TokenWalletContractErrors.error_message_transfer_balance_too_low);

    // Проверка что мы хотим приложить к транзакции перевода не меньше чем 0.01 ever.
    // Если мы приложим не достаточно, то транзакция упадет, и onBounce не сработает, потому что не будет на это денег
    // Это значение эмпирическое, в нашей сети газ не плавает от спроса, а повышения стоимости газа не ожидается
    // только понижение.
    require(_transfer_evers >= 0.01 ever, TokenWalletContractErrors.error_message_transfer_low_message_value);

    tvm.accept();

    // Считаем адрес адрес контракта кошелька назначения.
    TvmCell stateInit = tvm.buildStateInit({
        contr: TokenWalletContract,
        varInit: {
            root_address: root_address,
            wallet_code: wallet_code
        },
        pubkey: _recipient_public_key,
        code: wallet_code
    });

    address to;
    if (_deploy_evers > 0) {
        // Деплоим кошелек, тут вам уже все знакомо.
        to = new TokenWalletContract{
            stateInit: stateInit,
            value: _deploy_evers,
            wid: address(this).wid,
            flag: 1 // значит что мы оплатим факт создания исходящего сообщения не с _deploy_evers а с баланса кошелька
        }();
    } else {
        // Просто считаем адрес кошелька назначения.
        to = address(tvm.hash(stateInit));
    }

    balance -= _tokens;

    // Тут мы отправляем сообщение с вызовом функции internalTransfer, описанной ниже.
    // Так как у нас в бч есть гарантия по очередности доставки сообщений, то даже если мы
    // только что отправили сообщения деплоя контракта выше, мы можем быть уверены что он задеплоется
    // перед тем как будет вызван internalTransfer
    // так же мы выставляем bounce: true, чтобы в случае ошибок (контракт не был задеплоен и мы его не деплоили например)
    // вызовется функция onBounce и мы вернем себе токены.
    ITokenWalletContract(to).internalTransfer{ value: _transfer_evers, flag: 1, bounce: true } (
        _tokens,
        tvm.pubkey(),
        address(this)
    );
  }

  function internalTransfer(
    uint128 _tokens,
    uint256 _sender_public_key,
    address _send_gas_to
  ) override external {
    // Функция приема перевода. И за счет чего она работает это очень красивая концепция.
    // Мы можем токены переводить на прямую с кошелька на кошелек благодаря тому, что в EVER
    // Адрес контракта это однозначно вычислимое значение. Мы можем проверить что контракт который нас
    // вызываем это точно такой же контракт как мы, у которого точно такой же Root и Код.
    // То есть мы точно знаем что если он нас вызвал, то он эти токены не напечатал, и получил от рута.

    // Считаем какой был бы адрес у контракта который нас вызвал с _sender_public_key
    address expectedSenderAddress = getExpectedAddress(_sender_public_key);

    // Проверяем что нас вызвал правильный адрес.
    require(msg.sender == expectedSenderAddress, TokenWalletContractErrors.error_message_internal_transfer_bad_sender);

    // Увеличиваем баланс.
    balance += _tokens;

    if (_send_gas_to.value != 0) {
        // Отправляем весь неизрасходованный value что был в сообщении обратно контракту.
        // Воообщем можно было бы отправить и на msg.sender, но тут я хочу показать что можно передавать
        // по длинной цепочке адрес куда в итоге надо вернуть сдачу, если у нас длинное взаимодействие.
        _send_gas_to.transfer({ value: 0, flag: 64 });
    }
  }

  function getExpectedAddress(
    uint256 _wallet_public_key
  ) private inline view returns ( address ) {
    TvmCell stateInit = tvm.buildStateInit({
        contr: TokenWalletContract,
        varInit: {
            root_address: root_address,
            wallet_code: wallet_code
        },
        pubkey: _wallet_public_key,
        code: wallet_code
    });
    return address(tvm.hash(stateInit));
  }

  onBounce(TvmSlice body) external {
    // Служебная функция, сюда сообщения могут попасть только если при обработки сообщения которое послал
    // этот контракт произошла ошибка и там хватило денег на создание onBounce сообщения.
    // никаких доп проверок что вы и правда посылали это сообщение тут не надо, руками сюда ничего не послать.
    tvm.accept();
    uint32 functionId = body.decode(uint32);
    if (functionId == tvm.functionId(ITokenWalletContract.internalTransfer)) {
        // Наш трансфер не дошел, возвращаем деньги на баланс.
        uint128 tokens = body.decode(uint128);
        balance += tokens;
    }
  }
}
