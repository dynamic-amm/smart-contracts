const {artifacts, contract} = require('hardhat');
const Helper = require('./../helper');
const BN = web3.utils.BN;

const ExampleZapIn = artifacts.require('ExampleZapIn');
const DMMRouter = artifacts.require('DMMRouter02');
const DMMPool = artifacts.require('DMMPool');
const DMMFactory = artifacts.require('DMMFactory');
const WETH = artifacts.require('WETH9');
const TestToken = artifacts.require('TestToken');

contract('ExampleZapIn', accounts => {
  it('zap in', async () => {
    let token = await TestToken.new('tst', 'A', Helper.expandTo18Decimals(10000));
    let weth = await WETH.new();

    let factory = await DMMFactory.new(accounts[0]);
    let router = await DMMRouter.new(factory.address, weth.address);
    // set up pool with 100 token and 30 eth
    await token.approve(router.address, Helper.MaxUint256);
    await router.addLiquidityNewPoolETH(
      token.address,
      new BN(15000),
      Helper.precisionUnits.mul(new BN(100)),
      new BN(0),
      new BN(0),
      accounts[0],
      Helper.MaxUint256,
      {
        value: Helper.expandTo18Decimals(30)
      }
    );
    const poolAddress = (await factory.getPools(token.address, weth.address))[0];
    // swap to change the ratio of the pool a bit
    await router.swapExactETHForTokens(
      new BN(0),
      [poolAddress],
      [weth.address, token.address],
      accounts[0],
      Helper.MaxUint256,
      {value: Helper.expandTo18Decimals(7)}
    );

    let zapIn = await ExampleZapIn.new(factory.address);
    await token.approve(zapIn.address, Helper.MaxUint256, {from: accounts[1]});

    let userIn = Helper.expandTo18Decimals(5);
    await token.transfer(accounts[1], userIn);

    await zapIn.zapIn(token.address, weth.address, userIn, poolAddress, {from: accounts[1]});
  });
});
