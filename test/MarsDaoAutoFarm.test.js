const { expectRevert, time,BN,ether} = require('@openzeppelin/test-helpers');
const { ethers, network } = require('hardhat');
const { array } = require('yargs');
const MarsAutoFarm = artifacts.require('MarsAutoFarm');
const StratX= artifacts.require('StratX');
const BStratX= artifacts.require('BStratX');
const ForceSend = artifacts.require('ForceSend');
const IERC20= artifacts.require('IERC20');

//const { DONOR_ADDRESS,B_DONOR_ADDRESS} = process.env;
const DONOR_ADDRESS='0x73feaa1eE314F8c655E354234017bE2193C9E24E';
const B_DONOR_ADDRESS='0xdbc1a13490deef9c3c12b44fe77b503c1b061739';
const LP='0x0eD7e52944161450477ee417DE9Cd3a859b14fD0';// (Pancake: CAKE_BNB)
const LPpid=251;
const BLP='0x5a36E9659F94F27e4526DDf6Dd8f0c3B3386D7F3';// (Biswap: ATOM_BNB)
const BLPpid=97;
const MARS_ADDRESS="0x4eC57B0156564DDdEa375F313927ec2DDc975D69";
const BUSD="0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56";
const CakeToken="0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82";
const BSWToken="0x965F527D9159dCe6288a2219DB51fc6Eef120dD1";

