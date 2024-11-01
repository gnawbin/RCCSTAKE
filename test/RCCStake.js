// 导入 Chai 断言库的 expect 函数
const { expect } = require("chai");
// 导入 loadFixture 函数
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");


// 定义一个测试套件，用于测试 RCCStake 合约
describe("RCCStake contract", async function () {
    // 部署合约，并返回合约实例
    async function deployRCCStake() {
        // 获取 Calculator 合约的合约工厂
        const RCCStake = await ethers.getContractFactory("RCCStake");
        // 部署 Calculator 合约，获得合约实例 calculator
        const rccStake = await RCCStake.deploy();
        // 返回合约实例
        return { rccStake };
    };

    it("should return the correct total supply", async function () {
        // 部署合约，并返回合约实例
        const { rccStake } = await loadFixture(deployRCCStake);
        // 调用合约的 totalSupply 函数，获取总供应量
        const poolLength = await rccStake.poolLength();
        console.log(poolLength);
    })


}



);