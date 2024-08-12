const { expect } = require("chai");
const hre = require("hardhat");
const {
  loadFixture,
  time,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");


const AP_ACCOUNT_FACTORY = "ACCOUNT_FACTORY";

describe("AccountFactory", function () {
  async function deployOneYearLockFixture() {
    const lockedAmount = 1_000_000_000;
    const ONE_YEAR_IN_SECS = 365 * 24 * 60 * 60;
    const unlockTime = (await time.latest()) + ONE_YEAR_IN_SECS;

    const accountFactory = await hre.ethers.deployContract("AccountFactory");
    const addressProvider = await hre.ethers.deployContract("AddressProvider");
    const creditManager = await hre.ethers.deployContract("CreditManager");
    const creditFacade = await hre.ethers.deployContract("CreditFacade");

    await addressProvider.setAddress(AP_ACCOUNT_FACTORY, accountFactory.target);


    return { lock, unlockTime, lockedAmount };
  }

  it("Should set the right unlockTime", async function () {
    const { lock, unlockTime } = await loadFixture(deployOneYearLockFixture);

    // assert that the value is correct
    expect(await lock.unlockTime()).to.equal(unlockTime);
  });
});