contract('MarsAutoFarm', ([alice, bob, carol, scot,developer]) => {


    before(async () => {
        this.mars=await IERC20.at(MARS_ADDRESS);
        this.marsAutoFarm = await MarsAutoFarm.new(MARS_ADDRESS, { from: alice });
        this.StratX = await StratX.new(alice,this.marsAutoFarm.address,MARS_ADDRESS,developer,developer, { from: alice });
        this.BStratX = await BStratX.new(alice,this.marsAutoFarm.address,MARS_ADDRESS,developer,developer, { from: alice });

        const forceSend = await ForceSend.new();
        await forceSend.go(DONOR_ADDRESS, { value: web3.utils.toWei("1", "ether") });
        this.lp = await IERC20.at(LP);
        await network.provider.request({
            method: 'hardhat_impersonateAccount',
            params: [DONOR_ADDRESS],
        });

        await this.lp.transfer(bob,web3.utils.toWei("1000", "ether"),{ from: DONOR_ADDRESS });
        await this.lp.transfer(carol,web3.utils.toWei("1000", "ether"),{ from: DONOR_ADDRESS });
        await this.lp.transfer(scot,web3.utils.toWei("1000", "ether"),{ from: DONOR_ADDRESS });
        await this.lp.approve(this.StratX.address, web3.utils.toWei("1000", "ether"), { from: bob });
        await this.lp.approve(this.StratX.address, web3.utils.toWei("1000", "ether"), { from: carol });
        await this.lp.approve(this.StratX.address, web3.utils.toWei("1000", "ether"), { from: scot });

        const BforceSend = await ForceSend.new();
        await BforceSend.go(B_DONOR_ADDRESS, { value: web3.utils.toWei("1", "ether") });
        this.blp = await IERC20.at(BLP);

        await network.provider.request({
            method: 'hardhat_impersonateAccount',
            params: [B_DONOR_ADDRESS],
        });

        await this.blp.transfer(bob,web3.utils.toWei("1000", "ether"),{ from: B_DONOR_ADDRESS });
        await this.blp.transfer(carol,web3.utils.toWei("1000", "ether"),{ from: B_DONOR_ADDRESS });
        await this.blp.transfer(scot,web3.utils.toWei("1000", "ether"),{ from: B_DONOR_ADDRESS });       
        await this.blp.approve(this.BStratX.address, web3.utils.toWei("1000", "ether"), { from: bob });
        await this.blp.approve(this.BStratX.address, web3.utils.toWei("1000", "ether"), { from: carol });
        await this.blp.approve(this.BStratX.address, web3.utils.toWei("1000", "ether"), { from: scot });

    });

    it('add pools & setGov & setRouter', async () => {
        await this.marsAutoFarm.add(this.StratX.address,LP,LPpid,{ from: alice });
        await this.marsAutoFarm.add(this.BStratX.address,BLP,BLPpid,{ from: alice });
        await this.StratX.setGov(alice,{ from: alice });
        await this.BStratX.setGov(alice,{ from: alice });
        /*
        await this.StratX.setRouter0([
            [
                "0x0e09fabb73bd3ade0a17ecc321fd13a19e81ce82",
                "0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c",
                "0x20de22029ab63cf9a7cf5feb2b737ca1ee4c82a6"
            ],
            [
                "0x0e09fabb73bd3ade0a17ecc321fd13a19e81ce82",
                "0x20de22029ab63cf9a7cf5feb2b737ca1ee4c82a6"
            ]
        ],{ from: alice });*/
    });

    it('deposit & harvest', async () => {
        await this.marsAutoFarm.deposit(0,web3.utils.toWei("1000", "ether"),{ from: bob });
        await this.marsAutoFarm.deposit(1,web3.utils.toWei("1000", "ether"),{ from: bob });
        for (let i = 0; i < 100; ++i) {
            await time.advanceBlock();
        }
        await this.marsAutoFarm.deposit(0,web3.utils.toWei("1000", "ether"),{ from: carol });
        await this.marsAutoFarm.deposit(1,web3.utils.toWei("1000", "ether"),{ from: carol });
        for (let i = 0; i < 100; ++i) {
            await time.advanceBlock();
        }
        await this.marsAutoFarm.deposit(0,web3.utils.toWei("1000", "ether"),{ from: scot });
        await this.marsAutoFarm.deposit(1,web3.utils.toWei("1000", "ether"),{ from: scot });
        for (let i = 0; i < 100; ++i) {
            await time.advanceBlock();
        }
        await this.marsAutoFarm.deposit(0,0,{ from: scot });
        await this.marsAutoFarm.deposit(1,0,{ from: scot });
    });

    it('users info', async () => {
        
        console.log("bob : stakedWantTokens pool 0: ",
        web3.utils.fromWei(await this.marsAutoFarm.stakedWantTokens(0,bob)),
        " pool 1: ",web3.utils.fromWei(await this.marsAutoFarm.stakedWantTokens(1,bob)));
        console.log("carol : stakedWantTokens pool 0: ",
        web3.utils.fromWei(await this.marsAutoFarm.stakedWantTokens(0,carol)),
        " pool 1: ",web3.utils.fromWei(await this.marsAutoFarm.stakedWantTokens(1,carol)));
        console.log("scot : stakedWantTokens pool 0: ",
        web3.utils.fromWei(await this.marsAutoFarm.stakedWantTokens(0,scot)),
        " pool 1: ",web3.utils.fromWei(await this.marsAutoFarm.stakedWantTokens(1,scot)));

        console.log("bob : pendingReward pool 0: ",
        web3.utils.fromWei(await this.marsAutoFarm.pendingReward(0,bob)),
        " pool 1: ",web3.utils.fromWei(await this.marsAutoFarm.pendingReward(1,bob)));
        console.log("carol : pendingReward pool 0: ",
        web3.utils.fromWei(await this.marsAutoFarm.pendingReward(0,carol)),
        " pool 1: ",web3.utils.fromWei(await this.marsAutoFarm.pendingReward(1,carol)));
        console.log("scot : pendingReward pool 0: ",
        web3.utils.fromWei(await this.marsAutoFarm.pendingReward(0,scot)),
        " pool 1: ",web3.utils.fromWei(await this.marsAutoFarm.pendingReward(1,scot)));

    });

    it('withdraw', async () => {
        await this.marsAutoFarm.withdraw(0,web3.utils.toWei("100", "ether"),{ from: bob });
        await this.marsAutoFarm.withdraw(1,web3.utils.toWei("100", "ether"),{ from: bob });
        await this.marsAutoFarm.withdraw(0,web3.utils.toWei("100", "ether"),{ from: carol });
        await this.marsAutoFarm.withdraw(1,web3.utils.toWei("100", "ether"),{ from: carol });
        await this.marsAutoFarm.withdraw(0,web3.utils.toWei("100", "ether"),{ from: scot });
        await this.marsAutoFarm.withdraw(1,web3.utils.toWei("100", "ether"),{ from: scot });
    });

    it('withdraw all', async () => {
        await this.marsAutoFarm.withdraw(0,web3.utils.toWei("1000", "ether"),{ from: bob });
        await this.marsAutoFarm.withdraw(1,web3.utils.toWei("1000", "ether"),{ from: bob });
        await this.marsAutoFarm.withdraw(0,web3.utils.toWei("1000", "ether"),{ from: carol });
        await this.marsAutoFarm.withdraw(1,web3.utils.toWei("1000", "ether"),{ from: carol });
        await this.marsAutoFarm.withdraw(0,web3.utils.toWei("1000", "ether"),{ from: scot });
        await this.marsAutoFarm.withdraw(1,web3.utils.toWei("1000", "ether"),{ from: scot });
    });


});