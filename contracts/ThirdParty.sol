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
    // Весь этот Third party контракт сделан для того, чтобы показать вам как вызывать responsible функцию.
    // Тут должно быть все понятно, просто вызываем функцию и передаем callback - просто ID функции которую вызвать
    tvm.accept();
    ITokenRootContract(_root_contract).deployEmptyWallet{
        value: _send_evers,
        callback: onGetDeployed
    }(_wallet_public_key, _deploy_evers);
  }

  function onGetDeployed(
    address _address
  ) public {
    // Колбек который вызываем Root в ответ на deployEmptyWallet.
    // Тут нет никакой проверки встроенной под капотом, что эта функция и правда вызывается в ответ на ваш запрос.
    // То есть вам нужно самому проверять что вы и правда делали этот запрос. Например записать адрес root
    // с которым вы взаимодействовали и проверить что сообщение от него аля require(msg.sender == root_address)

    // Забавный факт, когда мы получили ответ тут, это еще не значит что кошелек задеплоен и мы можем
    // к нему обращатся. Это значит что Root контракт создал исходящее сообщение с деплоем кошелька.
    // мы можем получить это сообщение раньше чем кошелек будет задеплоен ( сообщение в пути ).
    // И даже если мы отсюда попробуем вызвать какой то метод кошелька, наш запрос может дойти раньше
    // чем кошелек будет задеплоен, ведь гарантии очередности работают только для сообщений отправленных
    // из контракта A в контракт B. Чтобы прямо отсюда начинать взаимодействовать с кошельком надо придумывать
    // более сложные цепочки. Например чтобы ROOT после отправки сообщения деплоя еще дергал какую то
    // responsible функцию у кошелька, и только после ответа ему, отправлял ответ нам.
    lastDeployedWallet = _address;
  }
}

