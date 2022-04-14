const { Account } = require("@tonclient/appkit");
const { TonClient, signerKeys } = require("@tonclient/core");
const { libNode } = require("@tonclient/lib-node");

TonClient.useBinaryLibrary(libNode);

const { TokenRootContract } = require("./artifacts/TokenRootContract.js")
const { TokenWalletContract } = require("./artifacts/TokenWalletContract.js")
const { ThirdPartyContract } = require("./artifacts/ThirdPartyContract.js")


async function main(client) {
    try {
        let response;
        const root_owner_keys = await TonClient.default.crypto.generate_random_sign_keys();
        const user1_keys = await TonClient.default.crypto.generate_random_sign_keys();
        const user2_keys = await TonClient.default.crypto.generate_random_sign_keys();

        const giver = await Account.getGiverForClient(client);

        const rootContract = new Account(TokenRootContract, {
            signer: signerKeys(root_owner_keys),
            client,
            initData: {
                wallet_code: TokenWalletContract.code
            }
        });

        const rootAddress = await rootContract.getAddress();
        await rootContract.deploy({useGiver: true});
        console.log(`root contract deployed at address: ${rootAddress}`);

        try {
            await rootContract.run("deployWalletWithBalance", {
                _wallet_public_key: `0x${root_owner_keys.public}`,
                _deploy_evers:   50_000_000,
                _tokens: 1_000_000_000
            }, {});
            assert(false, "Never reached")
        } catch (e) {
            assert(e.data.local_error.data.exit_code === 102, "Call unsuccessful. Necessary to set _deploy_evers to more then 0.1 ton")
        }

        try {
            await rootContract.run("deployWalletWithBalance", {
                _wallet_public_key: `0x${root_owner_keys.public}`,
                _deploy_evers:  100_000_000,
                _tokens: 1_000_000_000
            });
            assert(false, "Never reached")
        } catch (e) {
            assert(e.data.local_error.data.exit_code === 103, "Call unsuccessful. Necessary to fulfill balance to pass address(this).balance > start_gas_balance + _deploy_evers check")
        }

        await giver.sendTo(rootAddress, 10_000_000_000);
        response = await rootContract.run("deployWalletWithBalance", {
            _wallet_public_key: `0x${root_owner_keys.public}`,
            _deploy_evers:  5_000_000_000,
            _tokens: 1_000_000_000
        });

        let deployedRootWalletAddress = response.decoded.output.value0;
        let rootWalletContract = await getWalletContractForKeysWithRoot(root_owner_keys, rootAddress, client);
        assert(await rootWalletContract.getAddress() === deployedRootWalletAddress, "Must have the same address deployed and calculated offchain");

        response = await rootWalletContract.runLocal("balance", {});
        assert(1_000_000_000 === parseInt(response.decoded.output.balance), "Balance must be 1_000_000_000");

        await rootContract.run("mint", {
            _to: deployedRootWalletAddress,
            _tokens:  1_000_000_000,
        });

        response = await rootWalletContract.runLocal("balance", {});
        assert(2_000_000_000 === parseInt(response.decoded.output.balance), "Balance must be 2_000_000_000");

        response = await rootContract.runLocal("total_supply", {});
        assert(2_000_000_000 === parseInt(response.decoded.output.total_supply), "Total supply must be 2_000_000_000");

        let user1WalletContract = await getWalletContractForKeysWithRoot(user1_keys, rootAddress, client);
        await rootContract.run("mint", {
            _to: await user1WalletContract.getAddress(),
            _tokens:  1_000_000_000,
        });

        //user1WalletContract not deployed yet, so mint must bounce and total supply back to 2_000_000
        assert(2_000_000_000 === parseInt(response.decoded.output.total_supply), "Total supply must be 2_000_000_000");

        await rootWalletContract.run("transferToRecipient", {
            _recipient_public_key: `0x${user1_keys.public}`,
            _tokens: 500_000_000,
            _deploy_evers: 0,
            _transfer_evers: 100_000_000
        });
        response = await rootWalletContract.runLocal("balance", {});
        //user1WalletContract not deployed yet, so mint must bounce and total supply back to 2_000_000
        assert(2_000_000_000 === parseInt(response.decoded.output.balance), "Balance must be 2_000_000_000");

        await rootWalletContract.run("transferToRecipient", {
            _recipient_public_key: `0x${user1_keys.public}`,
            _tokens: 500_000_000,
            _deploy_evers: 100_000_000,
            _transfer_evers: 100_000_000
        });

        response = await rootWalletContract.runLocal("balance", {});
        assert(1_500_000_000 === parseInt(response.decoded.output.balance), "Balance must be 1_500_000_000");

        response = await user1WalletContract.runLocal("balance", {});
        assert(500_000_000 === parseInt(response.decoded.output.balance), "Balance must be 500_000_000");

        const thirdPartyContract = new Account(ThirdPartyContract, {
            signer: signerKeys(user2_keys),
            client,
            initData: {}
        });
        const thirdPartyContractAddress = await thirdPartyContract.getAddress();
        await thirdPartyContract.deploy({useGiver: true});

        let user2WalletContract = await getWalletContractForKeysWithRoot(user2_keys, rootAddress, client);
        //Try to deplo
        await thirdPartyContract.run("deployWallet", {
            _root_contract: rootAddress,
            _wallet_public_key: `0x${user2_keys.public}`,
            _send_evers: 1_000_000_000,
            _deploy_evers: 2_000_000_000
        });
        // response = await user1WalletContract.runLocal("deployWallet", {});
        assert(undefined === await user2WalletContract.getBalance(), "Contract must not be deployed, _send_evers < _deploy_evers");
        ``
        await thirdPartyContract.run("deployWallet", {
            _root_contract: rootAddress,
            _wallet_public_key: `0x${user2_keys.public}`,
            _send_evers: 2_000_000_000,
            _deploy_evers: 1_000_000_000
        });
        assert(parseInt(await user2WalletContract.getBalance(), 16) > 800_000_000, "Contract must be deployed and have > 800_000_000 nano evers");

        response = await thirdPartyContract.runLocal("lastDeployedWallet", {});
        assert( await user2WalletContract.getAddress() === response.decoded.output.lastDeployedWallet, "Offchain calculated and onchain addresses must be equal");

        console.log('Tests successful')
    } catch (e) {
        console.error(e);
    }
}

(async () => {
    const client = new TonClient({
        network: {
            // Local TON OS SE instance URL here
            endpoints: [ "http://localhost" ]
        }
    });
    try {
        console.log("Hello localhost TON!");
        await main(client);
        process.exit(0);
    } catch (error) {
        if (error.code === 504) {
            console.error(`Network is inaccessible. You have to start TON OS SE using \`tondev se start\`.\n If you run SE on another port or ip, replace http://localhost endpoint with http://localhost:port or http://ip:port in index.js file.`);
        } else {
            console.error(error);
        }
    }
    client.close();
})();

function assert(condition, error) {
    if (!condition) {
        throw new Error(error);
    }
}

function getWalletContractForKeysWithRoot(keys, rootAddress, client) {
    return new Account(TokenWalletContract, {
        signer: signerKeys(keys),
        client,
        initData: {
            wallet_code: TokenWalletContract.code,
            root_address: rootAddress
        }
    });
}
