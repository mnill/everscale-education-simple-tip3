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

  // Код wallet контракта, нужен чтобы деплоить контракт кошелька.
  // В tvm код тоже хранится в TvmCell и его можно пересылать сообщениями.
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
    // stateInit - сообщение деплоя контракта, в нем мы устанавливаем код контракт и значение static пермененных.
    // По сути hash(stateInit) это адрес контракта. Адрес контракта зависит от кода и начальных переменных.
    // то есть мы можем посчитать адрес контракта просто зная его код и начальные переменные
    // ( не те что в коструктор передаются )

    // Обратите внимание, от чего зависит адрес wallet контракта.
    // От root_address(this), кода кошелька, и публичного ключа владельца.
    TvmCell stateInit = tvm.buildStateInit({
        //Указываем интерфейс контракта, чтобы солидити правильно упаковал varInit в TvmCell (BoC, смотри предыдущую главу).
        contr: TokenWalletContract,
        varInit: {
            //значения static переменных
            root_address: address(this)
        },
        // pubkey - это то, что будет возвращать tvm.pubkey(). По сути это просто еще одна статик переменная,
        // просто вынесенная отдельно.
        pubkey: _wallet_public_key,
        code: wallet_code
    });

    // Тут мы по сути создаем одно сообщение, которое несет в себе деплой контракта
    // (если контракт уже задеплоен, то ничего не произойдет)
    // и так же в этом сообщении указанно что надо вызвать конструтор - () без аргументов.
    address wallet = new TokenWalletContract{
        stateInit: stateInit,
        value: _deploy_evers, //сколько мы передаем с сообщением нативных коинов сети
        wid: address(this).wid,
        flag: 0 //этот флаг означает что мы оплатим создание сообщение из value которое передаем в контракт.
    }();

    return wallet;
  }

  function deployEmptyWallet(
    uint256 _wallet_public_key,
    uint128 _deploy_evers
  ) override external responsible returns (address) {
    // С помощью этой функции любой другой контракт может задеплоить пустой кошелек.

    require(_wallet_public_key != 0, TokenRootContractErrors.error_deploy_wallet_pubkey_not_set);
    require(_deploy_evers >= 0.05 ton, TokenRootContractErrors.error_deploy_ever_to_small);

    // Эта функция резервирует на счету контракта деньги, равные балансу контракта,
    // на момент начала транзакции. Что не позволит сообщению потратить деньги с баланса контракта.
    // Это сложный момент, он разобран в дополнениях в "Аккуратная работа с value"
    tvm.rawReserve(0, 4);

    address deployed_contract = deployWallet(_wallet_public_key, _deploy_evers);

    // Наша функция помечана как responsible, это означает что ее можно вызвать смарт контрактом и она создаст
    // сообщение с обратным вызовом, (колбек). По компилятор просто добавит в аргументы функции поле
    // answerID, которое указывает ID функции которую надо вызвать отправив сообщение обратно по адресу msg.sender

    // Почему мы используем тут 128 а не 64 - потому что у нас из этой транзакции два внешных вызова,
    // один это деплой контракта кошелька, а второй ответ responsible.
    // подробнее почему так читайте в дополнениях в "Аккуратная работа с value".
    return { value: 0, bounce: false, flag: 128 } deployed_contract;
  }

  //минтим токены
  function mint(
    address _to,
    uint128 _tokens
  ) override external onlyOwner {
    // Этот метод вызывается внешним сообщением, тут мы вставили небольшую защиту от дурака.
    // так как мы будем оплачивать выполнение транзакции со счета контрата, то мы вставим проверку
    // что на счету контракта evers больше чем на момент деплоя. Чтобы избежать ситуации когда
    // на счету контракта не останется денег и он будет удален из сети или заморожен так как ему нечем платить
    // за свое хранение в сети.
    require(address(this).balance > start_gas_balance, TokenRootContractErrors.error_insufficient_evers_on_contract_balance);
    require(_tokens > 0);

    // Мы соглашаемся оплатить транзакцию со счета контракта.
    tvm.accept();

    // Посылаем сообщение с вызовом функции accept контракту по указанному адресу.
    // К сообщению будет прикрепленно с адреса контракта 0.01 EVER (по умолчанию, если не указанно иное)
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

    //Аналогично функции выше, защита от дурака, только мы еще прибавляем _deploy_evers
    require(address(this).balance > start_gas_balance + _deploy_evers, TokenRootContractErrors.error_insufficient_evers_on_contract_balance);

    require(_tokens > 0);

    tvm.accept();

    // деплоим кошелек
    address deployed_contract = deployWallet(_wallet_public_key, _deploy_evers);

    // Посылаем сообщение с вызовом функции accept контракту по указанному адресу.
    // К сообщению будет прикрепленно с адреса контракта 0.01 EVER (по умолчанию, если не указанно иное)
    ITokenWalletContract(deployed_contract).accept(_tokens);

    total_supply += _tokens;

    return deployed_contract;
  }

  onBounce(TvmSlice slice) external {
    tvm.accept();
    // Эта служебная функция для обработки ошибок. Вы наверное заметили что в функции mint мы не проверяли
    // был ли задеплоен контракт по адресу назначения. По умолчанию при вызове другого контракта у сообщения
    // установлен флаг bounce: true. Если в ходе обработки сообщения контрактом по адресу назначения будет
    // выкинут ексепшен или контракта не существует, то автоматически(если на это хватит денег
    // прикрепленных к сообщению) создастся обратное сообщение с вызовом этой функции и аргументами.
    // При этом существует тупейшее ограничение, что аргументы должны влезать в 224 bits(WTF) надеюсь это починят.

    // Мы используем эту функцию чтобы показать вам как обработать ситуацию когда был произведен mint
    // на несуществующий адрес, и убавить total_supply так как токены не были напечатаны.

    // Эту функцию нельзя вызвать просто так, у сообщения должен быть проставлен специальный флаг bounced: true,
    // который нельзя поставить руками при отправке.
    // Так что не надо делать никаких доп проверок что мы и правда отправляли такое сообщение, а не какой то
    // злоумышленник хочет убавить тотал суплай.

    uint32 functionId = slice.decode(uint32);
    if (functionId == tvm.functionId(ITokenWalletContract.accept)) {
        uint128 latest_bounced_tokens = slice.decode(uint128);
        total_supply -= latest_bounced_tokens;
    }
  }
}

