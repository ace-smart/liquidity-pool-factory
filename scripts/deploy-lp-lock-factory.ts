import * as hre from 'hardhat';
import { LiquidityPoolFactory } from '../types/ethers-contracts/LiquidityPoolFactory';
import { LiquidityPoolFactory__factory } from '../types/ethers-contracts/factories/LiquidityPoolFactory__factory';
import { LiquidityStakingV2 } from '../types/ethers-contracts/LiquidityStakingV2';
import { LiquidityStakingV2__factory } from '../types/ethers-contracts/factories/LiquidityStakingV2__factory';
import address from '../address';

require("dotenv").config();

const { ethers } = hre;

const sleep = (milliseconds, msg='') => {
    console.log(`Wait ${milliseconds} ms... (${msg})`);
    const date = Date.now();
    let currentDate = null;
    do {
      currentDate = Date.now();
    } while (currentDate - date < milliseconds);
}

const toEther = (val) => {
    return ethers.utils.formatEther(val);
}

const parseEther = (val, unit = 18) => {
    return ethers.utils.parseUnits(val, unit);
}

async function deploy() {
    console.log((new Date()).toLocaleString());
    
    const deployer = (await ethers.getSigners()).filter(account => account.address === "0x89352214a56bA80547A2842bbE21AEdD315722Ca")[0];
    
    console.log(
        "Deploying contracts with the account:",
        deployer.address
    );

    const beforeBalance = await deployer.getBalance();
    console.log("Account balance:", (await deployer.getBalance()).toString());

    const mainnet = process.env.NETWORK == "mainnet" ? true : false;
    const url = mainnet ? process.env.URL_MAIN : process.env.URL_TEST;
    const curBlock = await ethers.getDefaultProvider(url).getBlockNumber();
    const poolFactoryAddress = mainnet ? address.mainnet.lpLocker.factory: address.testnet.lpLocker.factory;

    const factory: LiquidityPoolFactory__factory = new LiquidityPoolFactory__factory(deployer);
    let poolFactory: LiquidityPoolFactory = factory.attach(poolFactoryAddress).connect(deployer);
    if ("redeploy" && true) {
        poolFactory = await factory.deploy();
    }
    console.log(`Deployed LiquidityPoolFactory... (${poolFactory.address})`);

    if (false) {
        const stakingFactory: LiquidityStakingV2__factory = new LiquidityStakingV2__factory(deployer);
        const staking: LiquidityStakingV2 = stakingFactory.attach("0x812Db49B5e44A079D128Fb636671b1E5A5422e81").connect(deployer);
        console.log("StartTime:", (await staking.startTime()).toString());
        console.log("EndTime:", (await staking.endTime()).toString());
    }

    const afterBalance = await deployer.getBalance();
    console.log(
        "Deployed cost:",
         (beforeBalance.sub(afterBalance)).toString()
    );
}

deploy()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    })