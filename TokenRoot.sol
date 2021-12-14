pragma ton-solidity >= 0.51.0;
pragma AbiHeader expire;
pragma AbiHeader pubkey;

import "./TokenWallet.sol";


interface ITokenRootContract {
    function deployEmptyWallet(
        uint256 _wallet_public_key,
        uint128 _deploy_evers,
        address _gas_back_address
    ) external responsible returns(address);

    function mint(
        address to,
        uint128 tokens
    ) external;

    function increment() external;

    function getWalletCode() external returns (TvmCell);
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
    uint256 public bounce;

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
        // С помощью этой функции можно задеплоить контракт кошелька.

        // stateInit - сообщение деплоя контракта, в нем мы устанавливаем код контракт и значение static пермененных.
        // По сути hash(stateInit) это адрес контракта. Адрес контракта зависит от кода и начальных переменных.
        // то есть мы можем посчитать адрес контракта просто зная его код и начальные переменные
        // ( не те что в коструктор передаются )
        TvmCell stateInit = tvm.buildStateInit({
            //Указываем интерфейс контракта, чтобы солидити правильно упаковал varInit в TvmCell.
            contr: TokenWalletContract,
            varInit: {
                //значения static переменных
                root_address: address(this),
                wallet_code: wallet_code
            },
            // pubkey - это то, что будет возвращать tvm.pubkey(). По сути это просто еще одна статик переменная,
            // просто скрытая, и к tvm оно не имеет никакого отношения.
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
        uint128 _deploy_evers,
        address _gas_back_address
    ) override external responsible returns (address) {
        // С помощью этой функции другой контракт может задеплоить пустой кошелек.
        // Мы нигде не вызваем tvm.accept() так что все исходящии сообщения и газ будут оплачены
        // Из денег которые прикрепленны к сообщению, а не со счета контракта.

        require(_wallet_public_key != 0, TokenRootContractErrors.error_deploy_wallet_pubkey_not_set);
        require(_deploy_evers > 0, TokenRootContractErrors.error_deploy_ever_to_small);

        //Этой функцией мы
        //tvm.rawReserve(address(this).balance - msg.value, 0);
        return deployWallet(_wallet_public_key, _deploy_evers);
    }

    //минтим токены
    function mint(
        address to,
        uint128 tokens
    ) override external onlyOwner {
        // Этот метод вызывается внешним сообщением, тут мы вставили небольшую защиту от дурака.
        // так как мы будем оплачивать выполнение транзакции со счета контрата, то мы вставим проверку
        // что на счету контракта evers больше чем на момент деплоя. Чтобы избежать ситуации когда
        // на счету контракта не останется денег и он будет удален из сети так как ему нечем платить
        // за свое хранение в сети.
        require(address(this).balance > start_gas_balance, TokenRootContractErrors.error_insufficient_evers_on_contract_balance);

        // Мы соглашаемся оплатить транзакцию со счета контракта.
        tvm.accept();

        // Посылаем сообщение с вызовом функции accept контракту по указанному адресу.
        // К сообщению будет прикрепленно с адреса контракта 0.01 EVER (по умолчанию, если не указанно иное)
        ITokenWalletContract(to).accept(tokens);

        total_supply += tokens;
    }

    //минтим токены
    function increment() override external onlyOwner {
        tvm.accept();
        bounce++;
    }

    onBounce(TvmSlice slice) external {
        tvm.accept();
        bounce++;
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
        // Так что не надо делать никаких доп проверок что мы правда отправляли такое сообщение, а не какой то
        // злоумышленник хочет убавить тотал суплай.

        uint32 functionId = slice.decode(uint32);
        if (functionId == tvm.functionId(ITokenWalletContract.accept)) {
            uint128 latest_bounced_tokens = slice.decode(uint128);
            total_supply -= latest_bounced_tokens;
        }
    }

    function getWalletCode() override external returns(TvmCell) {
        return wallet_code;
    }
}

