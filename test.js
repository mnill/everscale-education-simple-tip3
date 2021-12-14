const { Account } = require("@tonclient/appkit");
const { TonClient, signerKeys } = require("@tonclient/core");
const { libNode } = require("@tonclient/lib-node");

TonClient.useBinaryLibrary(libNode);

const { TokenRootContract } = require("./TokenRootContract.js")
const { TokenWalletContract } = require("./TokenWalletContract.js")
const { TokenWalletDeployerContract } = require("./TokenWalletDeployerContract.js")

async function main(client) {
    try {
        const keys = await TonClient.default.crypto.generate_random_sign_keys();
        const rootContract = new Account(TokenRootContract, {
            signer: signerKeys(keys),
            client,
            initData: {
                wallet_code: TokenWalletContract.code
            }
        });

        const rootAddress = await rootContract.getAddress();

        await rootContract.deploy({useGiver: true});
        console.log(`root contract deployed at address: ${rootAddress}`);

        const walletDeployerContract = new Account(TokenWalletDeployerContract, {
            signer: signerKeys(keys),
            client,
        });
        await walletDeployerContract.deploy({useGiver: true});

        const deployerAddress = await walletDeployerContract.getAddress();
        console.log(`deployer contract deployed at address: ${deployerAddress}`);

        console.log('root balance before deploy    ', parseInt(await rootContract.getBalance(), 16));
        console.log('deployer balance before deploy', parseInt(await walletDeployerContract.getBalance(), 16));


        let response = await walletDeployerContract.run("deployWallet", {
            _root_contract: await rootContract.getAddress(),
            _wallet_public_key: `0x${keys.public}`,
            _send_evers:   5000000000,
            _deploy_evers: 9000000000
        });

        await sleep(1);
        response = await walletDeployerContract.runLocal('lastDeployedWallet', {});
        console.log("wallet contract deployed:", response.decoded.output.lastDeployedWallet)

        const walletContract = new Account(TokenWalletContract, {
            signer: signerKeys(keys),
            client,
            initData: {
                wallet_code: TokenWalletContract.code,
                root_address: rootAddress
            }
        });

        //Эта строчка нужна чтобы победить багу с кешированием баланса.
        response = await rootContract.run('increment', {});

        console.log('root balance    ', parseInt(await rootContract.getBalance(), 16));
        console.log('deployer balance', parseInt(await walletDeployerContract.getBalance(), 16));
        console.log('wallet balance  ', parseInt(await walletContract.getBalance(), 16));

    } catch (e) {
        console.log(e);
    }
    process.exit(0);
}

(async () => {
    const client = new TonClient({
        network: {
            // Local TON OS SE instance URL here
            endpoints: ["http://localhost"]
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


function sleep (seconds) {
    return new Promise(function (resolve, reject) {
        setTimeout(resolve, seconds * 1000)
    })
}

