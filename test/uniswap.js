const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Uniswap V3 Adapter Test", function () {
  let creditManager, creditFacade, uniswapV3Adapter;
  let owner, user;

  before(async function () {
    [owner, user] = await ethers.getSigners();

    // Deploy Credit Manager
    const CreditManager = await ethers.getContractFactory("CreditManager");
    creditManager = await CreditManager.deploy();
    await creditManager.deployed();

    // Deploy Credit Facade
    const CreditFacade = await ethers.getContractFactory("CreditFacade");
    creditFacade = await CreditFacade.deploy();
    await creditFacade.deployed();

    // Deploy Uniswap V3 Adapter
    const UniswapV3Adapter = await ethers.getContractFactory("UniswapV3Adapter");
    uniswapV3Adapter = await UniswapV3Adapter.deploy(creditManager.address);
    await uniswapV3Adapter.deployed();
  });

  it("should swap USDC to WETH using the Uniswap V3 Adapter", async function () {
    const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"; // Example address
    const WETH = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"; // Example address
    const MIN_SWAP_RATE = ethers.utils.parseUnits("1", 27); // Example rate

    // Prepare the multicall data
    const calls = [{
      target: uniswapV3Adapter.address,
      callData: uniswapV3Adapter.interface.encodeFunctionData("exactDiffInputSingle", [
        {
          tokenIn: USDC,
          tokenOut: WETH,
          fee: 500,
          deadline: Math.floor(Date.now() / 1000) + 60 * 20, // 20 minutes from now
          leftoverAmount: 1,
          rateMinRAY: MIN_SWAP_RATE,
        }
      ]),
    }];

    // Execute the multicall
    const tx = await creditFacade.connect(user).multicall(calls);
    await tx.wait();

    console.log("Swap executed successfully");

    // Further assertions or checks can be done here.
  });
});
