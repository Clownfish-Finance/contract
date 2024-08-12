const { expect } = require("chai");
const hre = require("hardhat");
const {
  loadFixture,
  time,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");

const AP_ACCOUNT_FACTORY = "ACCOUNT_FACTORY";

describe("Test", function () {
  async function deploy() {
    const linearInterestRateModel = await hre.ethers.deployContract(
      "LinearInterestRateModel",
      [
        5000, // U_1 (in basis points, e.g., 50%)
        8000, // U_2 (in basis points, e.g., 80%)
        200, // R_base (in basis points, e.g., 2%)
        400, // R_slope1 (in basis points, e.g., 4%)
        800, // R_slope2 (in basis points, e.g., 8%)
        1500, // R_slope3 (in basis points, e.g., 15%)
        true, // isBorrowingMoreU2Forbidden (whether to prevent borrowing over U_2 utilization)
      ]
    );

    const addressProvider = await hre.ethers.deployContract("AddressProvider");
    const accountFactory = await hre.ethers.deployContract("AccountFactory");
    const key = hre.ethers.encodeBytes32String(AP_ACCOUNT_FACTORY);
    await addressProvider.setAddress(key, accountFactory.target);

    const underlyingToken = await hre.ethers.deployContract("UnderlyingToken");
    const pool = await hre.ethers.deployContract("Pool", [
      addressProvider.target,
      underlyingToken.target,
      linearInterestRateModel.target,
      "pool_token",
      "pool_token_symbol",
    ]);
    const creditManager = await hre.ethers.deployContract("CreditManager", [
      addressProvider.target,
      pool.target,
    ]);
    const creditFacade = await hre.ethers.deployContract("CreditFacade", [
      creditManager.target,
    ]);
    // initialize
    await creditManager.setCreditFacade(creditFacade.target);
    await accountFactory.addCreditManager(creditManager.target);

    const [account1] = await hre.ethers.getSigners();

    return { creditFacade, accountFactory, account1 };
  }

  it("openCreditAccount not multicall", async function () {
    const { creditFacade, accountFactory, account1 } = await loadFixture(
      deploy
    );
    // listen event
    accountFactory.on(
      "AddCreditManager",
      (creditManager, masterCreditAccount) => {
        console.log("AddCreditManager");
        console.log("creditManager", creditManager);
        console.log("masterCreditAccount", masterCreditAccount);
      }
    );
    accountFactory.on("TakeCreditAccount", (creditAccount, creditManager) => {
      console.log("creditAccount", creditAccount);
      console.log("creditManager", creditManager);
    });

    // const addCollateralABI = creditFacade.interface.encodeFunctionData(
    //   "addCollateral",
    //   [underlying, DAI_ACCOUNT_AMOUNT / 4]
    // );

    // 构造 multicall 的调用数据
    // const callData = {
    //   target: targetAddress,
    //   callData: addCollateralABI,
    // };

    await creditFacade.openCreditAccount(account1, []);

    await delay(1000);
  });


  it("addCollateral multicall", async function () {
    
    
  })
});

function delay(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}
